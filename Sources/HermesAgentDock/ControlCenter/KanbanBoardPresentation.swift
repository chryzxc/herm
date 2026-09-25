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

    /// The Hermes status a card takes when dropped into this lane.
    var status: String { rawValue.lowercased() }

    /// System-owned lanes: a card can be dragged out, never in (parity with
    /// the Hermes desktop board). The dispatcher sets Running and Review;
    /// Scheduled needs a wake-up time only an agent or the CLI can attach.
    var lockedDropReason: String? {
        switch self {
        case .running: "Running is set by the dispatcher when a worker claims the card."
        case .review: "Review is entered by the dispatcher when a review agent takes the card."
        case .scheduled: "Scheduled needs a wake-up time, so agents set it. Cards can’t be dragged into it."
        default: nil
        }
    }
}

/// What dropping a card on a lane does.
enum KanbanDropOutcome: Equatable {
    /// Same lane; nothing to do.
    case none
    /// A plain workflow move (Triage, Todo, Ready).
    case move(KanbanLane)
    /// A move that releases a worker claim; it is confirmed first, like the
    /// card menu's Done and Block.
    case confirm(KanbanTaskAction)
    case refused(String)
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

    static func dropOutcome(taskStatus: String, target: KanbanLane) -> KanbanDropOutcome {
        guard lane(for: taskStatus) != target else { return .none }
        if let reason = target.lockedDropReason { return .refused(reason) }
        return switch target {
        case .done: .confirm(.complete)
        case .blocked: .confirm(.block)
        default: .move(target)
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

    /// Minute-resolution age for card footers, e.g. "now", "5m", "8h", "2d".
    static func compactAge(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        if days < 365 { return "\(days / 7)w" }
        return "\(days / 365)y"
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
