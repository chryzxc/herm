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

    /// Uses Hermes' typed Kanban dashboard projection instead of `shell.exec`.
    /// That endpoint returns card summaries and is not subject to the control
    /// RPC's 4 KB stdout cap (full CLI rows include task bodies).
    func kanbanList(boardSlug: String? = nil, filter: KanbanListFilter = .init()) async throws -> HermesCLIResult {
        if let boardSlug, !boardSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await kanbanList(forBoard: boardSlug, filter: filter)
        }
        return try await kanbanListAggregate(filter: filter)
    }

    /// The global Control Kanban projection. This intentionally enumerates all
    /// active boards; callers that have a board selection must use `kanbanList`.
    func kanbanListAggregate(filter: KanbanListFilter = .init()) async throws -> HermesCLIResult {
        let inventory = try await rpc.fetchHTTP("/api/plugins/kanban/boards")
        let boards = inventory["boards"] as? [[String: Any]] ?? []
        let boardSlugs: [String] = boards.compactMap { board in
            guard (filter.includeArchived || !(board["archived"] as? Bool ?? false)),
                  let slug = board["slug"] as? String,
                  !slug.isEmpty else { return nil }
            return slug
        }

        return try await kanbanList(forBoardSlugs: boardSlugs, filter: filter)
    }

    private func kanbanList(forBoard boardSlug: String, filter: KanbanListFilter) async throws -> HermesCLIResult {
        try await kanbanList(forBoardSlugs: [boardSlug], filter: filter)
    }

    private func kanbanList(forBoardSlugs boardSlugs: [String], filter: KanbanListFilter) async throws -> HermesCLIResult {
        let boardPaths = try boardSlugs.map(Self.kanbanBoardPath)

        var rows: [[String: Any]] = []
        for (boardSlug, path) in zip(boardSlugs, boardPaths) {
            let response = try await rpc.fetchHTTP(path)
            let columns = response["columns"] as? [[String: Any]] ?? []
            rows += columns.flatMap { $0["tasks"] as? [[String: Any]] ?? [] }.map { task in
                var task = task
                // The aggregate endpoint does not consistently include the
                // owning board on each card. Preserve the request scope so
                // actions on a card can be routed back to the right board.
                if task["board_slug"] == nil {
                    task["board_slug"] = boardSlug
                }
                return task
            }
        }
        rows = rows.filter { Self.matches($0, filter: filter) }
        if let sort = filter.sort { rows = Self.sorted(rows, by: sort) }
        let data = try JSONSerialization.data(withJSONObject: rows)
        return HermesCLIResult(stdout: String(decoding: data, as: UTF8.self), stderr: "", succeeded: true)
    }

    private static func kanbanBoardPath(_ slug: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw HermesCLIError.invalidArgument
        }
        return "/api/plugins/kanban/board?board=\(encoded)"
    }

    private static func matches(_ row: [String: Any], filter: KanbanListFilter) -> Bool {
        if !filter.includeArchived, row["status"] as? String == "archived" { return false }
        if let status = filter.status, row["status"] as? String != status { return false }
        if let assignee = filter.assignee, !assignee.isEmpty, row["assignee"] as? String != assignee { return false }
        if let sessionID = filter.sessionID, !sessionID.isEmpty, row["session_id"] as? String != sessionID { return false }
        // Do not approximate Hermes' identity-aware `--mine` filter with
        // "has an assignee". The dashboard projection must explicitly mark
        // ownership or the filter would silently show someone else's work.
        return !filter.mine || (row["is_mine"] as? Bool ?? row["mine"] as? Bool ?? false)
    }

    private static func sorted(_ rows: [[String: Any]], by key: String) -> [[String: Any]] {
        let indexed = rows.enumerated().map { (index: $0.offset, row: $0.element) }
        guard key == "updated" || key == "title" || key == "status" || key == "assignee" else { return rows }
        return indexed.sorted { lhs, rhs in
            if key == "updated" {
                let leftDate = updatedDate(lhs.row)
                let rightDate = updatedDate(rhs.row)
                switch (leftDate, rightDate) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.index < rhs.index
                }
            }
            let comparison = ((lhs.row[key] as? String) ?? "").localizedCaseInsensitiveCompare((rhs.row[key] as? String) ?? "")
            return comparison == .orderedSame ? lhs.index < rhs.index : comparison == .orderedAscending
        }.map(\.row)
    }

    private static func updatedDate(_ row: [String: Any]) -> Date? {
        for key in ["updated_at", "updatedAt", "updated", "last_updated_at", "latest_event_at", "completed_at", "started_at"] {
            if let number = row[key] as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
            if let value = row[key] as? Double { return Date(timeIntervalSince1970: value) }
            if let value = row[key] as? String {
                if let timestamp = Double(value) { return Date(timeIntervalSince1970: timestamp) }
                if let date = ISO8601DateFormatter().date(from: value) { return date }
            }
        }
        return nil
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
    func kanbanCreate(boardSlug: String? = nil, title: String, body: String?, sessionID: String? = nil) async throws -> HermesCLIResult {
        var words = kanbanWords(boardSlug: boardSlug, action: "create") + ["--json"]
        if let body, !body.isEmpty { words += ["--body", body] }
        if let sessionID, !sessionID.isEmpty { words += ["--session", sessionID] }
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
    func enabledSkillsList() async throws -> HermesCLIResult {
        try await run(HermesFeatureContract.enabledSkillsCommand.words)
    }
    func mcpTest(name: String) async throws -> HermesCLIResult { try await run(["hermes", "mcp", "test", name]) }
    func journey() async throws -> HermesCLIResult { try await run(["hermes", "journey", "--json"]) }
    func sessionStats() async throws -> HermesCLIResult { try await run(["hermes", "sessions", "stats"]) }
    func memoryStatus() async throws -> HermesCLIResult { try await run(["hermes", "memory", "status"]) }
    func skinList() async throws -> HermesCLIResult { try await run(["hermes", "skin", "list"]) }
    func installedPetsList() async throws -> HermesCLIResult { try await run(["hermes", "pets", "list", "--installed"]) }
    func emergencyStop(reason: String? = nil) async throws -> HermesCLIResult {
        var words = ["hermes", "pause"]
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            words += ["--reason", reason]
        }
        return try await run(words)
    }
    func resumeEmergencyStop() async throws -> HermesCLIResult { try await run(["hermes", "resume"]) }

    private func kanbanWords(boardSlug: String?, action: String) -> [String] {
        var words = ["hermes", "kanban"]
        if let boardSlug, !boardSlug.isEmpty { words += ["--board", boardSlug] }
        words.append(action)
        return words
    }

    private func run(_ words: [String]) async throws -> HermesCLIResult {
        let raw = try await rpc.runCommand(HermesCLICommand(words))
        let stdout = raw["stdout"] as? String ?? ""
        let stderr = HermesDiagnosticsService.safeSummary(raw["stderr"] as? String ?? "")
        let succeeded = AppleRemindersAdapter.shellResultSucceeded(raw)
        return HermesCLIResult(stdout: stdout, stderr: stderr, succeeded: succeeded)
    }
}
