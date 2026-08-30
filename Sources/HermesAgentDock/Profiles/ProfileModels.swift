import Foundation

/// Stable, non-secret lifecycle states for profile and connection inventory.
enum HermesInventoryState: Equatable, Sendable {
    case ready
    case unavailable
    case unsupported
    case malformed
    case stale
}

/// A profile projection intentionally excludes paths, endpoints, credentials, and headers.
struct HermesProfileSummary: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let model: String?
    let isActive: Bool
    let state: HermesInventoryState

    init(name: String, model: String?, isActive: Bool = false, state: HermesInventoryState) {
        self.id = name
        self.name = name
        self.model = model
        self.isActive = isActive
        self.state = state
    }
}

/// A gateway connection projection intentionally contains only safe identity/status data.
struct HermesConnectionSummary: Equatable, Sendable, Identifiable {
    let id: String
    let label: String
    let profileName: String
    let transport: String
    let state: HermesInventoryState

    init(profileName: String, label: String? = nil, transport: String = "gateway", state: HermesInventoryState) {
        self.id = profileName
        self.label = label ?? profileName
        self.profileName = profileName
        self.transport = transport
        self.state = state
    }
}

struct HermesProfileInventory: Equatable, Sendable {
    let state: HermesInventoryState
    let profiles: [HermesProfileSummary]
    let connections: [HermesConnectionSummary]
    let diagnostic: String
}
