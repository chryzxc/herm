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

    @Test func kanbanListForwardsOnlyHermesSupportedFilters() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanList(filter: KanbanListFilter(status: "ready", assignee: "default", mine: true, sessionID: "session-1", includeArchived: true, sort: "priority-desc"))

        #expect(client.commands.last == "'hermes' 'kanban' 'list' '--json' '--status' 'ready' '--assignee' 'default' '--mine' '--session' 'session-1' '--archived' '--sort' 'priority-desc'")
    }

    @Test func kanbanBoardCommandsUseSupportedContracts() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanBoards(includeArchived: true)
        #expect(client.commands.last == "'hermes' 'kanban' 'boards' 'list' '--json' '--all'")

        _ = try await adapter.kanbanList(boardSlug: "client-board")
        #expect(client.commands.last == "'hermes' 'kanban' '--board' 'client-board' 'list' '--json'")
    }
}

@MainActor
private final class CLITestRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var commands: [String] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "shell.exec", let command = params["command"] as? String { commands.append(command) }
        return ["code": 0, "stdout": "ok"]
    }
}
