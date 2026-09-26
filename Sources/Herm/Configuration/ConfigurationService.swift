import Foundation

/// Read-only parser for a strict Dock-side configuration-health fixture boundary.
///
/// `hermes.configuration.health.v1` is not a verified Hermes contract or live
/// adapter. It remains unavailable for Hermes integration until Hermes exposes
/// and proves this structured schema.
enum ConfigurationService {
    private static let schema = "hermes.configuration.health.v1"
    private static let malformedMessage = "Configuration health output was malformed."
    private static let unavailableMessage = "Configuration health capability is unavailable."
    private static let unsupportedMessage = "Configuration health output format is unsupported."
    private static let staleMessage = "Configuration health snapshot is stale."

    static func parse(
        _ output: String,
        format: ConfigurationOutputFormat,
        capability: ConfigurationCapability = .available,
        observedAt: Date = .now,
        now: Date = .now,
        maxAge: TimeInterval = 300
    ) -> ConfigurationHealth {
        guard capability == .available else { return unavailable(capability: capability) }
        guard format == .json else {
            return ConfigurationHealth(state: .unsupported, diagnostic: unsupportedMessage)
        }
        do {
            return try parseVerifiedJSON(output, observedAt: observedAt, now: now, maxAge: maxAge)
        } catch {
            return ConfigurationHealth(state: .malformed, diagnostic: malformedMessage)
        }
    }

    /// Validates the strict Dock-side fixture shape only; this does not claim a
    /// live Hermes adapter or prove that Hermes exposes this schema.
    static func parseVerifiedJSON(
        _ output: String,
        observedAt: Date = .now,
        now: Date = .now,
        maxAge: TimeInterval = 300
    ) throws -> ConfigurationHealth {
        let decoded = try JSONDecoder().decode(Contract.self, from: Data(output.utf8))
        guard decoded.schema == schema,
              decoded.providers.allSatisfy({ safeIdentifier($0.id) }),
              decoded.models.allSatisfy({ safeIdentifier($0.id) }),
              decoded.credentials.allSatisfy({ safeIdentifier($0.provider) }),
              decoded.routing.fallbackCount >= 0
        else { throw ParseError.invalidContract }

        let isStale = now.timeIntervalSince(observedAt) > maxAge
        let state: ConfigurationHealthState = isStale ? .stale : .ready
        return ConfigurationHealth(
            state: state,
            providers: decoded.providers,
            models: decoded.models,
            routing: decoded.routing,
            credentials: decoded.credentials,
            diagnostic: isStale ? staleMessage : "Configuration health is ready."
        )
    }

    static func unavailable(capability: ConfigurationCapability) -> ConfigurationHealth {
        ConfigurationHealth(state: .unavailable, diagnostic: unavailableMessage)
    }

    static func mutationRequest(named _: String) -> ConfigurationMutationAvailability {
        .unavailable
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
              value.first?.isLetter == true || value.first?.isNumber == true else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    private enum ParseError: Error { case invalidContract }

    private struct Contract: Decodable {
        let schema: String
        let providers: [ProviderHealth]
        let models: [ModelAvailability]
        let routing: RoutingHealth
        let credentials: [CredentialPresence]

        private enum CodingKeys: String, CodingKey, CaseIterable { case schema, providers, models, routing, credentials }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schema = try container.decode(String.self, forKey: .schema)
            providers = try container.decode([ProviderHealth].self, forKey: .providers)
            models = try container.decode([ModelAvailability].self, forKey: .models)
            routing = try container.decode(RoutingHealth.self, forKey: .routing)
            credentials = try container.decode([CredentialPresence].self, forKey: .credentials)
            guard container.allKeys.count == CodingKeys.allCases.count else { throw ParseError.invalidContract }
        }
    }
}
