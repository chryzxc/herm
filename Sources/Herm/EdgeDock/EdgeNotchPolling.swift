import Foundation

enum EdgeNotchPolling {
    static let kanbanInterval: TimeInterval = 15
    static let idleInventoryInterval: TimeInterval = 60
    static let deliveryQuestionRecoveryInterval: TimeInterval = 60

    static func quotaInterval(workspaceVisible: Bool, previewExpanded: Bool) -> TimeInterval {
        workspaceVisible || previewExpanded ? 30 : 300
    }

    static func shouldPollKanban(
        now: Date, lastPoll: Date?, isWorking: Bool, isOffline: Bool, force: Bool
    ) -> Bool {
        guard !isOffline else { return false }
        guard !force, let lastPoll else { return true }
        return now.timeIntervalSince(lastPoll) >= (isWorking ? kanbanInterval : idleInventoryInterval)
    }
}
