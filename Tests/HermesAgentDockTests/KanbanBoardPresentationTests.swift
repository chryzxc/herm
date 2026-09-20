import Testing
@testable import HermesAgentDock

struct KanbanBoardPresentationTests {
    @Test func laneMappingNormalizesHermesStatuses() {
        #expect(KanbanBoardPresentation.lane(for: "in-progress") == .running)
        #expect(KanbanBoardPresentation.lane(for: "inprogress") == .running)
        #expect(KanbanBoardPresentation.lane(for: "archived") == .done)
        #expect(KanbanBoardPresentation.lane(for: "custom-state") == .todo)
    }

    @Test func snapshotBucketsTasksAndCountsInOneProjection() {
        let snapshot = KanbanBoardPresentation.makeSnapshot(tasks: [
            KanbanTaskSummary(id: "1", title: "Running", status: "running", detail: nil, priority: nil, assignee: nil),
            KanbanTaskSummary(id: "2", title: "Blocked", status: "blocked", detail: nil, priority: nil, assignee: nil),
            KanbanTaskSummary(id: "3", title: "Done", status: "completed", detail: nil, priority: nil, assignee: nil)
        ], bots: [])

        #expect(snapshot.totalCount == 3)
        #expect(snapshot.tasks(in: .running).map(\.id) == ["1"])
        #expect(snapshot.tasks(in: .blocked).map(\.id) == ["2"])
        #expect(snapshot.tasks(in: .done).map(\.id) == ["3"])
    }

    @Test func botLookupIsCaseInsensitive() {
        let bot = BotSummary(
            id: "Forge",
            name: "Forge",
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
        let snapshot = KanbanBoardPresentation.makeSnapshot(tasks: [], bots: [bot])

        #expect(snapshot.bot(for: " forge ")?.id == "Forge")
    }

    @Test func cardDetailRemovesProtocolMetadata() {
        let detail = KanbanBoardPresentation.cardDetail("TASK_ID: t_1\nOBJECTIVE: Ship it\n\nCheck tests")

        #expect(detail == "Ship it Check tests")
        #expect(KanbanBoardPresentation.cardDetail("TASK_ID: t_1") == nil)
    }
}
