import Foundation
import Testing

@testable import Herm

@MainActor
struct WorkspaceStatusSummaryTests {
    private func task(
        _ id: String, _ phase: EdgeNotchTask.Phase, live: Bool = true, failure: Bool = false
    ) -> EdgeNotchTask {
        EdgeNotchTask(
            id: id, title: id, phase: phase, statusLabel: "", detail: nil, updatedAt: nil,
            isCurrent: false, isStatusCurrent: live, session: nil, isFailure: failure)
    }

    @Test func groupsDecisionsAndFailuresInOneQueue() {
        let summary = WorkspaceStatusSummary(tasks: [
            task("a", .attention), task("b", .attention), task("f", .attention, failure: true),
            task("w1", .working), task("w2", .working), task("done", .finished), task("card", .pending),
        ])
        #expect(summary.attention.map(\.id) == ["a", "b", "f"])
        #expect(summary.running.map(\.id) == ["w1", "w2"])
        #expect(summary.finished.map(\.id) == ["done"])
        #expect(!summary.isStale)
    }

    @Test func emptyInventoryShowsNothingAndIsNotStale() {
        let summary = WorkspaceStatusSummary(tasks: [])
        #expect(summary.running.isEmpty && summary.attention.isEmpty)
        #expect(summary.finished.isEmpty)
        #expect(!summary.isStale)
    }

    @Test func offlineKeepsLastCountsButMarksThemStale() {
        let summary = WorkspaceStatusSummary(tasks: [
            task("a", .attention, live: false), task("w", .working, live: false),
        ])
        #expect(summary.isStale)
        #expect(summary.attention.count == 1)
        #expect(summary.running.count == 1)
    }

    @Test func staleRowsDropOutWhileOtherWorkIsLive() {
        let summary = WorkspaceStatusSummary(tasks: [task("old", .working, live: false), task("a", .attention)])
        #expect(!summary.isStale)
        #expect(summary.running.isEmpty)
        #expect(summary.attention.count == 1)
    }

    @Test func deduplicatesRequestsAndExcludesQueuedWork() {
        let request = AttentionRequest(sessionID: "chat", profileID: "bot", requestID: "approval")
        var approval = task("chat", .attention)
        approval.attentionRequest = request
        var alias = task("alias", .attention)
        alias.attentionRequest = request
        var queued = task("queued", .working)
        queued.isQueued = true
        let summary = WorkspaceStatusSummary(tasks: [
            approval, alias, approval, queued, task("failed-result", .finished, failure: true),
        ])

        #expect(summary.attention.map(\.id) == ["chat", "failed-result"])
        #expect(summary.running.isEmpty)
        #expect(summary.finished.isEmpty)
    }
}
