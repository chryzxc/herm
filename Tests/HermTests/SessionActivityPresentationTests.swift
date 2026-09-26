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

        #expect(snapshot.timeline.map(\.id) == ["agent:event-1", "kanban:card-1:10.0"])
        #expect(snapshot.timeline.last?.status == "CUSTOM_STATE")
    }

    private var emptyAgentSnapshot: AgentPresentationSnapshot {
        AgentPresentationSnapshot(
            displayedSubagents: [], pipeline: [], activityCountsByAgentID: [:],
            activeAgentIDs: [], revision: 0
        )
    }
}
