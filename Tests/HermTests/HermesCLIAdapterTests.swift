import Foundation
import Testing

@testable import Herm

@MainActor
struct HermesCLIAdapterTests {
    @Test func savedSessionRenameQuotesArgumentsAndChecksCapability() async throws {
        let client = CLITestRPCClient()
        client.result = ["code": 0, "stdout": "usage: hermes sessions rename session_id title"]
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))
        try await adapter.renameSavedSession(sessionID: "saved's", title: "title $(noop)", profileID: "bot's")
        #expect(
            client.commands == [
                "'hermes' 'sessions' 'rename' '--help'",
                "'hermes' '--profile' 'bot'\\''s' 'sessions' 'rename' '--' 'saved'\\''s' 'title $(noop)'",
            ])
        client.result = ["code": 0, "stdout": "unsupported"]
        await #expect(throws: HermesCLIError.self) {
            try await adapter.renameSavedSession(sessionID: "saved", title: "title", profileID: nil)
        }
        #expect(client.commands.count == 3)
    }
    @Test func sessionPinCommandsKeepProfileAndSessionAsQuotedWords() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))
        _ = try await adapter.setSessionPinned(true, sessionID: "saved's $(noop)", profileID: "bot's profile")
        #expect(
            client.commands.last
                == "'hermes' '--profile' 'bot'\\''s profile' 'sessions' 'pin' '--' 'saved'\\''s $(noop)'")
        _ = try await adapter.setSessionPinned(false, sessionID: "saved", profileID: nil)
        #expect(client.commands.last == "'hermes' 'sessions' 'unpin' '--' 'saved'")
    }

    @Test func profileDeletionUsesConfirmedQuotedCommand() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))
        _ = try await adapter.profileDeleteHelp()
        #expect(client.commands.last == "'hermes' 'profile' 'delete' '--help'")
        _ = try await adapter.deleteProfile(profileID: "worker's $(noop)")
        #expect(client.commands.last == "'hermes' 'profile' 'delete' '--yes' '--' 'worker'\\''s $(noop)'")
        let count = client.commands.count
        for name in ["default", "DEFAULT", ""] {
            await #expect(throws: HermesCLIError.self) { _ = try await adapter.deleteProfile(profileID: name) }
        }
        #expect(client.commands.count == count)
    }

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
        #expect(command.contains("'--name=Weekly review'"))
        #expect(command.contains("'--schedule=0 9 * * 1'"))
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

        #expect(
            client.httpPaths == [
                "/api/plugins/kanban/boards", "/api/plugins/kanban/board?board=default&include_archived=false",
            ])
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

        #expect(client.commands.last == "'hermes' 'kanban' 'create' '--json' '--' 'Session work'")
    }

    @Test func dashLeadingFreeTextIsNeverParsedAsAnOption() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanCreate(title: "--help", body: "- bullet")
        #expect(client.commands.last == "'hermes' 'kanban' 'create' '--json' '--body=- bullet' '--' '--help'")

        _ = try await adapter.kanbanComment(taskID: "t_1", text: "- fixed it")
        #expect(client.commands.last == "'hermes' 'kanban' 'comment' 't_1' '--' '- fixed it'")
    }

    @Test func kanbanAttributeSessionUsesUserStateHelper() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanAttributeSession(taskID: "t_abc123", sessionID: "session-1")

        #expect(
            client.commands.last
                == "'bash' '\(NSHomeDirectory())/.hermes/scripts/kanban-attribute-session.sh' 't_abc123' 'session-1'")
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
        #expect(client.httpPaths == ["/api/plugins/kanban/board?board=client-board&include_archived=false"])
    }

    @Test func kanbanBoardScopeSafelyEncodesQueryReservedCharacters() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanList(boardSlug: "client&ops=west")

        #expect(client.httpPaths == ["/api/plugins/kanban/board?board=client%26ops%3Dwest&include_archived=false"])
    }

    @Test func kanbanPollersShareOneBoardReadUntilACardChanges() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))
        let path = "/api/plugins/kanban/board?board=client-board&include_archived=false"
        let archivedPath = "/api/plugins/kanban/board?board=client-board&include_archived=true"

        _ = try await adapter.kanbanList(boardSlug: "client-board")
        _ = try await adapter.kanbanList(
            boardSlug: "client-board", filter: KanbanListFilter(includeArchived: true), background: true)
        _ = try await adapter.kanbanShow(boardSlug: "client-board", taskID: "t_1")
        _ = try await adapter.kanbanList(boardSlug: "client-board", background: true)
        #expect(client.httpPaths == [path, archivedPath])

        // An explicit refresh, or any card change, reads fresh.
        _ = try await adapter.kanbanList(boardSlug: "client-board")
        _ = try await adapter.kanbanComment(boardSlug: "client-board", taskID: "t_1", text: "done")
        _ = try await adapter.kanbanList(boardSlug: "client-board", background: true)
        #expect(client.httpPaths == [path, archivedPath, path, path])
    }

    @Test func aggregateKanbanIncludesArchivedBoardsOnlyWhenRequested() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        let result = try await adapter.kanbanList(filter: KanbanListFilter(includeArchived: true))

        #expect(
            client.httpPaths == [
                "/api/plugins/kanban/boards?include_archived=true",
                "/api/plugins/kanban/board?board=default&include_archived=true",
                "/api/plugins/kanban/board?board=archived-board&include_archived=true",
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

    @Test func createdAndPriorityKanbanSortsAreDescendingAndStable() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        let created = try await adapter.kanbanList(filter: KanbanListFilter(sort: "created-desc"))
        let createdData = try #require(created.stdout.data(using: .utf8))
        let createdRows = try #require(JSONSerialization.jsonObject(with: createdData) as? [[String: Any]])
        #expect(
            createdRows.compactMap { $0["id"] as? String } == ["new-task", "old-task", "ready-task", "undated-task"])

        let priority = try await adapter.kanbanList(filter: KanbanListFilter(sort: "priority-desc"))
        let priorityData = try #require(priority.stdout.data(using: .utf8))
        let priorityRows = try #require(JSONSerialization.jsonObject(with: priorityData) as? [[String: Any]])
        #expect(
            priorityRows.compactMap { $0["id"] as? String } == ["new-task", "old-task", "ready-task", "undated-task"])
    }

    @Test func largeISODatedBoardSortsWithoutMultiSecondStalls() async throws {
        let client = CLITestRPCClient()
        let formatter = ISO8601DateFormatter()
        client.boardTasks = (0..<500).map { index in
            let rank = (index * 7919) % 500
            return [
                "id": "task-\(rank)", "title": "Work", "status": "ready",
                "updated_at": formatter.string(from: Date(timeIntervalSince1970: 1_750_000_000 + Double(rank))),
            ]
        }
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))
        let start = ContinuousClock.now
        let result = try await adapter.kanbanList(boardSlug: "main", filter: KanbanListFilter(sort: "updated"))
        let elapsed = start.duration(to: .now)
        let data = try #require(result.stdout.data(using: .utf8))
        let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(rows.compactMap { $0["id"] as? String } == (0..<500).reversed().map { "task-\($0)" })
        #expect(elapsed < .seconds(2))
    }

    @Test func isoDatesAndNumericStringsKeepStableDateOrdering() async throws {
        let client = CLITestRPCClient()
        client.boardTasks = [
            [
                "id": "first", "title": "First", "status": "ready", "updated_at": "2025-01-01T00:00:00Z",
                "created_at": "2025-01-01T00:00:00Z",
            ],
            ["id": "undated", "title": "Undated", "status": "ready"],
            [
                "id": "equal", "title": "Equal", "status": "ready", "updated_at": "1735689600",
                "created_at": "1735689600",
            ],
            [
                "id": "newest", "title": "Newest", "status": "ready", "updated_at": "2025-01-02T00:00:00Z",
                "created_at": "2025-01-02T00:00:00Z",
            ],
        ]
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))
        for sort in ["updated", "created-desc"] {
            let result = try await adapter.kanbanList(boardSlug: "main", filter: KanbanListFilter(sort: sort))
            let data = try #require(result.stdout.data(using: .utf8))
            let rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            #expect(rows.compactMap { $0["id"] as? String } == ["newest", "first", "equal", "undated"])
        }
    }
    @Test func kanbanDiagnosticsAndAttachmentsForwardBoardScope() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanDiagnostics(boardSlug: "client-board", severity: "error", taskID: "task-1")
        #expect(
            client.commands.last
                == "'hermes' 'kanban' '--board' 'client-board' 'diagnostics' '--json' '--severity' 'error' '--task' 'task-1'"
        )

        _ = try await adapter.kanbanAttachments(boardSlug: "client-board", taskID: "task-1")
        #expect(client.commands.last == "'hermes' 'kanban' '--board' 'client-board' 'attachments' '--json' 'task-1'")
    }

    @Test func kanbanMovePatchesThePluginTaskRouteWithBoardScope() async throws {
        let client = CLITestRPCClient()
        let adapter = HermesCLIAdapter(rpc: HermesControlRPC(client: client))

        _ = try await adapter.kanbanMove(boardSlug: "client board", taskID: "t_1", status: "ready")
        #expect(client.httpWrites.last?.method == "PATCH")
        #expect(client.httpWrites.last?.path == "/api/plugins/kanban/tasks/t_1?board=client%20board")
        #expect(client.httpWrites.last?.body["status"] as? String == "ready")
        #expect(client.commands.isEmpty)
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
    var boardTasks: [[String: Any]]?

    func connect() async throws {}
    func close() {}

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        httpPaths.append(path)
        if path == "/api/plugins/kanban/boards" || path == "/api/plugins/kanban/boards?include_archived=true" {
            return [
                "boards": [
                    ["slug": "default", "archived": false],
                    ["slug": "archived-board", "archived": true],
                ]
            ]
        }
        if path.contains("archived-board") {
            return [
                "columns": [
                    [
                        "name": "archived",
                        "tasks": [
                            [
                                "id": "archived-task", "title": "Archived task", "status": "archived",
                            ]
                        ],
                    ]
                ]
            ]
        }
        if let boardTasks { return ["columns": [["tasks": boardTasks]]] }
        return [
            "columns": [
                [
                    "name": "ready",
                    "tasks": [
                        ["id": "ready-task", "title": "Ready task", "status": "ready"],
                        [
                            "id": "new-task", "title": "New task", "status": "ready", "updated_at": 200,
                            "created_at": 200, "priority": 80,
                        ],
                        [
                            "id": "old-task", "title": "Old task", "status": "ready", "updated_at": 100,
                            "created_at": 100, "priority": 10,
                        ],
                        ["id": "undated-task", "title": "Undated task", "status": "ready"],
                    ],
                ]
            ]
        ]
    }

    private(set) var httpWrites: [(method: String, path: String, body: [String: Any])] = []

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        httpWrites.append((method, path, body))
        return [:]
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "shell.exec", let command = params["command"] as? String { commands.append(command) }
        return result
    }
}
