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

struct HermesCLIResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let succeeded: Bool
}

/// The only CLI projection boundary used by the Dock. It deliberately exposes
/// named Hermes operations rather than a public arbitrary-command API.
@MainActor
final class HermesCLIAdapter {
    private struct KanbanBoardRows: @unchecked Sendable {
        let index: Int
        let rows: [[String: Any]]
    }

    private let rpc: HermesControlRPC
    /// A board read is several MB and seconds of backend CPU (card bodies), and
    /// five pollers ask for it. Background polls join any read of the board
    /// started this recently; explicit refreshes always read fresh.
    var backgroundBoardReadReuse: TimeInterval = 10
    private var boardReads: [String: (startedAt: Date, task: Task<KanbanBoardRows, Error>)] = [:]

    init(rpc: HermesControlRPC) {
        self.rpc = rpc
    }

    /// Uses Hermes' typed Kanban dashboard projection instead of `shell.exec`.
    /// That endpoint returns card summaries and is not subject to the control
    /// RPC's 4 KB stdout cap (full CLI rows include task bodies).
    func kanbanList(boardSlug: String? = nil, filter: KanbanListFilter = .init(), background: Bool = false) async throws
        -> HermesCLIResult
    {
        if let boardSlug, !boardSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await kanbanList(forBoardSlugs: [boardSlug], filter: filter, background: background)
        }
        return try await kanbanListAggregate(filter: filter, background: background)
    }

    /// The global Control Kanban projection. This intentionally enumerates all
    /// active boards; callers that have a board selection must use `kanbanList`.
    func kanbanListAggregate(filter: KanbanListFilter = .init(), background: Bool = false) async throws
        -> HermesCLIResult
    {
        let inventory = try await rpc.fetchHTTP("/api/plugins/kanban/boards")
        let boards = inventory["boards"] as? [[String: Any]] ?? []
        let boardSlugs: [String] = boards.compactMap { board in
            guard filter.includeArchived || !(board["archived"] as? Bool ?? false),
                let slug = board["slug"] as? String,
                !slug.isEmpty
            else { return nil }
            return slug
        }

        return try await kanbanList(forBoardSlugs: boardSlugs, filter: filter, background: background)
    }

    private func kanbanList(forBoardSlugs boardSlugs: [String], filter: KanbanListFilter, background: Bool) async throws
        -> HermesCLIResult
    {
        let fetchedBoards = try await withThrowingTaskGroup(of: KanbanBoardRows.self, returning: [KanbanBoardRows].self)
        { group in
            for (index, boardSlug) in boardSlugs.enumerated() {
                group.addTask {
                    try await self.fetchKanbanBoardRows(index: index, boardSlug: boardSlug, background: background)
                }
            }
            var results: [KanbanBoardRows] = []
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }

        return try await Task.detached(priority: .utility) {
            var rows = fetchedBoards.flatMap(\.rows)
            rows = rows.filter { Self.matches($0, filter: filter) }
            if let sort = filter.sort { rows = Self.sorted(rows, by: sort) }
            let data = try JSONSerialization.data(withJSONObject: rows)
            return HermesCLIResult(stdout: String(decoding: data, as: UTF8.self), stderr: "", succeeded: true)
        }.value
    }

    private func fetchKanbanBoardRows(index: Int, boardSlug: String, background: Bool) async throws -> KanbanBoardRows {
        if background, let read = boardReads[boardSlug],
            Date().timeIntervalSince(read.startedAt) < backgroundBoardReadReuse
        {
            return KanbanBoardRows(index: index, rows: try await read.task.value.rows)
        }
        // Archived cards are included once here and dropped by `matches`, so
        // every caller (notch, board, session activity, chat) shares one read.
        let path = try Self.kanbanBoardPath(boardSlug) + "&include_archived=true"
        let task = Task { [rpc] in
            let response = try await rpc.fetchHTTP(path)
            let columns = response["columns"] as? [[String: Any]] ?? []
            let rows = columns.flatMap { $0["tasks"] as? [[String: Any]] ?? [] }.map { task in
                var task = task
                // The aggregate endpoint does not consistently include the owning
                // board on each card. Preserve the request scope for task actions.
                if task["board_slug"] == nil {
                    task["board_slug"] = boardSlug
                }
                return task
            }
            return KanbanBoardRows(index: 0, rows: rows)
        }
        boardReads[boardSlug] = (Date(), task)
        do {
            return KanbanBoardRows(index: index, rows: try await task.value.rows)
        } catch {
            if boardReads[boardSlug]?.task == task { boardReads[boardSlug] = nil }
            throw error
        }
    }

    private static func kanbanBoardPath(_ slug: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw HermesCLIError.invalidArgument
        }
        return "/api/plugins/kanban/board?board=\(encoded)"
    }

    nonisolated private static func matches(_ row: [String: Any], filter: KanbanListFilter) -> Bool {
        if !filter.includeArchived, row["status"] as? String == "archived" { return false }
        if let status = filter.status, row["status"] as? String != status { return false }
        if let assignee = filter.assignee, !assignee.isEmpty, row["assignee"] as? String != assignee { return false }
        if let sessionID = filter.sessionID, !sessionID.isEmpty, row["session_id"] as? String != sessionID {
            return false
        }
        // Do not approximate Hermes' identity-aware `--mine` filter with
        // "has an assignee". The dashboard projection must explicitly mark
        // ownership or the filter would silently show someone else's work.
        return !filter.mine || (row["is_mine"] as? Bool ?? row["mine"] as? Bool ?? false)
    }

    nonisolated private static func sorted(_ rows: [[String: Any]], by key: String) -> [[String: Any]] {
        guard
            key == "updated" || key == "created-desc" || key == "priority-desc" || key == "title" || key == "status"
                || key == "assignee"
        else { return rows }
        let formatter = ISO8601DateFormatter()
        // Parse each timestamp once, rather than for every sort comparison.
        let indexed = rows.enumerated().map {
            (
                index: $0.offset, row: $0.element,
                date: key == "updated"
                    ? updatedDate($0.element, formatter: formatter)
                    : key == "created-desc" ? createdDate($0.element, formatter: formatter) : nil
            )
        }
        return indexed.sorted { lhs, rhs in
            if key == "updated" || key == "created-desc" {
                switch (lhs.date, rhs.date) {
                case (let left?, let right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.index < rhs.index
                }
            }
            if key == "priority-desc" {
                let leftPriority = priority(lhs.row)
                let rightPriority = priority(rhs.row)
                switch (leftPriority, rightPriority) {
                case (let left?, let right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.index < rhs.index
                }
            }
            let comparison = ((lhs.row[key] as? String) ?? "").localizedCaseInsensitiveCompare(
                (rhs.row[key] as? String) ?? "")
            return comparison == .orderedSame ? lhs.index < rhs.index : comparison == .orderedAscending
        }.map(\.row)
    }

    nonisolated private static func updatedDate(_ row: [String: Any], formatter: ISO8601DateFormatter) -> Date? {
        for key in [
            "updated_at", "updatedAt", "updated", "last_updated_at", "latest_event_at", "completed_at", "started_at",
        ] {
            if let number = row[key] as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
            if let value = row[key] as? Double { return Date(timeIntervalSince1970: value) }
            if let value = row[key] as? String {
                if let timestamp = Double(value) { return Date(timeIntervalSince1970: timestamp) }
                if let date = formatter.date(from: value) { return date }
            }
        }
        return nil
    }

    nonisolated private static func createdDate(_ row: [String: Any], formatter: ISO8601DateFormatter) -> Date? {
        for key in ["created_at", "createdAt", "created"] {
            if let number = row[key] as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
            if let value = row[key] as? Double { return Date(timeIntervalSince1970: value) }
            if let value = row[key] as? String {
                if let timestamp = Double(value) { return Date(timeIntervalSince1970: timestamp) }
                if let date = formatter.date(from: value) { return date }
            }
        }
        return nil
    }

    nonisolated private static func priority(_ row: [String: Any]) -> Int? {
        if let number = row["priority"] as? NSNumber { return number.intValue }
        if let value = row["priority"] as? Int { return value }
        if let value = row["priority"] as? String { return Int(value) }
        return nil
    }
    func kanbanAssignees(boardSlug: String? = nil) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "assignees") + ["--json"])
    }
    func kanbanShow(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "show") + ["--json", taskID])
    }
    func kanbanRuns(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "runs") + ["--json", taskID])
    }
    func kanbanStats(boardSlug: String? = nil) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "stats") + ["--json"])
    }
    func kanbanBoards(includeArchived: Bool = false) async throws -> HermesCLIResult {
        var words = ["hermes", "kanban", "boards", "list", "--json"]
        if includeArchived { words.append("--all") }
        return try await run(words)
    }
    func kanbanDiagnostics(boardSlug: String? = nil, severity: String? = nil, taskID: String? = nil) async throws
        -> HermesCLIResult
    {
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
        // Free text goes after `--` or as `--opt=value`: argparse would
        // otherwise read a title/body starting with "-" as an option.
        if let body, !body.isEmpty { words.append("--body=\(body)") }
        words += ["--", title]
        return try await run(words)
    }
    func kanbanAttributeSession(taskID: String, sessionID: String) async throws -> HermesCLIResult {
        defer { boardReads.removeAll() }
        return try await run([
            "bash", "\(NSHomeDirectory())/.hermes/scripts/kanban-attribute-session.sh", taskID, sessionID,
        ])
    }
    func configGetCommandAllowlist() async throws -> HermesCLIResult {
        try await run(["hermes", "config", "get", "command_allowlist"])
    }
    func kanbanComplete(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult {
        try await run(
            kanbanWords(boardSlug: boardSlug, action: "complete") + [
                taskID, "--summary", "Completed from Hermes Control",
            ])
    }
    func kanbanBlock(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "block") + [taskID, "Blocked from Hermes Control"])
    }
    func kanbanUnblock(boardSlug: String? = nil, taskID: String, reason: String = "Unblocked from Hermes Control")
        async throws -> HermesCLIResult
    { try await run(kanbanWords(boardSlug: boardSlug, action: "unblock") + [taskID, "--reason", reason]) }
    func kanbanArchive(boardSlug: String? = nil, taskID: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "archive") + [taskID])
    }
    func kanbanComment(boardSlug: String? = nil, taskID: String, text: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "comment") + [taskID, "--", text])
    }
    func kanbanSchedule(boardSlug: String? = nil, taskID: String, reason: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "schedule") + [taskID, "--", reason])
    }
    func kanbanAssign(boardSlug: String? = nil, taskID: String, profile: String, reassign: Bool, reclaim: Bool)
        async throws -> HermesCLIResult
    {
        var words = kanbanWords(boardSlug: boardSlug, action: reassign ? "reassign" : "assign")
        if reassign && reclaim { words.append("--reclaim") }
        words += [taskID, profile]
        return try await run(words)
    }
    /// Moves a card the way the Hermes desktop board does on a lane drop:
    /// PATCH the plugin task route, which applies the workflow-aware
    /// transition (unblock, reopen review) rather than a raw status write.
    func kanbanMove(boardSlug: String? = nil, taskID: String, status: String) async throws -> HermesCLIResult {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encodedID = taskID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw HermesCLIError.invalidArgument
        }
        var path = "/api/plugins/kanban/tasks/\(encodedID)"
        if let boardSlug, !boardSlug.isEmpty {
            guard let encodedBoard = boardSlug.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw HermesCLIError.invalidArgument
            }
            path += "?board=\(encodedBoard)"
        }
        defer { boardReads.removeAll() }
        _ = try await rpc.sendHTTP("PATCH", path: path, body: ["status": status])
        return HermesCLIResult(stdout: "", stderr: "", succeeded: true)
    }
    func kanbanPromote(boardSlug: String? = nil, taskID: String, reason: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "promote") + [taskID, "--", reason])
    }
    func kanbanReclaim(boardSlug: String? = nil, taskID: String, reason: String) async throws -> HermesCLIResult {
        try await run(kanbanWords(boardSlug: boardSlug, action: "reclaim") + ["--reason=\(reason)", taskID])
    }

    /// Removes one entry from Hermes' credential pool. Hermes performs any
    /// source-specific cleanup (such as its singleton device-code login).
    /// Read-only: Hermes peeks each pool and marks the credential it would pick with `←`.
    func authList() async throws -> HermesCLIResult { try await run(["hermes", "auth", "list"]) }
    /// Moves a pooled credential to `priority` (0 = first pick under `fill_first`).
    func authPriority(provider: String, credentialID: String, priority: Int) async throws -> HermesCLIResult {
        try await run(["hermes", "auth", "priority", provider, credentialID, String(priority)])
    }
    func authRemove(provider: String, credentialID: String) async throws -> HermesCLIResult {
        try await run(["hermes", "auth", "remove", provider, credentialID])
    }

    func profileDeleteHelp() async throws -> HermesCLIResult {
        try await run(["hermes", "profile", "delete", "--help"])
    }

    func sessionPinHelp(pinned: Bool) async throws -> HermesCLIResult {
        try await run(["hermes", "sessions", pinned ? "pin" : "unpin", "--help"])
    }

    func setSessionPinned(_ pinned: Bool, sessionID: String, profileID: String?) async throws -> HermesCLIResult {
        guard !sessionID.isEmpty else { throw HermesCLIError.invalidArgument }
        return try await run(
            ["hermes"] + (profileID.map { ["--profile", $0] } ?? [])
                + ["sessions", pinned ? "pin" : "unpin", "--", sessionID])
    }

    func deleteProfile(profileID: String) async throws -> HermesCLIResult {
        guard !profileID.isEmpty, profileID.lowercased() != "default" else {
            throw HermesCLIError.failed("The default Bot cannot be deleted.")
        }
        return try await run(["hermes", "profile", "delete", "--yes", "--", profileID])
    }

    func cronRun(jobID: String) async throws -> HermesCLIResult { try await run(["hermes", "cron", "run", jobID]) }
    func cronRuns(limit: Int = 20, jobID: String? = nil, profileID: String? = nil) async throws -> HermesCLIResult {
        try await run(
            ["hermes"] + (profileID.map { ["--profile", $0] } ?? []) + ["cron", "runs", "--limit", String(limit)]
                + (jobID.map { [$0] } ?? []))
    }
    func cronEdit(jobID: String, changes: [CronEditField: String], profileID: String? = nil) async throws
        -> HermesCLIResult
    {
        var words = ["hermes"] + (profileID.map { ["--profile", $0] } ?? []) + ["cron", "edit"]
        for field in CronEditField.allCases {
            if let value = changes[field] { words.append("\(field.flag)=\(value)") }
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
    func installedPetsList() async throws -> HermesCLIResult {
        try await run(["hermes", "pets", "list", "--installed"])
    }
    func emergencyStop(reason: String? = nil) async throws -> HermesCLIResult {
        var words = ["hermes", "pause"]
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            words.append("--reason=\(reason)")
        }
        return try await run(words)
    }
    func resumeEmergencyStop() async throws -> HermesCLIResult { try await run(["hermes", "resume"]) }

    private static let kanbanReadActions: Set<String> = [
        "assignees", "show", "runs", "stats", "diagnostics", "attachments", "boards", "list",
    ]

    static func isKanbanMutation(_ words: [String]) -> Bool {
        guard words.starts(with: ["hermes", "kanban"]) else { return false }
        var rest = words.dropFirst(2)
        if rest.first == "--board" { rest = rest.dropFirst(2) }
        return rest.first.map { !kanbanReadActions.contains($0) } ?? false
    }

    private func kanbanWords(boardSlug: String?, action: String) -> [String] {
        var words = ["hermes", "kanban"]
        if let boardSlug, !boardSlug.isEmpty { words += ["--board", boardSlug] }
        words.append(action)
        return words
    }

    private func run(_ words: [String]) async throws -> HermesCLIResult {
        // A card change must not be hidden behind the shared board read.
        defer { if Self.isKanbanMutation(words) { boardReads.removeAll() } }
        let raw = try await rpc.runCommand(HermesCLICommand(words))
        let stdout = raw["stdout"] as? String ?? ""
        let stderr = HermesDiagnosticsService.safeSummary(raw["stderr"] as? String ?? "")
        let succeeded = AppleRemindersAdapter.shellResultSucceeded(raw)
        return HermesCLIResult(stdout: stdout, stderr: stderr, succeeded: succeeded)
    }
}
