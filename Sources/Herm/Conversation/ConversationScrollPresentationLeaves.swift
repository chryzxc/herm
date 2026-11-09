import SwiftUI

struct ConversationLatestMessageControl: View {
    @ObservedObject var presentation: ConversationScrollPresentationState
    var isWorking = false
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if presentation.showsLatestControl {
                let unread = presentation.unseenMessageCount
                Button(action: onSelect) {
                    HStack(spacing: 7) {
                        DockIcon(.arrowDown, size: 11, color: Color.dockPrimaryText)
                            .frame(width: 22, height: 22)
                        if unread > 0 {
                            Text("\(unread) new \(unread == 1 ? "message" : "messages")")
                                .dockFont(.body, weight: .semibold)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(Color.dockPrimaryText)
                    .dockPadding(.horizontal, unread > 0 ? 14 : 0)
                    .frame(minWidth: 34, minHeight: 34)
                    .background(
                        Capsule()
                            .fill(Color.dockOpaqueCanvas)
                            .overlay(Capsule().fill(Color.dockControlSurface))
                            .overlay(Capsule().stroke(Color.dockBorder, lineWidth: DockLayout.outline))
                    )
                    .overlay {
                        if unread > 0 || isWorking {
                            DockLayerMotion(
                                kind: .capsuleRim(period: 2.4, lineWidth: 1),
                                color: .dockAccent, glow: Color.dockAccent.opacity(0.45)
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .animation(DockMotion.animation(reduceMotion: reduceMotion), value: unread)
                }
                .buttonStyle(.dockHover)
                .help("Scroll to bottom")
                .accessibilityLabel(unread > 0 ? "Scroll to bottom, \(unread) new" : "Scroll to bottom")
                .accessibilityValue(isWorking ? "Response in progress" : "")
                .transition(
                    .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
                        .combined(with: .offset(y: DockMotion.revealDistance))
                )
                .dockPadding(.bottom, 12)
            }
        }
        .animation(DockMotion.animation(reduceMotion: reduceMotion), value: presentation.showsLatestControl)
    }
}

/// SwiftUI re-hit-tests every hover region on each scroll frame, so rows
/// ignore the pointer until the scroll settles.
struct ConversationScrollHitTesting: ViewModifier {
    @ObservedObject var presentation: ConversationScrollPresentationState

    func body(content: Content) -> some View {
        content.allowsHitTesting(!presentation.isUserScrolling)
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
