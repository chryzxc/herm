import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct RestoreCheckpointTests {
    private func checkpoint(_ hash: String, session: String = "session-a", project: String? = nil, selection: String? = nil) -> RestoreCheckpoint {
        RestoreCheckpoint(
            sessionID: session,
            projectID: project,
            selectionID: selection,
            hash: hash,
            timestamp: "2026-09-18T12:00:00Z",
            message: "Before change"
        )!
    }

    @Test func eligibilityIsSessionScopedAndDeduplicated() {
        let checkpoints = [
            checkpoint("one"),
            checkpoint("one"),
            checkpoint("other-session", session: "session-b"),
            checkpoint("other-project", project: "project-b")
        ]

        let eligible = RestoreCheckpointEligibility.eligible(
            checkpoints,
            sessionID: "session-a",
            projectID: "project-a"
        )

        #expect(eligible.map(\.hash) == ["one"])
    }

    @Test func explicitConflictingSelectionScopeIsExcluded() {
        let scoped = checkpoint("scoped", project: "project-a", selection: "selection-a")
        let sameContext = RestoreCheckpointEligibility.isEligible(
            scoped,
            sessionID: "session-a",
            projectID: "project-a",
            selectionID: "selection-a"
        )
        let differentSelection = RestoreCheckpointEligibility.isEligible(
            scoped,
            sessionID: "session-a",
            projectID: "project-a",
            selectionID: "selection-b"
        )

        #expect(sameContext)
        #expect(!differentSelection)
    }

    @Test func coordinatorPreventsDuplicatePendingAndCompletedRestore() {
        let coordinator = RestoreCheckpointCoordinator()
        let first = checkpoint("one")
        let second = checkpoint("two")

        #expect(coordinator.begin(first))
        #expect(!coordinator.begin(first))
        #expect(!coordinator.begin(second))
        coordinator.succeed()
        #expect(coordinator.state == .completed(first))
        #expect(!coordinator.begin(first))
        #expect(coordinator.begin(second))
    }

    @Test func cancellationResetsPendingStateWithoutInventingCompletion() {
        let coordinator = RestoreCheckpointCoordinator()
        let selected = checkpoint("one")

        #expect(coordinator.begin(selected))
        coordinator.cancel()

        #expect(coordinator.state == .idle)
    }

    @Test func failureRetainsCheckpointForAccessibleRetryState() {
        let coordinator = RestoreCheckpointCoordinator()
        let selected = checkpoint("one")

        #expect(coordinator.begin(selected))
        coordinator.fail("Restore failed")

        #expect(coordinator.state == .failed(selected, message: "Restore failed"))
        #expect(coordinator.begin(selected))
    }
}
