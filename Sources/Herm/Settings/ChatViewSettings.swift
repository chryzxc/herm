import SwiftUI

struct ChatViewSettings: View {
    static let gridViewKey = "herm.chats.gridView"
    @AppStorage(gridViewKey) private var gridView = false
    @AppStorage(SidebarGrouping.preferenceKey) private var grouping: SidebarGrouping = .agent

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
        SettingsPreferenceRow(
            title: "Group chats by",
            detail:
                "With more than one bot, Agent shows one row per bot that expands into its running, unread, and recent chats. Session lists every bot's chats together, newest first."
        ) {
            Picker("Group chats by", selection: $grouping) {
                ForEach(SidebarGrouping.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
    }
}
