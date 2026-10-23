import Testing

@testable import Herm

struct SessionKanbanActivityPresentationTests {
    @Test func activeWorkIsSortedBeforeCompletedHistory() {
        let snapshot = SessionKanbanActivityPresentation.makeSnapshot(tasks: [
            KanbanTaskSummary(id: "done", title: "Finished", status: "done", detail: nil, priority: nil, assignee: nil),
            KanbanTaskSummary(
                id: "ready", title: "Prepare", status: "ready", detail: nil, priority: nil, assignee: nil),
            KanbanTaskSummary(
                id: "blocked", title: "Blocked", status: "blocked", detail: "Waiting on API", priority: nil,
                assignee: "Terra"),
            KanbanTaskSummary(
                id: "running", title: "Running", status: "running", detail: nil, priority: nil, assignee: "Luna"),
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

    @Test func botWorkIncludesOnlySessionTasksAssignedToKnownBots() {
        let tasks = [
            KanbanTaskSummary(
                id: "t1", title: "Implement fix", status: "running", detail: nil, priority: nil, assignee: "forge",
                sessionID: "session-1"),
            KanbanTaskSummary(
                id: "t2", title: "Other session", status: "running", detail: nil, priority: nil, assignee: "cypher",
                sessionID: "session-2"),
            KanbanTaskSummary(
                id: "t3", title: "Generic task", status: "running", detail: nil, priority: nil, assignee: "delegate",
                sessionID: "session-1"),
        ]
        let bots = [bot(id: "forge", name: "Forge"), bot(id: "cypher", name: "Cypher")]

        let rows = SessionKanbanActivityPresentation.botWork(tasks: tasks, bots: bots, sessionID: "session-1")

        #expect(rows.map(\.taskID) == ["t1"])
        #expect(rows.first?.botName == "Forge")
        #expect(rows.first?.status == .running)
    }

    @Test func botWorkDoesNotUseBotRecencyWithoutAnAssignedSessionTask() {
        let bots = [bot(id: "forge", name: "Forge")]

        let rows = SessionKanbanActivityPresentation.botWork(tasks: [], bots: bots, sessionID: "session-1")

        #expect(rows.isEmpty)
    }

    private func bot(id: String, name: String) -> BotSummary {
        BotSummary(
            id: id,
            name: name,
            title: nil,
            description: nil,
            model: nil,
            isActive: true,
            chat: nil,
            avatarURL: nil,
            preview: nil,
            lastActive: nil,
            isHidden: false,
            hasAvatar: false,
            isDefault: false
        )
    }
}
