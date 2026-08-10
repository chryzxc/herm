import Foundation

/// An allow-listed command sent through Hermes' authenticated `shell.exec` RPC.
/// Keeping executable words and arguments separate prevents views and models from
/// constructing ad-hoc shell expressions.
struct HermesCLICommand: Equatable {
    let words: [String]

    init(_ words: [String]) {
        self.words = words
    }

    func rendered() throws -> String {
        guard !words.isEmpty else { throw HermesCLIError.invalidCommand }
        return try words.map(Self.quote).joined(separator: " ")
    }

    private static func quote(_ word: String) throws -> String {
        guard !word.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw HermesCLIError.invalidArgument
        }
        // The executable/subcommands are allow-listed by the adapter as well;
        // quoting them too keeps rendering uniform and testable.
        return "'\(word.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum HermesCLIError: LocalizedError {
    case invalidCommand
    case invalidArgument
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand: "Hermes command is invalid."
        case .invalidArgument: "A Hermes command argument contains an unsupported null character."
        case .failed(let detail): detail
        }
    }
}

struct HermesCLIResult: Equatable {
    let stdout: String
    let stderr: String
    let succeeded: Bool
}

/// The only CLI projection boundary used by the Dock. It deliberately exposes
/// named Hermes operations rather than a public arbitrary-command API.
@MainActor
final class HermesCLIAdapter {
    private let rpc: HermesControlRPC

    init(rpc: HermesControlRPC) {
        self.rpc = rpc
    }

    func kanbanList(boardSlug: String? = nil, filter: KanbanListFilter = .init()) async throws -> HermesCLIResult {
        var words = kanbanWords(boardSlug: boardSlug, action: "list") + ["--json"]
        if let status = filter.status { words += ["--status", status] }
        if let assignee = filter.assignee, !assignee.isEmpty { words += ["--assignee", assignee] }
        if filter.mine { words.append("--mine") }
        if let sessionID = filter.sessionID, !sessionID.isEmpty { words += ["--session", sessionID] }
        if filter.includeArchived { words.append("--archived") }
        if let sort = filter.sort { words += ["--sort", sort] }
        return try await run(words)
    }
    func kanbanAssignees(boardSlug: String? = nil) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "assignees") + ["--json"]) }
    func kanbanShow(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "show") + ["--json", taskID]) }
    func kanbanRuns(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "runs") + ["--json", taskID]) }
    func kanbanStats(boardSlug: String? = nil) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "stats") + ["--json"]) }
    func kanbanBoards(includeArchived: Bool = false) async throws -> HermesCLIResult {
        var words = ["hermes", "kanban", "boards", "list", "--json"]
        if includeArchived { words.append("--all") }
        return try await run(words)
    }
    func kanbanDiagnostics(boardSlug: String? = nil, severity: String? = nil, taskID: String? = nil) async throws -> HermesCLIResult {
        var words = kanbanWords(boardSlug: boardSlug, action: "diagnostics") + ["--json"]
        if let severity, !severity.isEmpty { words += ["--severity", severity] }
        if let taskID, !taskID.isEmpty { words += ["--task", taskID] }
        return try await run(words)
    }
    func kanbanAttachments(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "attachments") + ["--json", taskID])
    }
    func promptSize(platform: String? = nil) async throws -> HermesCLIResult {
        var words = ["hermes", "prompt-size", "--json"]
        if let platform, !platform.isEmpty { words += ["--platform", platform] }
        return try await run(words)
    }
    func kanbanCreate(boardSlug: String? = nil, title: String, body: String?) async throws -> HermesCLIResult {
        var words = kanbanWords(boardSlug: boardSlug, action: "create") + ["--json"]
        if let body, !body.isEmpty { words += ["--body", body] }
        words.append(title)
        return try await run(words)
    }
    func kanbanComplete(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "complete") + [taskID, "--summary", "Completed from Hermes Control"]) }
    func kanbanBlock(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "block") + [taskID, "Blocked from Hermes Control"]) }
    func kanbanUnblock(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "unblock") + [taskID, "--reason", "Unblocked from Hermes Control"]) }
    func kanbanArchive(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "archive") + [taskID]) }
    func kanbanComment(boardSlug: String? = nil, taskID: String, text: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "comment") + [taskID, text]) }
    func kanbanSchedule(boardSlug: String? = nil, taskID: String, reason: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "schedule") + [taskID, reason]) }
    func kanbanAssign(boardSlug: String? = nil, taskID: String, profile: String, reassign: Bool, reclaim: Bool) async throws -> HermesCLIResult {
        var words = kanbanWords(boardSlug: boardSlug, action: reassign ? "reassign" : "assign")
        if reassign && reclaim { words.append("--reclaim") }
        words += [taskID, profile]
        return try await run(words)
    }
    func kanbanPromote(boardSlug: String? = nil, taskID: String, reason: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "promote") + [taskID, reason]) }
    func kanbanReclaim(boardSlug: String? = nil, taskID: String, reason: String) async throws -> HermesCLIResult { try await run(kanbanWords(boardSlug: boardSlug, action: "reclaim") + ["--reason", reason, taskID]) }

    func cronRun(jobID: String) async throws -> HermesCLIResult { try await run(["hermes", "cron", "run", jobID]) }
    func cronRuns(limit: Int = 20) async throws -> HermesCLIResult { try await run(["hermes", "cron", "runs", "--limit", String(limit)]) }
    func cronEdit(jobID: String, changes: [CronEditField: String]) async throws -> HermesCLIResult {
        var words = ["hermes", "cron", "edit"]
        for field in CronEditField.allCases {
            if let value = changes[field] { words += [field.flag, value] }
        }
        words.append(jobID)
        return try await run(words)
    }

    func mcpList() async throws -> HermesCLIResult { try await run(["hermes", "mcp", "list"]) }
    func mcpTest(name: String) async throws -> HermesCLIResult { try await run(["hermes", "mcp", "test", name]) }
    func journey() async throws -> HermesCLIResult { try await run(["hermes", "journey", "--json"]) }
    func sessionStats() async throws -> HermesCLIResult { try await run(["hermes", "sessions", "stats"]) }
    func memoryStatus() async throws -> HermesCLIResult { try await run(["hermes", "memory", "status"]) }

    private func kanbanWords(boardSlug: String?, action: String) -> [String] {
        var words = ["hermes", "kanban"]
        if let boardSlug, !boardSlug.isEmpty { words += ["--board", boardSlug] }
        words.append(action)
        return words
    }

    private func run(_ words: [String]) async throws -> HermesCLIResult {
        let rendered = try HermesCLICommand(words).rendered()
        let raw = try await rpc.shell(rendered)
        let stdout = raw["stdout"] as? String ?? ""
        let stderr = HermesDiagnosticsService.safeSummary(raw["stderr"] as? String ?? "")
        let succeeded = AppleRemindersAdapter.shellResultSucceeded(raw)
        return HermesCLIResult(stdout: stdout, stderr: stderr, succeeded: succeeded)
    }
}
