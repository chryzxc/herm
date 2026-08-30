import SwiftUI

/// Read-only MCP/plugin inventory surface. The view deliberately does not
/// expose configuration or third-party tool invocation controls: Hermes
/// v0.20.6 has no verified contract for those operations.
public struct ExtensionsCenterView: View {
    private let inventory: MCPExtensionInventory?
    private let service: MCPExtensionService

    public init(inventory: MCPExtensionInventory? = nil, service: MCPExtensionService = MCPExtensionService()) {
        self.inventory = inventory
        self.service = service
    }

    public var body: some View {
        List {
            Section("MCP servers") {
                if let inventory, !inventory.servers.isEmpty {
                    ForEach(inventory.servers, id: \.id) { server in
                        inventoryRow(id: server.id, name: server.name, status: server.connection.rawValue,
                                     capabilities: server.capabilities.map(\.rawValue))
                    }
                } else {
                    emptyRow("No MCP server inventory is available.")
                }
            }

            Section("Plugins") {
                if let inventory, !inventory.plugins.isEmpty {
                    ForEach(inventory.plugins, id: \.id) { plugin in
                        inventoryRow(id: plugin.id, name: plugin.name, status: plugin.status.rawValue,
                                     capabilities: plugin.capabilities.map(\.rawValue))
                    }
                } else {
                    emptyRow("No plugin inventory is available.")
                }
            }

            Section("Actions") {
                Label("Server and plugin changes are unavailable until Hermes exposes a verified contract.", systemImage: "lock.slash")
                    .foregroundStyle(.secondary)
                Label("Third-party MCP tool invocation is upstream-blocked until Hermes exposes a structured catalog and invocation schema.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Extensions")
        .overlay {
            if inventory == nil {
                ContentUnavailableView("Extensions unavailable", systemImage: "puzzlepiece.extension",
                                       description: Text("Refresh from Hermes to load a typed MCP/plugin inventory."))
            }
        }
    }

    @ViewBuilder
    private func inventoryRow(id: String, name: String, status: String, capabilities: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.headline)
            HStack {
                Text(status.capitalized)
                if !capabilities.isEmpty {
                    Text(capabilities.joined(separator: " · "))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(id)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func emptyRow(_ text: String) -> some View {
        Label(text, systemImage: "minus.circle")
            .foregroundStyle(.secondary)
    }
}

#Preview {
    ExtensionsCenterView()
}
