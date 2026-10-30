import SwiftUI

struct ConversationLatestMessageControl: View {
    @ObservedObject var presentation: ConversationScrollPresentationState
    let onSelect: () -> Void

    var body: some View {
        if presentation.showsLatestControl {
            let unread = presentation.unseenMessageCount
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    DockIcon(.arrowDown, size: 11, color: Color.dockPrimaryText)
                    if unread > 0 {
                        Text("\(unread) new \(unread == 1 ? "message" : "messages")")
                            .dockFont(.body, weight: .semibold)
                    }
                }
                .foregroundStyle(Color.dockPrimaryText)
                .dockPadding(.horizontal, unread > 0 ? 14 : 0)
                .frame(minWidth: 34, minHeight: 34)
                .background(
                    Capsule()
                        .fill(Color.dockOpaqueCanvas)
                        .overlay(Capsule().fill(Color.dockControlSurface))
                        .overlay(Capsule().stroke(Color.dockBorder, lineWidth: DockLayout.outline)))
            }
            .buttonStyle(.dockHover)
            .help("Scroll to bottom")
            .accessibilityLabel(unread > 0 ? "Scroll to bottom, \(unread) new" : "Scroll to bottom")
            .dockPadding(.bottom, 12)
        }
    }
}

struct ConversationScrollNavigator: View {
    @ObservedObject var presentation: ConversationScrollPresentationState
    let snapshot: MessageNavigatorSnapshot
    let sessionID: String
    @Binding var isSearchPresented: Bool
    let showsMap: Bool
    let isLoadingHistory: Bool
    let onSearch: () -> Void
    let onSelect: (MessageNavigatorItem) -> Void

    var body: some View {
        MessageNavigatorView(
            snapshot: snapshot,
            sessionID: sessionID,
            visibleTargets: presentation.visibleTargets,
            isSearchPresented: $isSearchPresented,
            showsMap: showsMap,
            isLoadingHistory: isLoadingHistory,
            onSearch: onSearch,
            onSelect: onSelect
        )
    }
}
