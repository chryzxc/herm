import Foundation
import Testing

@testable import Herm

@MainActor
struct KanbanMoveTests {
    @Test func loadedHTTPBoardEnablesMovesWithoutCLICapabilities() async throws {
        let client = KanbanMoveClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        #expect(!control.canMoveKanbanTasks)
        control.refreshGlobalKanban()
        try await settle(control)
        #expect(!control.capabilityAvailable("kanban"))
        #expect(control.canMoveKanbanTasks)
        let task = try #require(control.kanbanTasks.first)

        control.moveKanbanTask(task, to: .ready)
        control.moveKanbanTask(task, to: .triage)
        #expect(control.kanbanTasks.first?.status == "todo")
        try await settle(control)
        #expect(client.writes == 1)
        #expect(client.lastPath == "/api/plugins/kanban/tasks/task?board=main")
        #expect(control.kanbanTasks.first?.status == "ready")
    }

    @Test func rejectedMovePreservesCardAndReportsFailure() async throws {
        let client = KanbanMoveClient()
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.refreshGlobalKanban()
        try await settle(control)
        let task = try #require(control.kanbanTasks.first)
        client.rejectMove = true
        control.moveKanbanTask(task, to: .ready)
        try await settle(control)
        #expect(control.kanbanTasks.first?.status == "todo")
        #expect(control.lastError != nil)

        client.failRead = true
        control.refreshGlobalKanban()
        try await settle(control)
        #expect(!control.canMoveKanbanTasks)
    }

    private func settle(_ control: ControlCenterModel) async throws {
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(10))
            if control.pendingActionIDs.isEmpty { return }
        }
        Issue.record("Kanban operations did not settle")
    }
}

@MainActor
private final class KanbanMoveClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var status = "todo"
    var rejectMove = false
    var failRead = false
    var writes = 0
    var lastPath: String?

    func connect() async throws {}
    func close() {}

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if failRead { throw URLError(.cannotConnectToHost) }
        if path == "/api/plugins/kanban/boards" {
            return ["boards": [["slug": "main", "name": "Main", "is_current": true]]]
        }
        return ["columns": [["tasks": [["id": "task", "title": "Work", "status": status]]]]]
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        writes += 1
        lastPath = path
        if rejectMove { throw URLError(.cannotConnectToHost) }
        status = body["status"] as? String ?? status
        return [:]
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        ["code": 0, "stdout": "[]"]
    }
}
