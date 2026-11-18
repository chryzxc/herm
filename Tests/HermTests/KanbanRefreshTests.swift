import Foundation
import Testing

@testable import Herm

@MainActor
struct KanbanRefreshTests {
    @Test(arguments: [false, true])
    func navigationDuringRefreshLoadsTheLatestBoard(firstReadFails: Bool) async throws {
        let client = SuspendedKanbanClient()
        client.failFirstRead = firstReadFails
        client.inventories = [["old"]]
        client.laterInventory = ["old", "other", "latest"]
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.refreshVisibleKanban()
        try await waitUntil { client.inventoryStarted }

        for board in ["other", "latest"] {
            control.revealKanbanTask(
                KanbanTaskSummary(
                    id: "ready-task", boardSlug: board, title: "Work", status: "ready",
                    detail: nil, priority: nil, assignee: nil
                ))
        }
        client.holdInventory = false
        try await waitUntil { !control.isKanbanRefreshPending }

        #expect(control.selectedKanbanBoardSlug == "latest")
        #expect(control.kanbanTasks.map(\.boardSlug) == ["latest", "latest"])
        #expect(client.paths.contains("/api/plugins/kanban/board?board=latest&include_archived=false"))
        #expect(!client.paths.contains("/api/plugins/kanban/board?board=other&include_archived=false"))
        #expect(control.pendingActionIDs.isEmpty)
    }

    @Test func filterChangesDuringRefreshKeepOnlyTheLatestRequest() async throws {
        let client = SuspendedKanbanClient()
        // Two aggregate passes read inventory; the later board-inventory refresh finds the
        // dashboard API unavailable, so only the coalesced filter reads reach a board.
        client.inventories = [["old"], ["old"]]
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
    /// Inventory responses in request order; `laterInventory` answers the rest, or nil
    /// reports the dashboard API unavailable.
    var inventories: [[String]] = []
    var laterInventory: [String]?
    private var inventoryReads = 0

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        ["code": 0, "stdout": "[]"]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        if path == "/api/plugins/kanban/boards" {
            inventoryStarted = true
            let read = inventoryReads
            inventoryReads += 1
            while holdInventory { try await Task.sleep(for: .milliseconds(5)) }
            if failFirstRead {
                failFirstRead = false
                throw URLError(.cannotConnectToHost)
            }
            guard let boards = read < inventories.count ? inventories[read] : laterInventory else {
                throw URLError(.resourceUnavailable)
            }
            return ["boards": boards.map { ["slug": $0, "archived": false] }]
        }
        return [
            "columns": [
                [
                    "tasks": [
                        ["id": "ready-task", "title": "Ready", "status": "ready"],
                        ["id": "done-task", "title": "Done", "status": "done"],
                    ]
                ]
            ]
        ]
    }
}
