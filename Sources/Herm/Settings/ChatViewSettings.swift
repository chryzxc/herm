import SwiftUI

struct ChatViewSettings: View {
    static let gridViewKey = "herm.chats.gridView"
    @AppStorage(gridViewKey) private var gridView = false

    var body: some View {
        SettingsPreferenceRow(
            title: "Default chat view",
            detail:
                "Choose how Chats opens. List shows a conversation beside your sessions; Grid shows updates from multiple chats."
        ) {
            Picker("Default chat view", selection: $gridView) {
                Text("List").tag(false)
                Text("Grid").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
    }
}
