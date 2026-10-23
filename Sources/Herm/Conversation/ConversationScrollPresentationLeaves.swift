import SwiftUI

struct ConversationLatestMessageControl: View {
    @ObservedObject var presentation: ConversationScrollPresentationState
    let onSelect: () -> Void

    var body: some View {
        if presentation.unseenMessageCount > 0 {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    DockIcon(.arrowDown, size: 11, color: Color.dockPrimaryText)
                    Text("\(presentation.unseenMessageCount) new \(presentation.unseenMessageCount == 1 ? "message" : "messages")")
                        .dockFont(.body, weight: .semibold)
                }
                .foregroundStyle(Color.dockPrimaryText)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(Color.dockControlSurface).stroke(Color.dockBorder, lineWidth: DockLayout.outline))
            }
            .buttonStyle(.dockHover)
            .padding(.bottom, 12)
        }
    }
}

struct ConversationScrollNavigator: View {
    @ObservedObject var presentation: ConversationScrollPresentationState
    let items: [MessageNavigatorItem]
    let sessionID: String
    @Binding var isSearchPresented: Bool
    let showsMap: Bool
    let isLoadingHistory: Bool
    let onSearch: () -> Void
    let onSelect: (MessageNavigatorItem) -> Void

    var body: some View {
        MessageNavigatorView(
            items: items,
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
