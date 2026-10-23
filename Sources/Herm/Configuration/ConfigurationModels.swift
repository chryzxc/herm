import Foundation

enum ConfigurationHealthState: String, Codable, Equatable, Sendable {
    case ready
    case unavailable
    case unsupported
    case malformed
    case stale
}

enum ConfigurationOutputFormat: Sendable { case json, humanTable, yaml }
enum ConfigurationCapability: Equatable, Sendable { case available, missing, denied }
enum ConfigurationMutationAvailability: Equatable, Sendable { case unavailable }

struct ProviderHealth: Decodable, Equatable, Sendable {
    let id: String
    let state: ConfigurationHealthState
    private enum Keys: String, CodingKey, CaseIterable { case id, state }
    init(id: String, state: ConfigurationHealthState) {
        self.id = id
        self.state = state
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(ConfigurationHealthState.self, forKey: .state)
        guard c.allKeys.count == Keys.allCases.count else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Unexpected field")
        }
    }
}

struct ModelAvailability: Decodable, Equatable, Sendable {
    let id: String
    let state: ConfigurationHealthState
    private enum Keys: String, CodingKey, CaseIterable { case id, state }
    init(id: String, state: ConfigurationHealthState) {
        self.id = id
        self.state = state
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        state = try c.decode(ConfigurationHealthState.self, forKey: .state)
        guard c.allKeys.count == Keys.allCases.count else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Unexpected field")
        }
    }
}

struct RoutingHealth: Decodable, Equatable, Sendable {
    let state: ConfigurationHealthState
    let fallbackCount: Int
    private enum Keys: String, CodingKey, CaseIterable { case state, fallbackCount }
    init(state: ConfigurationHealthState, fallbackCount: Int) {
        self.state = state
        self.fallbackCount = fallbackCount
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = try c.decode(ConfigurationHealthState.self, forKey: .state)
        fallbackCount = try c.decode(Int.self, forKey: .fallbackCount)
        guard c.allKeys.count == Keys.allCases.count else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: c, debugDescription: "Unexpected field")
        }
    }
}

/// Credential values are deliberately represented only by presence.
struct CredentialPresence: Decodable, Equatable, Sendable {
    let provider: String
    let present: Bool
    private enum Keys: String, CodingKey, CaseIterable { case provider, present }
    init(provider: String, present: Bool) {
        self.provider = provider
        self.present = present
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        provider = try c.decode(String.self, forKey: .provider)
        present = try c.decode(Bool.self, forKey: .present)
        guard c.allKeys.count == Keys.allCases.count else {
            throw DecodingError.dataCorruptedError(forKey: .provider, in: c, debugDescription: "Unexpected field")
        }
    }
}

struct ConfigurationHealth: Equatable, Sendable {
    let state: ConfigurationHealthState
    let providers: [ProviderHealth]
    let models: [ModelAvailability]
    let routing: RoutingHealth
    let credentials: [CredentialPresence]
    let diagnostic: String

    init(
        state: ConfigurationHealthState, providers: [ProviderHealth] = [], models: [ModelAvailability] = [],
        routing: RoutingHealth? = nil, credentials: [CredentialPresence] = [], diagnostic: String
    ) {
        self.state = state
        self.providers = providers
        self.models = models
        self.routing = routing ?? RoutingHealth(state: state, fallbackCount: 0)
        self.credentials = credentials
        self.diagnostic = diagnostic
    }
}
