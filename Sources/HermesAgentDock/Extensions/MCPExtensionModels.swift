import Foundation

public enum MCPExtensionCapability: String, Codable, CaseIterable, Equatable, Sendable {
    case tools
    case platform
    case commands
}

public enum MCPExtensionInventoryState: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case unavailable
    case unsupported
    case malformed
    case stale
}


public enum MCPConnectionStatus: String, Codable, Equatable, Sendable {
    case connected
    case failed
    case denied
    case unknown
}

public enum MCPPluginStatus: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
    case denied
    case unknown
}

public struct MCPServerInventory: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let connection: MCPConnectionStatus
    public let capabilities: [MCPExtensionCapability]

    public init(id: String, name: String, connection: MCPConnectionStatus, capabilities: [MCPExtensionCapability]) {
        self.id = id; self.name = name; self.connection = connection; self.capabilities = capabilities
    }
}

public struct MCPPluginInventory: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: MCPPluginStatus
    public let capabilities: [MCPExtensionCapability]

    public init(id: String, name: String, status: MCPPluginStatus, capabilities: [MCPExtensionCapability]) {
        self.id = id; self.name = name; self.status = status; self.capabilities = capabilities
    }
}

public struct MCPExtensionInventory: Codable, Equatable, Sendable {
    public let state: MCPExtensionInventoryState
    public let servers: [MCPServerInventory]
    public let plugins: [MCPPluginInventory]

    public init(state: MCPExtensionInventoryState, servers: [MCPServerInventory], plugins: [MCPPluginInventory]) {
        self.state = state
        self.servers = servers
        self.plugins = plugins
    }

    /// A bounded presentation summary safe for diagnostics.
    public var safeSummary: String {
        let serverLabel = servers.count == 1 ? "server" : "servers"
        let pluginLabel = plugins.count == 1 ? "plugin" : "plugins"
        return "\(servers.count) \(serverLabel) · \(plugins.count) \(pluginLabel) · \(state.rawValue)"
    }
}
