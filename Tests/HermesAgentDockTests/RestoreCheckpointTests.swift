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

    @Test func restoreCheckpointCarriesExactSessionAndHashToHermes() async {
        let client = RestoreCheckpointClient(result: ["success": true])
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let selected = checkpoint("abc123")

        #expect(await model.restoreCheckpoint(selected))
        #expect(client.lastMethod == "rollback.restore")
        #expect(client.lastParams?["session_id"] as? String == "session-a")
        #expect(client.lastParams?["hash"] as? String == "abc123")
        #expect(model.restoreCheckpointState == .completed(selected))
    }

    @Test func restoreCheckpointFailureRetainsRetryableStateAndCancelClearsIt() async {
        let client = RestoreCheckpointClient(result: ["success": false, "error": "restore rejected"])
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let selected = checkpoint("abc123")

        #expect(!(await model.restoreCheckpoint(selected)))
        #expect(model.restoreCheckpointState == .failed(selected, message: "restore rejected"))
        model.cancelRestoreCheckpoint()
        #expect(model.restoreCheckpointState == .idle)
    }

    @Test func checkpointProjectionDrivesListConfirmationRestoreAndCanonicalRefresh() async {
        let client = RestoreCheckpointClient(result: ["success": true])
        client.listResult = [
            "enabled": true,
            "checkpoints": [["hash": "live-hash", "timestamp": "now", "message": "Before restore"]]
        ]
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        model.refreshCheckpoints(sessionID: "session-a")

        await eventually { !model.restoreCheckpoints.isEmpty }
        #expect(!model.restoreCheckpoints.isEmpty)
        guard let selected = model.restoreCheckpoints.first else { return }
        #expect(selected.sessionID == "session-a")
        #expect(await model.restoreCheckpoint(selected))
        #expect(client.methods.contains("rollback.list"))
        #expect(client.methods.contains("rollback.restore"))
        #expect(client.restoreParams?["session_id"] as? String == "session-a")
        #expect(client.restoreParams?["hash"] as? String == "live-hash")
        #expect(model.restoreCheckpointState == .completed(selected))

        await eventually { client.methods.filter { $0 == "rollback.list" }.count >= 2 }
        #expect(client.lastMethod == "rollback.list")
        let listCountAfterRestore = client.methods.filter { $0 == "rollback.list" }.count
        #expect(listCountAfterRestore >= 2)
        #expect(!(await model.restoreCheckpoint(selected)))

        let second = checkpoint("second-hash")
        client.restoreDelayNanoseconds = 100_000_000
        let pendingRestore = Task { await model.restoreCheckpoint(second) }
        await eventually { model.restoreCheckpointState == .pending(second) }
        #expect(model.restoreCheckpointState == .pending(second))
        #expect(!(await model.restoreCheckpoint(second)))
        #expect(await pendingRestore.value)

        model.cancelRestoreCheckpoint()
        #expect(model.restoreCheckpointState == .completed(second))
    }

    @Test func renderedRestoreHarnessDrivesScopedSelectionConfirmationCancelAndRetry() async {
        let client = RestoreCheckpointClient(result: ["success": true])
        client.listResult = [
            "enabled": true,
            "checkpoints": [
                ["hash": "session-a-project-a-selection-a", "timestamp": "now", "message": "A"],
                ["hash": "session-b", "timestamp": "now", "message": "B"]
            ]
        ]
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let harness = RestoreCheckpointRenderedActionHarness(model: model)

        harness.renderList(sessionID: "session-a", projectID: "project-a", selectionID: "selection-a")
        await eventually { !model.restoreCheckpoints.isEmpty }
        #expect(model.restoreCheckpoints.allSatisfy {
            $0.sessionID == "session-a" && $0.projectID == nil && $0.selectionID == "session-a"
        })
        guard let selected = model.restoreCheckpoints.first else { return }

        harness.tapRestore(selected)
        #expect(harness.confirmation == selected)
        harness.cancelConfirmation()
        #expect(harness.confirmation == nil)
        #expect(model.restoreCheckpointState == .idle)

        harness.tapRestore(selected)
        client.restoreDelayNanoseconds = 100_000_000
        let restore = harness.confirmRestore()
        await eventually { model.restoreCheckpointState == .pending(selected) }
        #expect(!(await model.restoreCheckpoint(selected)))
        #expect(model.restoreCheckpointState == .pending(selected))
        #expect(await restore.value)
        #expect(model.restoreCheckpointState == .completed(selected))
        #expect(client.restoreParams?["session_id"] as? String == "session-a")
        #expect(client.restoreParams?["hash"] as? String == selected.hash)

        client.result = ["success": false, "error": "retryable"]
        let retry = checkpoint("retry", session: "session-a")
        harness.tapRestore(retry)
        #expect(!(await harness.confirmRestore().value))
        #expect(model.restoreCheckpointState == .failed(retry, message: "retryable"))
        harness.cancelConfirmation()
        #expect(model.restoreCheckpointState == .idle)
    }
}

/// Executable equivalent of the rendered sidebar action/confirmation path.
/// The production view has no UI-test target; this harness preserves its
/// RESTORE tap, confirmation, cancel, and confirmed Task boundaries while
/// driving the real ControlCenterModel and HermesControlRPC transport.
@MainActor
private final class RestoreCheckpointRenderedActionHarness {
    let model: ControlCenterModel
    private(set) var confirmation: RestoreCheckpoint?

    init(model: ControlCenterModel) { self.model = model }

    func renderList(sessionID: String, projectID _: String, selectionID _: String) {
        model.focus(sessionID: sessionID)
        model.refreshCheckpoints(sessionID: sessionID)
    }

    func tapRestore(_ checkpoint: RestoreCheckpoint) { confirmation = checkpoint }

    func cancelConfirmation() {
        model.cancelRestoreCheckpoint()
        confirmation = nil
    }

    func confirmRestore() -> Task<Bool, Never> {
        guard let checkpoint = confirmation else { return Task { false } }
        confirmation = nil
        return Task { await model.restoreCheckpoint(checkpoint) }
    }
}

@MainActor
private final class RestoreCheckpointClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var result: [String: Any]
    var listResult: [String: Any] = ["enabled": true, "checkpoints": []]
    var restoreDelayNanoseconds: UInt64 = 0
    private(set) var methods: [String] = []
    private(set) var lastMethod: String?
    private(set) var lastParams: [String: Any]?
    private(set) var restoreParams: [String: Any]?

    init(result: [String: Any]) { self.result = result }
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        methods.append(method)
        lastMethod = method
        lastParams = params
        if method == "rollback.list" { return listResult }
        if method == "rollback.restore" {
            restoreParams = params
            if restoreDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
            }
        }
        return result
    }
}

@MainActor
private func eventually(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
