import SwiftUI

struct ChatViewSettings: View {
    static let gridViewKey = "herm.chats.gridView"
    @AppStorage(gridViewKey) private var gridView = false

    var body: some View {
        chatViewRow
    }

    private var chatViewRow: some View {
        SettingsPreferenceRow(
            title: "Default chat view",
            detail:
                "Choose how Chats opens. List shows a conversation beside your sessions; Tiles show every chat's status, requests, and latest reply, with inline answers and replies."
        ) {
            DockSegmentedPicker(selection: $gridView, options: [(false, "List"), (true, "Tiles")])
        }
    }
}
