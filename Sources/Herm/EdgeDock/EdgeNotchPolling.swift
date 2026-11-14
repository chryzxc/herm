import Foundation

enum EdgeNotchPolling {
    static let kanbanInterval: TimeInterval = 15
    static let deliveryQuestionInterval: TimeInterval = 5

    static func shouldPollKanban(
        now: Date, lastPoll: Date?, isWorking: Bool, isOffline: Bool, force: Bool
    ) -> Bool {
        guard !isOffline else { return false }
        guard !force, let lastPoll else { return true }
        return now.timeIntervalSince(lastPoll) >= (isWorking ? kanbanInterval : 60)
    }
}
