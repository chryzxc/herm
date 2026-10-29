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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                refreshButton
                layoutPicker
                botPicker.disabled(isLoading)
                newChatButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    refreshButton
                    layoutPicker
                }
                HStack(spacing: 8) {
                    botPicker.disabled(isLoading)
                    newChatButton
                }
            }
        }
        .dockButtonSize(.compact)
    }

    private var refreshButton: some View {
        DockIconButton(
            icon: .arrowsClockwise, label: "Refresh chats", isBusy: isRefreshing,
            size: DockControlMetrics.compactHeight,
            style: DockThemePalette(theme: DockThemeRuntime.current), action: onRefresh)
    }

    private var layoutPicker: some View {
        DockMenu(outlined: true) {
            DockMenuChoices(
                selection: Binding(get: { true }, set: { if !$0 { onShowList() } })
            ) {
                DockMenuOption("List", value: false)
                DockMenuOption("Tiles", value: true)
            }
        } label: {
            HStack(spacing: 6) {
                DockIconLabel("Tiles", icon: .squaresFour)
                DockIcon(.caretDown, size: 10, color: Color.dockMetadataText)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Chat layout, Tiles")
        .help("Change chat layout")
    }

    private var newChatButton: some View {
        Button(action: onNewConversation) {
            DockIconLabel("New chat", icon: .plus)
        }
        .buttonStyle(.dockPrimary)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isLoading)
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
                    BotAvatarView(bot: bot, imageData: bots.avatarImages[bot.id], size: 18, animated: false)
                        .accessibilityHidden(true)
                } else {
                    BotFaceMark(id: selectedID, size: 18, animated: false, mood: .idle)
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
