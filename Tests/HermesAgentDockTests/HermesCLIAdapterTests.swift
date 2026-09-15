import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct HermesCLIAdapterTests {
    @Test func quotesEveryArgumentWithoutBreakingApostrophes() throws {
        let rendered = try HermesCLICommand(["hermes", "kanban", "comment", "task 1", "it's safe; $(nope)"]).rendered()

        #expect(rendered == "'hermes' 'kanban' 'comment' 'task 1' 'it'\\''s safe; $(nope)'")
    }

    @Test func rejectsNullCharacters() {
        #expect(throws: HermesCLIError.self) {
            try HermesCLICommand(["hermes", "kanban", "show", "bad\u{0000}id"]).rendered()
        }
    }

    @Test func cronEditSendsOnlyChangedFields() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.cronEdit(jobID: "job-1", changes: [.schedule: "0 9 * * 1", .name: "Weekly review"])

        let command = client.commands.last ?? ""
        #expect(command.contains("'--name' 'Weekly review'"))
        #expect(command.contains("'--schedule' '0 9 * * 1'"))
        #expect(!command.contains("'--prompt'"))
        #expect(command.hasSuffix("'job-1'"))
    }

    @Test func kanbanMutationCommandsAreAllowListed() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanAssign(taskID: "task-1", profile: "worker", reassign: true, reclaim: true)

        #expect(client.commands.last == "'hermes' 'kanban' 'reassign' '--reclaim' 'task-1' 'worker'")
    }

    @Test func kanbanListUsesStructuredReadOnlyBoardProjection() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        let result = try await adapter.kanbanList(filter: KanbanListFilter(status: "ready"))

        #expect(client.httpPaths == ["/api/plugins/kanban/boards", "/api/plugins/kanban/board?board=default"])
        #expect(result.succeeded)
        #expect(result.stdout.contains("ready-task"))
        #expect(result.stdout.contains("\"board_slug\":\"default\""))
    }

    @Test func mineFilterDoesNotTreatAnyAssignmentAsMine() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        let result = try await adapter.kanbanList(filter: KanbanListFilter(mine: true))

        #expect(result.stdout == "[]")
    }

    @Test func kanbanCreateOmitsUnsupportedSessionFlag() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanCreate(title: "Session work", body: nil)

        #expect(client.commands.last == "'hermes' 'kanban' 'create' '--json' 'Session work'")
    }

    @Test func kanbanAttributeSessionUsesUserStateHelper() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanAttributeSession(taskID: "t_abc123", sessionID: "session-1")

        #expect(client.commands.last == "'bash' '\(NSHomeDirectory())/.hermes/scripts/kanban-attribute-session.sh' 't_abc123' 'session-1'")
    }

    @Test func configGetCommandAllowlistUsesTypedConfigPath() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.configGetCommandAllowlist()

        #expect(client.commands.last == "'hermes' 'config' 'get' 'command_allowlist'")
    }

    @Test func kanbanBoardCommandsUseSupportedContracts() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanBoards(includeArchived: true)
        #expect(client.commands.last == "'hermes' 'kanban' 'boards' 'list' '--json' '--all'")

        _ = try await adapter.kanbanList(boardSlug: "client-board")
        #expect(client.httpPaths == ["/api/plugins/kanban/board?board=client-board"])
    }

    @Test func kanbanBoardScopeSafelyEncodesQueryReservedCharacters() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanList(boardSlug: "client&ops=west")

        #expect(client.httpPaths == ["/api/plugins/kanban/board?board=client%26ops%3Dwest"])
    }

    @Test func aggregateKanbanIncludesArchivedBoardsOnlyWhenRequested() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        let result = try await adapter.kanbanList(filter: KanbanListFilter(includeArchived: true))

        #expect(client.httpPaths == [
            "/api/plugins/kanban/boards",
            "/api/plugins/kanban/board?board=default",
            "/api/plugins/kanban/board?board=archived-board"
        ])
        #expect(result.stdout.contains("archived-task"))
    }

    @Test func updatedKanbanSortIsNewestFirstAndStableForMissingDates() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        let result = try await adapter.kanbanList(filter: KanbanListFilter(sort: "updated"))
        let data = try #require(result.stdout.data(using: .utf8))
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(rows.compactMap { $0["id"] as? String } == ["new-task", "old-task", "ready-task", "undated-task"])
    }
    @Test func kanbanDiagnosticsAndAttachmentsForwardBoardScope() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanDiagnostics(boardSlug: "client-board", severity: "error", taskID: "task-1")
        #expect(client.commands.last == "'hermes' 'kanban' '--board' 'client-board' 'diagnostics' '--json' '--severity' 'error' '--task' 'task-1'")

        _ = try await adapter.kanbanAttachments(boardSlug: "client-board", taskID: "task-1")
        #expect(client.commands.last == "'hermes' 'kanban' '--board' 'client-board' 'attachments' '--json' 'task-1'")
    }

    @Test func enabledSkillsUsesTheVerifiedDisplayOnlyContract() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.enabledSkillsList()

        #expect(client.commands.last == "'hermes' 'skills' 'list' '--enabled-only'")
    }
}

@MainActor
private final class CLITestRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var commands: [String] = []
    private(set) var httpPaths: [String] = []
    var result: [String: Any] = ["code": 0, "stdout": "ok"]

    func connect() async throws {}
    func close() {}

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        httpPaths.append(path)
        if path == "/api/plugins/kanban/boards" {
            return ["boards": [
                ["slug": "default", "archived": false],
                ["slug": "archived-board", "archived": true]
            ]]
        }
        if path.contains("archived-board") {
            return ["columns": [["name": "archived", "tasks": [[
                "id": "archived-task", "title": "Archived task", "status": "archived"
            ]]]]]
        }
        return ["columns": [["name": "ready", "tasks": [
            ["id": "ready-task", "title": "Ready task", "status": "ready"],
            ["id": "new-task", "title": "New task", "status": "ready", "updated_at": 200],
            ["id": "old-task", "title": "Old task", "status": "ready", "updated_at": 100],
            ["id": "undated-task", "title": "Undated task", "status": "ready"]
        ]]]]
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "shell.exec", let command = params["command"] as? String { commands.append(command) }
        return result
    }
}
