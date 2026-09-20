import Foundation

enum KanbanLane: String, CaseIterable, Identifiable, Hashable {
    case triage = "Triage"
    case todo = "Todo"
    case ready = "Ready"
    case running = "Running"
    case review = "Review"
    case scheduled = "Scheduled"
    case blocked = "Blocked"
    case done = "Done"

    var id: String { rawValue }
}

struct KanbanBoardPresentation {
    struct Snapshot {
        let tasksByLane: [KanbanLane: [KanbanTaskSummary]]
        let botByAssignee: [String: BotSummary]
        let visibleBotByAssignee: [String: BotSummary]
        let detailByTaskID: [String: String]

        var totalCount: Int { tasksByLane.values.reduce(0) { $0 + $1.count } }

        func tasks(in lane: KanbanLane) -> [KanbanTaskSummary] {
            tasksByLane[lane] ?? []
        }

        func detail(for taskID: String) -> String? {
            detailByTaskID[taskID]
        }

        func bot(for assignee: String?) -> BotSummary? {
            guard let assignee else { return nil }
            return botByAssignee[KanbanBoardPresentation.normalized(assignee)]
        }

        func visibleBot(for assignee: String?) -> BotSummary? {
            guard let assignee else { return nil }
            return visibleBotByAssignee[KanbanBoardPresentation.normalized(assignee)]
        }
    }

    static func makeSnapshot(
        tasks: [KanbanTaskSummary],
        bots: [BotSummary],
        visibleBots: [BotSummary]? = nil
    ) -> Snapshot {
        var tasksByLane = Dictionary(uniqueKeysWithValues: KanbanLane.allCases.map { ($0, [KanbanTaskSummary]()) })
        var detailByTaskID: [String: String] = [:]

        for task in tasks {
            tasksByLane[lane(for: task.status), default: []].append(task)
            if let detail = cardDetail(task.detail) {
                detailByTaskID[task.id] = detail
            }
        }

        var botByAssignee: [String: BotSummary] = [:]
        for bot in bots {
            botByAssignee[normalized(bot.id)] = bot
        }
        var visibleBotByAssignee: [String: BotSummary] = [:]
        for bot in visibleBots ?? bots {
            visibleBotByAssignee[normalized(bot.id)] = bot
        }

        return Snapshot(
            tasksByLane: tasksByLane,
            botByAssignee: botByAssignee,
            visibleBotByAssignee: visibleBotByAssignee,
            detailByTaskID: detailByTaskID
        )
    }

    static func lane(for rawStatus: String) -> KanbanLane {
        let status = normalized(rawStatus).replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if ["done", "completed", "complete", "archived"].contains(status) { return .done }
        if ["blocked", "failed", "error"].contains(status) { return .blocked }
        return switch status {
        case "triage": KanbanLane.triage
        case "todo": KanbanLane.todo
        case "ready": KanbanLane.ready
        case "running", "active", "in_progress", "inprogress", "working": KanbanLane.running
        case "review": KanbanLane.review
        case "scheduled": KanbanLane.scheduled
        default: KanbanLane.todo
        }
    }

    static func cardDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let lines = detail
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("TASK_ID:") }
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "OBJECTIVE:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let normalized = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
