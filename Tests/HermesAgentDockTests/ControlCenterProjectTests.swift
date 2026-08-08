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

    @Test func kanbanChangeRequestsHaveStableActionIdentity() {
        let task = KanbanTaskSummary(id: "k1", title: "Task", status: "ready", detail: nil, priority: nil, assignee: nil)

        #expect(KanbanChangeRequest(task: task, action: .complete).id == "complete:k1")
        #expect(KanbanChangeRequest(task: task, action: .block).id == "block:k1")
    }
}
