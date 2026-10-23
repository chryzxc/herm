import Foundation

enum SessionKanbanActivityPresentation {
    struct BotWorkRow: Identifiable, Equatable {
        let taskID: String
        let botID: String
        let botName: String
        let title: String
        let status: Status

        var id: String { taskID }
    }

    enum Status: Equatable {
        case blocked
        case done
        case ready
        case review
        case running
        case unknown(String)

        init(rawValue: String) {
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "blocked": self = .blocked
            case "done", "completed", "complete", "archived": self = .done
            case "ready", "scheduled", "todo", "triage": self = .ready
            case "review", "waiting", "pending": self = .review
            case "running", "working", "in_progress", "in-progress": self = .running
            case let value: self = .unknown(value.isEmpty ? "unknown" : value)
            }
        }

        var label: String {
            switch self {
            case .blocked: "BLOCKED"
            case .done: "DONE"
            case .ready: "READY"
            case .review: "REVIEW"
            case .running: "RUNNING"
            case .unknown(let value): value.uppercased()
            }
        }

        var isCompleted: Bool {
            if case .done = self { return true }
            return false
        }

        private var sortRank: Int {
            switch self {
            case .running: 0
            case .blocked: 1
            case .ready: 2
            case .review: 3
            case .unknown: 4
            case .done: 5
            }
        }

        static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.sortRank < rhs.sortRank
        }
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let status: Status
        let detail: String?
        let assignee: String?
        let boardSlug: String?
    }

    struct Snapshot: Equatable {
        let activeRows: [Row]
        let completedRows: [Row]

        var activeCount: Int { activeRows.count }
        var completedCount: Int { completedRows.count }
        var blockedCount: Int { activeRows.filter { $0.status == .blocked }.count }
        var runningCount: Int { activeRows.filter { $0.status == .running }.count }
    }

    static func makeSnapshot(tasks: [KanbanTaskSummary]) -> Snapshot {
        let rows = tasks.map { task in
            Row(
                id: task.id,
                title: task.title,
                status: Status(rawValue: task.status),
                detail: trimmed(task.detail),
                assignee: trimmed(task.assignee),
                boardSlug: task.boardSlug
            )
        }
        let completedRows =
            rows
            .filter { $0.status.isCompleted }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let activeRows =
            rows
            .filter { !$0.status.isCompleted }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status < rhs.status
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        return Snapshot(activeRows: activeRows, completedRows: completedRows)
    }

    static func botWork(tasks: [KanbanTaskSummary], bots: [BotSummary], sessionID: String?) -> [BotWorkRow] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        let botByID = Dictionary(uniqueKeysWithValues: bots.map { ($0.id, $0) })
        return tasks.compactMap { task in
            guard task.sessionID == sessionID,
                let assignee = trimmed(task.assignee),
                let bot = botByID[assignee],
                !bot.isHidden
            else { return nil }
            return BotWorkRow(
                taskID: task.id,
                botID: bot.id,
                botName: bot.name,
                title: task.title,
                status: Status(rawValue: task.status)
            )
        }.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status < rhs.status }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
