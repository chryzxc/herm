import Testing
@testable import Herm

struct ChatRailActivityTests {
    @Test func showsRunningAndUnreadCompletionsTogether() {
        let activity = ChatRailActivity(
            statuses: [.unreadComplete, .working, .none, .unreadComplete],
            foregroundWorking: false, isConnected: true)
        #expect(activity.isWorking)
        #expect(activity.unreadCount == 2)
        #expect(activity.summary == "Sessions running, 2 completed chats to review")
    }

    @Test func attentionAndFailuresAreNotCountedAsCompleted() {
        let activity = ChatRailActivity(
            statuses: [.needsApproval, .needsClarification, .failed, .none],
            foregroundWorking: false, isConnected: true)
        #expect(!activity.isWorking)
        #expect(activity.unreadCount == 0)
    }

    @Test func foregroundWorkDoesNotNeedAnIndexedRowAndDisconnectStopsSpinner() {
        #expect(ChatRailActivity(statuses: [], foregroundWorking: true, isConnected: true).isWorking)
        let offline = ChatRailActivity(
            statuses: [.working, .unreadComplete],
            foregroundWorking: true, isConnected: false)
        #expect(!offline.isWorking)
        #expect(offline.unreadCount == 1)
        #expect(offline.summary == "1 completed chat to review")
    }

    @Test func reviewingAResultClearsTheBadgeAndIdleChatsStayQuiet() {
        let activity = ChatRailActivity(
            statuses: [.none, .none], foregroundWorking: false, isConnected: true)
        #expect(!activity.isWorking)
        #expect(activity.unreadCount == 0)
        #expect(activity.summary.isEmpty)
    }
}
