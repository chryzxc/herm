import SwiftUI

struct SessionDashboardToolbar: View {
    @ObservedObject var bots: BotModeModel
    let fallbackName: String
    let isLoading: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onShowList: () -> Void
    let onNewConversation: () -> Void

    private var selectedID: String { bots.selectedProfileID ?? "default" }
    private var selectedBot: BotSummary? { bots.botsByID[selectedID] }
    private var name: String { selectedBot?.name ?? fallbackName }

    var body: some View {
        HStack(spacing: 12) {
            DockIconButton(
                icon: .arrowsClockwise, label: "Refresh chats", isBusy: isRefreshing, size: 36,
                style: DockThemePalette(theme: DockThemeRuntime.current), action: onRefresh)
            DockSegmentedPicker(
                selection: Binding(get: { true }, set: { if !$0 { onShowList() } }),
                options: [(false, "List"), (true, "Tiles")]
            )
            .padding(3)
            .background(DockThemeShape(cornerRadius: DockLayout.controlRadius).fill(Color.dockControlSurface))
            .accessibilityLabel("Chat layout")
            Color.dockBorderLight.frame(width: DockLayout.hairline, height: 20)
            botPicker
                .disabled(isLoading)
            Button(action: onNewConversation) {
                DockIconLabel("New chat", icon: .plus)
            }
            .buttonStyle(.dockPrimary)
            .disabled(isLoading)
        }
        .dockButtonSize(.standard)
    }

    private var botPicker: some View {
        DockMenu(outlined: true) {
            if bots.bots.isEmpty {
                Button(name) { bots.selectProfile(selectedID) }
            }
            ForEach(bots.bots.filter { !$0.isHidden }) { bot in
                Button {
                    bots.selectProfile(bot.id)
                } label: {
                    HStack(spacing: 8) {
                        BotAvatarView(bot: bot, imageData: bots.avatarImages[bot.id], size: 22, animated: false)
                            .accessibilityHidden(true)
                        Text(bot.name).lineLimit(1)
                        Spacer(minLength: 12)
                        DockIcon(.check, size: 12, color: Color.dockSecondaryText)
                            .opacity(bot.id == selectedID ? 1 : 0)
                    }
                }
                .accessibilityValue(bot.id == selectedID ? "Selected" : "")
            }
        } label: {
            HStack(spacing: 8) {
                if let bot = selectedBot {
                    BotAvatarView(bot: bot, imageData: bots.avatarImages[bot.id], size: 22, animated: false)
                        .accessibilityHidden(true)
                } else {
                    BotFaceMark(id: selectedID, size: 22, animated: false, mood: .idle)
                        .accessibilityHidden(true)
                }
                Text(name).lineLimit(1).truncationMode(.tail).frame(maxWidth: 140)
                DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
            }
        }
        .accessibilityLabel("Choose bot, \(name)")
        .help("Choose bot")
    }
}
