import Foundation
import Testing

@testable import Herm

struct TodoPlanTests {
    @Test func activeTasksLeadAndResolvedTasksStayAtTheBottom() {
        let plan = TodoPlan(
            sessionID: "session",
            items: [
                .init(content: "Finished first", status: "completed"),
                .init(content: "Next step", status: "pending"),
                .init(content: "Active step", status: "in_progress"),
                .init(content: "Cancelled step", status: "cancelled"),
                .init(content: "Another pending step", status: "pending"),
                .init(content: "Second active step", status: "in_progress"),
                .init(content: "Another finished step", status: "completed"),
            ])
        #expect(plan.orderedItemIndices == [2, 5, 1, 4, 0, 3, 6])
        #expect(plan.inProgress?.content == "Active step")
        #expect(plan.current == plan.inProgress)
        #expect(plan.done == 3)
        #expect(plan.items.first?.content == "Finished first")
    }

    @Test func statusChangesMoveRowsWithoutChangingTheirOriginalIdentities() {
        let before = TodoPlan(
            sessionID: "session",
            items: [
                .init(content: "First", status: "in_progress"), .init(content: "Second", status: "pending"),
                .init(content: "Third", status: "pending"),
            ])
        let after = TodoPlan(
            sessionID: "session",
            items: [
                .init(content: "First", status: "completed"), .init(content: "Second", status: "in_progress"),
                .init(content: "Third", status: "pending"),
            ])
        #expect(before.orderedItemIndices == [0, 1, 2])
        #expect(after.orderedItemIndices == [1, 2, 0])
        #expect(before.items.map(\.content) == after.items.map(\.content))
    }

    @Test func pendingAndUnknownStatusesAreNeverClaimedAsInProgress() {
        let plan = TodoPlan(
            sessionID: "session",
            items: [
                .init(content: "Finished", status: "completed"), .init(content: "Blocked", status: "blocked"),
                .init(content: "Pending", status: "pending"),
            ])
        #expect(plan.orderedItemIndices == [1, 2, 0])
        #expect(plan.inProgress == nil)
        #expect(plan.current?.content == "Pending")
        let empty = TodoPlan(sessionID: "session", items: [])
        #expect(empty.orderedItemIndices.isEmpty && empty.inProgress == nil && empty.current == nil)
    }

    @Test func aPlanIsCurrentOnlyWhenWrittenSinceTheLatestPrompt() {
        let written = Date(timeIntervalSince1970: 1_000)
        let plan = TodoPlan(
            sessionID: "session", items: [.init(content: "Step", status: "pending")], updatedAt: written)
        #expect(plan.isCurrent(latestPromptAt: nil))
        #expect(plan.isCurrent(latestPromptAt: written.addingTimeInterval(-60)))
        // A later prompt the agent never planned for leaves the plan abandoned.
        #expect(!plan.isCurrent(latestPromptAt: written.addingTimeInterval(60)))
        // A plan missing from the loaded tail predates every prompt in it.
        let undated = TodoPlan(sessionID: "session", items: plan.items)
        #expect(!undated.isCurrent(latestPromptAt: written))
    }
}
