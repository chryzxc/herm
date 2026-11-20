import Foundation
import Testing

@testable import Herm

struct SessionPlansTests {
    private func summary(_ path: String) -> PlanArtifactSummary {
        PlanArtifactSummary(
            relativePath: path, title: path, modifiedAt: nil, byteCount: 0, sha256: nil, state: .available)
    }

    @Test func keepsOnlyPlansTheChatNamed() {
        let plans = [summary("2026-11-15_101500-ship-it.md"), summary("2026-11-14_090000-other.md")]
        let texts = ["Saved the plan to .hermes/plans/2026-11-15_101500-ship-it.md"]
        #expect(SessionPlans.mentioned(plans, in: texts).map(\.relativePath) == ["2026-11-15_101500-ship-it.md"])
        #expect(SessionPlans.mentioned(plans, in: []).isEmpty)
    }

    /// The shape Hermes `/plan` writes: goals, file lists and steps, no checkboxes.
    @Test func planWithoutCheckboxesHasNoProgress() {
        let text = """
            # Add export

            ## Goal

            Let people export reports.

            ## Non-goals

            - Scheduling

            ## Files

            - Create: Sources/Export.swift
            - Test: Tests/ExportTests.swift

            ## Steps

            1. Add the exporter
            2. Wire the menu item
            3. Write tests
            """
        let plan = SessionPlans.plan(path: "/w/.hermes/plans/a.md", title: "a", modifiedAt: nil, text: text)
        #expect(plan.title == "Add export")
        #expect(plan.done == nil)
        #expect(plan.total == nil)
        #expect(plan.nextUp == nil)
    }

    @Test func progressChecklistCountsDoneAndNextUp() {
        let text = """
            # Add export

            ## Progress

            - [x] Add the exporter
            - [~] Wire the menu item
            - [ ] Write tests

            ## Steps

            1. Add the exporter
            2. Wire the menu item
            3. Write tests
            """
        let plan = SessionPlans.plan(path: "/w/.hermes/plans/a.md", title: "a", modifiedAt: nil, text: text)
        #expect(plan.done == 1)
        #expect(plan.total == 3)
        #expect(plan.nextUp == "Wire the menu item")
    }

    @Test func taskListCountsWhenThePlanStatesNothing() {
        let text = "# Add export\n## Steps\n1. Add the exporter\n2. Wire the menu item\n3. Write tests"
        let tasks = [
            TodoPlan.Item(content: "Add the exporter", status: "completed"),
            TodoPlan.Item(content: "Wire the menu item", status: "in_progress"),
            TodoPlan.Item(content: "Unrelated chore", status: "pending"),
        ]
        let plan = SessionPlans.plan(path: "/p.md", title: "p", modifiedAt: nil, text: text, tasks: tasks)
        #expect(plan.source == .taskList)
        #expect(plan.done == 1)
        #expect(plan.total == 2)
        #expect(plan.nextUp == "Wire the menu item")
        // A task list that names no step is not plan progress.
        let other = SessionPlans.plan(
            path: "/p.md", title: "p", modifiedAt: nil, text: text,
            tasks: [TodoPlan.Item(content: "Refactor logging", status: "completed")])
        #expect(other.total == nil)
        #expect(other.source == nil)
    }

    @Test func linkedFileThatIsGoneIsMissing() {
        let path = NSTemporaryDirectory() + "herm-missing-\(UUID().uuidString).md"
        let plans = SessionPlans.load(workspace: nil, texts: [], linked: [path], tasks: [])
        #expect(plans.count == 1)
        #expect(plans[0].isLinked && plans[0].isMissing)
        #expect(plans[0].total == nil)
    }

    @Test func trackProgressAsksForAMatchingTaskList() {
        let context = SessionPlans.trackProgressContext(path: "/w/.hermes/plans/a.md", title: "Add export")
        #expect(context.title == "Track progress · Add export")
        #expect(context.body.contains("/w/.hermes/plans/a.md"))
        #expect(context.body.contains("task list"))
    }
}
