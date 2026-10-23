import Foundation

/// Presentation-only comparison of successful, unfiltered all-board snapshots.
/// The initial snapshot is a silent baseline; failures never replace it.
struct EdgeKanbanActivity {
    private var previous: [KanbanTaskIdentity: KanbanTaskSummary]?
    private var changes: [KanbanTaskIdentity: Change] = [:]
    private struct Change {
        let detail: String
        let observedAt: Date
    }

    mutating func ingest(_ tasks: [KanbanTaskSummary], now: Date = .now) -> Bool {
        let current = Dictionary(tasks.map { (Self.identity($0), $0) }, uniquingKeysWith: { _, last in last })
        defer { previous = current }
        guard let previous else { return false }
        changes = changes.filter { current[$0.key] != nil }
        var changed = false
        for (identity, task) in current {
            guard previous[identity] != task else { continue }
            // Queued cards are not running work, so the preview never shows them.
            guard Self.phase(task.status) != nil else {
                changes.removeValue(forKey: identity)
                continue
            }
            let old = previous[identity]
            let detail: String
            if let old, old.status != task.status {
                detail = "\(Self.label(old.status)) → \(Self.label(task.status))"
            } else {
                detail = old == nil ? "Card added" : "Card updated"
            }
            changes[identity] = Change(detail: detail, observedAt: now)
            changed = true
        }
        // A bounded unread window, independent of the board's active work.
        let retained = Set(
            changes.keys.sorted {
                let lhs = changes[$0]!.observedAt
                let rhs = changes[$1]!.observedAt
                return lhs == rhs ? Self.rowID($0) < Self.rowID($1) : lhs > rhs
            }.prefix(30))
        changes = changes.filter { retained.contains($0.key) }
        return changed
    }

    mutating func acknowledge(_ task: KanbanTaskSummary) {
        changes.removeValue(forKey: Self.identity(task))
    }

    func rows(isCurrent: Bool) -> [EdgeNotchTask] {
        var result: [EdgeNotchTask] = []
        for (identity, task) in previous ?? [:] {
            let change = changes[identity]
            guard let phase = Self.phase(task.status), change != nil || phase != .finished else { continue }
            // The default board is implied; only name boards the user created.
            let board = task.boardSlug == "default" ? nil : task.boardSlug
            let context = [change?.detail, board, task.assignee].compactMap { $0 }.filter { !$0.isEmpty }
            result.append(
                EdgeNotchTask(
                    id: Self.rowID(identity), title: task.title, phase: phase,
                    statusLabel: Self.label(task.status), detail: context.joined(separator: " · "),
                    updatedAt: change?.observedAt ?? task.latestEventAt ?? task.startedAt,
                    isCurrent: false, isStatusCurrent: isCurrent, session: nil, kanbanTask: task))
        }
        let changedIDs = Set(changes.keys.map(Self.rowID))
        return result.sorted {
            let lhsChanged = changedIDs.contains($0.id)
            let rhsChanged = changedIDs.contains($1.id)
            if lhsChanged != rhsChanged { return lhsChanged }
            if lhsChanged, $0.updatedAt != $1.updatedAt {
                return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            if $0.phase != $1.phase { return $0.phase < $1.phase }
            if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            return $0.id < $1.id
        }
    }

    /// Running, review, blocked and done cards; nil hides queued or unknown ones.
    private static func phase(_ status: String) -> EdgeNotchTask.Phase? {
        switch SessionKanbanActivityPresentation.Status(rawValue: status) {
        case .blocked: .attention
        case .running: .working
        case .review: .pending
        case .done: .finished
        case .ready, .unknown: nil
        }
    }

    static func identity(_ task: KanbanTaskSummary) -> KanbanTaskIdentity {
        KanbanTaskIdentity(boardSlug: task.boardSlug, taskID: task.id)
    }

    private static func rowID(_ identity: KanbanTaskIdentity) -> String {
        // Length-prefix the board so IDs containing separators cannot collide.
        let board = identity.boardSlug ?? ""
        return "kanban:\(board.utf8.count):\(board):\(identity.taskID)"
    }

    private static func label(_ status: String) -> String {
        status.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ").capitalized
    }
}
