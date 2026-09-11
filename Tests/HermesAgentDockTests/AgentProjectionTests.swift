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

    @Test func genericDelegatesRemainExplicitlyUnprofiledInActivity() {
        let agents = DockModel.projectedDelegationAgents(
            toolCallID: "delegate-security",
            args: ["goal": "Have a security reviewer audit authentication and authorization"],
            startedAt: .distantPast
        )

        let row = AgentActivityPresentation.pipeline(activities: [], toolCalls: [], subagents: agents).first
        #expect(row?.agent == "Unprofiled Delegate · Security Reviewer")
    }

    @Test func inlineAgentMapPreservesTopDownDepthAndScrollableSpacing() {
        let agents = [
            HermesSubagent(id: "parent", childSessionID: "parent-session", goal: "Plan implementation", status: "running"),
            HermesSubagent(id: "child", parentID: "parent-session", childSessionID: "child-session", goal: "Build feature", status: "running"),
            HermesSubagent(id: "grandchild", parentID: "child-session", goal: "Verify feature", status: "running"),
            HermesSubagent(id: "sibling", goal: "Review work", status: "running")
        ]

        let layout = AgentMapTreeLayout.make(agents: agents, minimumSize: CGSize(width: 500, height: 460))
        let parent = layout.positions["parent"]!
        let child = layout.positions["child"]!
        let grandchild = layout.positions["grandchild"]!
        let sibling = layout.positions["sibling"]!

        #expect(child.y - parent.y == AgentMapTreeLayout.verticalStride)
        #expect(grandchild.y - child.y == AgentMapTreeLayout.verticalStride)
        #expect(abs(sibling.x - parent.x) >= AgentMapTreeLayout.horizontalStride)
        #expect(layout.contentSize.height > 460)
    }

    @Test func inlineAgentMapWrapsWideDelegationBatchesIntoThreeColumns() {
        let agents = (0..<8).map { index in
            HermesSubagent(id: "agent-\(index)", goal: "Task \(index)", status: "running")
        }

        let layout = AgentMapTreeLayout.make(agents: agents, minimumSize: CGSize(width: 700, height: 460))

        #expect(layout.positions["agent-0"]?.y == layout.positions["agent-2"]?.y)
        #expect(layout.positions["agent-3"]!.y - layout.positions["agent-0"]!.y == AgentMapTreeLayout.verticalStride)
        #expect(layout.positions["agent-6"]!.y - layout.positions["agent-3"]!.y == AgentMapTreeLayout.verticalStride)
        #expect(layout.rootPosition.x == AgentMapTreeLayout.horizontalInset + AgentMapTreeLayout.nodeWidth / 2)
    }

    @Test func eventsMustProveCurrentSessionOwnershipBeforeProjection() {
        let currentAgent = HermesSubagent(
            id: "agent-current",
            childSessionID: "child-current",
            goal: "Current work",
            status: "running"
        )

        #expect(DockModel.eventBelongsToSession(
            type: "tool.result",
            envelopeSessionID: "other-session",
            eventSessionID: "other-session",
            payload: ["subagent_id": currentAgent.id],
            currentSessionID: "current-session",
            agents: [currentAgent]
        ) == false)
        #expect(DockModel.eventBelongsToSession(
            type: "message.delta",
            envelopeSessionID: nil,
            eventSessionID: nil,
            payload: ["delta": "unattributed"],
            currentSessionID: "current-session",
            agents: [currentAgent]
        ) == false)
        #expect(DockModel.eventBelongsToSession(
            type: "subagent.tool",
            envelopeSessionID: "other-child",
            eventSessionID: "other-child",
            payload: [
                "child_session_id": "child-current",
                "parent_session_id": "current-session"
            ],
            currentSessionID: "current-session",
            agents: [currentAgent]
        ) == false)
        #expect(DockModel.eventBelongsToSession(
            type: "subagent.tool",
            envelopeSessionID: "child-current",
            eventSessionID: "child-current",
            payload: ["child_session_id": "child-current"],
            currentSessionID: "current-session",
            agents: [currentAgent]
        ))
        #expect(DockModel.eventBelongsToSession(
            type: "message.complete",
            envelopeSessionID: "current-session",
            eventSessionID: "current-session",
            payload: [:],
            currentSessionID: "current-session",
            agents: [currentAgent]
        ))
        #expect(DockModel.eventBelongsToSession(
            type: "message.complete",
            envelopeSessionID: "current-session",
            eventSessionID: "current-session",
            payload: ["session_id": "other-session"],
            currentSessionID: "current-session",
            agents: [currentAgent]
        ) == false)
        #expect(DockModel.eventBelongsToSession(
            type: "subagent.tool",
            envelopeSessionID: "child-current",
            eventSessionID: "child-current",
            payload: ["child_session_id": "other-child"],
            currentSessionID: "current-session",
            agents: [currentAgent]
        ) == false)
    }

    @Test func switchingSessionsRestoresEachSessionsAgentStateWithoutLeakage() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-agent-state-\(UUID().uuidString).json")
        let model = DockModel(sessionAgentStateFileURL: storeURL)
        let activityA = AgentActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 10),
            agentID: "agent-a",
            kind: "subagent.tool.complete",
            text: "Updated session A",
            toolName: "patch",
            handoffTarget: nil
        )
        let activityB = AgentActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 20),
            agentID: "agent-b",
            kind: "subagent.tool.complete",
            text: "Tested session B",
            toolName: "terminal",
            handoffTarget: nil
        )

        model.activeSubagents = [HermesSubagent(id: "agent-a", goal: "Work in A", status: "complete")]
        model.sessionAgents = model.activeSubagents
        model.agentActivities = [activityA]
        model.cacheAgentState(for: "session-a")

        model.activeSubagents = [HermesSubagent(id: "agent-b", goal: "Work in B", status: "running")]
        model.sessionAgents = model.activeSubagents
        model.agentActivities = [activityB]
        model.cacheAgentState(for: "session-b")

        #expect(model.restoreAgentState(for: "session-a"))
        #expect(model.activeSubagents.isEmpty)
        #expect(model.sessionAgents.map(\.id) == ["agent-a"])
        #expect(model.displayedSubagents.first?.status == "complete")
        #expect(model.agentActivities == [activityA])

        #expect(model.restoreAgentState(for: "session-b"))
        #expect(model.activeSubagents.isEmpty)
        #expect(model.sessionAgents.map(\.id) == ["agent-b"])
        #expect(model.displayedSubagents.first?.status == "complete")
        #expect(model.agentActivities == [activityB])

        #expect(!model.restoreAgentState(for: "session-c"))
        #expect(model.activeSubagents.isEmpty)
        #expect(model.agentActivities.isEmpty)
    }

    @Test func sessionAgentStateSurvivesModelRelaunch() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-agent-state-\(UUID().uuidString).json")
        let activity = AgentActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 30),
            agentID: "persistent-agent",
            kind: "subagent.tool.complete",
            text: "Completed retained work",
            toolName: "patch",
            handoffTarget: nil
        )

        let firstLaunch = DockModel(sessionAgentStateFileURL: storeURL)
        firstLaunch.activeSubagents = [HermesSubagent(id: "persistent-agent", goal: "Retain me", status: "complete")]
        firstLaunch.sessionAgents = firstLaunch.activeSubagents
        firstLaunch.agentActivities = [activity]
        firstLaunch.cacheAgentState(for: "persistent-session")

        let secondLaunch = DockModel(sessionAgentStateFileURL: storeURL)
        #expect(secondLaunch.restoreAgentState(for: "persistent-session"))
        #expect(secondLaunch.activeSubagents.isEmpty)
        #expect(secondLaunch.sessionAgents.map(\.id) == ["persistent-agent"])
        #expect(secondLaunch.displayedSubagents.first?.status == "complete")
        #expect(secondLaunch.agentActivities == [activity])
        try? FileManager.default.removeItem(at: storeURL)
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

    @Test func exactKanbanIDsAreExtractedFromToolEvidenceOnly() {
        #expect(DockModel.kanbanTaskIDs(in: "hermes kanban show t_33604ca9 --json") == ["t_33604ca9"])
        #expect(DockModel.kanbanTaskIDs(in: "unrelated prose has no durable card") == [])
    }

    @Test func activeSessionRetainsKanbanReferenceAfterTerminalToolActivity() {
        let model = DockModel(initialSessionID: "session-a")

        model.receiveGatewayEvent("tool.start", params: [
            "session_id": "session-a",
            "payload": [
                "name": "terminal",
                "input": "hermes kanban show t_33604ca9 --json"
            ]
        ])
        model.receiveGatewayEvent("tool.start", params: [
            "session_id": "session-b",
            "payload": [
                "name": "terminal",
                "input": "hermes kanban show t_unowned --json"
            ]
        ])

        #expect(model.observedKanbanTaskIDs == ["t_33604ca9"])
        #expect(model.observedKanbanTaskRevision == 1)
    }

    @Test func restoredBoundedToolHistoryCanRecoverAnObservedKanbanCard() {
        let model = DockModel(initialSessionID: "session-a")
        model.recentEvents = [AgentEvent(
            id: UUID(),
            type: "tool.complete",
            detail: #"{"payload":{"input":"hermes kanban show t_33604ca9 --json"}}"#,
            timestamp: .now
        )]

        #expect(model.observedKanbanTaskIDs == ["t_33604ca9"])
    }

    @Test func lateProgressCannotReopenACompletedAgent() {
        #expect(DockModel.agentStatus(current: "complete", eventType: "subagent.tool") == "complete")
        #expect(DockModel.agentStatus(current: "running", eventType: "subagent.complete") == "complete")
        #expect(DockModel.agentStatus(current: "queued", eventType: "subagent.start") == "running")
    }

    @Test func completionStatusUpdatesAndLifecycleVariantsAreTerminal() {
        #expect(DockModel.agentStatus(
            current: "running",
            eventType: "subagent.status",
            reportedStatus: "completed"
        ) == "complete")
        #expect(DockModel.agentStatus(current: "running", eventType: "subagent.completed") == "complete")
        #expect(DockModel.agentStatus(
            current: "complete",
            eventType: "subagent.status",
            reportedStatus: "running"
        ) == "complete")
        #expect(!AgentActivityPresentation.isActiveStatus(
            DockModel.canonicalAgentStatus("succeeded") ?? "running"
        ))
    }

    @Test func authoritativeLiveRefreshDropsFinishedNativeAgentsButKeepsPendingPlaceholders() {
        let finished = HermesSubagent(id: "native-finished", goal: "Done", status: "running")
        let placeholder = HermesSubagent(id: "delegate:0", goal: "Awaiting native ID", status: "running")
        let running = HermesSubagent(id: "native-running", goal: "Still working", status: "running")

        let live = DockModel.reconciledLiveAgents(
            authoritative: [running],
            current: [finished, placeholder],
            synthesizedIDs: [placeholder.id]
        )

        #expect(live.map(\.id) == ["native-running", "delegate:0"])
    }

    @Test func emptyAuthoritativeLiveProjectionDoesNotResurrectSavedChildSessions() {
        let previouslyVisibleChild = HermesSubagent(
            id: "saved-child-session",
            goal: "Already finished",
            status: "running"
        )

        let live = DockModel.reconciledLiveAgents(
            authoritative: [],
            current: [previouslyVisibleChild],
            synthesizedIDs: []
        )

        #expect(live.isEmpty)
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
        #expect(DockModel.agentID(
            explicitAgentID: nil,
            eventSessionID: "parent-session",
            childSessionID: "child-session-1",
            agents: [agent]
        ) == "agent-1")
    }

    @Test func legacySubagentEventsResolveByGoalOrBatchIndex() {
        let agents = [
            HermesSubagent(id: "delegate-call:0", goal: "Inspect the API", status: "running"),
            HermesSubagent(id: "delegate-call:1", goal: "Implement the UI", status: "running")
        ]

        #expect(DockModel.agentID(
            explicitAgentID: nil,
            eventSessionID: "parent-session",
            goal: "Implement the UI",
            agents: agents
        ) == "delegate-call:1")
        #expect(DockModel.agentID(
            explicitAgentID: nil,
            eventSessionID: "parent-session",
            taskIndex: 0,
            agents: agents
        ) == "delegate-call:0")
    }

    @Test func stableSessionIdentityPrefersDurableGatewayKeys() {
        #expect(DockModel.stableSessionID(from: [
            "session_id": "live-1234",
            "stored_session_id": "stored-2026"
        ]) == "stored-2026")
        #expect(DockModel.stableSessionID(from: [
            "session_id": "live-5678",
            "session_key": "stored-resumed"
        ]) == "stored-resumed")
        #expect(DockModel.sessionAttributionID(runtimeID: "live-5678", storageID: "stored-resumed") == "stored-resumed")
        #expect(DockModel.sessionAttributionID(runtimeID: "live-5678", storageID: nil) == "live-5678")
        #expect(DockModel.kanbanAttributionAfterResume(
            requestedSessionID: "requested-stale-id",
            resolvedSessionID: "resolved-live-id"
        ) == "resolved-live-id")
        #expect(DockModel.kanbanAttributionID(
            requestedSessionID: "durable-selected-session",
            runtimeID: "gateway-runtime-alias",
            storageID: "gateway-storage-alias"
        ) == "durable-selected-session")
        #expect(DockModel.kanbanAttributionID(
            requestedSessionID: nil,
            runtimeID: "gateway-runtime-alias",
            storageID: "gateway-storage-alias"
        ) == "gateway-storage-alias")
    }

    @Test func realHermesSubagentEnvelopeSequenceProjectsEveryTaskToOneAgent() {
        let agent = HermesSubagent(
            id: "sa-0-abcd1234",
            childSessionID: "child-session-1",
            goal: "Implement issue 51",
            status: "running"
        )
        let base: [String: Any] = [
            "session_id": "parent-live-session",
            "timestamp": 100.0
        ]
        let payloads: [[String: Any]] = [
            ["subagent_id": agent.id, "child_session_id": "child-session-1", "goal": agent.goal, "task_index": 0, "text": agent.goal],
            ["subagent_id": agent.id, "child_session_id": "child-session-1", "goal": agent.goal, "task_index": 0, "tool_name": "read_file", "tool_preview": "Sources/App.swift"],
            ["subagent_id": agent.id, "child_session_id": "child-session-1", "goal": agent.goal, "task_index": 0, "tool_name": "terminal", "tool_preview": "swift test"],
            ["subagent_id": agent.id, "child_session_id": "child-session-1", "goal": agent.goal, "task_index": 0, "status": "completed", "summary": "Implemented and tested"]
        ]
        let types = ["subagent.start", "subagent.tool", "subagent.tool", "subagent.complete"]

        let projections = zip(types, payloads).compactMap { type, payload in
            DockModel.agentActivityProjection(
                type: type,
                params: base.merging(["payload": payload]) { _, new in new },
                currentSessionID: "parent-live-session",
                agents: [agent]
            )
        }

        #expect(projections.count == 4)
        #expect(projections.allSatisfy { $0.payload["subagent_id"] as? String == agent.id })
        #expect(projections.compactMap { ($0.payload["tool_name"] as? String) } == ["read_file", "terminal"])
        #expect(projections.last?.kind == "subagent.complete")
    }

    @Test func delegationStatusLastToolBecomesAgentOwnedActivity() {
        let previous = HermesSubagent(
            id: "agent-1",
            goal: "Implement the feature",
            status: "running",
            toolCount: 2,
            latestActivity: "read_file"
        )
        let current = HermesSubagent(
            id: "agent-1",
            goal: "Implement the feature",
            status: "running",
            toolCount: 3,
            latestActivity: "read_file"
        )

        let projection = DockModel.telemetryActivityProjection(
            row: [
                "subagent_id": "agent-1",
                "last_tool": "read_file",
                "tool_count": 3
            ],
            agent: current,
            previous: previous
        )

        #expect(projection?.kind == "subagent.tool")
        #expect(projection?.payload["subagent_id"] as? String == "agent-1")
        #expect(projection?.payload["tool_name"] as? String == "read_file")
        #expect(projection?.payload["text"] as? String == "read_file")
    }

    @Test func delegationStatusRowsRequireCurrentSessionOwnership() {
        #expect(DockModel.delegationStatusRow([
            "subagent_id": "current-agent",
            "owner_agent_session_id": "session-current"
        ], belongsTo: "session-current"))
        #expect(DockModel.delegationStatusRow([
            "subagent_id": "current-agent",
            "parent_session_id": "session-current"
        ], belongsTo: "session-current"))
        #expect(!DockModel.delegationStatusRow([
            "subagent_id": "other-agent",
            "parent_session_id": "session-other"
        ], belongsTo: "session-current"))
        #expect(!DockModel.delegationStatusRow([
            "subagent_id": "unscoped-agent"
        ], belongsTo: "session-current"))
        #expect(!DockModel.delegationStatusRow([
            "subagent_id": "session-current",
            "parent_id": "session-current"
        ], belongsTo: "session-current"))
    }

    @Test func unchangedDelegationStatusDoesNotDuplicateAgentActivity() {
        let agent = HermesSubagent(
            id: "agent-1",
            goal: "Implement the feature",
            status: "running",
            toolCount: 3,
            latestActivity: "read_file"
        )

        let projection = DockModel.telemetryActivityProjection(
            row: [
                "subagent_id": "agent-1",
                "last_tool": "read_file",
                "tool_count": 3
            ],
            agent: agent,
            previous: agent
        )

        #expect(projection?.kind == nil)
    }

    @Test func resolvedChildSessionIDIsPersistedOnEveryAgentActivity() {
        let agent = HermesSubagent(
            id: "frontend-agent",
            childSessionID: "frontend-session",
            goal: "Implement the todo feature",
            status: "running"
        )
        let resolvedID = DockModel.agentID(
            explicitAgentID: nil,
            eventSessionID: "frontend-session",
            agents: [agent]
        )
        let start = DockModel.agentActivityPayload(["text": "Read TodoView.swift"], resolvedAgentID: resolvedID)
        let complete = DockModel.agentActivityPayload(["text": "Updated TodoView.swift"], resolvedAgentID: resolvedID)

        #expect(start["subagent_id"] as? String == "frontend-agent")
        #expect(complete["subagent_id"] as? String == "frontend-agent")
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
        #expect(DockModel.agentActivityKind(for: "message.complete") == "subagent.complete")
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
        #expect(pipeline.first?.agent == "Orchestrator")
        #expect(pipeline.first?.timestamp == Date(timeIntervalSince1970: 30))
        #expect(pipeline.first?.elapsedDuration() == 10)
    }

    @Test func pipelinePreservesExactAgentAndSessionOwnership() {
        let agent = HermesSubagent(
            id: "agent-1",
            parentID: "parent-agent",
            childSessionID: "child-session",
            goal: "Implement the UI",
            role: "Frontend",
            status: "running"
        )
        let call = ActiveToolCall(
            id: "tool-1",
            name: "read_file",
            input: "",
            context: "Sources/App.swift",
            startedAt: .distantPast,
            result: nil,
            isComplete: false,
            agentID: agent.id,
            parentAgentID: agent.parentID,
            childSessionID: agent.childSessionID
        )

        let row = AgentActivityPresentation.pipeline(
            activities: [],
            toolCalls: [call],
            subagents: [agent]
        ).first

        #expect(row?.agent == "Unprofiled Delegate · Frontend")
        #expect(row?.agentID == "agent-1")
        #expect(AgentActivityPresentation.pipeline(activities: [], toolCalls: [call], subagents: [agent]).filter { $0.agentID == agent.id }.count == 1)
        #expect(row?.parentAgentID == "parent-agent")
        #expect(row?.childSessionID == "child-session")
    }

    @Test func agentActivityTitleMatchesThePipelineTaskLabel() {
        let activity = AgentActivity(
            id: UUID(),
            timestamp: .distantPast,
            agentID: "frontend-agent",
            kind: "subagent.tool",
            text: "Sources/HermesAgentDock/AgentMapView.swift",
            toolName: "read_file",
            handoffTarget: nil
        )

        let pipeline = AgentActivityPresentation.pipeline(
            activities: [activity],
            toolCalls: [],
            subagents: [HermesSubagent(id: "frontend-agent", goal: "Improve the UI", status: "running")]
        )

        #expect(AgentActivityPresentation.activityTitle(for: activity) == "Read Sources/HermesAgentDock/AgentMapView.swift")
        #expect(pipeline.first?.task == AgentActivityPresentation.activityTitle(for: activity))
    }

    @Test func pipelineDurationUsesCanonicalAgentDurationAndFormatsCompactly() {
        let agent = HermesSubagent(
            id: "agent-duration",
            goal: "Review the patch",
            status: "Complete",
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 92),
            durationSeconds: 82
        )

        let pipeline = AgentActivityPresentation.pipeline(
            activities: [],
            toolCalls: [],
            subagents: [agent]
        )

        #expect(pipeline.first?.elapsedDuration() == 82)
        #expect(AgentBoardView.formatDuration(82) == "1m 22s")
        #expect(AgentBoardView.formatDuration(3_785) == "1h 3m")
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

    @Test func completedDelegationHistoryDoesNotKeepConversationActivityVisible() {
        let completedAgent = HermesSubagent(
            id: "qa-agent",
            goal: "Review the working tree",
            status: "completed",
            completedAt: Date()
        )
        let historicalStart = AgentActivity(
            id: UUID(),
            timestamp: Date(),
            agentID: completedAgent.id,
            kind: "subagent.start",
            text: completedAgent.goal,
            toolName: nil,
            handoffTarget: nil
        )

        let pipeline = AgentActivityPresentation.pipeline(
            activities: [historicalStart],
            toolCalls: [],
            subagents: [completedAgent]
        )

        #expect(pipeline.first?.status == "completed")
        #expect(pipeline.first?.isActive == false)
        #expect(!AgentActivityPresentation.hasActiveWork(
            toolCalls: [],
            subagents: [completedAgent]
        ))
    }

    @Test func duplicatedSubagentIDsDoNotCrashThePipelineProjection() {
        let agent = HermesSubagent(id: "dupe-agent", goal: "Same worker", status: "running")

        let pipeline = AgentActivityPresentation.pipeline(
            activities: [],
            toolCalls: [],
            subagents: [agent, agent]
        )

        #expect(pipeline.count == 1)
    }

    @Test func pipelineRowIDsRemainUniqueWhenSourcesCollide() {
        let agent = HermesSubagent(id: "agent-1", goal: "Worker", status: "running")
        let tool = ActiveToolCall(
            id: "same",
            name: "patch",
            input: "",
            context: "",
            startedAt: Date(timeIntervalSince1970: 10),
            result: nil,
            isComplete: false
        )
        let activity = AgentActivity(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 5),
            agentID: "agent-1",
            kind: "tool.start",
            text: "patch",
            toolName: "patch",
            handoffTarget: nil
        )

        let pipeline = AgentActivityPresentation.pipeline(
            activities: [activity, activity, activity, activity],
            toolCalls: [tool],
            subagents: [agent]
        )

        #expect(pipeline.count == 5)
        #expect(Set(pipeline.map(\.id)).count == pipeline.count)
    }

    @Test func activeToolOrSubagentKeepsConversationActivityVisible() {
        let runningAgent = HermesSubagent(
            id: "qa-agent",
            goal: "Review the working tree",
            status: "running"
        )
        let completeTool = ActiveToolCall(
            id: "tool-1",
            name: "terminal",
            input: "swift test",
            context: "",
            startedAt: Date(),
            result: "ok",
            isComplete: true,
            completedAt: Date()
        )

        #expect(AgentActivityPresentation.hasActiveWork(toolCalls: [], subagents: [runningAgent]))
        #expect(!AgentActivityPresentation.hasActiveWork(toolCalls: [completeTool], subagents: []))
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
