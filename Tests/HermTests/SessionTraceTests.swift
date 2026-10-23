import Foundation
import Testing

@testable import Herm

struct SessionTraceTests {
    private let origin = Date(timeIntervalSince1970: 1_000)
    private func call(_ id: String, _ offset: Double, duration: Double? = nil, agent: String? = nil)
        -> ActiveToolCall
    {
        ActiveToolCall(
            id: id, name: "terminal", input: "swift test", context: "swift test",
            startedAt: origin.addingTimeInterval(offset), isComplete: duration != nil,
            completedAt: duration.map { origin.addingTimeInterval(offset + $0) }, agentID: agent,
            traceDuration: duration, traceTiming: .observed)
    }
    private func project(
        _ calls: [ActiveToolCall], agents: [HermesSubagent] = [], connected: Bool = true
    ) -> [SessionTraceRow] {
        SessionTraceProjection.make(
            turns: [.init(id: "turn", title: "Request", start: origin, calls: calls)],
            live: [], agents: agents, working: true, connected: connected)[0].rows
    }

    @Test func parallelToolsKeepOffsetsAndMeasuredDuration() throws {
        let rows = project([call("a", 2, duration: 8), call("b", 4, duration: 3)])
        let a = try #require(rows.first { $0.id == "tool:session:a" })
        let b = try #require(rows.first { $0.id == "tool:session:b" })
        #expect(a.start == origin.addingTimeInterval(2))
        #expect(b.start == origin.addingTimeInterval(4))
        #expect(a.elapsed(at: .distantFuture) == 8)
        #expect(a.end! > b.start!)
    }

    @Test func liveCompletionReplacesHistoryAndDoesNotInventSuccess() {
        let old = call("same", 2)
        let live = call("same", 2, duration: 5)
        let result = SessionTraceProjection.make(
            turns: [.init(id: "t", title: "", start: origin, calls: [old, old])],
            live: [live], agents: [], working: false, connected: true)
        #expect(result[0].toolCount == 1)
        #expect(result[0].rows.last?.duration == 5)
        #expect(result[0].rows.last?.status == "Finished · outcome unavailable")
    }

    @Test func missingAndReplayedTimingStayUnplaced() {
        var restored = call("restored", 3, duration: 2)
        restored.traceTiming = nil
        var replayed = call("replayed", 4)
        replayed.traceTiming = .unavailable
        let rows = project([restored, replayed])
        #expect(rows.filter { $0.kind == .tool }.allSatisfy { $0.start == nil && !$0.active })
        #expect(rows.first { $0.id == "tool:session:restored" }?.duration == 2)
        let disconnected = project([call("running", 2)], connected: false)
        #expect(disconnected.allSatisfy { !$0.active })
    }

    @Test func hierarchySearchPreservesAncestorsAndCyclesCannotHideTools() {
        let a = HermesSubagent(
            id: "a", name: "Writer", parentID: "b", goal: "Copy", status: "running",
            startedAt: origin)
        let b = HermesSubagent(
            id: "b", name: "Coder", parentID: "a", goal: "Code", status: "running",
            startedAt: origin)
        let rows = project([call("compile", 2, agent: "a")], agents: [a, b, a])
        let visible = SessionTraceProjection.visible(
            rows, collapsed: ["agent:a"], query: "swift test")
        #expect(Set(visible.map(\.row.id)) == ["turn:turn", "agent:a", "tool:agent:1:a:compile"])
        #expect(SessionTraceProjection.visible(rows, collapsed: [], query: "").count == rows.count)
    }

    @Test func durationsAndOutcomesUseStructuredEvidence() {
        #expect(SessionTraceProjection.measuredDuration(-1) == nil)
        #expect(SessionTraceProjection.measuredDuration(Double.infinity) == nil)
        #expect(SessionTraceProjection.measuredDuration(true) == nil)
        #expect(SessionTraceProjection.measuredDuration(0) == 0)
        #expect(SessionTraceProjection.outcome(["exit_code": 1]) == "Failed")
        #expect(SessionTraceProjection.outcome(["success": true]) == "Succeeded")
        #expect(SessionTraceProjection.outcome("failed to find an optional file") == nil)
    }

    @Test func separateTurnsDoNotInheritEveryDelegate() {
        let first = SessionTraceTurn(id: "one", title: "One", start: origin)
        let second = SessionTraceTurn(id: "two", title: "Two", start: origin.addingTimeInterval(20))
        let worker = HermesSubagent(
            id: "a", goal: "First", status: "running", startedAt: origin.addingTimeInterval(1))
        let turns = SessionTraceProjection.make(
            turns: [first, second], live: [call("new", 22)],
            agents: [worker], working: true, connected: true)
        #expect(turns[0].agentCount == 1)
        #expect(turns[1].agentCount == 0)
        #expect(turns[0].rows.first { $0.kind == .agent }?.active == true)
        #expect(turns[1].toolCount == 1)
    }

    @Test @MainActor func gatewayRetainsDurationAndRejectsOtherSessionMetadata() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = DockModel(
            sessionAgentStateFileURL: url, initialSessionID: "one", botActivityFileURL: url)
        model.receiveGatewayEvent(
            "tool.start",
            params: ["session_id": "one", "payload": ["tool_id": "call", "name": "terminal"]])
        model.receiveGatewayEvent(
            "tool.complete",
            params: ["session_id": "other", "payload": ["tool_id": "call", "duration_s": 99]])
        #expect(model.activeToolCalls.first?.isComplete == false)
        model.receiveGatewayEvent(
            "tool.complete",
            params: [
                "session_id": "one",
                "payload": ["tool_id": "call", "duration_s": 2.5, "result": ["exit_code": 1]],
            ])
        #expect(model.activeToolCalls.first?.traceDuration == 2.5)
        #expect(model.activeToolCalls.first?.traceOutcome == "Failed")
        #expect(model.activeToolCalls.first?.traceTiming == .observed)
        model.receiveGatewayEvent(
            "tool.start",
            params: [
                "session_id": "one", "herm_trace_replayed": true,
                "payload": ["tool_id": "replayed", "name": "read"],
            ])
        #expect(model.activeToolCalls.last?.traceTiming == .unavailable)
    }

    @Test func pairedChildEventsProduceSpansWhileProgressRemainsAMarker() {
        let start = AgentActivity(
            id: UUID(), timestamp: origin, agentID: "a", kind: "subagent.tool", text: "Compile",
            toolName: "terminal", handoffTarget: nil, traceCallID: "c", traceTiming: .observed)
        let end = AgentActivity(
            id: UUID(), timestamp: origin.addingTimeInterval(4), agentID: "a",
            kind: "subagent.tool.complete", text: "Done",
            toolName: "terminal", handoffTarget: nil, traceCallID: "c", traceTiming: .observed,
            traceDuration: 3.5)
        #expect(start.traceCallID == "c")
        #expect(end.traceDuration == 3.5)
        let progress = AgentActivity(
            id: UUID(), timestamp: origin.addingTimeInterval(5), agentID: "a",
            kind: "subagent.tool",
            text: "Read file",
            toolName: "read_file", handoffTarget: nil, traceTiming: .observed)
        let worker = HermesSubagent(id: "a", goal: "Compile", status: "running", startedAt: origin)
        let turns = SessionTraceProjection.make(
            turns: [.init(id: "t", title: "", start: origin)], live: [], agents: [worker],
            working: false, connected: true, activities: [start, end, progress])
        #expect(turns[0].toolCount == 1)
        #expect(turns[0].rows.first { $0.kind == .tool }?.duration == 3.5)
        #expect(turns[0].rows.filter { $0.kind == .marker }.count == 1)
        #expect(SessionTraceProjection.agentCalls([end]).first?.traceTiming == .unavailable)
    }

    @Test func delegatesWithoutStartTimesAreListedByTheirTask() throws {
        let started = AgentActivity(
            id: UUID(), timestamp: origin.addingTimeInterval(3), agentID: "a",
            kind: "subagent.start", text: "Started", toolName: nil, handoffTarget: nil,
            traceTiming: .observed)
        let skill = AgentActivity(
            id: UUID(), timestamp: origin.addingTimeInterval(4), agentID: "a",
            kind: "subagent.tool", text: "testing", toolName: "skill_view", handoffTarget: nil,
            traceTiming: .observed)
        let done = HermesSubagent(
            id: "a", goal: "Write the parser tests\nthen report", status: "complete",
            completedAt: origin.addingTimeInterval(9))
        let running = HermesSubagent(
            id: "b", goal: "Audit", status: "running", latestActivity: "Reading Package.swift")
        let rows = SessionTraceProjection.make(
            turns: [.init(id: "t", title: "", start: origin)], live: [], agents: [done, running],
            working: true, connected: true,
            activities: [
                started, skill,
                AgentActivity(
                    id: UUID(), timestamp: origin.addingTimeInterval(5), agentID: "b",
                    kind: "subagent.start", text: "", toolName: nil, handoffTarget: nil,
                    traceTiming: .observed),
            ])[0].rows
        let agent = try #require(rows.first { $0.id == "agent:a" })
        #expect(agent.title == "Write the parser tests")
        #expect(agent.activity == nil)
        #expect(rows.first { $0.id == "agent:b" }?.activity == "Reading Package.swift")
        #expect(rows.contains { $0.kind == .marker && $0.parentID == "agent:a" && $0.toolName == "skill_view" })
    }

    @Test func asynchronousChildKeepsGrowingAfterParentTurnEnds() throws {
        let worker = HermesSubagent(id: "a", goal: "Continue", status: "running", startedAt: origin)
        let row = try #require(
            SessionTraceProjection.make(
                turns: [.init(id: "t", title: "", start: origin)],
                live: [call("child", 2, agent: "a")], agents: [worker], working: false,
                connected: true,
                observedAt: origin.addingTimeInterval(10))[0].rows.first { $0.kind == .tool })
        #expect(row.active)
        #expect(row.elapsed(at: origin.addingTimeInterval(12)) == 10)
        #expect(row.elapsed(at: origin.addingTimeInterval(13)) == 11)
    }

    @Test func jsonNumbersAreNotConfusedWithBooleans() throws {
        let payload = try #require(
            JSONSerialization.jsonObject(
                with: Data("{\"duration\":1,\"exit_code\":1,\"success\":false}".utf8))
                as? [String: Any])
        #expect(SessionTraceProjection.measuredDuration(payload["duration"]) == 1)
        #expect(SessionTraceProjection.outcome(["exit_code": payload["exit_code"]!]) == "Failed")
        #expect(SessionTraceProjection.outcome(["success": 1]) == nil)
        #expect(SessionTraceProjection.outcome(["exit_code": true]) == nil)
    }

    @Test func toolIDsStayDistinctAcrossOwnersAndSearchFindsTheirSteps() {
        let a = HermesSubagent(
            id: "a", name: "Writer", goal: "Copy", status: "complete", startedAt: origin)
        let b = HermesSubagent(
            id: "b", name: "Coder", goal: "Code", status: "complete", startedAt: origin)
        let rows = project(
            [
                call("shared", 1, duration: 2, agent: "a"),
                call("shared", 2, duration: 2, agent: "b"),
                call("agent:1:a:shared", 4, duration: 1),
            ], agents: [a, b])
        #expect(rows.filter { $0.kind == .tool }.count == 3)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(
            SessionTraceProjection.visible(rows, collapsed: [], query: "Writer").contains {
                $0.row.id == "tool:agent:1:a:shared"
            })
    }

    @Test func replayedDelegateStartsDoNotGetArrivalTimeBars() {
        let worker = HermesSubagent(
            id: "a", goal: "Old turn", status: "complete", startedAt: origin, durationSeconds: 4)
        let event = AgentActivity(
            id: UUID(), timestamp: origin, agentID: "a", kind: "subagent.start", text: "",
            toolName: nil, handoffTarget: nil, traceTiming: .unavailable)
        let rows = SessionTraceProjection.make(
            turns: [.init(id: "t", title: "", start: origin)], live: [], agents: [worker],
            working: false, connected: true, activities: [event])[0].rows
        #expect(rows.first { $0.kind == .agent }?.start == nil)
        #expect(rows.first { $0.kind == .agent }?.duration == 4)
    }

    @Test func longTurnMergesEveryLiveCompletionWithoutDuplicateRows() {
        let history = (0..<1_000).map { call("call-\($0)", Double($0)) }
        let completed = (0..<1_000).map { call("call-\($0)", Double($0), duration: 1) }
        let turn = SessionTraceProjection.make(
            turns: [.init(id: "t", title: "", start: origin, calls: history + history)],
            live: completed, agents: [], working: false, connected: true)[0]
        #expect(turn.toolCount == 1_000)
        #expect(turn.rows.filter { $0.kind == .tool }.allSatisfy { $0.duration == 1 && !$0.active })
    }

    @Test func legacyToolArchiveDecodesWithoutTraceMetadata() throws {
        let old = """
            {"id":"old","name":"read","input":"","context":"","startedAt":0,"isComplete":true}
            """
        let decoded = try JSONDecoder().decode(ActiveToolCall.self, from: Data(old.utf8))
        #expect(decoded.traceTiming == nil)
        #expect(decoded.traceDuration == nil)
    }

    @Test @MainActor func tabMigrationPreservesSelectedClosedAndRecentState() throws {
        let value = InspectorPresentation(
            selected: "Activity", closed: "Activity|Browser",
            recentClosed: ["Terminal", "Activity"])
        let data = try JSONEncoder().encode(value)
        let migrated = try JSONDecoder().decode(InspectorPresentation.self, from: data)
            .migratingActivity
        #expect(migrated.selected == "Timeline")
        #expect(migrated.closed == "Timeline|Browser")
        #expect(migrated.recentClosed == ["Terminal", "Timeline"])
        #expect(migrated.migratingActivity.selected == "Timeline")
        #expect(InspectorPresentation.migratedTab("Trace") == "Timeline")
    }

    @Test @MainActor func replyTextDoesNotReprojectAndSwitchingClearsExecution() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = DockModel(
            sessionAgentStateFileURL: url, initialSessionID: "one", botActivityFileURL: url)
        let requestID = UUID()
        let replyID = UUID()
        let request = ChatMessage(id: requestID, role: .user, text: "Check", timestamp: origin)
        model.messages = [
            request,
            ChatMessage(id: replyID, role: .hermes, text: "Starting", activity: [call("a", 1)]),
        ]
        let trace = SessionTraceModel()
        trace.update(model)
        let count = trace.projectionCount
        model.messages = [
            request,
            ChatMessage(id: replyID, role: .hermes, text: "More tokens", activity: [call("a", 1)]),
        ]
        trace.update(model)
        #expect(trace.projectionCount == count)
        #expect(trace.turns.first?.toolCount == 1)
        model.sessionID = "two"
        model.sessionStorageID = "two"
        model.messages = []
        model.activeToolCalls = []
        trace.update(model)
        #expect(trace.turns.isEmpty)
    }

    @Test func restoredHistoryUsesRequestAndResultTimestamps() {
        let rows: [[String: Any]] = [
            ["role": "user", "content": "Fix it", "timestamp": 1_000],
            [
                "role": "assistant", "content": "", "timestamp": 1_004,
                "tool_calls": [["id": "t1", "function": ["name": "terminal", "arguments": "{}"]]],
            ],
            ["role": "tool", "tool_call_id": "t1", "content": "ok", "timestamp": 1_007],
            ["role": "assistant", "content": "Done", "timestamp": 1_009],
        ]
        let call = DockModel.parseMessages(rows).messages.last?.activity.first
        #expect(call?.traceTiming == .runtime)
        #expect(call?.startedAt == Date(timeIntervalSince1970: 1_004))
        #expect(call?.completedAt == Date(timeIntervalSince1970: 1_007))

        let unstamped = DockModel.parseMessages([
            ["role": "user", "content": "Fix it"],
            [
                "role": "assistant", "content": "",
                "tool_calls": [["id": "t1", "function": ["name": "terminal", "arguments": "{}"]]],
            ],
            ["role": "tool", "tool_call_id": "t1", "content": "ok"],
            ["role": "assistant", "content": "Done"],
        ]).messages.last?.activity.first
        #expect(unstamped?.traceTiming == .unavailable)
    }

    /// session.resume drops the requesting row, so only the result's stamp survives.
    @Test func resumedToolRowsArePlacedAtTheirFinishStamp() {
        let activity =
            DockModel.parseMessages([
                ["role": "user", "content": "Fix it", "timestamp": 1_000],
                ["role": "tool", "name": "terminal", "context": "ls", "timestamp": 1_007],
                ["role": "assistant", "content": "Done", "reasoning": "Look first", "timestamp": 1_009],
            ]).messages.last?.activity ?? []
        let tool = activity.first { $0.name == "terminal" }
        #expect(tool?.traceTiming == .runtime)
        #expect(tool?.startedAt == Date(timeIntervalSince1970: 1_007))
        #expect(tool?.completedAt == Date(timeIntervalSince1970: 1_007))
        #expect(activity.first { $0.name == ActiveToolCall.thinkingName }?.traceTiming == .runtime)
        #expect(
            DockModel.parseMessages([
                ["role": "user", "content": "Fix it"], ["role": "tool", "name": "terminal"],
                ["role": "assistant", "content": "Done"],
            ]).messages.last?.activity.first?.traceTiming == .unavailable)
    }

    @Test func modelSpansFillRuntimeGapsBetweenToolBatches() {
        func runtime(_ id: String, _ offset: Double, _ duration: Double) -> ActiveToolCall {
            var value = call(id, offset, duration: duration)
            value.traceTiming = .runtime
            value.traceDuration = nil
            return value
        }
        let turn = SessionTraceProjection.make(
            turns: [
                .init(
                    id: "turn", title: "Request", start: origin,
                    calls: [runtime("a", 3, 2), runtime("b", 3, 4), runtime("c", 10, 1)])
            ],
            live: [], agents: [], working: false, connected: true)[0]
        let spans = turn.rows.filter { $0.kind == .model }
        #expect(spans.map(\.start) == [origin, origin.addingTimeInterval(7)])
        #expect(spans.map(\.end) == [origin.addingTimeInterval(3), origin.addingTimeInterval(10)])
        #expect(turn.modelCallCount == 2)
        #expect(turn.slowestRowID == "tool:session:b")
        // Observed (receive-time) steps never imply model spans.
        #expect(project([call("x", 3, duration: 1)]).allSatisfy { $0.kind != .model })
    }

    @Test func replayAdvancesPausesAndRestartsAtTheEnd() {
        let start = Date(timeIntervalSince1970: 0)
        var replay = SessionTraceReplay(resumedAt: start, speed: 2)
        #expect(replay.time(at: start.addingTimeInterval(3), span: 20) == 6)
        replay.pause(at: start.addingTimeInterval(3), span: 20)
        #expect(replay.time(at: start.addingTimeInterval(30), span: 20) == 6)
        replay.play(at: start.addingTimeInterval(30), span: 20)
        #expect(replay.time(at: start.addingTimeInterval(100), span: 20) == 20)
        #expect(!replay.playing(at: start.addingTimeInterval(100), span: 20))
        replay.play(at: start.addingTimeInterval(100), span: 20)
        #expect(replay.time(at: start.addingTimeInterval(100), span: 20) == 0)
        #expect(SessionTraceReplay.visibleElapsed(offset: 5, elapsed: 4, at: 3) == nil)
        #expect(SessionTraceReplay.visibleElapsed(offset: 5, elapsed: 4, at: 7) == 2)
        #expect(SessionTraceReplay.visibleElapsed(offset: 5, elapsed: 4, at: 12) == 4)
    }

    @Test func allActivityStacksRequestsAndCollapsesIdleTime() throws {
        let later = origin.addingTimeInterval(3_600)
        var second = call("b", 0, duration: 4)
        second = ActiveToolCall(
            id: "b", name: "terminal", input: "", context: "", startedAt: later,
            isComplete: true, completedAt: later.addingTimeInterval(4), traceDuration: 4,
            traceTiming: .observed)
        let turns = SessionTraceProjection.make(
            turns: [
                .init(id: "one", title: "First", start: origin, calls: [call("a", 0, duration: 5)]),
                .init(id: "two", title: "Second", start: later, calls: [second]),
            ],
            live: [], agents: [], working: false, connected: true)
        let all = try #require(SessionTraceProjection.combined(turns, gap: 2))
        #expect(all.rows.filter { $0.kind == .turn }.map(\.title) == ["First", "Second"])
        #expect(all.toolCount == 2)
        #expect(
            all.rows.first { $0.id == "tool:session:b" }?.start == origin.addingTimeInterval(7))
        #expect(
            SessionTraceProjection.visible(all.rows, collapsed: [], query: "").filter {
                $0.depth == 0
            }.count == 2)
    }

    @Test func allActivityKeepsRunningStepsOnTheRealClock() throws {
        let later = origin.addingTimeInterval(3_600)
        let running = ActiveToolCall(
            id: "b", name: "terminal", input: "", context: "", startedAt: later,
            isComplete: false, traceTiming: .observed)
        let turns = SessionTraceProjection.make(
            turns: [
                .init(id: "one", title: "First", start: origin, calls: [call("a", 0, duration: 5)]),
                .init(id: "two", title: "Second", start: later, calls: [running]),
            ],
            live: [], agents: [], working: true, connected: true)
        let now = later.addingTimeInterval(10)
        let all = try #require(SessionTraceProjection.combined(turns, gap: 2, now: now))
        let row = try #require(all.rows.first { $0.id == "tool:session:b" && $0.active })
        #expect(row.elapsed(at: now) == 10)
        #expect(row.finish(at: now) == row.start?.addingTimeInterval(10))
    }

    @Test func detailMarkdownFencesToolPayloadsAndKeepsAgentProse() {
        let md = SessionTraceProjection.detailMarkdown
        #expect(md("  ", .input, .tool) == nil)
        #expect(md("Fix the **tests**", .input, .agent) == "Fix the **tests**")
        #expect(md("ls -la", .input, .tool) == "```\nls -la\n```")
        #expect(
            md("mode: patch, patch: *** Begin Patch\n+a", .input, .tool)
                == "```diff\nmode: patch, patch: *** Begin Patch\n+a\n```")
        #expect(md(#"{"output": "ok\n"}"#, .result, .tool) == "```\nok\n```")
        #expect(md(#"{"error": "denied"}"#, .result, .tool) == "```\nError: denied\n```")
        #expect(md("a ``` b", .result, .tool) == "````\na ``` b\n````")
        #expect(md("-x\n+y", .diff, .agent) == "```diff\n-x\n+y\n```")
    }
}
