import SwiftUI

struct SessionDashboardToolbar: View {
    let isLoading: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onNewConversation: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                refreshButton
                newChatButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    refreshButton
                }
                newChatButton
            }
        }
        .dockButtonSize(.compact)
    }

    private var refreshButton: some View {
        DockIconButton(
            icon: .arrowsClockwise, label: "Refresh chats", isBusy: isRefreshing, hasBackground: false,
            size: DockControlMetrics.compactHeight,
            style: DockThemePalette(theme: DockThemeRuntime.current), action: onRefresh)
    }

    private var newChatButton: some View {
        Button(action: onNewConversation) {
            DockIconLabel("New chat", icon: .plus)
        }
        .buttonStyle(.dockPrimary)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isLoading)
    }
}
