import Testing
@testable import HermesAgentDock

struct SessionKanbanActivityPresentationTests {
    @Test func activeWorkIsSortedBeforeCompletedHistory() {
        let snapshot = SessionKanbanActivityPresentation.makeSnapshot(tasks: [
            KanbanTaskSummary(id: "done", title: "Finished", status: "done", detail: nil, priority: nil, assignee: nil),
            KanbanTaskSummary(id: "ready", title: "Prepare", status: "ready", detail: nil, priority: nil, assignee: nil),
            KanbanTaskSummary(id: "blocked", title: "Blocked", status: "blocked", detail: "Waiting on API", priority: nil, assignee: "Terra"),
            KanbanTaskSummary(id: "running", title: "Running", status: "running", detail: nil, priority: nil, assignee: "Luna")
        ])

        #expect(snapshot.activeRows.map(\.id) == ["running", "blocked", "ready"])
        #expect(snapshot.completedRows.map(\.id) == ["done"])
        #expect(snapshot.completedCount == 1)
        #expect(snapshot.blockedCount == 1)
        #expect(snapshot.runningCount == 1)
    }

    @Test func unknownStatusRemainsVisibleAndOptionalMetadataIsTrimmed() {
        let snapshot = SessionKanbanActivityPresentation.makeSnapshot(tasks: [
            KanbanTaskSummary(
                id: "unknown",
                title: "Unclassified",
                status: "  custom_state ",
                detail: "   ",
                priority: nil,
                assignee: "  "
            )
        ])

        #expect(snapshot.activeRows.count == 1)
        #expect(snapshot.activeRows[0].status.label == "CUSTOM_STATE")
        #expect(snapshot.activeRows[0].detail == nil)
        #expect(snapshot.activeRows[0].assignee == nil)
    }
}
