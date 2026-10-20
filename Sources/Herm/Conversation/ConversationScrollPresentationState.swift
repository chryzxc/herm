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

    func reset() {
        isAtBottom = true
        unseenMessageCount = 0
        visibleTargets = []
    }
}
