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

    @Test func repeatedPollsFindNewFilesAndRefreshEditedOrRemovedPlans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".hermes/plans")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = directory.appendingPathComponent("café.md")
        let later = directory.appendingPathComponent("later.md")
        let other = directory.appendingPathComponent("cafe.md")
        try "# Initial\n## Steps\n1. Build exporter".write(to: initial, atomically: true, encoding: .utf8)
        try "# Other".write(to: other, atomically: true, encoding: .utf8)
        var loader = SessionPlans.Loader()
        let first = loader.load(
            workspace: root.path, newTexts: ["See cafe\u{301}.md and later.md, not CAFE.md"], linked: [], tasks: [])
        #expect(first.map(\.title) == ["Initial"])

        try "# Later".write(to: later, atomically: true, encoding: .utf8)
        let second = loader.load(
            workspace: root.path, newTexts: nil, linked: [],
            tasks: [.init(content: "Build exporter", status: "completed")])
        #expect(Set(second.map(\.title)) == ["Initial", "Later"])
        #expect(second.first { $0.title == "Initial" }?.done == 1)

        try "# New one\n## Steps\n1. Build exporter".write(to: initial, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: later)
        let third = loader.load(workspace: root.path, newTexts: nil, linked: [later.path], tasks: [])
        #expect(third.map(\.title) == ["New one", "later"])
        #expect(third.last?.isMissing == true)
        let reset = loader.load(workspace: root.path, newTexts: ["Open cafe.md"], linked: [], tasks: [])
        #expect(reset.map(\.title) == ["Other"])
    }

    @Test func cachedPlanCannotFollowAReplacementSymlinkOutOfThePlansFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".hermes/plans")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("plan.md")
        let outside = root.appendingPathComponent("outside.md")
        try "# Plan".write(to: file, atomically: true, encoding: .utf8)
        try "# Outside".write(to: outside, atomically: true, encoding: .utf8)
        var loader = SessionPlans.Loader()
        #expect(loader.load(workspace: root.path, newTexts: ["See plan.md"], linked: [], tasks: []).count == 1)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(loader.load(workspace: root.path, newTexts: nil, linked: [], tasks: []).isEmpty)
    }

    @Test func previewAndRailRefreshTheSameAtomicReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("linked.md")
        let cache = PlanFileCache.shared
        try "# Plan\n## Work\n- [ ] Build".write(to: file, atomically: true, encoding: .utf8)
        let first = try #require(cache.preview(at: file, markdown: true, after: nil))
        #expect(first.map?.progress?.done == 0)
        #expect(cache.preview(at: file, markdown: true, after: first.revision) == nil)
        #expect(SessionPlans.load(workspace: nil, texts: [], linked: [file.path], tasks: []).first?.done == 0)

        try "# Plan\n## Work\n- [x] Build".write(to: file, atomically: true, encoding: .utf8)
        let originalDate = try #require(first.revision?.modifiedAt)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        #expect(SessionPlans.load(workspace: nil, texts: [], linked: [file.path], tasks: []).first?.done == 1)
        let replacement = try #require(cache.preview(at: file, markdown: true, after: first.revision))
        #expect(replacement.map?.progress?.done == 1)

        try FileManager.default.removeItem(at: file)
        #expect(cache.preview(at: file, markdown: true, after: replacement.revision)?.content == .missing)
        #expect(SessionPlans.load(workspace: nil, texts: [], linked: [file.path], tasks: []).first?.isMissing == true)
    }

    @Test func trackProgressAsksForAMatchingTaskList() {
        let context = SessionPlans.trackProgressContext(path: "/w/.hermes/plans/a.md", title: "Add export")
        #expect(context.title == "Track progress · Add export")
        #expect(context.body.contains("/w/.hermes/plans/a.md"))
        #expect(context.body.contains("task list"))
    }
}
