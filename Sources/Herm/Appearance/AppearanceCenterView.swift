import SwiftUI

/// Appearance inventory presentation. Controls remain visibly unavailable until
/// a verified Hermes command contract exists; this view never changes Dock colors.
public struct AppearanceCenterView: View {
    public let inventory: AppearanceInventory?
    public let onRefresh: () -> Void

    public init(inventory: AppearanceInventory? = nil, onRefresh: @escaping () -> Void = {}) {
        self.inventory = inventory
        self.onRefresh = onRefresh
    }

    public var body: some View {
        Form {
            Section("Hermes appearance") {
                if let inventory {
                    LabeledContent("State", value: inventory.state.rawValue.capitalized)
                    LabeledContent("Active skin", value: inventory.activeSkinID ?? "None reported")
                    Button("Refresh", action: onRefresh)
                } else {
                    Text("No verified Hermes appearance inventory is available.")
                        .foregroundStyle(Color.dockSecondaryText)
                    Button("Refresh", action: onRefresh)
                }
            }
            if let inventory {
                Section("Installed skins") {
                    if inventory.skins.isEmpty { Text("None reported").foregroundStyle(Color.dockSecondaryText) }
                    ForEach(inventory.skins, id: \.id) { skin in
                        LabeledContent(skin.name, value: skin.isActive ? "Active" : "Installed")
                    }
                }
                Section("Pets") {
                    if inventory.pets.isEmpty { Text("None reported").foregroundStyle(Color.dockSecondaryText) }
                    ForEach(inventory.pets, id: \.id) { pet in
                        LabeledContent(pet.name, value: pet.isActive ? "Active" : "Installed")
                    }
                }
                Section("Desktop plugins") {
                    if inventory.desktopPlugins.isEmpty { Text("None reported").foregroundStyle(Color.dockSecondaryText) }
                    ForEach(inventory.desktopPlugins, id: \.id) { plugin in
                        VStack(alignment: .leading, spacing: 3) {
                            LabeledContent(plugin.name, value: plugin.status.rawValue.capitalized)
                            Text("\(plugin.mode.rawValue.capitalized) plugin")
                                .font(.caption)
                                .foregroundStyle(Color.dockSecondaryText)
                        }
                    }
                }
            }
            Section("Unavailable actions") {
                Text("Skin and pet selection, and desktop-plugin enable/reload, require a verified Hermes command contract. No configuration is edited locally.")
                    .font(.caption)
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Appearance")
        .foregroundStyle(Color.dockPrimaryText)
        .tint(Color.dockAccent)
        .background(Color.dockCanvas)
    }
}

#Preview {
    AppearanceCenterView()
}
