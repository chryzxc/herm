import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct ConversationScrollPresentationStateTests {
    @Test func latestControlShowsAwayFromBottomWithoutUnreadMessages() {
        let state = ConversationScrollPresentationState()
        #expect(!state.showsLatestControl)
        state.isAtBottom = false
        #expect(state.unseenMessageCount == 0)
        #expect(state.showsLatestControl)
        state.updatePosition(
            ConversationScrollGeometry(visibleTop: 2_600, visibleHeight: 400, documentHeight: 3_000), isLiveTail: true)
        #expect(!state.showsLatestControl)
        // A transcript that fits its viewport is already at the bottom.
        state.updatePosition(
            ConversationScrollGeometry(visibleTop: 0, visibleHeight: 400, documentHeight: 200), isLiveTail: true)
        #expect(!state.showsLatestControl)
    }

    @Test func contentGrowthKeepsFollowingUntilTheReaderScrollsAway() {
        let state = ConversationScrollPresentationState()
        state.updatePosition(
            ConversationScrollGeometry(visibleTop: 600, visibleHeight: 400, documentHeight: 3_000),
            isLiveTail: true
        )
        #expect(state.isAtBottom, "A large streamed block must not disable bottom follow before layout catches up")

        state.isAtBottom = false
        state.unseenMessageCount = 2
        state.updatePosition(
            ConversationScrollGeometry(visibleTop: 600, visibleHeight: 400, documentHeight: 3_400),
            isLiveTail: true
        )
        #expect(!state.isAtBottom)
        #expect(state.unseenMessageCount == 2)
    }

    @Test func followingResumesOnlyAtTheActualBottom() {
        let state = ConversationScrollPresentationState()
        state.isAtBottom = false
        state.unseenMessageCount = 3
        state.updatePosition(
            ConversationScrollGeometry(visibleTop: 588, visibleHeight: 400, documentHeight: 1_000),
            isLiveTail: true
        )
        #expect(!state.isAtBottom)
        #expect(state.unseenMessageCount == 3)

        state.updatePosition(
            ConversationScrollGeometry(visibleTop: 600, visibleHeight: 400, documentHeight: 1_000),
            isLiveTail: true
        )
        #expect(state.isAtBottom)
        #expect(state.unseenMessageCount == 0)
    }

    @Test func theBottomOfAnOlderWindowDoesNotResumeFollowing() {
        let state = ConversationScrollPresentationState()
        state.updatePosition(
            ConversationScrollGeometry(visibleTop: 600, visibleHeight: 400, documentHeight: 1_000),
            isLiveTail: false
        )
        #expect(!state.isAtBottom)
    }

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
