import Foundation
import Testing

@testable import Herm

struct EdgeKanbanActivityTests {
    private func card(
        _ id: String = "task", board: String = "main", status: String = "running", title: String = "Fix login"
    ) -> KanbanTaskSummary {
        KanbanTaskSummary(
            id: id, boardSlug: board, title: title, status: status,
            detail: nil, priority: nil, assignee: "Builder")
    }

    @Test func baselineShowsActiveCardsWithoutReplayingOldCompletions() {
        var activity = EdgeKanbanActivity()
        let tasks = [
            card(), card("review", status: "review"), card("blocked", status: "blocked"),
            card("old", status: "done"), card("queued", status: "ready"),
        ]
        let announced1 = activity.ingest(tasks)
        #expect(!announced1)
        let rows = activity.rows(isCurrent: true)
        #expect(rows.map(\.kanbanTask?.id) == ["blocked", "task", "review"])
        #expect(rows.map(\.tone) == [.attention, .working, .review])
        let announced2 = activity.ingest(Array(tasks.reversed()))
        #expect(!announced2)
    }

    @Test func everyLaneMoveAnnouncesOnceAndShowsTheTransition() {
        var activity = EdgeKanbanActivity()
        let announced3 = activity.ingest([card(status: "triage")])
        #expect(!announced3)
        var previous = "triage"
        for status in ["todo", "ready", "running", "review", "blocked", "scheduled", "done"] {
            let task = card(status: status)
            let announced4 = activity.ingest([task])
            let queued = ["todo", "ready", "scheduled"].contains(status)
            #expect(announced4 == !queued)
            let announced5 = activity.ingest([task])
            #expect(!announced5)
            let row = activity.rows(isCurrent: true).first
            if queued {
                #expect(row == nil)
                previous = status
                continue
            }
            #expect(row?.statusLabel == status.capitalized)
            #expect(row?.detail?.contains("\(previous.capitalized) → \(status.capitalized)") == true)
            #expect(row?.kanbanTask == task)
            previous = status
        }
    }

    @Test func movedCardLeadsThePreviewEvenWhenOtherWorkIsRunning() {
        var activity = EdgeKanbanActivity()
        _ = activity.ingest([card("unchanged"), card("moved")])
        _ = activity.ingest([card("unchanged"), card("moved", status: "done")])
        #expect(activity.rows(isCurrent: true).first?.kanbanTask?.id == "moved")
        #expect(activity.rows(isCurrent: true).first?.statusLabel == "Done")
    }

    @Test func editsAndCardsAddedAfterAnEmptyBaselineAnnounce() {
        var activity = EdgeKanbanActivity()
        let announced6 = activity.ingest([])
        #expect(!announced6)
        let announced7 = activity.ingest([card(status: "review")])
        #expect(announced7)
        #expect(activity.rows(isCurrent: true).first?.detail?.contains("Card added") == true)
        let announced8 = activity.ingest([card(status: "review", title: "Fix logout")])
        #expect(announced8)
        #expect(activity.rows(isCurrent: true).first?.title == "Fix logout")
        #expect(activity.rows(isCurrent: true).first?.detail?.contains("Card updated") == true)
    }

    @Test func sameTaskIDOnDifferentBoardsStaysIndependent() {
        var activity = EdgeKanbanActivity()
        _ = activity.ingest([card(board: "a"), card(board: "b")])
        #expect(activity.rows(isCurrent: true).count == 2)
        #expect(Set(activity.rows(isCurrent: true).map(\.id)).count == 2)
        let announced9 = activity.ingest([card(board: "a", status: "done"), card(board: "b")])
        #expect(announced9)
        activity.acknowledge(card(board: "a", status: "done"))
        #expect(activity.rows(isCurrent: true).map(\.kanbanTask?.boardSlug) == ["b"])
    }

    @Test func openingAnActiveCardKeepsItVisibleAndFinishedCardsDisappear() {
        var activity = EdgeKanbanActivity()
        _ = activity.ingest([])
        _ = activity.ingest([card()])
        activity.acknowledge(card())
        #expect(activity.rows(isCurrent: true).count == 1)
        _ = activity.ingest([card(status: "done")])
        activity.acknowledge(card(status: "done"))
        #expect(activity.rows(isCurrent: true).isEmpty)
        let announced10 = activity.ingest([card(status: "done")])
        #expect(!announced10)
    }

    @Test func staleRowsKeepContentAndStopClaimingLiveWork() {
        var activity = EdgeKanbanActivity()
        _ = activity.ingest([card()])
        #expect(activity.rows(isCurrent: false).first?.title == "Fix login")
        #expect(activity.rows(isCurrent: false).first?.tone == .inactive)
        #expect(activity.rows(isCurrent: false).first?.displayStatus == "Status not current")
        let announced11 = activity.ingest([card()])
        #expect(!announced11)
        #expect(activity.rows(isCurrent: true).first?.tone == .working)
    }

    @Test func recentChangesAreBoundedWithoutCappingRunningWork() {
        var activity = EdgeKanbanActivity()
        _ = activity.ingest([])
        let tasks =
            (0..<40).map { card("done-\($0)", status: "done") }
            + (0..<40).map { card("active-\($0)") }
        _ = activity.ingest(tasks)
        #expect(activity.rows(isCurrent: true).filter { $0.phase == .working }.count == 40)
        #expect(activity.rows(isCurrent: true).filter { $0.phase == .finished }.count <= 30)
        let announced12 = activity.ingest([])
        #expect(!announced12)
        #expect(activity.rows(isCurrent: true).isEmpty)
    }

    @Test func mergedListOrdersInProgressFinishedReviewAttention() {
        func row(_ id: String, _ phase: EdgeNotchTask.Phase, _ age: TimeInterval?, current: Bool = false)
            -> EdgeNotchTask
        {
            EdgeNotchTask(
                id: id, title: id, phase: phase, statusLabel: "", detail: nil,
                updatedAt: age.map { Date(timeIntervalSince1970: 1_000 - $0) },
                isCurrent: current, isStatusCurrent: true, session: nil)
        }
        var activity = EdgeKanbanActivity()
        _ = activity.ingest([card()])
        let kanban = activity.rows(isCurrent: true)
        let rows = EdgeNotchTask.merged(
            [
                row("done", .finished, 1), row("blocked", .attention, 1), row("old", .working, 50),
                row("queued", .pending, 5), row("current", .working, nil, current: true),
            ] + kanban)
        #expect(rows.map(\.id) == ["current", "old", "kanban:4:main:task", "done", "queued", "blocked"])
        #expect(rows.map(\.section) == [.inProgress, .inProgress, .inProgress, .finished, .review, .attention])
    }

    @MainActor @Test func railReflectsKanbanWithoutInventingCurrentSessionActivity() {
        var activity = EdgeKanbanActivity()
        _ = activity.ingest([card()])
        let state = EdgeNotchState()
        state.tasks = activity.rows(isCurrent: true)
        #expect(state.railActivity.working)
        #expect(!state.activity.working)
        #expect(!state.isQuiet)
        #expect(state.railActivity.title == "1 Kanban card running")
        state.tasks = activity.rows(isCurrent: false)
        #expect(!state.railActivity.working)
    }
}

@MainActor
struct EdgeKanbanProjectionTests {
    @Test func backgroundRefreshKeepsAggregateIndependentAndRetainsFailedSnapshot() async throws {
        let client = NotchKanbanClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        // Each background poll here must reach the client, not the shared read.
        control.cli?.backgroundBoardReadReuse = 0
        control.refreshGlobalKanban()
        try await settle(control)
        #expect(control.globalKanbanTasks.first?.status == "running")
        #expect(control.refreshState(for: "kanban.global")?.lastSuccess != nil)

        // A filtered board and a background aggregate must not share scope.
        control.refreshVisibleKanban(filter: KanbanListFilter(status: "done"))
        try await settle(control)
        client.status = "review"
        control.refreshGlobalKanban(trigger: .background)
        try await settle(control)
        #expect(control.globalKanbanTasks.first?.status == "review")
        #expect(control.kanbanFilter.status == "done")
        #expect(control.refreshState(for: "kanban.global")?.isStale == false)

        client.fail = true
        control.refreshGlobalKanban(trigger: .background)
        try await settle(control)
        #expect(control.globalKanbanTasks.first?.status == "review")
        #expect(control.refreshState(for: "kanban.global")?.isStale == true)
        #expect(control.refreshState(for: "kanban.global")?.error != nil)

        client.fail = false
        control.refreshGlobalKanban(trigger: .background)
        try await settle(control)
        #expect(control.refreshState(for: "kanban.global")?.isStale == false)
    }

    @Test func identicalBackgroundPollSkipsOnlyWhileTasksMatchItsOutput() async throws {
        let client = NotchKanbanClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.cli?.backgroundBoardReadReuse = 0
        control.refreshGlobalKanban()
        try await settle(control)
        control.refreshGlobalKanban(trigger: .background)
        try await settle(control)
        #expect(control.lastAggregateKanbanStdout != nil)

        // A local write invalidates the cached output, so the next identical
        // poll must restore Hermes' projection instead of skipping it.
        control.globalKanbanTasks = []
        #expect(control.lastAggregateKanbanStdout == nil)
        control.refreshGlobalKanban(trigger: .background)
        try await settle(control)
        #expect(control.globalKanbanTasks.first?.status == "running")

        client.status = "review"
        control.refreshGlobalKanban(trigger: .background)
        try await settle(control)
        #expect(control.globalKanbanTasks.first?.status == "review")
    }

    @Test func cardNavigationSelectsOwningBoardAndClearsVisibleFilters() async throws {
        let client = NotchKanbanClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        // Each background poll here must reach the client, not the shared read.
        control.cli?.backgroundBoardReadReuse = 0
        control.refreshGlobalKanban()
        try await settle(control)
        let task = KanbanTaskSummary(
            id: "task", boardSlug: "other", title: "Other board card",
            status: "running", detail: nil, priority: nil, assignee: nil)
        control.revealKanbanTask(task)
        #expect(control.selectedKanbanBoardSlug == "other")
        #expect(control.requestedKanbanTask == task)
        #expect(control.kanbanFilter == KanbanListFilter())
        try await settle(control)
        #expect(control.selectedKanbanBoardSlug == "other")
    }

    private func settle(_ control: ControlCenterModel) async throws {
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            if control.pendingActionIDs.isEmpty, !control.hasKanbanReadInFlight,
                control.refreshState(for: "kanban.global")?.isRefreshing != true,
                control.refreshState(for: "kanban.visible")?.isRefreshing != true
            {
                return
            }
        }
        Issue.record("Kanban refresh did not settle")
    }
}

@MainActor
private final class NotchKanbanClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var status = "running"
    var fail = false
    func connect() async throws {}
    func close() {}
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if fail { throw URLError(.cannotConnectToHost) }
        if path == "/api/plugins/kanban/boards" {
            return [
                "boards": [
                    ["slug": "main", "name": "Main", "is_current": true, "archived": false],
                    ["slug": "other", "name": "Other", "is_current": false, "archived": false],
                ]
            ]
        }
        if path.hasPrefix("/api/plugins/kanban/board?") {
            return ["columns": [["tasks": [["id": "task", "title": "Work", "status": status]]]]]
        }
        return [:]
    }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        ["code": 0, "stdout": "[]"]
    }
}
