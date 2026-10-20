import Foundation
import Testing
@testable import Herm

@MainActor
struct KanbanRefreshTests {
    @Test(arguments: [false, true])
    func navigationDuringRefreshLoadsTheLatestBoard(firstReadFails: Bool) async throws {
        let client = SuspendedKanbanClient()
        client.failFirstRead = firstReadFails
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.refreshVisibleKanban()
        try await waitUntil { client.inventoryStarted }

        for board in ["other", "latest"] {
            control.revealKanbanTask(KanbanTaskSummary(
                id: "ready-task", boardSlug: board, title: "Work", status: "ready",
                detail: nil, priority: nil, assignee: nil
            ))
        }
        client.holdInventory = false
        try await waitUntil { !control.isKanbanRefreshPending }

        #expect(control.selectedKanbanBoardSlug == "latest")
        #expect(control.kanbanTasks.map(\.boardSlug) == ["latest", "latest"])
        #expect(client.paths.contains("/api/plugins/kanban/board?board=latest&include_archived=true"))
        #expect(!client.paths.contains("/api/plugins/kanban/board?board=other&include_archived=true"))
        #expect(control.pendingActionIDs.isEmpty)
    }

    @Test func filterChangesDuringRefreshKeepOnlyTheLatestRequest() async throws {
        let client = SuspendedKanbanClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.refreshVisibleKanban(filter: KanbanListFilter(status: "done"))
        try await waitUntil { client.inventoryStarted }

        control.refreshVisibleKanban(filter: KanbanListFilter(status: "blocked"))
        control.refreshVisibleKanban(filter: KanbanListFilter(status: "ready"))
        client.holdInventory = false
        try await waitUntil { !control.isKanbanRefreshPending }

        #expect(control.kanbanFilter.status == "ready")
        #expect(control.kanbanTasks.map(\.id) == ["ready-task"])
        #expect(client.paths.filter { $0.contains("/board?") }.count == 2)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Kanban request did not settle")
    }
}

@MainActor
private final class SuspendedKanbanClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var paths: [String] = []
    var inventoryStarted = false
    var holdInventory = true
    var failFirstRead = false

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        ["code": 0, "stdout": "[]"]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        if path == "/api/plugins/kanban/boards" {
            inventoryStarted = true
            while holdInventory { try await Task.sleep(for: .milliseconds(5)) }
            if failFirstRead {
                failFirstRead = false
                throw URLError(.cannotConnectToHost)
            }
            return ["boards": [["slug": "old", "archived": false]]]
        }
        return ["columns": [["tasks": [
            ["id": "ready-task", "title": "Ready", "status": "ready"],
            ["id": "done-task", "title": "Done", "status": "done"]
        ]]]]
    }
}
