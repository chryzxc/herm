import CoreFoundation
import Foundation

/// Optional metadata keeps older tool archives decodable without inventing timing.
enum SessionTraceTiming: String, Codable, Sendable { case runtime, observed, unavailable }

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
    /// Transcript order is authoritative even if stored timestamps are out of order.
    static func interleave(_ transcript: [SessionTraceTurn], with dispatches: [SessionTraceTurn]) -> [SessionTraceTurn]
    {
        guard !dispatches.isEmpty else { return transcript }
        let sorted = dispatches.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var result: [SessionTraceTurn] = []
        result.reserveCapacity(transcript.count + sorted.count)
        var next = 0
        for dispatch in sorted {
            while next < transcript.count, transcript[next].start <= dispatch.start {
                result.append(transcript[next])
                next += 1
            }
            result.append(dispatch)
        }
        result.append(contentsOf: transcript.dropFirst(next))
        return result
    }

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

    fileprivate struct Worker: Equatable {
        let agent: HermesSubagent
        let start: AgentActivity?
        let completion: AgentActivity?
        let markers: [AgentActivity]
    }

    fileprivate struct HistoryIndex {
        let starts: [Date]
        let ordered: Bool
        let calls: [[String: ActiveToolCall]]
        let ownerByCall: [String: Int]
        let agentsByTurn: [Set<String>]
        let turnsByAgent: [String: Set<Int>]

        init(_ turns: [SessionTraceTurn]) {
            starts = turns.map(\.start)
            ordered = zip(starts, starts.dropFirst()).allSatisfy { $0.0 <= $0.1 }
            calls = turns.map { turn in
                Dictionary(turn.calls.map { (callKey($0), $0) }, uniquingKeysWith: { _, last in last })
            }
            var owners: [String: Int] = [:]
            for index in calls.indices {
                for key in calls[index].keys { owners[key] = index }
            }
            ownerByCall = owners
            let agents = calls.map { Set($0.values.compactMap(\.agentID)) }
            agentsByTurn = agents
            var turnsByAgent: [String: Set<Int>] = [:]
            for (index, ids) in agents.enumerated() {
                for id in ids { turnsByAgent[id, default: []].insert(index) }
            }
            self.turnsByAgent = turnsByAgent
        }

        func lastTurn(startingBy date: Date) -> Int? {
            guard ordered else { return starts.lastIndex { $0 <= date } }
            var lower = 0
            var upper = starts.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if starts[middle] <= date { lower = middle + 1 } else { upper = middle }
            }
            return lower > 0 ? lower - 1 : nil
        }

        func turns(containing date: Date) -> [Int] {
            if ordered { return lastTurn(startingBy: date).map { [$0] } ?? [] }
            // The transcript can prepend imported turns with out-of-order timestamps.
            return starts.indices.filter { index in
                date >= starts[index]
                    && date < (starts.indices.contains(index + 1) ? starts[index + 1] : .distantFuture)
            }
        }
    }

    /// Retain only historical turns from this session's previous projection.
    final class HistoryCache {
        fileprivate struct Entry {
            let input: SessionTraceTurn
            let workers: [Worker]
            let calls: [String: ActiveToolCall]
            let result: SessionTraceTurn
        }
        fileprivate struct Projection {
            let generation: Int
            let turns: [SessionTraceTurn]
            let calls: [Int: [String: ActiveToolCall]]
            let workers: [String: Worker]
            let placements: [String: [Int]]
        }
        private var indexed: (revision: UInt64, count: Int, lastID: String?, lastStart: Date?, index: HistoryIndex)?
        private(set) var indexBuildCount = 0
        fileprivate(set) var visitedTurnCount = 0

        fileprivate func historyIndex(for turns: [SessionTraceTurn], revision: UInt64?) -> HistoryIndex {
            if let indexed, indexed.revision == revision,
                indexed.count == turns.count, indexed.lastID == turns.last?.id, indexed.lastStart == turns.last?.start
            {
                return indexed.index
            }
            let index = HistoryIndex(turns)
            indexBuildCount += 1
            indexed = revision.map { ($0, turns.count, turns.last?.id, turns.last?.start, index) }
            return index
        }

        fileprivate var entries: [String: Entry] = [:]
        fileprivate var projection: Projection?
        fileprivate var connected = false
        private(set) var reused = 0
        fileprivate func recordReuse(_ count: Int = 1) { reused += count }
    }

    static func make(
        turns input: [SessionTraceTurn], live: [ActiveToolCall], agents: [HermesSubagent],
        working: Bool, connected: Bool, activities: [AgentActivity] = [], cache: HistoryCache? = nil,
        historyRevision: UInt64? = nil
    ) -> [SessionTraceTurn] {
        guard let lastTurn = input.indices.last else {
            cache?.entries = [:]
            cache?.projection = nil
            return []
        }
        let history = cache?.historyIndex(for: input, revision: historyRevision) ?? HistoryIndex(input)
        let reuse = cache?.connected == connected
        let prior = cache?.projection.flatMap {
            reuse && historyRevision != nil && $0.generation == cache?.indexBuildCount ? $0 : nil
        }
        var turns = prior?.turns ?? input
        var nextEntries = prior != nil ? cache?.entries ?? [:] : [:]
        var patchedCalls: [Int: [String: ActiveToolCall]] = [:]
        let agentByID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var liveOwners: [String: Int] = [:]
        let liveKeys = Set(live.map(callKey))
        let childCalls = agentCalls(activities).filter { !liveKeys.contains(callKey($0)) }
        for call in live + childCalls {
            let key = callKey(call)
            let actorStart = call.agentID.flatMap { agentByID[$0]?.startedAt } ?? call.startedAt
            guard let owner = liveOwners[key] ?? history.ownerByCall[key] ?? history.lastTurn(startingBy: actorStart)
            else { continue }
            patchedCalls[owner, default: history.calls[owner]][key] = call
            liveOwners[key] = owner
        }
        var starts: [String: AgentActivity] = [:]
        var completions: [String: AgentActivity] = [:]
        var markers: [String: [AgentActivity]] = [:]
        for event in activities {
            guard let id = event.agentID else { continue }
            if event.kind == "subagent.start", starts[id] == nil { starts[id] = event }
            if event.kind == "subagent.complete" { completions[id] = event }
            if event.kind == "subagent.tool", event.traceCallID == nil { markers[id, default: []].append(event) }
        }
        var seen = Set<String>()
        let allWorkers: [Worker] = agents.compactMap { agent in
            guard seen.insert(agent.id).inserted else { return nil }
            return Worker(
                agent: agent, start: starts[agent.id], completion: completions[agent.id],
                markers: markers[agent.id] ?? [])
        }
        var placedWorkers: [Int: Set<String>] = [:]
        let workerIndices = Dictionary(uniqueKeysWithValues: allWorkers.indices.map { (allWorkers[$0].agent.id, $0) })
        let workersByID = Dictionary(uniqueKeysWithValues: allWorkers.map { ($0.agent.id, $0) })
        var placements: [String: [Int]] = [:]
        for worker in allWorkers {
            if let date = worker.agent.startedAt ?? worker.start?.timestamp ?? worker.agent.completedAt {
                let positions = history.turns(containing: date)
                placements[worker.agent.id] = positions
                for turn in positions { placedWorkers[turn, default: []].insert(worker.agent.id) }
            }
        }
        let indices: [Int]
        if let prior {
            let liveTurns = Set(patchedCalls.keys).union(prior.calls.keys)
            var dirty = liveTurns.filter { patchedCalls[$0] != prior.calls[$0] }
            for id in Set(workersByID.keys).union(prior.workers.keys)
            where workersByID[id] != prior.workers[id] || placements[id] != prior.placements[id] {
                dirty.formUnion(history.turnsByAgent[id] ?? [])
                dirty.formUnion(placements[id] ?? [])
                dirty.formUnion(prior.placements[id] ?? [])
                dirty.formUnion(liveTurns)
            }
            dirty.insert(lastTurn)
            indices = dirty.sorted()
            cache?.recordReuse(turns.count - indices.count)
        } else {
            indices = Array(turns.indices)
        }
        cache?.visitedTurnCount = indices.count
        for index in indices {
            turns[index] = input[index]
            let rootID = "turn:" + turns[index].id
            let current = index == turns.count - 1
            let calls = patchedCalls[index] ?? history.calls[index]
            let referenced =
                patchedCalls[index].map { Set($0.values.compactMap(\.agentID)) }
                ?? history.agentsByTurn[index]
            let workers = referenced.union(placedWorkers[index] ?? [])
                .compactMap { workerIndices[$0] }.sorted().map { allWorkers[$0] }
            if !current, reuse, let entry = cache?.entries[input[index].id], entry.input == input[index],
                entry.workers == workers, entry.calls == calls
            {
                turns[index] = entry.result
                nextEntries[entry.input.id] = entry
                cache?.recordReuse()
                continue
            }
            let ordered = calls.sorted {
                $0.value.startedAt == $1.value.startedAt
                    ? $0.key < $1.key : $0.value.startedAt < $1.value.startedAt
            }.map(\.value)
            turns[index].calls = ordered
            let agents = workers.map(\.agent)
            let workerIDs = Set(agents.map(\.id))
            let activeWorkerIDs = Set(
                agents.filter {
                    AgentActivityPresentation.isActiveStatus($0.status)
                        && !["queued", "pending"].contains($0.status.lowercased())
                }.map(\.id))
            var rows = workers.map { worker in
                let agent = worker.agent
                let active = connected && activeWorkerIDs.contains(agent.id)
                let startEvent = worker.start
                let eventTiming = startEvent.map { $0.traceTiming ?? .unavailable } ?? .observed
                let endEvent = worker.completion
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
                contentsOf: workers.flatMap { worker in
                    worker.markers.map { event in
                        SessionTraceRow(
                            id: "event:" + event.id.uuidString, parentID: "agent:" + worker.agent.id,
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
                    }
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
            if !current, cache != nil {
                nextEntries[input[index].id] = .init(
                    input: input[index], workers: workers, calls: calls, result: turns[index])
            }
        }
        if let cache {
            cache.entries = nextEntries
            cache.connected = connected
            cache.projection = historyRevision.map { _ in
                .init(
                    generation: cache.indexBuildCount, turns: turns, calls: patchedCalls,
                    workers: workersByID, placements: placements)
            }
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
