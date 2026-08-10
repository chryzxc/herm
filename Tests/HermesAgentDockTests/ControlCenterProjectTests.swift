import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct ControlCenterProjectTests {
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

    @Test func parsesKanbanJSONWithoutOwningTheRecords() {
        let tasks = ControlCenterModel.parseKanbanTasks("""
        [{"id":"k1","title":"Prepare launch","status":"ready","body":"Write the checklist","priority":"1","assignee":"operator"}]
        """)

        #expect(tasks.count == 1)
        #expect(tasks.first?.title == "Prepare launch")
        #expect(tasks.first?.status == "ready")
        #expect(tasks.first?.assignee == "operator")
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
        let slowProject = ProjectSummary(id: "slow", name: "Slow", repoCount: 0, sessionCount: 1, preview: nil, isActive: false)
        let fastProject = ProjectSummary(id: "fast", name: "Fast", repoCount: 0, sessionCount: 1, preview: nil, isActive: false)

        model.openProject(slowProject)
        model.openProject(fastProject)
        try await Task.sleep(for: .milliseconds(80))

        #expect(model.selectedProjectID == "fast")
        #expect(model.projectSessions.map(\.id) == ["fast-session"])

        model.openProject(slowProject)
        model.closeProject()
        try await Task.sleep(for: .milliseconds(80))

        #expect(model.selectedProjectID == nil)
        #expect(model.projectSessions.isEmpty)
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

    @Test func cronCreationRetainsFailureAndSendsTrimmedSuccessfulInput() async {
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
        #expect(succeedingClient.createdParams?["schedule"] as? String == "0 9 * * *")
        #expect(succeedingClient.createdParams?["prompt"] as? String == "Review")
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
