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
                DockIconLabel("Server and plugin changes are unavailable until Hermes exposes a verified contract.", icon: .lockOpen)
                    .foregroundStyle(Color.dockSecondaryText)
                DockIconLabel("Third-party MCP tool invocation is upstream-blocked until Hermes exposes a structured catalog and invocation schema.", icon: .warning)
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .foregroundStyle(Color.dockPrimaryText)
        .tint(Color.dockAccent)
        .background(Color.dockCanvas)
        .navigationTitle("Extensions")
        .overlay {
            if inventory == nil {
                VStack(spacing: 10) {
                    DockIcon(.sparkle, size: 28, color: .dockSecondaryText)
                    Text("Extensions unavailable")
                        .font(.headline)
                    Text("Refresh from Hermes to load a typed MCP/plugin inventory.")
                        .font(.subheadline)
                        .foregroundStyle(Color.dockSecondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
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
            .foregroundStyle(Color.dockSecondaryText)
            Text(id)
                .font(.caption2)
                .foregroundStyle(Color.dockMetadataText)
        }
        .accessibilityElement(children: .combine)
    }

    private func emptyRow(_ text: String) -> some View {
        DockIconLabel(text, icon: .minusCircle)
            .foregroundStyle(Color.dockSecondaryText)
    }

}

#Preview {
    ExtensionsCenterView()
}
