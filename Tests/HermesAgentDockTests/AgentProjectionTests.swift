import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct AgentProjectionTests {
    @Test func batchDelegationProjectsOneNamedAgentPerTask() {
        let startedAt = Date(timeIntervalSince1970: 123)
        let agents = DockModel.projectedDelegationAgents(
            toolCallID: "delegate-1",
            args: [
                "source_skill": "dev-orchestrator",
                "tasks": [
                    ["goal": "Build the responsive frontend", "agent_role": "Frontend"],
                    ["goal": "Implement the API and persistence layer", "agent_role": "Backend"],
                    ["goal": "Review authentication and authorization", "agent_role": "Security Reviewer"],
                    ["goal": "Run the quality assurance test plan", "agent_role": "QA"]
                ]
            ],
            startedAt: startedAt
        )

        #expect(agents.map(\.id) == ["delegate-1:0", "delegate-1:1", "delegate-1:2", "delegate-1:3"])
        #expect(agents.map(\.name) == ["Frontend", "Backend", "Security Reviewer", "QA"])
        #expect(agents.allSatisfy { $0.status == "running" })
        #expect(agents.allSatisfy { $0.sourceSkill == "dev-orchestrator" })
        #expect(agents.allSatisfy { $0.startedAt == startedAt })
    }

    @Test func legacyGoalTextStillProducesUsefulAgentIdentity() {
        let agents = DockModel.projectedDelegationAgents(
            toolCallID: "delegate-2",
            args: ["goal": "Act as the frontend implementer and build the settings screen", "role": "leaf"],
            startedAt: .distantPast
        )

        #expect(agents.count == 1)
        #expect(agents.first?.name == "Frontend")
        #expect(agents.first?.role == "Frontend")
        #expect(agents.first?.name != "Leaf")
    }

    @Test func backgroundAcknowledgementDoesNotMeanAgentCompleted() {
        #expect(DockModel.isBackgroundDelegationDispatch("""
        {"status":"dispatched","mode":"background","count":2}
        """))
        #expect(!DockModel.isBackgroundDelegationDispatch("""
        {"results":[{"status":"success","summary":"done"}]}
        """))
        #expect(!DockModel.isBackgroundDelegationDispatch("plain text result"))
    }

    @Test func lateProgressCannotReopenACompletedAgent() {
        #expect(DockModel.agentStatus(current: "complete", eventType: "subagent.tool") == "complete")
        #expect(DockModel.agentStatus(current: "running", eventType: "subagent.complete") == "complete")
        #expect(DockModel.agentStatus(current: "queued", eventType: "subagent.start") == "running")
    }

    @Test func extractsOnlyAvailableDiffDataForMiniPreview() {
        let inline = DockModel.diffPreview(from: [
            "inline_diff": "\u{001B}[32m+added line\u{001B}[0m\n-removed line"
        ])
        let tail = DockModel.diffPreview(from: [
            "output_tail": [["tool": "patch", "preview": "@@ -1 +1 @@\n-old\n+new"]]
        ])
        let ordinaryOutput = DockModel.diffPreview(from: [
            "output_tail": [["tool": "read_file", "preview": "Read 25 lines"]]
        ])

        #expect(inline == "+added line\n-removed line")
        #expect(tail == "@@ -1 +1 @@\n-old\n+new")
        #expect(ordinaryOutput == nil)
    }

    @Test func objectToolResultsRetainBackgroundDispatchMeaning() {
        let result = DockModel.eventText(["status": "dispatched", "mode": "background"])

        #expect(DockModel.isBackgroundDelegationDispatch(result))
    }
}
