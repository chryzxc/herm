import Foundation

enum HermesGatewaySnapshotState: String, Codable, Equatable, Sendable { case ready, unavailable, unsupported, malformed, stale, disconnected, unpaired }
enum HermesGatewayInputFormat: Sendable { case json, humanTable }

enum HermesGatewayOperationResult: Equatable, Sendable { case performed, confirmationRequired, unavailable }

struct HermesLastSafeEvent: Equatable, Sendable {
    let kind: String
    let at: String
}

struct HermesChannelSummary: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    let connected: Bool
    let pairingRequired: Bool
    let authRequired: Bool
    let diagnostic: String
    let lastEvent: HermesLastSafeEvent?
}

struct HermesPeerSummary: Equatable, Sendable, Identifiable {
    let id: String
    let state: HermesGatewaySnapshotState
    let diagnostic: String
}

struct HermesGatewaySnapshot: Equatable, Sendable {
    let state: HermesGatewaySnapshotState
    let diagnostic: String
    let channels: [HermesChannelSummary]
    let peers: [HermesPeerSummary]
    let observedAt: Date?
}

enum HermesGatewaySafety {
    static func safe(_ value: String, max: Int = 160) -> Bool {
        guard value.count <= max, !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        let lower = value.lowercased()
        return !["token", "secret", "credential", "password", "bearer", "private message", "phone"].contains(where: { lower.contains($0) })
            && !value.contains("/") && !value.contains("\\")
    }
    static func state(_ value: String) -> HermesGatewaySnapshotState {
        switch value.lowercased() {
        case "ready", "online", "connected", "running": return .ready
        case "unpaired": return .unpaired
        case "disconnected", "offline", "stopped": return .disconnected
        case "unsupported": return .unsupported
        case "stale": return .stale
        default: return .unavailable
        }
    }
}
