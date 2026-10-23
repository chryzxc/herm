import Combine

/// Only the scroll controls observe this object. The transcript owner keeps an
/// unobserved reference so settled geometry does not invalidate its message rows.
@MainActor
final class ConversationScrollPresentationState: ObservableObject {
    @Published private var atBottom = true
    @Published private var unreadCount = 0
    @Published private var targets: Set<MessageNavigatorTarget> = []

    var isAtBottom: Bool {
        get { atBottom }
        set {
            guard newValue != atBottom else { return }
            atBottom = newValue
        }
    }

    var unseenMessageCount: Int {
        get { unreadCount }
        set {
            guard newValue != unreadCount else { return }
            unreadCount = newValue
        }
    }

    var visibleTargets: Set<MessageNavigatorTarget> {
        get { targets }
        set {
            guard newValue != targets else { return }
            targets = newValue
        }
    }

    func updatePosition(_ geometry: ConversationScrollGeometry, isLiveTail: Bool) {
        // Content growth must not disable follow before the next layout scroll.
        // The native scroll observer clears it as soon as the reader scrolls up.
        isAtBottom =
            isLiveTail
            && (isAtBottom
                || ConversationScrollMetrics.isAtBottom(
                    topMinY: -geometry.visibleTop,
                    bottomMaxY: geometry.documentHeight - geometry.visibleTop,
                    viewportHeight: geometry.visibleHeight,
                    tolerance: ConversationScrollMetrics.pastEndTolerance
                ))
        if isAtBottom { unseenMessageCount = 0 }
    }

    func reset() {
        isAtBottom = true
        unseenMessageCount = 0
        visibleTargets = []
    }
}
