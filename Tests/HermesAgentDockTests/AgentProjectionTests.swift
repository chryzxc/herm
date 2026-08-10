import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct AgentProjectionTests {
    @Test func classifiesAgentActivityPhases() {
        #expect(AgentActivityPresentation.phase(for: "subagent.spawn_requested") == .pending)
        #expect(AgentActivityPresentation.phase(for: "subagent.tool") == .running)
        #expect(AgentActivityPresentation.phase(for: "subagent.complete") == .complete)
        #expect(AgentActivityPresentation.phase(for: "subagent.error") == .failed)
        #expect(AgentActivityPresentation.phase(for: "subagent.interrupted") == .interrupted)
        #expect(AgentActivityPresentation.displayStatus(for: .complete) == "Complete")
    }

    @Test func unknownCompletedActivityDoesNotRemainRunning() {
        #expect(AgentActivityPresentation.phase(for: "custom-event", isActive: false) == .pending)
        #expect(AgentActivityPresentation.phase(for: "custom-event", isActive: true) == .running)
    }

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

    @Test func childSessionEventsResolveToTheirAgent() {
        let agent = HermesSubagent(
            id: "agent-1",
            childSessionID: "child-session-1",
            goal: "Inspect the API",
            status: "running"
        )

        #expect(DockModel.agentID(explicitAgentID: nil, eventSessionID: "child-session-1", agents: [agent]) == "agent-1")
        #expect(DockModel.agentID(explicitAgentID: "agent-2", eventSessionID: nil, agents: [agent]) == "agent-2")
    }

    @Test func parentDelegationToolCallIsNotSwallowedAsAgentActivity() {
        #expect(!DockModel.isAgentScopedActivity(
            eventAgentID: "future-agent",
            eventSessionID: "parent-session",
            parentSessionID: nil,
            currentSessionID: "parent-session",
            agents: []
        ))

        let agent = HermesSubagent(id: "agent-1", goal: "Inspect API", status: "running")
        #expect(DockModel.isAgentScopedActivity(
            eventAgentID: "agent-1",
            eventSessionID: "parent-session",
            parentSessionID: nil,
            currentSessionID: "parent-session",
            agents: [agent]
        ))
    }

    @Test func delegatedToolEventsBecomeMeaningfulActivityRows() {
        #expect(DockModel.agentActivityKind(for: "tool.call") == "subagent.tool")
        #expect(DockModel.agentActivityKind(for: "tool.result") == "subagent.tool.complete")
        #expect(DockModel.agentActivityKind(for: "reasoning.delta") == nil)
        let text = DockModel.agentActivityText(
            type: "subagent.tool",
            payload: ["arguments": ["path": "Sources/App.swift"]],
            toolName: "read_file"
        )
        #expect(text.hasPrefix("read_file: "))
        #expect(text.contains("Sources"))
        #expect(text.contains("App.swift"))
    }

    @Test func pipelineProjectionExposesTheExactNewestTaskTitle() {
        let olderActivity = AgentActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 10),
            agentID: nil,
            kind: "subagent.tool.complete",
            text: "search_files",
            toolName: "search_files",
            handoffTarget: nil
        )
        let latestTool = ActiveToolCall(
            id: "tool-1",
            name: "patch",
            input: "",
            context: "Sources/App.swift",
            startedAt: Date(timeIntervalSince1970: 20),
            result: "done",
            isComplete: true,
            completedAt: Date(timeIntervalSince1970: 30)
        )

        let pipeline = AgentActivityPresentation.pipeline(
            activities: [olderActivity],
            toolCalls: [latestTool],
            subagents: []
        )

        #expect(pipeline.first?.task == "Edit Sources/App.swift")
        #expect(pipeline.first?.status == "Complete")
        #expect(pipeline.first?.timestamp == Date(timeIntervalSince1970: 30))
    }

    @Test func terminalActivityTitlesAreMeaningfulAndHideLeadingEnvironmentValues() {
        let title = AgentActivityPresentation.toolActivityTitle(
            name: "terminal",
            context: "API_SECRET='not-for-display' NODE_ENV=test npm run build"
        )

        #expect(title == "Run npm run build")
        #expect(!title.contains("not-for-display"))
    }

    @Test func conversationUsesTheLatestPipelineTaskInsteadOfWorkingFallback() {
        let pipeline = AgentActivityPresentation.PipelineActivity(
            id: "tool:1",
            timestamp: Date(timeIntervalSince1970: 20),
            status: "Complete",
            task: "Run gh pr checks 85",
            agent: "Hermes",
            detail: nil,
            diffPreview: nil
        )
        let unrelatedEvent = AgentEvent(
            id: UUID(),
            type: "sessions.changed",
            detail: "",
            timestamp: Date(timeIntervalSince1970: 30)
        )

        #expect(AgentActivityPresentation.conversationTitle(
            latestPipelineActivity: pipeline,
            recentEvents: [unrelatedEvent]
        ) == "Run gh pr checks 85")
    }

    @Test func onlyANewerReasoningDeltaOverridesThePipelineTask() {
        let pipeline = AgentActivityPresentation.PipelineActivity(
            id: "tool:1",
            timestamp: Date(timeIntervalSince1970: 20),
            status: "Complete",
            task: "Run git status --short",
            agent: "Hermes",
            detail: nil,
            diffPreview: nil
        )
        let reasoningDelta = AgentEvent(
            id: UUID(),
            type: "reasoning.delta",
            detail: "",
            timestamp: Date(timeIntervalSince1970: 30)
        )

        #expect(AgentActivityPresentation.conversationTitle(
            latestPipelineActivity: pipeline,
            recentEvents: [reasoningDelta]
        ) == "Thinking")
    }

    @Test func runningPipelineActivityRemainsVisibleWhenConversationStatusIsIdle() {
        let running = AgentActivityPresentation.PipelineActivity(
            id: "tool:1",
            timestamp: Date(),
            status: "Running",
            task: "Run npm install --package-lock-only",
            agent: "Hermes",
            detail: nil,
            diffPreview: nil
        )
        let complete = AgentActivityPresentation.PipelineActivity(
            id: "tool:2",
            timestamp: Date(),
            status: "Complete",
            task: "Run npm test",
            agent: "Hermes",
            detail: nil,
            diffPreview: nil
        )

        #expect(running.isActive)
        #expect(!complete.isActive)
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
