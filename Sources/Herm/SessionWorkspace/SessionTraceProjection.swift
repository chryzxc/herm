import CoreFoundation
import Foundation

/// Optional metadata keeps older tool archives decodable without inventing timing.
enum SessionTraceTiming: String, Codable { case runtime, observed, unavailable }

struct SessionTraceRow: Identifiable, Equatable {
    enum Kind: Equatable { case turn, agent, model, tool, thinking, compaction, marker }
    let id: String
    var parentID: String?
    let kind: Kind
    let title: String
    var model: String? = nil
    var start: Date?
    var end: Date?
    var duration: TimeInterval?
    var timing: SessionTraceTiming
    var active = false
    var outcome: String? = nil
    var input: String? = nil
    var result: String? = nil
    var diff: String? = nil
    var relatedSessionID: String? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var apiCalls: Int? = nil
    /// Raw tool name and context, so the trace shows the same icon as the chat.
    var toolName: String? = nil
    var context: String? = nil
    /// What a running delegate last reported doing.
    var activity: String? = nil
    /// Exact profile identity for an explicitly dispatched Bot; generic delegates remain anonymous.
    var crewProfileID: String? = nil

    var failed: Bool { outcome == "Failed" || outcome == "Error" }

    /// Seconds this row was moved earlier to collapse idle time; running rows
    /// measure against the clock moved by the same amount.
    var shift: TimeInterval = 0
    /// Where the bar ends now: the clock for running rows, else its recorded end.
    func finish(at now: Date) -> Date? {
        active ? now.addingTimeInterval(-shift) : end ?? start.map { $0.addingTimeInterval(duration ?? 0) }
    }
    func elapsed(at now: Date) -> TimeInterval? {
        if active, let start { return max(0, now.addingTimeInterval(-shift).timeIntervalSince(start)) }
        if let duration { return duration }
        guard let start, let finish = end ?? (active ? now : nil) else { return nil }
        return max(0, finish.timeIntervalSince(start))
    }
    var status: String { outcome ?? (active ? "Running" : "Finished · outcome unavailable") }
}

struct SessionTraceTurn: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    var calls: [ActiveToolCall] = []
    var executionStart: Date? = nil
    var executionEnd: Date? = nil
    var outcome: String? = nil
    var rows: [SessionTraceRow] = []
    var toolCount: Int { rows.filter { $0.kind == .tool }.count }
    var agentCount: Int { rows.filter { $0.kind == .agent && $0.crewProfileID == nil }.count }
    var errorCount: Int { rows.filter { $0.kind != .turn && $0.failed }.count }
    /// Derived model spans plus what delegates report; never a guess for the rest.
    var modelCallCount: Int {
        rows.filter { $0.kind == .model }.count
            + rows.filter { $0.kind == .agent }.compactMap(\.apiCalls).reduce(0, +)
    }
    var reportedTokens: Int? {
        let values = rows.compactMap { row in
            row.inputTokens.map { $0 + (row.outputTokens ?? 0) } ?? row.outputTokens
        }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    /// The longest finished step, flagged only when there is something to compare.
    var slowestRowID: String? {
        let timed = rows.filter {
            ($0.kind == .tool || $0.kind == .model) && !$0.active && $0.start != nil
        }
        guard timed.count > 1 else { return nil }
        return timed.max { ($0.elapsed(at: .distantPast) ?? 0) < ($1.elapsed(at: .distantPast) ?? 0) }?.id
    }
}

enum SessionTraceProjection {
    static func measuredDuration(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let seconds = number.doubleValue
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    /// Only explicit structured tool results establish an outcome.
    static func outcome(_ value: Any?) -> String? {
        guard let result = value as? [String: Any] else { return nil }
        if boolean(result["success"]) == false || boolean(result["ok"]) == false { return "Failed" }
        if let error = result["error"] as? String, !error.isEmpty { return "Failed" }
        if let code = result["exit_code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(),
            code.doubleValue.isFinite, code.doubleValue.rounded(.towardZero) == code.doubleValue
        {
            return code.doubleValue == 0 ? "Succeeded" : "Failed"
        }
        if boolean(result["success"]) == true || boolean(result["ok"]) == true {
            return "Succeeded"
        }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    static func callKey(_ call: ActiveToolCall) -> String {
        call.agentID.map { "agent:\($0.utf8.count):\($0):\(call.id)" } ?? "session:" + call.id
    }

    static func make(
        turns input: [SessionTraceTurn], live: [ActiveToolCall], agents: [HermesSubagent],
        working: Bool, connected: Bool, activities: [AgentActivity] = []
    ) -> [SessionTraceTurn] {
        var turns = input
        guard !turns.isEmpty else { return [] }
        var tables = turns.map { turn in
            Dictionary(turn.calls.map { (callKey($0), $0) }, uniquingKeysWith: { _, b in b })
        }
        let agentByID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ownerByCall: [String: Int] = [:]
        for index in tables.indices { for key in tables[index].keys { ownerByCall[key] = index } }
        let liveKeys = Set(live.map(callKey))
        let childCalls = agentCalls(activities).filter { !liveKeys.contains(callKey($0)) }
        for call in live + childCalls {
            let key = callKey(call)
            let actorStart = call.agentID.flatMap { agentByID[$0]?.startedAt } ?? call.startedAt
            guard let owner = ownerByCall[key] ?? turns.lastIndex(where: { $0.start <= actorStart })
            else { continue }
            tables[owner][key] = call
            ownerByCall[key] = owner
        }
        for index in turns.indices {
            let rootID = "turn:" + turns[index].id
            let nextStart = turns.indices.contains(index + 1) ? turns[index + 1].start : nil
            let current = index == turns.count - 1
            let ordered = tables[index].sorted {
                $0.value.startedAt == $1.value.startedAt
                    ? $0.key < $1.key : $0.value.startedAt < $1.value.startedAt
            }.map(\.value)
            turns[index].calls = ordered
            let referenced = Set(ordered.compactMap(\.agentID))
            var seen = Set<String>()
            // Hermes often omits startedAt on delegates; its start event (or, failing
            // that, completion) still places the delegate in the request it served.
            let workers = agents.filter { agent in
                guard seen.insert(agent.id).inserted else { return false }
                let placed =
                    agent.startedAt
                    ?? activities.first { $0.agentID == agent.id && $0.kind == "subagent.start" }?
                    .timestamp
                    ?? agent.completedAt
                return referenced.contains(agent.id)
                    || (placed.map {
                        $0 >= turns[index].start && $0 < (nextStart ?? .distantFuture)
                    } ?? false)
            }
            let workerIDs = Set(workers.map(\.id))
            let activeWorkerIDs = Set(
                workers.filter {
                    AgentActivityPresentation.isActiveStatus($0.status)
                        && !["queued", "pending"].contains($0.status.lowercased())
                }.map(\.id))
            var rows = workers.map { agent in
                let active = connected && activeWorkerIDs.contains(agent.id)
                let startEvent = activities.first {
                    $0.agentID == agent.id && $0.kind == "subagent.start"
                }
                let eventTiming = startEvent.map { $0.traceTiming ?? .unavailable } ?? .observed
                let endEvent = activities.last {
                    $0.agentID == agent.id && $0.kind == "subagent.complete"
                }
                let end =
                    endEvent.map {
                        $0.traceTiming == nil || $0.traceTiming == .unavailable ? nil : $0.timestamp
                    } ?? agent.completedAt
                let duration = agent.durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                // Hermes often omits startedAt but reports when a delegate finished and how
                // long it ran; that places an untimed (replayed or legacy) start honestly.
                let measuredStart = end.flatMap { end in duration.map { end.addingTimeInterval(-$0) } }
                let timing = eventTiming == .unavailable && measuredStart != nil ? .runtime : eventTiming
                return SessionTraceRow(
                    id: "agent:" + agent.id,
                    parentID: agent.parentID.flatMap {
                        workerIDs.contains($0) ? "agent:" + $0 : nil
                    }
                        ?? rootID,
                    kind: .agent, title: agent.name ?? agent.role ?? taskTitle(agent.goal),
                    model: agent.model,
                    start: eventTiming == .unavailable
                        ? measuredStart : startEvent?.timestamp ?? agent.startedAt ?? measuredStart,
                    end: end,
                    duration: duration,
                    timing: timing, active: active,
                    outcome: active
                        ? nil
                        : (!connected && AgentActivityPresentation.isActiveStatus(agent.status)
                            ? "Not current" : agent.status.capitalized),
                    input: agent.goal, result: agent.summary, relatedSessionID: agent.childSessionID,
                    inputTokens: agent.inputTokens, outputTokens: agent.outputTokens,
                    apiCalls: agent.apiCalls,
                    activity: active ? agent.latestActivity : nil
                )
            }
            rows.append(
                contentsOf: ordered.map { call in
                    let kind: SessionTraceRow.Kind =
                        call.name == ActiveToolCall.thinkingName
                        ? .thinking
                        : call.name == ActiveToolCall.compactionName ? .compaction : .tool
                    let timing = call.traceTiming ?? .unavailable
                    let active =
                        connected
                        && ((current && working) || call.agentID.map(activeWorkerIDs.contains) == true)
                        && !call.isComplete && timing != .unavailable
                    let stoppedAt = call.agentID.flatMap { agentByID[$0]?.completedAt } ?? turns[index].executionEnd
                    return SessionTraceRow(
                        id: "tool:" + callKey(call),
                        parentID: call.agentID.flatMap {
                            workerIDs.contains($0) ? "agent:" + $0 : nil
                        }
                            ?? rootID,
                        kind: kind,
                        title: kind == .thinking
                            ? "Thinking"
                            : kind == .compaction
                                ? "Compacting context"
                                : AgentActivityPresentation.toolActivityTitle(
                                    name: call.name, context: call.context),
                        start: timing == .unavailable ? nil : call.startedAt,
                        end: call.completedAt ?? (!call.isComplete && !active ? stoppedAt : nil),
                        duration: call.traceDuration,
                        timing: timing, active: active,
                        outcome: !call.isComplete ? "Not current" : call.traceOutcome,
                        input: call.input, result: call.result, diff: call.diffPreview,
                        relatedSessionID: call.childSessionID, toolName: call.name,
                        context: call.context)
                })
            // Unpaired delegate progress is a point event, never a made-up tool span.
            rows.append(
                contentsOf: activities.compactMap { event -> SessionTraceRow? in
                    guard event.kind == "subagent.tool", event.traceCallID == nil,
                        let agentID = event.agentID, workerIDs.contains(agentID)
                    else { return nil }
                    return SessionTraceRow(
                        id: "event:" + event.id.uuidString, parentID: "agent:" + agentID,
                        kind: .marker,
                        title: event.toolName.map {
                            AgentActivityPresentation.toolActivityTitle(name: $0, context: event.text)
                        } ?? "Reported tool activity",
                        start: event.traceTiming == .unavailable || event.traceTiming == nil
                            ? nil : event.timestamp,
                        end: event.timestamp, duration: 0,
                        timing: event.traceTiming ?? .unavailable,
                        outcome: "Reported activity", result: event.text,
                        relatedSessionID: event.childSessionID, toolName: event.toolName,
                        context: event.text
                    )
                })
            rows.append(
                contentsOf: modelSpans(
                    rows, rootID: rootID, from: turns[index].executionStart ?? turns[index].start))
            // A malformed parent cycle must never hide rows or recurse forever.
            var parents = Dictionary(
                rows.map { ($0.id, $0.parentID ?? rootID) }, uniquingKeysWith: { a, _ in a })
            for rowIndex in rows.indices {
                var path: Set<String> = [rows[rowIndex].id]
                var parent = rows[rowIndex].parentID
                while let id = parent, id != rootID {
                    guard path.insert(id).inserted else {
                        rows[rowIndex].parentID = rootID
                        parents[rows[rowIndex].id] = rootID
                        break
                    }
                    parent = parents[id]
                }
            }
            rows.sort {
                if $0.start != $1.start {
                    return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture)
                }
                return $0.id < $1.id
            }
            let starts = rows.compactMap(\.start) + [turns[index].executionStart].compactMap { $0 }
            let start = starts.min()
            let active = rows.contains(where: \.active) || (current && working && connected)
            let end =
                (rows.filter { $0.start != nil }.compactMap(\.end)
                + [turns[index].executionEnd].compactMap { $0 }).max()
            rows.insert(
                SessionTraceRow(
                    id: rootID, parentID: nil, kind: .turn,
                    title: turns[index].title.isEmpty ? "Request" : turns[index].title,
                    start: start, end: active ? nil : end, timing: .observed, active: active,
                    outcome: active ? nil : turns[index].outcome ?? "Execution window"), at: 0)
            turns[index].rows = rows
        }
        return turns
    }

    /// The model is working between one batch of tool results and the next tool
    /// request. Only Hermes-stamped boundaries qualify; the final reply is not traced.
    static func modelSpans(_ rows: [SessionTraceRow], rootID: String, from turnStart: Date)
        -> [SessionTraceRow]
    {
        let tools = rows.filter {
            $0.parentID == rootID && $0.timing == .runtime && $0.start != nil
                && ($0.kind == .tool || $0.kind == .compaction)
        }
        let batches = Dictionary(grouping: tools) { $0.start! }.sorted { $0.key < $1.key }
        var cursor: Date? = turnStart
        var spans: [SessionTraceRow] = []
        for (start, batch) in batches {
            if let from = cursor, start.timeIntervalSince(from) > 0.05 {
                spans.append(
                    SessionTraceRow(
                        id: "model:\(rootID):\(spans.count)", parentID: rootID, kind: .model,
                        title: "Model call", start: from, end: start, timing: .runtime,
                        outcome: "Derived from step timestamps"))
            }
            // An unfinished batch leaves the next boundary unknown.
            let ends = batch.map(\.end)
            cursor = ends.contains(nil) ? nil : ends.compactMap { $0 }.max()
        }
        return spans
    }

    static let allTurnsID = "all"

    /// An unnamed delegate is known by its task: the goal's first line, shortened.
    static func taskTitle(_ goal: String) -> String {
        let line =
            goal.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "Delegate" }
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    enum DetailSection { case input, result, diff }

    /// Markdown for the step detail card. Agent goals and summaries are prose;
    /// tool payloads are machine text, so they are fenced and patch envelopes
    /// read as diffs. Tool results unwrap Hermes' `{"output"}`/`{"error"}` JSON.
    static func detailMarkdown(_ value: String?, section: DetailSection, kind: SessionTraceRow.Kind) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if section == .result, kind == .tool, let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let error = json["error"] as? String, !error.isEmpty {
                text = "Error: " + error
            } else if let output = json["output"] as? String {
                text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if text.isEmpty { return nil }
        }
        let prose = kind == .agent || kind == .thinking || kind == .marker || kind == .turn
        if section != .diff, prose { return text }
        let patch = section == .diff || text.contains("*** Begin Patch") || text.hasPrefix("diff --git")
        // A fence longer than any backtick run inside keeps the block closed.
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + (patch ? "diff" : "") + "\n" + text + "\n" + fence
    }

    /// Every request on one timeline, each as its own top-level node. Idle time
    /// between requests collapses to `gap` so long sessions stay readable.
    static func combined(_ turns: [SessionTraceTurn], gap: TimeInterval = 2, now: Date = Date())
        -> SessionTraceTurn?
    {
        guard let first = turns.first else { return nil }
        var rows: [SessionTraceRow] = []
        var seen = Set<String>()
        var cursor: Date?
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let starts = turn.rows.compactMap(\.start)
            let ends = turn.rows.compactMap { $0.finish(at: now) }
            var shift: TimeInterval = 0
            if let start = starts.min() {
                if let cursor { shift = max(0, start.timeIntervalSince(cursor) - gap) }
                cursor = (ends.max() ?? start).addingTimeInterval(-shift)
            }
            for var row in turn.rows where seen.insert(row.id).inserted {
                row.start = row.start?.addingTimeInterval(-shift)
                row.end = row.end?.addingTimeInterval(-shift)
                row.shift = shift
                rows.append(row)
            }
        }
        return SessionTraceTurn(
            id: allTurnsID, title: "All activity", start: first.start, rows: rows)
    }

    static func agentCalls(_ activities: [AgentActivity]) -> [ActiveToolCall] {
        let events = activities.filter {
            ($0.kind == "subagent.tool" || $0.kind == "subagent.tool.complete")
                && $0.traceCallID != nil && $0.agentID != nil
        }
        let groups = Dictionary(grouping: events) { event in
            "\(event.agentID!.utf8.count):\(event.agentID!):\(event.traceCallID!)"
        }
        return groups.values.compactMap { events in
            guard let first = events.first, let id = first.traceCallID else { return nil }
            let start = events.first { $0.kind == "subagent.tool" }
            let end = events.last { $0.kind == "subagent.tool.complete" }
            var timing = start?.traceTiming ?? .unavailable
            if let end, end.traceTiming == nil || end.traceTiming == .unavailable {
                timing = .unavailable
            }
            return ActiveToolCall(
                id: id, name: first.toolName ?? "Tool call", input: start?.text ?? "", context: "",
                startedAt: start?.timestamp ?? first.timestamp, result: end?.text,
                isComplete: end != nil,
                completedAt: end?.timestamp, diffPreview: end?.diffPreview, agentID: first.agentID,
                parentAgentID: first.parentAgentID, childSessionID: first.childSessionID,
                traceDuration: end?.traceDuration, traceTiming: timing,
                traceOutcome: end?.traceOutcome)
        }
    }

    static func visible(_ rows: [SessionTraceRow], collapsed: Set<String>, query: String) -> [(
        row: SessionTraceRow, depth: Int
    )] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var included = Set<String>()
        if !query.isEmpty {
            for row in rows
            where [row.title, row.model, row.input, row.parentID.flatMap { byID[$0]?.title }]
                .compactMap({ $0 }).contains(where: {
                    $0.localizedStandardContains(query)
                })
            {
                var cursor: String? = row.id
                while let id = cursor, included.insert(id).inserted { cursor = byID[id]?.parentID }
            }
        }
        let children = Dictionary(grouping: rows, by: { $0.parentID ?? "" })
        var result: [(SessionTraceRow, Int)] = []
        var visited = Set<String>()
        func append(_ parent: String, depth: Int) {
            for row in children[parent] ?? [] where visited.insert(row.id).inserted {
                guard query.isEmpty || included.contains(row.id) else { continue }
                result.append((row, depth))
                if !collapsed.contains(row.id) || !query.isEmpty {
                    append(row.id, depth: depth + 1)
                }
            }
        }
        append("", depth: 0)
        return result
    }
}
