import Testing
import Foundation
@testable import Herm

struct SessionActivityPresentationTests {
    @Test func linkedBotRecordsAreDeduplicatedAndIndependentDispatchesRemain() {
        let task = KanbanTaskSummary(
            id: "card-1", title: "Ship the fix", status: "running", detail: nil,
            priority: nil, assignee: "Luna", latestEventAt: Date(timeIntervalSince1970: 20)
        )
        let linked = BotActivityRecord(
            id: "linked", originSessionID: "s", botID: "luna", botName: "Luna",
            summary: "Ship the fix", state: .working, updatedAt: Date(timeIntervalSince1970: 19),
            linkedCardID: "card-1"
        )
        let direct = BotActivityRecord(
            id: "direct", originSessionID: "s", botID: "forge", botName: "Forge",
            summary: "Run checks", state: .waiting, updatedAt: Date(timeIntervalSince1970: 18)
        )

        let snapshot = SessionActivityOverviewPresentation.makeSnapshot(
            agentSnapshot: emptyAgentSnapshot,
            botRecords: [linked, direct],
            kanbanTasks: [task]
        )

        #expect(snapshot.work.map(\.id) == ["kanban:card-1", "bot:direct"])
        #expect(snapshot.blockedWorkCount == 1)
        #expect(snapshot.timeline.filter { $0.source == .bot }.map(\.id) == ["bot:direct"])
    }

    @Test func timelineKeepsUnknownStatusesAndSortsNewestFirst() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let pipeline = AgentActivityPresentation.PipelineActivity(
            id: "event-1", timestamp: newer, status: "paused_by_runtime",
            task: "Inspect logs", agent: "Luna", detail: nil, diffPreview: nil
        )
        let task = KanbanTaskSummary(
            id: "card-1", title: "Older task", status: "custom_state", detail: nil,
            priority: nil, assignee: nil, latestEventAt: older
        )
        let snapshot = SessionActivityOverviewPresentation.makeSnapshot(
            agentSnapshot: AgentPresentationSnapshot(
                displayedSubagents: [], pipeline: [pipeline],
                activityCountsByAgentID: [:], activeAgentIDs: [], revision: 1
            ),
            botRecords: [], kanbanTasks: [task]
        )

        // An unfinished card sits in its status section, not in Recent.
        #expect(snapshot.timeline.map(\.id) == ["agent:event-1"])
        #expect(snapshot.work.first?.status == "CUSTOM_STATE")
    }

    @Test func kanbanCardsShowOnceInTheirStatusSection() {
        let at = Date(timeIntervalSince1970: 10)
        func card(_ id: String, _ status: String) -> KanbanTaskSummary {
            KanbanTaskSummary(id: id, title: id, status: status, detail: nil, priority: nil, assignee: nil, latestEventAt: at)
        }
        let snapshot = SessionActivityOverviewPresentation.makeSnapshot(
            agentSnapshot: emptyAgentSnapshot, botRecords: [],
            kanbanTasks: [card("b", "blocked"), card("t", "triage"), card("r", "running"),
                          card("s", "scheduled"), card("d", "done")]
        )

        let lanes = Dictionary(uniqueKeysWithValues: snapshot.work.map { ($0.id, $0.lane) })
        #expect(lanes == ["kanban:b": .blocked, "kanban:t": .blocked, "kanban:r": .inProgress, "kanban:s": .queued])
        #expect(snapshot.work.first { $0.id == "kanban:t" }?.status == "TRIAGE")
        #expect(snapshot.blockedWorkCount == 2)
        #expect(snapshot.timeline.map(\.id) == ["kanban:d:10.0"])
        #expect(snapshot.timeline.first?.kanbanTask?.id == "d")
    }

    @Test func activeTurnLeadsInProgressWithItsRunningStep() {
        let running = AgentActivityPresentation.PipelineActivity(
            id: "tool:t1", timestamp: Date(timeIntervalSince1970: 5), status: "Running",
            task: "Run patch", agent: "Orchestrator", detail: nil, diffPreview: nil
        )
        let agentSnapshot = AgentPresentationSnapshot(
            displayedSubagents: [], pipeline: [running],
            activityCountsByAgentID: [:], activeAgentIDs: [], revision: 1
        )
        let idle = SessionActivityOverviewPresentation.makeSnapshot(agentSnapshot: agentSnapshot, botRecords: [], kanbanTasks: [])
        let active = SessionActivityOverviewPresentation.makeSnapshot(agentSnapshot: agentSnapshot, botRecords: [], kanbanTasks: [], isTurnActive: true)
        let between = SessionActivityOverviewPresentation.makeSnapshot(agentSnapshot: emptyAgentSnapshot, botRecords: [], kanbanTasks: [], isTurnActive: true)

        #expect(idle.work.isEmpty)
        #expect(active.work.map(\.title) == ["Run patch"])
        #expect(between.work.map(\.id) == ["turn"])
    }

    private var emptyAgentSnapshot: AgentPresentationSnapshot {
        AgentPresentationSnapshot(
            displayedSubagents: [], pipeline: [], activityCountsByAgentID: [:],
            activeAgentIDs: [], revision: 0
        )
    }
}
