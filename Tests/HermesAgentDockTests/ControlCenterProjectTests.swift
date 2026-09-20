import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct ControlCenterProjectTests {
    @Test func sessionLifecycleProjectionUsesTextualAccessibleStates() {
        #expect(SessionLifecyclePresentation.status(for: SessionSummary(id: "active", title: "Active", state: "running", preview: nil)) == .active)
        #expect(SessionLifecyclePresentation.status(for: SessionSummary(id: "done", title: "Done", state: "completed", preview: nil)) == .completed)
        #expect(SessionLifecyclePresentation.status(for: SessionSummary(id: "failed", title: "Failed", state: "error", preview: nil)) == .failed)
        #expect(SessionLifecyclePresentation.status(for: SessionSummary(id: "unknown", title: "Unknown", state: "mystery", preview: nil)) == .unavailable)
        #expect(SessionLifecycleStatus.allCases.map(\.label) == ["Active", "Completed", "Failed", "Stale", "Unavailable"])
    }

    @Test func sessionLifecycleProjectionKeepsLastSnapshotStaleOnRefreshFailure() {
        let session = SessionSummary(id: "session-a", title: "Session", state: "running", preview: nil)
        let refresh = ProjectionRefreshState(lastSuccess: Date(), error: "connection lost", isStale: true, isRefreshing: false)

        #expect(SessionLifecyclePresentation.status(for: session, refresh: refresh) == .stale)
        #expect(SessionLifecyclePresentation.detail(for: session, refresh: refresh) == "Stale")
    }

    @Test func projectSessionRefreshFailureIsUnavailableWithoutSnapshotAndStaleWithSnapshot() {
        let withoutSnapshot = ControlCenterModel()
        withoutSnapshot.recordProjectionFailure("projects.sessions", error: "connection lost")
        let session = SessionSummary(id: "session-a", title: "Session", state: "running", preview: nil)

        #expect(SessionLifecyclePresentation.status(for: session, refresh: withoutSnapshot.refreshState(for: "projects.sessions")) == .unavailable)

        let withSnapshot = ControlCenterModel()
        withSnapshot.recordProjectionSuccess("projects.sessions", count: 1)
        withSnapshot.recordProjectionFailure("projects.sessions", error: "connection lost")

        #expect(SessionLifecyclePresentation.status(for: session, refresh: withSnapshot.refreshState(for: "projects.sessions")) == .stale)
    }

    @Test func currentSessionRowKeepsIdentityAlongsideLifecycleStatus() {
        let session = SessionSummary(id: "session-a", title: "Session", state: "running", preview: nil)

        #expect(SessionLifecyclePresentation.rowLabel(for: session, isCurrent: true) == "Current · Active")
        #expect(SessionLifecyclePresentation.rowLabel(for: session, isCurrent: false) == "Active")
        #expect(SessionLifecyclePresentation.accessibilityLabel(for: session, isCurrent: true) == "Current · Active: Session")
    }

    @Test func sessionWithoutAnAttributionIDIsUnavailable() {
        let session = SessionSummary(id: "", title: "Unattributed", state: "running", preview: nil)

        #expect(SessionLifecyclePresentation.status(for: session) == .unavailable)
        #expect(SessionLifecyclePresentation.accessibilityLabel(for: session) == "Unavailable: Unattributed")
    }

    @Test func projectDisclosureToggleUpdatesCollapsedStateImmediately() {
        var state = ProjectDisclosureState()

        state.toggle(projectID: "project-a")

        #expect(state.isCollapsed(projectID: "project-a"))
        #expect(!state.isCollapsed(projectID: "project-b"))

        state.toggle(projectID: "project-a")

        #expect(!state.isCollapsed(projectID: "project-a"))
    }

    @Test func unchangedProjectRefreshPreservesNavigationOrder() {
        let first = ProjectSummary(id: "a", name: "A", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
        let second = ProjectSummary(id: "b", name: "B", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)

        let refreshed = ControlCenterModel.reconcileProjectRefresh(current: [first, second], incoming: [second, first])

        #expect(refreshed.map(\.id) == ["a", "b"])
    }

    @Test func initialProjectRefreshUsesDeterministicStableIDOrder() {
        let first = ProjectSummary(id: "b", name: "B", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
        let second = ProjectSummary(id: "a", name: "A", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)

        let refreshed = ControlCenterModel.reconcileProjectRefresh(current: [], incoming: [first, second])

        #expect(refreshed.map(\.id) == ["a", "b"])
    }

    @Test func projectMembershipChangesPreserveExistingOrderAndSortNewProjects() {
        let first = ProjectSummary(id: "a", name: "A", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
        let second = ProjectSummary(id: "b", name: "B", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
        let newFirst = ProjectSummary(id: "d", name: "D", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
        let newSecond = ProjectSummary(id: "c", name: "C", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)

        let refreshed = ControlCenterModel.reconcileProjectRefresh(
            current: [first, second],
            incoming: [newFirst, second, newSecond]
        )

        #expect(refreshed.map(\.id) == ["b", "c", "d"])
    }

    @Test func changedProjectRowsAcceptAuthoritativeReorder() {
        let first = ProjectSummary(id: "a", name: "A", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
        let second = ProjectSummary(id: "b", name: "B", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
        let changedFirst = ProjectSummary(id: "a", name: "A renamed", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)

        let refreshed = ControlCenterModel.reconcileProjectRefresh(current: [first, second], incoming: [second, changedFirst])

        #expect(refreshed.map(\.id) == ["b", "a"])
        #expect(refreshed.last?.name == "A renamed")
    @Test func createdProjectSelectionMatchesTheAuthoritativeProjectPath() {
        let projects = [
            ProjectSummary(id: "other", name: "/work/other", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false),
            ProjectSummary(id: "created", name: "/work/app", repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
        ]

        #expect(ControlCenterModel.projectMatchingPath("/work/app/", projects: projects)?.id == "created")
        #expect(ControlCenterModel.projectMatchingPath("/work/missing", projects: projects) == nil)
    }

    @Test func completedProjectRefreshPublishesAuthoritativeRowsForTheSelectedProject() {
        let createdSession = SessionSummary(id: "created-session", title: "New chat", state: "active", preview: nil)

        #expect(ControlCenterModel.projectSessionsAfterNavigationRefresh(
            projectID: "created-project",
            selectedProjectID: "created-project",
            refreshedSessions: [createdSession]
        ) == [createdSession])
        #expect(ControlCenterModel.projectSessionsAfterNavigationRefresh(
            projectID: "other-project",
            selectedProjectID: "created-project",
            refreshedSessions: []
        ) == nil)
    }

    @Test func clearingSelectedProfileDisablesProjectHydration() {
        let model = ControlCenterModel()

        model.setProjectProfile("bot-a")
        model.setProjectProfile(nil)

        #expect(model.projectProfileID == nil)
        #expect(model.projectProfileScopeUnavailable)
    }

    @Test func syntheticProjectBucketsAreNotRenderableProjects() {
        let projects = ControlCenterModel.parseProjects([
            "projects": [
                ["id": "tmp", "name": "TMP"],
                ["id": "P_A3A4F8A1", "name": "P_A3A4F8A1"],
                ["id": "repo-1", "name": "iboard-lokal"]
            ]
        ])

        #expect(projects.map(\.isRenderableProject) == [false, false, true])
    }

    @Test func projectCountsNestedSessionsWhenTheDeclaredCountIsStale() {
        let projects = ControlCenterModel.parseProjects([
            "projects": [[
                "id": "dock",
                "name": "hermes-agent-dock",
                "session_count": 0,
                "repos": [["sessions": [["id": "session-1", "state": "active"]]]]
            ]]
        ])

        #expect(projects.first?.sessionCount == 1)
        #expect(projects.first?.sessionIDs == Set(["session-1"]))
    }

    @Test func malformedSessionContextRemainsUnavailableAndUsesUniqueFallbackCategories() {
        let context = ControlCenterModel.parseSessionContext([
            "categories": [
                ["tokens": 10],
                ["tokens": 20]
            ]
        ])

        #expect(context.contextPercent == nil)
        #expect(context.categories.map(\.id) == ["category-0", "category-1"])
        #expect(context.categories.map(\.label) == ["Category 1", "Category 2"])
        #expect(SessionContextPressure.make(percent: context.contextPercent) == .unavailable)
    }

    @Test func checkpointsRequireAnEnabledBoundedPayload() {
        let checkpoints = ControlCenterModel.parseCheckpoints([
            "enabled": true,
            "checkpoints": [
                ["hash": "abc123", "timestamp": "2026-09-07T12:00:00Z", "message": "Before refactor"],
                ["timestamp": "2026-09-07T12:01:00Z"]
            ]
        ])

        #expect(checkpoints == [HermesCheckpointSummary(hash: "abc123", timestamp: "2026-09-07T12:00:00Z", message: "Before refactor")])
        #expect(ControlCenterModel.parseCheckpoints(["enabled": false, "checkpoints": [["hash": "abc"]]]).isEmpty)
        #expect(ControlCenterModel.parseCheckpoints(["enabled": true, "checkpoints": Array(repeating: ["hash": "abc"], count: 51)]).isEmpty)
    }

    @Test func parsesNestedProjectSessionsAndDeduplicatesRows() {
        let result: [String: Any] = [
            "project": [
                "repos": [
                    ["lanes": [
                        ["sessions": [
                            ["id": "one", "title": "First", "state": "active", "preview": "Investigate"],
                            ["id": "two", "name": "Second", "status": "idle"],
                            ["id": "one", "title": "First again", "state": "active"]
                        ]]
                    ]]
                ]
            ]
        ]

        let sessions = ControlCenterModel.parseProjectSessions(result)

        #expect(sessions.map(\.id) == ["one", "two"])
        #expect(sessions.first?.title == "First")
        #expect(sessions.last?.state == "idle")
    }

    @Test func sessionKanbanQueryDoesNotDependOnCapabilityProbe() {
        #expect(ControlCenterModel.shouldAttemptSessionKanbanQuery(
            sessionID: "session-a",
            hasCLI: true
        ))
        #expect(!ControlCenterModel.shouldAttemptSessionKanbanQuery(
            sessionID: nil,
            hasCLI: true
        ))
        #expect(!ControlCenterModel.shouldAttemptSessionKanbanQuery(
            sessionID: "session-a",
            hasCLI: false
        ))
    }

    @Test func globalKanbanFilterNeverRetainsSessionScope() {
        let scoped = KanbanListFilter(
            status: "running",
            assignee: "forge",
            mine: true,
            sessionID: "session-a",
            includeArchived: true,
            sort: "updated"
        )
        let global = ControlCenterModel.globalKanbanFilter(scoped)
        #expect(global.sessionID == nil)
        #expect(global.status == "running")
        #expect(global.assignee == "forge")
        #expect(global.mine)
        #expect(global.includeArchived)
        #expect(global.sort == "updated")
    }

    @Test func sessionKanbanRefreshCoalescesOnlyIdenticalInFlightQueries() {
        let active = SessionKanbanProjectionRequest(sessionID: "session-a", boardSlug: "default")

        #expect(ControlCenterModel.shouldCoalesceSessionKanbanRefresh(
            activeRequest: active,
            hasInFlightTask: true,
            requested: active
        ))
        #expect(!ControlCenterModel.shouldCoalesceSessionKanbanRefresh(
            activeRequest: active,
            hasInFlightTask: true,
            requested: SessionKanbanProjectionRequest(sessionID: "session-b", boardSlug: "default")
        ))
        #expect(!ControlCenterModel.shouldCoalesceSessionKanbanRefresh(
            activeRequest: active,
            hasInFlightTask: false,
            requested: active
        ))
    }

    @Test func sessionKanbanResultRemainsCurrentWhileGlobalBoardSelectionResolves() {
        // Session Activity owns a distinct projection. The global board picker
        // resolving from nil to a board must not discard that in-flight result.
        #expect(ControlCenterModel.isCurrentSessionKanbanResult(
            generationMatches: true,
            publishedSessionID: "session-a",
            requestedSessionID: "session-a",
            publishedBoardSlug: nil,
            requestedBoardSlug: nil
        ))
        #expect(!ControlCenterModel.isCurrentSessionKanbanResult(
            generationMatches: true,
            publishedSessionID: "session-b",
            requestedSessionID: "session-a",
            publishedBoardSlug: nil,
            requestedBoardSlug: nil
        ))
        #expect(!ControlCenterModel.isCurrentSessionKanbanResult(
            generationMatches: true,
            publishedSessionID: "session-a",
            requestedSessionID: "session-a",
            publishedBoardSlug: "default",
            requestedBoardSlug: nil
        ))
    }

    @Test func parsesDelegatedAgents() {
        let agents = ControlCenterModel.parseAgents([
            "active": [
                ["subagent_id": "agent-1", "role": "researcher", "status": "running", "session_id": "session-1"]
            ]
        ])

        #expect(agents.first?.id == "agent-1")
        #expect(agents.first?.name == "researcher")
        #expect(agents.first?.sessionID == "session-1")
    }

    @Test func excludesCompletedAgentsFromTheLiveDelegationProjection() {
        let agents = ControlCenterModel.parseAgents([
            "active": [
                ["subagent_id": "running", "status": "running"],
                ["subagent_id": "finished", "status": "completed"],
                ["subagent_id": "failed", "status": "failed"]
            ]
        ])

        #expect(agents.map(\.id) == ["running"])
    }

    @Test func searchesAcrossHydratedControlSources() {
        let results = ControlCenterModel.makeSearchResults(
            query: "launch",
            sessions: [SessionSummary(id: "s1", title: "Launch plan", state: "active", preview: "Prepare release")],
            attention: [],
            reminders: [ReminderSummary(id: "r1", title: "Launch checklist", list: "Work", dueDate: nil, isOverdue: false)],
            projects: []
        )

        #expect(results.count == 2)
        #expect(results.map(\.reference.source).contains(.hermesSession))
        #expect(results.map(\.reference.source).contains(.appleReminder))
    }

    @Test func sessionKanbanProjectionPublishesOnlyExactSessionAttribution() {
        let parsed = ControlCenterModel.parseKanbanTasks("""
        [
          {"id":"current","title":"Current task","session_id":"session-a"},
          {"id":"other","title":"Other task","session_id":"session-b"},
          {"id":"unscoped","title":"Unscoped task"}
        ]
        """)

        let scoped = ControlCenterModel.filterSessionKanbanTasks(parsed, sessionID: "session-a")

        #expect(scoped.map(\.id) == ["current"])
    }

    @Test func parsesKanbanJSONWithoutOwningTheRecords() {
        let tasks = ControlCenterModel.parseKanbanTasks("""
        [{"id":"k1","title":"Prepare launch","status":"ready","body":"Write the checklist","priority":"1","assignee":"operator"}]
        """)

        #expect(tasks.count == 1)
        #expect(tasks.first?.title == "Prepare launch")
        #expect(tasks.first?.status == "ready")
        #expect(tasks.first?.assignee == "operator")
    }

    @Test func kanbanTaskParserPreservesAggregateBoardOwnership() {
        let tasks = ControlCenterModel.parseKanbanTasks(
            "[{\"id\":\"k1\",\"title\":\"Cross-board task\",\"status\":\"ready\",\"board_slug\":\"client-board\"}]"
        )

        #expect(tasks.first?.boardSlug == "client-board")
    }

    @Test func presentsConfiguredBotModelAndProviderForKanbanAssignee() {
        let bot = BotSummary(id: "forge", name: "Forge", title: nil, description: nil, model: "gpt-5", provider: "openai", isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)

        let metadata = KanbanModelMetadataPresentation.make(taskModel: nil, taskProvider: nil, bot: bot)

        #expect(metadata.label == "openai / gpt-5")
        #expect(!metadata.isOverride)
    }

    @Test func marksKanbanCardModelOverrideDistinctFromBotConfiguration() {
        let bot = BotSummary(id: "forge", name: "Forge", title: nil, description: nil, model: "gpt-5", provider: "openai", isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)

        let metadata = KanbanModelMetadataPresentation.make(taskModel: "claude-sonnet", taskProvider: "anthropic", bot: bot)

        #expect(metadata.label == "anthropic / claude-sonnet")
        #expect(metadata.isOverride)
    }

    @Test func reportsMissingKanbanModelHonestly() {
        let metadata = KanbanModelMetadataPresentation.make(taskModel: nil, taskProvider: nil, bot: nil)

        #expect(metadata.label == "Model unavailable")
        #expect(!metadata.isOverride)
    }

    @Test func normalizesEmptyKanbanModelMetadata() {
        let bot = BotSummary(id: "forge", name: "Forge", title: nil, description: nil, model: "  gpt-5  ", provider: " \n", isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)

        let metadata = KanbanModelMetadataPresentation.make(taskModel: " \t", taskProvider: " ", bot: bot)

        #expect(metadata.label == "gpt-5")
        #expect(!metadata.isOverride)
    }

    @Test func resolvesKanbanMetadataFromHiddenAssignedBot() {
        let bot = BotSummary(id: "forge", name: "Forge", title: nil, description: nil, model: "gpt-5", provider: "openai", isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: true, hasAvatar: false, isDefault: false)

        let resolved = KanbanModelMetadataPresentation.bot(for: "FORGE", in: [bot])

        #expect(resolved == bot)
        #expect(KanbanModelMetadataPresentation.make(taskModel: nil, taskProvider: nil, bot: resolved).label == "openai / gpt-5")
    }

    @Test func parsesKanbanModelOverrideMetadata() {
        let task = ControlCenterModel.parseKanbanTasks("""
        [{"id":"k-model","title":"Use alternate model","status":"ready","assignee":"forge","model_override":"claude-sonnet","provider_override":"anthropic"}]
        """).first

        #expect(task?.modelOverride == "claude-sonnet")
        #expect(task?.providerOverride == "anthropic")
    }

    @Test func strictKanbanParserDistinguishesEmptyBoardFromMalformedOutput() {
        let empty = ControlCenterModel.parseKanbanTasksStrict("[]", boardSlug: "default")
        #expect(empty != nil)
        #expect(empty?.isEmpty == true)
        #expect(ControlCenterModel.parseKanbanTasksStrict("{}", boardSlug: "default") == nil)
        #expect(ControlCenterModel.parseKanbanTasksStrict("not-json", boardSlug: "default") == nil)
        let wrapped = ControlCenterModel.parseKanbanTasksStrict("{\"tasks\":[{\"id\":\"wrapped\",\"title\":\"Wrapped task\",\"status\":\"running\"}]}", boardSlug: "default")
        #expect(wrapped?.map(\.id) == ["wrapped"])
    }

    @Test func parsesKanbanBoardInventoryWithoutLeakingDatabasePaths() {
        let boards = ControlCenterModel.parseKanbanBoards("""
        [{"slug":"default","name":"Default","description":"","is_current":true,"archived":false,"db_path":"/private/hermes.db","counts":{"ready":1},"total":1}]
        """)

        #expect(boards == [KanbanBoardSummary(slug: "default", name: "Default", description: nil, isCurrent: true, archived: false, total: 1, counts: ["ready": 1])])
        #expect(!String(describing: boards).contains("hermes.db"))
    }

    @Test func parsesInstalledHermesNumericPriorityAndByStatusStats() {
        let tasks = ControlCenterModel.parseKanbanTasks("""
        [{"id":"t_b6f0fce2","title":"test","status":"ready","priority":0,"assignee":null}]
        """)
        let stats = ControlCenterModel.parseKanbanStats("""
        {"by_status":{"ready":1},"by_assignee":{},"oldest_ready_age_seconds":12}
        """)

        #expect(tasks.first?.priority == "0")
        #expect(stats?.counts == ["ready": 1])
    }

    @Test func parsesKanbanTaskDetailAndRunsFromJSON() {
        let fallback = KanbanTaskSummary(id: "k1", title: "Fallback", status: "todo", detail: nil, priority: nil, assignee: nil)
        let detail = ControlCenterModel.parseKanbanTaskDetail("""
        {"id":"k1","title":"Implement detail","body":"Inspect the run history","status":"review","priority":"high","assignee":"worker"}
        """, fallback: fallback)
        let runs = ControlCenterModel.parseKanbanRuns("""
        [{"id":"r1","status":"complete","outcome":"success","profile":"worker","summary":"Done","elapsed":"4s"}]
        """)

        #expect(detail?.title == "Implement detail")
        #expect(detail?.status == "review")
        #expect(runs.first?.outcome == "success")
        #expect(runs.first?.elapsed == "4s")
    }

    @Test func preservesShownKanbanModelOverrideWhenRunsEnrichTheDetail() {
        let fallback = KanbanTaskSummary(id: "k-model", title: "Fallback", status: "todo", detail: nil, priority: nil, assignee: nil)
        let detail = ControlCenterModel.parseKanbanTaskDetail("""
        {"id":"k-model","title":"Use alternate model","status":"running","assignee":"forge","model_override":"claude-sonnet","provider_override":"anthropic"}
        """, fallback: fallback)
        let runs = ControlCenterModel.parseKanbanRuns("[]")

        let enriched = ControlCenterModel.enrichedKanbanTaskDetail(detail, runs: runs, boardSlug: "default")

        #expect(enriched?.modelOverride == "claude-sonnet")
        #expect(enriched?.providerOverride == "anthropic")
        #expect(enriched?.runs.isEmpty == true)
    }

    @Test func parsesWrappedKanbanTaskDetailResponses() {
        let fallback = KanbanTaskSummary(id: "k1", title: "Fallback", status: "todo", detail: nil, priority: nil, assignee: nil)
        let detail = ControlCenterModel.parseKanbanTaskDetail(
            "{\"result\":[{\"id\":\"k1\",\"title\":\"Wrapped detail\",\"status\":\"blocked\"}]}",
            fallback: fallback
        )

        #expect(detail?.title == "Wrapped detail")
        #expect(detail?.status == "blocked")
    }

    @Test func fallsBackToKanbanSummaryWhenDetailsAreNotStructured() {
        let task = KanbanTaskSummary(
            id: "k1",
            boardSlug: "default",
            title: "Summary task",
            status: "blocked",
            detail: "Waiting on a dependency",
            priority: "1",
            assignee: "forge"
        )
        let detail = ControlCenterModel.fallbackKanbanTaskDetail(task)

        #expect(detail.title == "Summary task")
        #expect(detail.body == "Waiting on a dependency")
        #expect(detail.status == "blocked")
        #expect(detail.assignee == "forge")
    }

    @Test func parsesShownKanbanTaskAndCanAttributeExactObservedTaskToSession() {
        let task = ControlCenterModel.parseKanbanTaskSummary("""
        {"task":{"id":"t_33604ca9","title":"Correct communications authorization review findings","status":"running","assignee":"forge","started_at":1789015230,"current_step_key":"review"},"events":[{"kind":"heartbeat","created_at":1789015231,"payload":{"note":"still working"}}]}
        """, boardSlug: "default", sessionID: "session-a")

        #expect(task?.id == "t_33604ca9")
        #expect(task?.status == "running")
        #expect(task?.sessionID == "session-a")
        #expect(task?.currentStepKey == "review")
        #expect(task?.latestEventKind == "heartbeat")
        #expect(task?.latestEventNote == "still working")
    }

    @Test func parsesKanbanDiagnosticsAndUsesStableFallbackIDs() {
        let diagnostics = ControlCenterModel.parseKanbanDiagnostics("""
        [{"severity":"error","title":"Missing owner","message":"Assign the task","task_id":"k1"},{"severity":"warning","title":"Old task"}]
        """, boardSlug: "board-1")

        #expect(diagnostics.count == 2)
        #expect(diagnostics.first?.taskID == "k1")
        #expect(diagnostics.first?.id == "board-1:k1:error:Missing owner:0")
        #expect(diagnostics.last?.id == "board-1:all:warning:Old task:1")
    }

    @Test func parsesKanbanAttachmentsAndUsesStableFallbackIDs() {
        let attachments = ControlCenterModel.parseKanbanAttachments([
            "attachments": [
                ["filename": "plan.md", "mime_type": "text/markdown", "size_bytes": 128]
            ]
        ], boardSlug: "board-1", taskID: "k1")

        #expect(attachments.first?.id == "board-1:k1:plan.md:0")
        #expect(attachments.first?.sizeBytes == 128)
    }

    @Test func parsesHermesProjectFactsAndVerificationScope() {
        let facts = ControlCenterModel.parseProjectFacts([
            "facts": [
                "root": "/work/app",
                "manifests": ["Package.swift"],
                "packageManagers": ["swift"],
                "verifyCommands": ["swift test"],
                "contextFiles": ["DESIGN.md"]
            ]
        ])
        let verification = ControlCenterModel.parseVerification([
            "verification": [
                "status": "passed",
                "evidence": ["canonical_command": "swift test", "scope": "targeted", "exit_code": 0]
            ]
        ])

        #expect(facts?.verifyCommands == ["swift test"])
        #expect(facts?.contextFiles == ["DESIGN.md"])
        #expect(verification.state == .passed)
        #expect(verification.evidence?.scope == "targeted")
    }

    @Test func parsesOptionalQualityGateMetadataWithoutInferringMalformedValues() {
        let verification = ControlCenterModel.parseVerification([
            "verification": [
                "status": "passed",
                "evidence": [
                    "adapter": "swiftpm",
                    "captured_at": "2026-08-24T12:00:00Z",
                    "repository_identity": "repo-1",
                    "commit_fingerprint": "abc123",
                    "target_fingerprint": "target-1",
                    "diff_fingerprint": "diff-1",
                    "rules_scope_detail": "Package.swift tests",
                    "stale_reason": "superseded by commit",
                    "exit_code": "not-an-int",
                    "capturedAt": 42
                ]
            ]
        ])

        #expect(verification.evidence?.adapter == "swiftpm")
        #expect(verification.evidence?.capturedAt == ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z"))
        #expect(verification.evidence?.repositoryIdentity == "repo-1")
        #expect(verification.evidence?.commitFingerprint == "abc123")
        #expect(verification.evidence?.targetFingerprint == "target-1")
        #expect(verification.evidence?.diffFingerprint == "diff-1")
        #expect(verification.evidence?.rulesScopeDetail == "Package.swift tests")
        #expect(verification.evidence?.staleReason == "superseded by commit")
        #expect(verification.evidence?.exitCode == nil)
    }

    @Test func boundsAndRedactsVerificationEvidenceMetadataAtTheEvidenceBoundary() {
        let verification = ControlCenterModel.parseVerification([
            "verification": [
                "status": "passed",
                "evidence": [
                    "adapter": String(repeating: "adapter-", count: 40),
                    "repository_identity": "/Users/christian/private/repo",
                    "commit_fingerprint": String(repeating: "a", count: 161),
                    "target_fingerprint": "target-1",
                    "diff_fingerprint": "diff-1",
                    "rules_scope_detail": "  Package.swift tests  ",
                    "stale_reason": "\u{0000}invalid"
                ]
            ]
        ])

        #expect(verification.evidence?.adapter == nil)
        #expect(verification.evidence?.repositoryIdentity == "••••/private/repo")
        #expect(verification.evidence?.commitFingerprint == nil)
        #expect(verification.evidence?.targetFingerprint == "target-1")
        #expect(verification.evidence?.diffFingerprint == "diff-1")
        #expect(verification.evidence?.rulesScopeDetail == "Package.swift tests")
        #expect(verification.evidence?.staleReason == nil)
    }

    @Test func preservesInvalidStaleReasonAsAnUnrenderedStaleSignal() {
        let verification = ControlCenterModel.parseVerification([
            "verification": [
                "status": "passed",
                "evidence": [
                    "scope": "repository",
                    "exit_code": 0,
                    "stale_reason": "\u{0000}do not expose"
                ]
            ]
        ])

        #expect(verification.evidence?.staleReason == nil)
        #expect(verification.evidence?.hasInvalidStaleReason == true)
        #expect(!String(describing: verification).contains("do not expose"))
    }

    @Test func preservesNonStringStaleReasonAsAnUnrenderedStaleSignal() {
        let verification = ControlCenterModel.parseVerification([
            "verification": [
                "status": "passed",
                "evidence": [
                    "scope": "repository",
                    "exit_code": 0,
                    "stale_reason": ["unsafe": true]
                ]
            ]
        ])

        #expect(verification.evidence?.staleReason == nil)
        #expect(verification.evidence?.hasInvalidStaleReason == true)
        #expect(!String(describing: verification).contains("unsafe"))
    }

    @Test func verificationEvidenceInitializersRemainBackwardCompatible() {
        let evidence = VerificationEvidenceSummary(command: "swift test", canonicalCommand: nil, kind: "test", scope: "targeted", status: "passed", exitCode: 0, outputSummary: "ok")
        #expect(evidence.adapter == nil)
        #expect(evidence.capturedAt == nil)
    }

    @Test func kanbanChangeRequestsHaveStableActionIdentity() {
        let task = KanbanTaskSummary(id: "k1", title: "Task", status: "ready", detail: nil, priority: nil, assignee: nil)

        #expect(KanbanChangeRequest(task: task, action: .complete).id == "complete:k1")
        #expect(KanbanChangeRequest(task: task, action: .block).id == "block:k1")
    }

    @Test func parsesCronRunHistoryAndAttachedErrors() {
        let runs = ControlCenterModel.parseCronRuns("""
        run-1  success   job=morning  source=cron  2026-08-08T08:00:00Z
            timed out after 30s
        """)

        #expect(runs.count == 1)
        #expect(runs.first?.jobID == "morning")
        #expect(runs.first?.error == "timed out after 30s")
        #expect(runs.first?.sessionID == "cron_morning_20260808_080000")
    }

    @Test func parsesCanonicalCronJobIDUsedByHermesRunSessions() {
        let jobs = ControlCenterModel.parseCronJobs([
            "jobs": [[
                "job_id": "f817f2069f9c",
                "name": "iboard-lokal repo activity",
                "schedule": "0 10 * * *",
                "next_run_at": "2026-08-11T10:00:00+08:00",
                "enabled": true
            ]]
        ])

        #expect(jobs.first?.id == "f817f2069f9c")
        #expect(jobs.first?.name == "iboard-lokal repo activity")
        #expect(jobs.first?.nextRun == "2026-08-11T10:00:00+08:00")
    }

    @Test func attachesLatestCronRunSessionWithoutUsingAnotherJobsPrefix() {
        let jobs = [
            CronSummary(id: "job-1", name: "Daily report", schedule: "0 9 * * *", enabled: true, nextRun: nil),
            CronSummary(id: "job-10", name: "Weekly report", schedule: "0 9 * * 1", enabled: true, nextRun: nil)
        ]
        let result: [String: Any] = [
            "sessions": [
                ["id": "cron_job-10_2026-08-10T09:00:00", "source": "cron"],
                ["id": "cron_job-1_2026-08-10T09:00:00", "source": "cron"],
                ["id": "cron_job-1_2026-08-09T09:00:00", "source": "cron"],
                ["id": "cron_job-1_ignored", "source": "cli"]
            ]
        ]

        let attached = ControlCenterModel.attachLatestCronSessions(to: jobs, from: result)

        #expect(attached[0].sessionID == "cron_job-1_2026-08-10T09:00:00")
        #expect(attached[1].sessionID == "cron_job-10_2026-08-10T09:00:00")
    }

    @Test func parsesFinalAssistantMessageAsCronReport() {
        let job = CronSummary(id: "job-1", name: "Daily report", schedule: "0 9 * * *", enabled: true, nextRun: nil)
        let result: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Generate the report"],
                ["role": "assistant", "content": "Earlier progress"],
                ["role": "tool", "content": "internal output"],
                ["role": "assistant", "content": [["type": "text", "text": "# Final report\n\nEverything passed."]]]
            ]
        ]

        let report = ControlCenterModel.parseCronReport(result, job: job, sessionID: "cron_job-1_latest")

        #expect(report?.title == "Daily report")
        #expect(report?.markdown == "# Final report\n\nEverything passed.")
    }

    @Test func parsesMCPInventoryWithoutLeakingStatusFormatting() {
        let servers = ControlCenterModel.parseMCPServers("""
          MCP Servers:
          Name             Transport                      Tools        Status
          ───────────────────────────────────────────────────────────────────
          github           https://api.example.test/mcp   all          ✓ enabled
          local            npx @example/server            2 selected   ✗ disabled
        """)

        #expect(servers.count == 2)
        #expect(servers.first?.name == "github")
        #expect(servers.first?.transport == "https://api.example.test/mcp")
        #expect(servers.first?.isEnabled == true)
        #expect(servers.last?.tools == "2 selected")
        #expect(servers.last?.isEnabled == false)
    }

    @Test func currentFocusFeedsTodaySnapshot() {
        let model = ControlCenterModel()
        model.focus(sessionID: "session-1")

        #expect(model.todaySnapshot.currentFocus?.source == .hermesSession)
        #expect(model.todaySnapshot.currentFocus?.sessionID == "session-1")
    }

    @Test func restoringSessionAfterFocusClearStartsANewSessionKanbanQuery() async throws {
        let client = DelayedSessionKanbanClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))

        model.focus(sessionID: "session-a")
        for _ in 0..<100 where client.kanbanListCalls == 0 {
            await Task.yield()
        }
        #expect(client.kanbanListCalls == 1)

        model.focus(sessionID: nil)
        model.focus(sessionID: "session-a")
        for _ in 0..<100 where client.kanbanListCalls < 2 {
            await Task.yield()
        }

        #expect(client.kanbanListCalls == 2)
        model.focus(sessionID: nil)
    }

    @Test func boardInventoryResolutionNeverRestartsTheSessionKanbanProjection() {
        let initialResolution = ControlCenterModel.boardInventoryRefreshPlan(
            previousSelection: nil,
            resolvedSelection: "default"
        )
        #expect(initialResolution.refreshBoard)
        #expect(!initialResolution.refreshSession)

        let unchangedResolution = ControlCenterModel.boardInventoryRefreshPlan(
            previousSelection: "default",
            resolvedSelection: "default"
        )
        #expect(!unchangedResolution.refreshBoard)
        #expect(!unchangedResolution.refreshSession)
    }

    @Test func repositoryProjectionFeedsTodaySnapshotWithoutOwningSelection() {
        let model = ControlCenterModel()
        let repository = RepositorySnapshot(path: "/work/app", branch: "main", changedFiles: 2, latestCommit: "abc update", isGitRepository: true)

        model.setDevelopmentContextProjection(repository)

        #expect(model.todaySnapshot.developmentContext == repository)

        model.focus(sessionID: "another-session")

        #expect(model.todaySnapshot.developmentContext == nil)
    }

    @Test func latestProjectSelectionOwnsTheSessionProjection() async throws {
        let client = ProjectSessionRaceClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let slowProject = ProjectSummary(id: "slow", name: "Slow", repoCount: 0, sessionCount: 1, sessionIDs: [], preview: nil, isActive: false)
        let fastProject = ProjectSummary(id: "fast", name: "Fast", repoCount: 0, sessionCount: 1, sessionIDs: [], preview: nil, isActive: false)

        model.openProject(slowProject)
        model.openProject(fastProject)
        try await Task.sleep(for: .milliseconds(80))

        #expect(model.selectedProjectID == "fast")
        #expect(model.selectedProject?.id == "fast")
        #expect(model.projectSessions.map(\.id) == ["fast-session"])

        model.openProject(slowProject)
        model.closeProject()
        try await Task.sleep(for: .milliseconds(80))

        #expect(model.selectedProjectID == nil)
        #expect(model.selectedProject == nil)
        #expect(model.projectSessions.isEmpty)
    }

    @Test func projectSessionRefreshStateDoesNotLeakAcrossProjects() async throws {
        let client = ProjectSessionIsolationClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let projectA = ProjectSummary(id: "project-a", name: "A", repoCount: 0, sessionCount: 1, sessionIDs: [], preview: nil, isActive: false)
        let projectB = ProjectSummary(id: "project-b", name: "B", repoCount: 0, sessionCount: 1, sessionIDs: [], preview: nil, isActive: false)

        model.openProject(projectA)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.refreshState(for: model.projectSessionsProjectionKey(for: projectA.id))?.lastSuccess != nil)
        #expect(model.projectSessions.map(\.id) == ["project-a-session"])

        client.failingProjectID = projectA.id
        model.openProject(projectA)
        try await Task.sleep(for: .milliseconds(50))
        let projectARefresh = model.refreshState(for: model.projectSessionsProjectionKey(for: projectA.id))
        #expect(client.requestedProjectIDs == [projectA.id, projectA.id])
        #expect(model.projectSessions.map(\.id) == ["project-a-session"])
        #expect(model.projectionState(for: model.projectSessionsProjectionKey(for: projectA.id)) == .stale(1, safeMessage: "Hermes projection is unavailable. Refresh to try again."))
        #expect(SessionLifecyclePresentation.status(for: model.projectSessions[0], refresh: projectARefresh) == .stale)

        client.failingProjectID = projectB.id
        model.openProject(projectB)
        try await Task.sleep(for: .milliseconds(50))

        let projectBRefresh = model.refreshState(for: model.projectSessionsProjectionKey(for: projectB.id))
        let projectBKey = model.projectSessionsProjectionKey(for: projectB.id)
        #expect(client.requestedProjectIDs == [projectA.id, projectA.id, projectB.id])
        #expect(model.refreshState(for: model.projectSessionsProjectionKey(for: projectA.id))?.isStale == true)
        #expect(projectBRefresh?.isStale == false)
        #expect(projectBRefresh?.error != nil)
        #expect(model.selectedProjectID == projectB.id)
        #expect(model.projectSessions.isEmpty)
        #expect(model.projectionState(for: projectBKey) == .failed(safeMessage: "Hermes projection is unavailable. Refresh to try again."))
        #expect(SessionLifecyclePresentation.status(for: SessionSummary(id: "project-b-session", title: "B", state: "active", preview: nil), refresh: projectBRefresh) == .unavailable)
    }

    @Test func verifiedSessionProjectSurvivesCompactProjectRefresh() async throws {
        let client = SessionProjectMembershipClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))

        model.focus(sessionID: "session-1")
        model.refresh()
        for _ in 0..<100_000 {
            if model.project(forSessionID: "session-1")?.name == "/work/iboard-lokal" {
                break
            }
            await Task.yield()
        }

        #expect(model.project(forSessionID: "session-1")?.name == "/work/iboard-lokal")

        client.returnCompactTree = true
        model.refresh()
        for _ in 0..<100_000 {
            if model.project(forSessionID: "session-1")?.name == "/work/iboard-lokal" {
                break
            }
            await Task.yield()
        }

        // A compact tree omits session rows; it is not evidence that an
        // already verified Hermes membership was removed.
        #expect(model.project(forSessionID: "session-1")?.name == "/work/iboard-lokal")
    }

    @Test func parsesHermesAssigneesAndJourneyNodes() {
        let assignees = ControlCenterModel.parseKanbanAssignees("""
        [{"name":"default"},{"profile":"worker"},{"name":"default"}]
        """)
        let journey = ControlCenterModel.parseJourneyNodes("""
        {"nodes":[{"id":"skill-1","label":"Planning","kind":"skill","category":"development","state":"active","useCount":3}]}
        """)

        #expect(assignees == ["default", "worker"])
        #expect(journey == [HermesJourneyNode(id: "skill-1", label: "Planning", kind: "skill", category: "development", state: "active", useCount: 3)])
    }

    @Test func cronCreationRetainsFailureAndPreservesHermesScheduleInput() async {
        let capability = CapabilityState(id: "rpc-scheduling", title: "Cron", detail: "Available", isAvailable: true, recovery: nil)
        let failingClient = CronCreationClient(shouldFail: true)
        let failingModel = ControlCenterModel(rpc: HermesControlRPC(client: failingClient), capabilities: [capability])

        #expect(await failingModel.createCron(name: " Morning", schedule: "0 9 * * *", prompt: "Review") == false)
        #expect(!failingModel.isActionPending("cron.create"))
        #expect(failingModel.lastError != nil)

        let succeedingClient = CronCreationClient(shouldFail: false)
        let succeedingModel = ControlCenterModel(rpc: HermesControlRPC(client: succeedingClient), capabilities: [capability])

        #expect(await succeedingModel.createCron(name: " Morning ", schedule: " 0 9 * * * ", prompt: " Review "))
        #expect(succeedingClient.createdParams?["name"] as? String == "Morning")
        #expect(succeedingClient.createdParams?["schedule"] as? String == " 0 9 * * * ")
        #expect(succeedingClient.createdParams?["prompt"] as? String == "Review")
    }

    @Test func cronCreationDelegatesScheduleGrammarToHermes() async {
        let capability = CapabilityState(id: "rpc-scheduling", title: "Cron", detail: "Available", isAvailable: true, recovery: nil)
        let client = CronCreationClient(shouldFail: false)
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client), capabilities: [capability])

        #expect(await model.createCron(name: "Bad", schedule: "not a schedule", prompt: "Review"))
        #expect(client.createdParams?["schedule"] as? String == "not a schedule")
        #expect(model.lastError == nil)
    }

    @Test func killProcessRequiresActivityCapabilityAndNeverCallsRPC() async {
        let client = ProcessControlClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))

        let process = ProcessSummary(id: "p-1", name: "node", state: "running", detail: nil)
        #expect(await model.killProcess(process) == false)
        #expect(client.killCallCount == 0)
        #expect(model.lastError?.contains("unavailable") == true)
    }

    @Test func projectionRefreshPreservesLastSuccessAfterTransientFailure() async throws {
        let client = ProjectionRefreshClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))

        model.refresh()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.refreshState(for: "projects")?.isStale == false)
        #expect(model.refreshState(for: "projects")?.lastSuccess != nil)

        client.failProjects = true
        model.refresh()
        try await Task.sleep(for: .milliseconds(50))

        #expect(model.refreshState(for: "projects")?.isStale == true)
        #expect(model.refreshState(for: "projects")?.isRefreshing == false)
    }
}

@MainActor
private final class ProjectSessionRaceClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "projects.project_sessions",
              let projectID = params["project_id"] as? String else { return [:] }
        if projectID == "slow" {
            try await Task.sleep(for: .milliseconds(40))
        }
        return ["sessions": [["id": "\(projectID)-session", "title": projectID, "state": "active"]]]
    }
}

@MainActor
private final class ProjectSessionIsolationClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var failingProjectID: String?
    private(set) var requestedProjectIDs: [String] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "projects.project_sessions",
              let projectID = params["project_id"] as? String else { return [:] }
        requestedProjectIDs.append(projectID)
        if projectID == failingProjectID {
            throw NSError(domain: "ProjectSessionIsolationClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "project session refresh failed"])
        }
        return ["sessions": [["id": "\(projectID)-session", "title": projectID, "state": "active"]]]
    }
}

@MainActor
private final class DelayedSessionKanbanClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var kanbanListCalls = 0

    func connect() async throws {}
    func close() {}

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path == "/api/plugins/kanban/boards" {
            return ["boards": [["slug": "default", "name": "Default", "is_current": true, "archived": false]]]
        }
        if path == "/api/plugins/kanban/board?board=default" {
            kanbanListCalls += 1
            try await Task.sleep(for: .seconds(10))
            return ["columns": []]
        }
        return [:]
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == HermesFeatureIDs.ID.shellExec.rawValue,
           let command = params["command"] as? String {
            if command.contains("'kanban' 'boards' 'list'") {
                return ["code": 0, "stdout": "[{\"slug\":\"default\",\"name\":\"Default\",\"is_current\":true,\"archived\":false}]"]
            }
            if command.contains("'kanban' 'list'") && command.contains("'--session'") {
                kanbanListCalls += 1
                try await Task.sleep(for: .seconds(10))
                return ["code": 0, "stdout": "[]"]
            }
        }
        return ["code": 0, "stdout": "[]"]
    }
}

@MainActor
private final class SessionProjectMembershipClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var returnCompactTree = false

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "projects.tree":
            if returnCompactTree {
                return ["projects": [["id": "iboard", "name": "/work/iboard-lokal", "session_count": 1]]]
            }
            return ["projects": [["id": "iboard", "name": "/work/iboard-lokal", "session_count": 1]]]
        case "projects.project_sessions":
            return ["sessions": [["id": "session-1", "title": "Fix issues", "state": "active"]]]
        case "shell.exec":
            return ["code": 0, "stdout": ""]
        default:
            return [:]
        }
    }
}

@MainActor
private final class CronCreationClient: HermesRPCClientProtocol {
    enum Failure: Error { case rejected }

    var onEvent: ((String, [String: Any]) -> Void)?
    let shouldFail: Bool
    private(set) var createdParams: [String: Any]?

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "cron.manage", params["action"] as? String == "add" {
            createdParams = params
            if shouldFail { throw Failure.rejected }
        }
        return [:]
    }
}

@MainActor
private final class ProcessControlClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var killCallCount = 0

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "process.kill" { killCallCount += 1 }
        return [:]
    }
}

@MainActor
private final class ProjectionRefreshClient: HermesRPCClientProtocol {
    enum Failure: Error { case projects }

    var onEvent: ((String, [String: Any]) -> Void)?
    var failProjects = false

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "projects.tree", failProjects { throw Failure.projects }
        if method == "shell.exec" { return ["code": 0, "stdout": ""] }
        return [:]
    }
}
