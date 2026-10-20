import Combine
import Testing
import Foundation
@testable import Herm

@MainActor
struct ConversationScrollPresentationStateTests {
    @Test func equalSettleResultsDoNotPublish() {
        let state = ConversationScrollPresentationState()
        let target = MessageNavigatorTarget(sessionID: "session", messageID: UUID())
        state.isAtBottom = false
        state.visibleTargets = [target]
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        for _ in 0..<100 {
            state.isAtBottom = false
            state.visibleTargets = [target]
            state.unseenMessageCount = 0
        }
        #expect(publications == 0)
        #expect(state.visibleTargets == [target])
    }

    @Test func changedPresentationPublishesAndRepinningClearsUnread() {
        let state = ConversationScrollPresentationState()
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        state.isAtBottom = false
        state.unseenMessageCount += 1
        state.unseenMessageCount += 2
        #expect(!state.isAtBottom)
        #expect(state.unseenMessageCount == 3)
        #expect(publications == 3)

        state.isAtBottom = true
        state.unseenMessageCount = 0
        #expect(state.isAtBottom)
        #expect(state.unseenMessageCount == 0)
        #expect(publications == 5)
    }

    @Test func changedVisibilityPublishesWithoutChangingPositionOrUnread() {
        let state = ConversationScrollPresentationState()
        state.isAtBottom = false
        state.unseenMessageCount = 2
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        let first = MessageNavigatorTarget(sessionID: "session", messageID: UUID())
        let second = MessageNavigatorTarget(sessionID: "session", messageID: UUID())

        state.visibleTargets = [first]
        state.visibleTargets = [first, second]
        state.visibleTargets = [second, first]
        #expect(publications == 2)
        #expect(state.visibleTargets == [first, second])
        #expect(!state.isAtBottom)
        #expect(state.unseenMessageCount == 2)
    }

    @Test func sessionResetClearsOldVisibilityAndUnreadOnlyOnce() {
        let state = ConversationScrollPresentationState()
        state.isAtBottom = false
        state.unseenMessageCount = 4
        state.visibleTargets = [MessageNavigatorTarget(sessionID: "old", messageID: UUID())]
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        state.reset()
        #expect(state.isAtBottom)
        #expect(state.unseenMessageCount == 0)
        #expect(state.visibleTargets.isEmpty)
        let resetPublications = publications
        #expect(resetPublications > 0)
        state.reset()
        #expect(publications == resetPublications)
    }
}
