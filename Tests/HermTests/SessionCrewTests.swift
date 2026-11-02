import Foundation
import Testing

@testable import Herm

@MainActor
struct SessionCrewTests {
    private let origin = Date(timeIntervalSince1970: 1_000)

    private func row(
        _ id: String, _ kind: SessionTraceRow.Kind, parent: String? = nil,
        start: Double? = 0, end: Double? = 20, active: Bool = false
    ) -> SessionTraceRow {
        SessionTraceRow(
            id: id, parentID: parent, kind: kind, title: id,
            start: start.map { origin.addingTimeInterval($0) },
            end: end.map { origin.addingTimeInterval($0) }, timing: .runtime,
            active: active, outcome: active ? nil : "Completed")
    }

    @Test func selectionFollowsExactOwnershipAndRequests() throws {
        let rows = [
            row("one", .turn), row("a", .agent, parent: "one"),
            row("b", .agent, parent: "a"), row("tool", .tool, parent: "b"),
            row("two", .turn, start: 30, end: 60), row("c", .agent, parent: "two", start: 30, end: 60),
        ]
        let crew = SessionCrewProjection(rows: rows)
        #expect(crew.ownerByRow["tool"] == "b")
        #expect(crew.actors.first { $0.id == "b" }?.parentID == "a")
    }

    @Test func lanesGroupHermBotProfilesAndSubagents() {
        var bot = row("bot-1", .agent, parent: "two", start: 40, end: 50)
        bot.crewProfileID = "sentry"
        var again = row("bot-2", .agent, parent: "three", start: 70, end: 80)
        again.crewProfileID = "sentry"
        let dispatch = row("turn:bot-dispatch:job", .turn, start: 5, end: 9)
        var direct = row("bot-dispatch:job", .agent, parent: dispatch.id, start: 5, end: 9)
        direct.crewProfileID = "archon"
        let rows = [
            row("one", .turn), row("tool", .tool, parent: "one"), row("sub", .agent, parent: "one", start: 2, end: 8),
            row("two", .turn, start: 40, end: 60), bot, row("three", .turn, start: 70, end: 90), again,
            dispatch, direct,
        ]
        let lanes = SessionActivityLanes(SessionCrewProjection(rows: rows))
        #expect(lanes.lanes.map(\.kind) == [.main, .subagent, .bot, .bot])
        #expect(lanes.lanes[0].actorIDs == ["one", "two", "three"])
        #expect(lanes.lanes.map(\.identity).suffix(2) == ["archon", "sentry"])
        #expect(lanes.lanes[3].actorIDs == ["bot-1", "bot-2"])
        #expect(lanes.lane(owning: "tool")?.kind == .main)
    }

    @Test func scopedStepsKeepAncestorsOnly() {
        let rows = [
            row("one", .turn), row("a", .agent, parent: "one"), row("tool", .tool, parent: "a"),
            row("other", .tool, parent: "one"),
        ]
        #expect(SessionActivityLanes.scoped(rows) { $0.id == "tool" }.map(\.id) == ["one", "a", "tool"])
    }

    @Test func replayDoesNotLeakCurrentActivityOrFinalOutcome() throws {
        var worker = row("worker", .agent, start: 10, end: 30)
        worker.activity = "Later activity"
        worker.outcome = "Failed"
        var tool = row("tool", .tool, parent: "worker", start: 15, end: 20)
        tool.toolName = "terminal"
        let actor = try #require(SessionCrewProjection(rows: [worker, tool]).actors.first)
        #expect(!SessionCrewProjection.state(actor, at: origin, connected: true).visible)
        let gap = SessionCrewProjection.state(actor, at: origin.addingTimeInterval(12), connected: true)
        #expect(gap.label == "Activity not recorded")
        #expect(gap.mood == .idle)
        let running = SessionCrewProjection.state(actor, at: origin.addingTimeInterval(17), connected: true)
        #expect(running.toolID == "tool")
        #expect(running.moving)
        let end = SessionCrewProjection.state(actor, at: origin.addingTimeInterval(30), connected: true)
        #expect(end.mood == .failed)
    }

    @Test func missingTimingAndDisconnectDoNotInventWork() throws {
        let worker = row("worker", .agent, start: nil, end: nil, active: true)
        let actor = try #require(SessionCrewProjection(rows: [worker]).actors.first)
        #expect(SessionCrewProjection.state(actor, at: origin, connected: true).label == "Timing unavailable")
        let offline = SessionCrewProjection.state(actor, at: nil, connected: false)
        #expect(offline.label == "Not current")
        #expect(!offline.moving)
    }

    @Test func malformedCyclesAndDuplicateIDsRemainBounded() {
        let crew = SessionCrewProjection(rows: [
            row("a", .agent, parent: "b"), row("b", .agent, parent: "a"), row("a", .agent),
        ])
        #expect(crew.actors.count == 2)
        #expect(crew.actors.allSatisfy { $0.parentID == nil })
    }

    @Test func directBotJobsKeepInstanceIdentityAndUnknownHistory() throws {
        let records = ["first", "second"].map { id in
            BotActivityRecord(
                id: id, originSessionID: "origin", botID: "same-profile", botName: "Builder",
                summary: "Separate task", state: .completed, createdAt: origin,
                updatedAt: origin.addingTimeInterval(20), result: "Done")
        }
        let turns = SessionCrewProjection.botTurns(records + [records[0]], connected: true)
        #expect(turns.count == 2)
        let actors = SessionCrewProjection(rows: turns.flatMap(\.rows)).actors.filter { $0.row.kind == .agent }
        #expect(Set(actors.map(\.id)).count == 2)
        #expect(Set(actors.map(\.identity)) == ["same-profile"])
        #expect(actors.allSatisfy { $0.kind == "Bot" })
        let actor = try #require(actors.first)
        #expect(
            SessionCrewProjection.state(actor, at: origin.addingTimeInterval(5), connected: true).label
                == "Activity not recorded")
    }

    @Test func directBotProjectionClearsOnSessionSwitch() {
        let model = DockModel(initialSessionID: "crew-origin")
        model.botActivityBySessionID = [
            "crew-origin": [
                BotActivityRecord(
                    id: "job", originSessionID: "crew-origin", botID: "builder", botName: "Builder",
                    summary: "Task", state: .completed, createdAt: origin, updatedAt: origin)
            ]
        ]
        let trace = SessionTraceModel()
        trace.update(model)
        #expect(trace.turns.contains { $0.id == "bot-dispatch:job" })
        model.sessionID = "other-session"
        model.sessionStorageID = "other-session"
        model.kanbanAttributionSessionID = "other-session"
        trace.update(model)
        #expect(!trace.turns.contains { $0.id == "bot-dispatch:job" })
    }

    @Test func pendingBotRequestsStopTheClockWithoutInventingCompletion() throws {
        for state: BotActivityState in [.queued, .waiting] {
            let waitingAt = origin.addingTimeInterval(20)
            let record = BotActivityRecord(
                id: "pending", originSessionID: "origin", botID: "builder", botName: "Builder",
                summary: "Task", state: state, createdAt: origin, updatedAt: waitingAt)
            let turns = SessionCrewProjection.botTurns([record], connected: true, now: waitingAt)
            let actor = try #require(SessionCrewProjection(rows: turns.flatMap(\.rows)).actors.last)
            #expect(turns.flatMap(\.rows).allSatisfy { !$0.active })
            #expect(actor.row.status == state.label)
            #expect(actor.row.finish(at: waitingAt.addingTimeInterval(3_600)) == waitingAt)
            let all = try #require(SessionTraceProjection.combined(turns, now: waitingAt))
            let bounds = SessionTraceTimeBounds(all)
            #expect(bounds.span(at: waitingAt) == 20)
            #expect(bounds.span(at: waitingAt.addingTimeInterval(3_600)) == 20)
            let display = SessionCrewProjection.state(actor, at: nil, connected: true)
            #expect(display.label == state.label)
            #expect(!display.moving)
        }
    }

    @Test func workingBotRequestsKeepTheClockRunning() throws {
        let record = BotActivityRecord(
            id: "working", originSessionID: "origin", botID: "builder", botName: "Builder",
            summary: "Task", state: .working, createdAt: origin, updatedAt: origin)
        let turn = try #require(SessionCrewProjection.botTurns([record], connected: true, now: origin).first)
        #expect(turn.rows.allSatisfy { $0.active })
        let bounds = SessionTraceTimeBounds(turn)
        #expect(bounds.span(at: origin.addingTimeInterval(5)) == 5)
        #expect(bounds.span(at: origin.addingTimeInterval(10)) == 10)
    }

    @Test func staleBotRequestsStopTheClock() {
        let later = origin.addingTimeInterval(SessionCrewProjection.staleBotActivity + 1)
        let orphan = BotActivityRecord(
            id: "orphan", originSessionID: "origin", botID: "cypher", botName: "Cypher",
            summary: "Audit", state: .working, createdAt: origin, updatedAt: origin)
        let card = BotActivityRecord(
            id: "card", originSessionID: "origin", botID: "forge", botName: "Forge",
            summary: "Build", state: .queued, createdAt: origin, updatedAt: origin, linkedCardID: "t_1")
        let rows = SessionCrewProjection.botTurns([orphan, card], connected: true, now: later).flatMap(\.rows)
        #expect(rows.allSatisfy { !$0.active })
        #expect(rows.filter { $0.id.contains("orphan") }.allSatisfy { $0.status == "Not current" })
        #expect(rows.filter { $0.id.contains("card") }.allSatisfy { $0.status == "Queued" })
    }

    @Test func compressedReplayUsesTheSameShiftedRows() throws {
        let first = SessionTraceTurn(id: "first", title: "First", start: origin, rows: [row("first", .turn)])
        let second = SessionTraceTurn(
            id: "second", title: "Second", start: origin.addingTimeInterval(100),
            rows: [
                row("second", .turn, start: 100, end: 120),
                row("agent", .agent, parent: "second", start: 100, end: 120),
            ])
        let combined = try #require(SessionTraceProjection.combined([first, second]))
        let crew = SessionCrewProjection(rows: combined.rows)
        let actor = try #require(crew.actors.first { $0.id == "agent" })
        #expect(actor.row.start == origin.addingTimeInterval(22))
        #expect(!SessionCrewProjection.state(actor, at: origin.addingTimeInterval(21), connected: true).visible)
        #expect(SessionCrewProjection.state(actor, at: origin.addingTimeInterval(42), connected: true).mood == .done)
    }
}
