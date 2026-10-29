import SwiftUI

struct ChatViewSettings: View {
    static let gridViewKey = "herm.chats.gridView"
    @AppStorage(gridViewKey) private var gridView = false

    var body: some View {
        SettingsPreferenceRow(
            title: "Default chat view",
            detail:
                "Choose how Chats opens. List shows a conversation beside your sessions; Tiles show every chat's status, requests, and latest reply, with inline answers and replies."
        ) {
            Picker("Default chat view", selection: $gridView) {
                Text("List").tag(false)
                Text("Tiles").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
    }
}
