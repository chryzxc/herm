import Foundation

/// A disposable index over the same rows the waterfall renders. No separate event store.
struct SessionCrewProjection {
    struct Actor: Identifiable {
        let row: SessionTraceRow
        let parentID: String?
        let name: String
        let tools: [SessionTraceRow]
        var id: String { row.id }
        var identity: String { row.crewProfileID ?? row.id }
        var kind: String { row.kind == .turn ? "Main session" : row.crewProfileID == nil ? "Subagent" : "Bot" }
    }

    struct State: Equatable {
        let visible: Bool
        let label: String
        let mood: BotMood
        let toolID: String?
        let toolName: String?
        let moving: Bool
    }

    let actors: [Actor]
    let ownerByRow: [String: String]
    let rootByActor: [String: String]

    init(rows: [SessionTraceRow]) {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let actorRows = rows.filter { $0.kind == .turn || $0.kind == .agent }
        let actorIDs = Set(actorRows.map(\.id))
        var owners: [String: String] = [:]
        for row in rows {
            var cursor: String? = row.id
            var seen = Set<String>()
            while let id = cursor, seen.insert(id).inserted {
                if actorIDs.contains(id) {
                    owners[row.id] = id
                    break
                }
                cursor = byID[id]?.parentID
            }
        }
        var roots: [String: String] = [:]
        var parents: [String: String] = [:]
        for row in actorRows {
            var cursor = row.parentID
            var seen: Set<String> = [row.id]
            var root = row.id
            while let id = cursor, let parent = byID[id], seen.insert(id).inserted {
                if actorIDs.contains(id) {
                    if parents[row.id] == nil { parents[row.id] = id }
                    root = id
                }
                cursor = parent.parentID
            }
            // Malformed cycles are disconnected, rather than presented as delegation.
            if cursor != nil, seen.contains(cursor!) {
                parents[row.id] = nil
                root = row.id
            }
            roots[row.id] = root
        }
        let tools = Dictionary(grouping: rows.filter { !actorIDs.contains($0.id) }) { owners[$0.id] ?? "" }
        var seen = Set<String>()
        actors = actorRows.filter { seen.insert($0.id).inserted }.enumerated().map { index, row in
            let task = row.input.map(SessionTraceProjection.taskTitle)
            let name = row.kind == .turn ? "Herm" : row.title == task ? "Agent \(index)" : row.title
            return Actor(row: row, parentID: parents[row.id], name: name, tools: tools[row.id] ?? [])
        }
        ownerByRow = owners
        rootByActor = roots
    }

    static func state(_ actor: Actor, at date: Date?, connected: Bool) -> State {
        let row = actor.row
        if let date {
            guard let start = row.start, row.timing != .unavailable else {
                return State(
                    visible: true, label: "Timing unavailable", mood: .idle, toolID: nil, toolName: nil, moving: false)
            }
            if date < start {
                return State(
                    visible: false, label: "Not started", mood: .idle, toolID: nil, toolName: nil, moving: false)
            }
            let end = row.end ?? row.duration.map { start.addingTimeInterval($0) }
            if let end, date >= end { return settled(row) }
            if let tool = actor.tools.last(where: { tool in
                guard let start = tool.start, tool.timing != .unavailable, start <= date,
                    let end = tool.end ?? tool.duration.map({ start.addingTimeInterval($0) })
                else { return false }
                return date < end
            }) {
                return working(tool)
            }
            // A dispatch/completion pair does not record the intermediate lifecycle.
            return State(
                visible: true, label: "Activity not recorded", mood: .idle, toolID: nil, toolName: nil, moving: false)
        }
        if !connected && (row.active || row.outcome == "Not current") {
            return State(visible: true, label: "Not current", mood: .offline, toolID: nil, toolName: nil, moving: false)
        }
        if let tool = actor.tools.last(where: \.active), connected { return working(tool) }
        if row.active && connected {
            if row.outcome == "Queued" || row.outcome == "Waiting" { return settled(row) }
            let label = row.activity ?? "Working"
            return State(visible: true, label: label, mood: .tool, toolID: nil, toolName: nil, moving: true)
        }
        return settled(row)
    }

    private static func working(_ tool: SessionTraceRow) -> State {
        let mood: BotMood = tool.kind == .compaction ? .compressing : tool.kind == .thinking ? .thinking : .tool
        return State(
            visible: true, label: tool.title, mood: mood, toolID: tool.id, toolName: tool.toolName, moving: true)
    }

    private static func settled(_ row: SessionTraceRow) -> State {
        let outcome = row.outcome ?? "Finished · outcome unavailable"
        let mood: BotMood
        switch outcome.lowercased() {
        case "failed", "error": mood = .failed
        case "completed", "succeeded", "done": mood = .done
        case "canceled", "cancelled", "stopped": mood = .stopped
        case "queued": mood = .queued
        case "needs approval": mood = .approval
        case "needs clarification": mood = .clarify
        case "not current": mood = .offline
        default: mood = .idle
        }
        return State(visible: true, label: outcome, mood: mood, toolID: nil, toolName: nil, moving: false)
    }

    /// The synthetic request row that carries a direct Bot dispatch; it is not Herm's own work.
    static func isDispatchRoot(_ row: SessionTraceRow) -> Bool {
        row.kind == .turn && row.id.hasPrefix("turn:" + dispatchPrefix)
    }
    private static let dispatchPrefix = "bot-dispatch:"

    /// Direct requests have their own exact dispatch identity. Do not attach them to a
    /// nearby transcript turn by timestamp or mistake a generic delegate for a Bot.
    /// A pending record untouched this long no longer runs the clock: in-flight tracking
    /// is lost on relaunch, and a card can sit queued on the board for days.
    static let staleBotActivity: TimeInterval = 3 * 3600

    static func botTurns(_ records: [BotActivityRecord], connected: Bool, now: Date = Date())
        -> [SessionTraceTurn]
    {
        var seen = Set<String>()
        return records.filter { !$0.isKanbanReference && seen.insert($0.id).inserted }.map { record in
            let id = dispatchPrefix + record.id
            let terminal = [.completed, .failed, .canceled].contains(record.state)
            let stale = now.timeIntervalSince(record.updatedAt) > staleBotActivity
            // Process- and card-backed records are still reconciled from Hermes; others never resolve.
            let tracked = record.processID != nil || record.linkedCardID != nil
            let active = connected && !terminal && !stale
            let status =
                !terminal && (!connected || (stale && !tracked)) ? "Not current" : record.state.label
            let root = SessionTraceRow(
                id: "turn:" + id, kind: .turn, title: record.summary, start: record.createdAt,
                end: terminal ? record.updatedAt : nil, timing: .observed, active: active, outcome: status)
            let bot = SessionTraceRow(
                id: id, parentID: root.id, kind: .agent, title: record.botName,
                start: record.createdAt, end: terminal ? record.updatedAt : nil,
                timing: .observed, active: active, outcome: status, input: record.summary,
                result: record.result, relatedSessionID: record.botChatSessionID, crewProfileID: record.botID)
            return SessionTraceTurn(id: id, title: record.summary, start: record.createdAt, rows: [root, bot])
        }
    }
}
