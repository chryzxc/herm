import Foundation

@MainActor
final class HermesCapabilityService {
    func probe(client: HermesRPCClientProtocol, remindersAvailable: Bool) async -> [CapabilityState] {
        let toolResult = await request(client, method: "tools.list")
        let pluginResult = await request(client, method: "plugins.list")
        let configResult = await request(client, method: "config.show")
        let notesResult = await request(client, method: "shell.exec", params: ["command": "memo --version"])
        let emailResult = await request(client, method: "shell.exec", params: ["command": "himalaya --version"])
        let imessageResult = await request(client, method: "shell.exec", params: ["command": "imsg --version"])
        let version = (configResult?["version"] as? String)
            ?? (configResult?["hermes_version"] as? String)

        return [
            CapabilityState(
                id: "gateway",
                title: "Hermes gateway",
                detail: configResult == nil ? "Gateway health is unavailable" : "Gateway is responding",
                isAvailable: configResult != nil,
                recovery: configResult == nil ? "Reconnect Hermes and refresh Core." : nil
            ),
            CapabilityState(
                id: "hermes-version",
                title: "Hermes version",
                detail: version ?? "Version information is unavailable",
                isAvailable: version != nil,
                recovery: version == nil ? "Update Hermes manually if a newer version is required." : nil
            ),
            CapabilityState(
                id: "reminders",
                title: "Apple Reminders",
                detail: remindersAvailable ? "Connected through remindctl" : "remindctl is unavailable or unauthorized",
                isAvailable: remindersAvailable,
                recovery: remindersAvailable ? nil : "Install remindctl and authorize Reminders access."
            ),
            CapabilityState(
                id: "notes",
                title: "Apple Notes",
                detail: notesResult == nil ? "memo is unavailable or unauthorized" : "Available through memo and the Hermes apple-notes skill",
                isAvailable: notesResult != nil,
                recovery: notesResult == nil ? "Install memo and authorize Notes access." : nil
            ),
            CapabilityState(
                id: "tools",
                title: "Hermes tools",
                detail: toolResult == nil ? "Tool catalogue is unavailable" : "Tool catalogue available",
                isAvailable: toolResult != nil,
                recovery: toolResult == nil ? "This Hermes version may not support tools.list." : nil
            ),
            CapabilityState(
                id: "plugins",
                title: "Hermes plugins",
                detail: pluginResult == nil ? "Plugin catalogue is unavailable" : "Plugin catalogue available",
                isAvailable: pluginResult != nil,
                recovery: pluginResult == nil ? "This Hermes version may not support plugins.list." : nil
            ),
            CapabilityState(
                id: "calendar",
                title: "Calendar",
                detail: "No Hermes Calendar provider is configured",
                isAvailable: false,
                recovery: "Calendar integration is planned for a future provider."
            ),
            CapabilityState(
                id: "messaging",
                title: "Messaging",
                detail: imessageResult == nil ? "imsg is unavailable or unauthorized" : "iMessage CLI is available through Hermes",
                isAvailable: imessageResult != nil,
                recovery: imessageResult == nil ? "Install imsg and grant Messages access." : nil
            ),
            CapabilityState(
                id: "email",
                title: "Email",
                detail: emailResult == nil ? "himalaya is unavailable or unconfigured" : "Email CLI is available through Hermes",
                isAvailable: emailResult != nil,
                recovery: emailResult == nil ? "Install and configure himalaya before enabling email actions." : nil
            ),
            CapabilityState(
                id: "kanban",
                title: "Hermes Kanban",
                detail: "The installed gateway does not expose Kanban RPC methods",
                isAvailable: false,
                recovery: "Kanban integration will activate when Hermes exposes a desktop RPC surface."
            ),
            CapabilityState(
                id: "mcp",
                title: "Third-party MCP",
                detail: pluginResult == nil ? "MCP/plugin state is unavailable" : "Use Hermes MCP configuration for third-party services",
                isAvailable: pluginResult != nil,
                recovery: pluginResult == nil ? "Reconnect Hermes and configure MCP servers there." : nil
            )
        ]
    }

    private func request(_ client: HermesRPCClientProtocol, method: String, params: [String: Any] = [:]) async -> [String: Any]? {
        try? await client.request(method, params: params)
    }
}
