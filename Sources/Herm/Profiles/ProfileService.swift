import Foundation

/// Read-only profile/gateway inventory adapter.
///
/// Hermes v0.20.6 exposes human-oriented profile and gateway tables through the
/// CLI and does not advertise a profile-inventory RPC. Consequently this service
/// accepts only the narrow structured snapshot supplied by a verified caller;
/// it never guesses from display tables or invents an RPC method.
enum HermesProfileInputFormat: Sendable {
    case json
    case humanTable
}

enum HermesProfileService {
    private static let unavailableDiagnostic = "Inventory is unavailable."

    static func parse(_ output: String, format: HermesProfileInputFormat) -> HermesProfileInventory {
        switch format {
        case .humanTable:
            return HermesProfileInventory(
                state: .unsupported, profiles: [], connections: [],
                diagnostic: "Human-readable inventory is unsupported.")
        case .json:
            do {
                return try parseVerifiedJSON(output)
            } catch {
                return HermesProfileInventory(
                    state: .malformed, profiles: [], connections: [], diagnostic: "Structured inventory was malformed.")
            }
        }
    }

    static func unavailable(reason: String = "Inventory is unavailable.") -> HermesProfileInventory {
        HermesProfileInventory(
            state: .unavailable,
            profiles: [],
            connections: [],
            diagnostic: unavailableDiagnostic
        )
    }

    static func parseVerifiedJSON(
        _ output: String,
        observedAt: Date = Date(),
        now: Date = Date(),
        maxAge: TimeInterval = 300
    ) throws -> HermesProfileInventory {
        guard let data = output.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == ["profiles", "connections"],
            let rawProfiles = object["profiles"] as? [[String: Any]],
            let rawConnections = object["connections"] as? [[String: Any]]
        else {
            throw ParseError.invalid
        }

        var profiles: [HermesProfileSummary] = []
        for raw in rawProfiles {
            guard Set(raw.keys).isSubset(of: ["name", "model", "gateway", "is_active"]),
                let name = raw["name"] as? String, safeIdentifier(name),
                let gateway = raw["gateway"] as? String, safeIdentifier(gateway)
            else { throw ParseError.invalid }

            let model: String?
            if let rawModel = raw["model"] {
                guard let value = rawModel as? String, safeModel(value) else { throw ParseError.invalid }
                model = value
            } else {
                model = nil
            }

            let isActive: Bool
            if let rawIsActive = raw["is_active"] {
                guard let value = rawIsActive as? Bool else { throw ParseError.invalid }
                isActive = value
            } else {
                isActive = false
            }
            profiles.append(
                HermesProfileSummary(name: name, model: model, isActive: isActive, state: state(for: gateway)))
        }

        var connections: [HermesConnectionSummary] = []
        for raw in rawConnections {
            guard Set(raw.keys).isSubset(of: ["profile", "status", "label", "transport"]),
                let profileName = raw["profile"] as? String, safeIdentifier(profileName),
                let status = raw["status"] as? String, safeIdentifier(status)
            else { throw ParseError.invalid }

            let label: String?
            if let rawLabel = raw["label"] {
                guard let value = rawLabel as? String, safeIdentifier(value) else { throw ParseError.invalid }
                label = value
            } else {
                label = nil
            }

            let transport: String
            if let rawTransport = raw["transport"] {
                guard let value = rawTransport as? String, safeIdentifier(value) else { throw ParseError.invalid }
                transport = value
            } else {
                transport = "gateway"
            }
            connections.append(
                HermesConnectionSummary(
                    profileName: profileName, label: label, transport: transport, state: state(for: status)))
        }

        let stale = maxAge >= 0 && now.timeIntervalSince(observedAt) > maxAge
        return HermesProfileInventory(
            state: stale ? .stale : .ready,
            profiles: profiles,
            connections: connections,
            diagnostic: stale ? "Inventory is stale; refresh is required." : ""
        )
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128,
            value.first?.isLetter == true || value.first?.isNumber == true
        else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || ".:_-".contains($0) }
    }

    private static func safeModel(_ value: String) -> Bool {
        guard safeIdentifier(value),
            !value.lowercased().contains("token"),
            !value.lowercased().contains("secret")
        else { return false }
        return true
    }

    private static func state(for value: String) -> HermesInventoryState {
        switch value.lowercased() {
        case "ready", "running", "connected", "online": return .ready
        case "unavailable", "stopped", "disconnected", "offline": return .unavailable
        case "unsupported": return .unsupported
        case "malformed": return .malformed
        case "stale": return .stale
        default: return .unavailable
        }
    }

    private enum ParseError: Error { case invalid }
}
