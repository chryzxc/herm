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
        #expect(crew.root(selectedRowID: "tool", replayDate: nil) == "one")
        #expect(crew.root(selectedRowID: nil, replayDate: origin.addingTimeInterval(35)) == "two")
        #expect(crew.branch("one").map(\.id) == ["one", "a", "b"])
        #expect(SessionCrewLayout.focused(crew.actors, on: "a").map(\.id) == ["a", "b"])
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
        let layout = SessionCrewLayout(actors: crew.actors, width: 380, zoom: 1)
        #expect(layout.positions.count == 2)
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

    @Test func pendingBotRequestsRemainLiveWithoutInventingWork() throws {
        for state: BotActivityState in [.queued, .waiting] {
            let record = BotActivityRecord(
                id: "pending", originSessionID: "origin", botID: "builder", botName: "Builder",
                summary: "Task", state: state, createdAt: origin, updatedAt: origin)
            let turns = SessionCrewProjection.botTurns([record], connected: true)
            let actor = try #require(SessionCrewProjection(rows: turns.flatMap(\.rows)).actors.last)
            #expect(actor.row.active)
            #expect(actor.row.status == state.label)
            #expect(actor.row.finish(at: origin.addingTimeInterval(5)) == origin.addingTimeInterval(5))
            let display = SessionCrewProjection.state(actor, at: nil, connected: true)
            #expect(display.label == state.label)
            #expect(!display.moving)
        }
    }

    @Test func fortyWorkersHaveDistinctReadablePositions() {
        let rows = [row("root", .turn)] + (0..<40).map { row("worker-\($0)", .agent, parent: "root") }
        let actors = SessionCrewProjection(rows: rows).actors
        for width in [320.0, 380, 900] {
            let layout = SessionCrewLayout(actors: actors, width: width, zoom: 1)
            let positions = Array(layout.positions.values)
            #expect(positions.count == 41)
            #expect(layout.nodeWidth >= 100)
            for (index, position) in positions.enumerated() {
                #expect(position.x >= layout.nodeWidth / 2)
                #expect(position.x + layout.nodeWidth / 2 <= layout.size.width)
                #expect(position.y + 63 <= layout.size.height)
                for other in positions.dropFirst(index + 1) {
                    #expect(abs(position.x - other.x) >= layout.nodeWidth || abs(position.y - other.y) >= 126)
                }
            }
        }
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
