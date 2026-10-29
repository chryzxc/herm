import Foundation
import Testing

@testable import Herm

@MainActor
private final class LiveRunClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var status = "completed"
    var timestamp = "2026-10-28T09:00:00Z"
    var calls: [(String, String)] = []
    var pendingTrigger: CheckedContinuation<Void, Never>?
    var pendingInventory: CheckedContinuation<[String: Any], Error>?
    var suspendTrigger = false
    var suspendInventory = false
    var failTrigger = false
    var failInventory = false
    var rejectInventory = false

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(("RPC", method))
        if suspendInventory { return try await withCheckedThrowingContinuation { pendingInventory = $0 } }
        if failInventory { throw URLError(.notConnectedToInternet) }
        if rejectInventory { return ["success": false, "scoped": "research", "jobs": []] }
        return inventory()
    }
    func inventory() -> [String: Any] {
        [
            "scoped": "research",
            "jobs": [
                [
                    "job_id": "job", "name": "Review", "schedule": "daily", "enabled": true,
                    "last_status": status, "last_run_at": timestamp,
                ]
            ],
        ]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        calls.append(("GET", path))
        return ["runs": []]
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        try await sendHTTP(method, path: path, body: body, timeout: 0)
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String:
        Any]
    {
        calls.append((method, path))
        if suspendTrigger { await withCheckedContinuation { pendingTrigger = $0 } }
        if failTrigger { throw URLError(.timedOut) }
        return [
            "id": "job", "job_id": "job", "name": "Review", "schedule": "daily", "enabled": true,
            "profile": "research", "prompt": "Review",
        ]
    }
}

@MainActor
struct AutomationLiveRunTests {
    private func model(_ client: LiveRunClient) -> ControlCenterModel {
        let model = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-scheduling", title: "Cron", detail: "Available", isAvailable: true, recovery: nil)
            ])
        model.routineProfileID = "research"
        var job = CronSummary(id: "job", name: "Review", schedule: "daily", enabled: true, nextRun: nil)
        job.owner = CronOwner(profileID: "research")
        model.cronJobs = [job]
        return model
    }

    @Test func suspendedTriggerAutomaticallyObservesActiveThenTerminal() async throws {
        let client = LiveRunClient()
        client.suspendTrigger = true
        let control = model(client)
        control.runCronNow(try #require(control.cronJobs.first))
        for _ in 0..<1_000 where client.pendingTrigger == nil { await Task.yield() }
        let pending = try #require(client.pendingTrigger)
        client.status = "running"
        client.timestamp = "2026-10-29T09:00:00Z"
        for _ in 0..<40 where control.cronJobs.first?.lastStatus != "running" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(control.cronJobs.first?.lastStatus == "running")
        #expect(control.routineReference(for: try #require(control.cronJobs.first)).running)
        #expect(
            control.routineFeedback(control.routineReference(for: try #require(control.cronJobs.first))) == "Running")
        client.failInventory = true
        await control.refreshRoutineInventory(profileID: "research")
        #expect(
            control.routineFeedback(control.routineReference(for: try #require(control.cronJobs.first)))
                == "Not current")
        client.failInventory = false
        client.status = "completed"
        client.timestamp = "2026-10-30T09:00:00Z"
        for _ in 0..<40 where control.cronJobs.first?.lastStatus != "completed" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(control.cronJobs.first?.lastStatus == "completed")
        #expect(client.calls.filter { $0.0 == "POST" }.count == 1)
        #expect(client.calls.contains { $0.0 == "GET" && $0.1.contains("/job/runs?") })
        pending.resume()
        for _ in 0..<100 where !control.routineRunRequestIDs.isEmpty { await Task.yield() }
        #expect(control.routineRunRequestIDs.isEmpty)
        #expect(control.uncertainRoutineIDs.isEmpty)
        #expect(control.routineFeedback(control.routineReference(for: try #require(control.cronJobs.first))) == nil)
    }

    @Test func failedReadPreservesInventoryAndUncertainTriggerRequiresReview() async throws {
        let client = LiveRunClient()
        client.failTrigger = true
        let control = model(client)
        let job = try #require(control.cronJobs.first)
        let reference = control.routineReference(for: job)
        await control.recoverRoutine(reference, run: true)
        #expect(control.uncertainRoutineIDs.contains(reference.id))
        #expect(control.routineNeedsReview(reference))
        #expect(!control.canTriggerRoutine(reference))
        #expect(!control.routineRunRequestIDs.contains(reference.id))
        client.failInventory = true
        let before = control.cronJobs
        await control.refreshRoutineInventory(profileID: "research")
        #expect(control.cronJobs == before)
        #expect(control.refreshState(for: "cron.jobs")?.error != nil)
        #expect(control.uncertainRoutineIDs.contains(reference.id))
        client.failInventory = false
        client.timestamp = "2026-10-30T09:00:00Z"
        await control.refreshRoutineInventory(profileID: "research")
        #expect(control.routineNeedsReview(reference))
        #expect(client.calls.filter { $0.0 == "POST" }.count == 1)
    }

    @Test func cancelledSelectionStopsProgressAfterPendingInventory() async throws {
        let client = LiveRunClient()
        client.suspendInventory = true
        let control = model(client)
        let progress = Task { await control.refreshRoutineProgress(jobID: "job", profileID: "research") }
        for _ in 0..<1_000 where client.pendingInventory == nil { await Task.yield() }
        let pending = try #require(client.pendingInventory)
        let before = control.cronJobs
        progress.cancel()
        pending.resume(returning: [
            "scoped": "research",
            "jobs": [
                [
                    "job_id": "different", "name": "Other", "schedule": "daily", "enabled": true,
                ]
            ],
        ])
        #expect(await progress.value == false)
        #expect(control.cronJobs == before)
        #expect(control.refreshState(for: "cron.jobs")?.error == nil)
        #expect(!client.calls.contains { $0.0 == "POST" })
    }

    @Test func mutationStartsNewInventoryAfterSuspendedRead() async throws {
        let client = LiveRunClient()
        client.suspendInventory = true
        let control = model(client)
        let old = Task { await control.refreshRoutineInventory(profileID: "research") }
        for _ in 0..<1_000 where client.pendingInventory == nil { await Task.yield() }
        let pending = try #require(client.pendingInventory)
        client.suspendInventory = false
        client.timestamp = "2026-10-30T09:00:00Z"
        await control.recoverRoutine(control.routineReference(for: try #require(control.cronJobs.first)), run: true)
        #expect(client.calls.filter { $0.0 == "RPC" }.count >= 2)
        #expect(control.cronJobs.first?.lastRunAt == "2026-10-30T09:00:00Z")
        pending.resume(returning: ["scoped": "research", "jobs": []])
        await old.value
        #expect(control.cronJobs.first?.lastRunAt == "2026-10-30T09:00:00Z")
    }

    @Test func laterConsumerFetchesFreshSnapshotAfterOnlyConsumerCancels() async throws {
        let client = LiveRunClient()
        client.suspendInventory = true
        let control = model(client)
        let cancelled = Task { await control.refreshRoutineProgress(jobID: "job", profileID: "research") }
        for _ in 0..<1_000 where client.pendingInventory == nil { await Task.yield() }
        let pending = try #require(client.pendingInventory)
        cancelled.cancel()
        pending.resume(returning: ["scoped": "research", "jobs": []])
        #expect(await cancelled.value == false)
        client.suspendInventory = false
        client.status = "running"
        client.timestamp = "2026-10-30T09:00:00Z"
        await control.refreshRoutineInventory(profileID: "research")
        #expect(client.calls.filter { $0.0 == "RPC" }.count == 2)
        #expect(control.cronJobs.first?.lastStatus == "running")
        #expect(control.cronJobs.first?.lastRunAt == "2026-10-30T09:00:00Z")
    }

    @Test func cancelledConsumerDoesNotPreventSharedConsumerPublishing() async throws {
        let client = LiveRunClient()
        client.suspendInventory = true
        let control = model(client)
        let cancelled = Task { await control.refreshRoutineProgress(jobID: "job", profileID: "research") }
        for _ in 0..<1_000 where client.pendingInventory == nil { await Task.yield() }
        let pending = try #require(client.pendingInventory)
        let survivor = Task { await control.refreshRoutineInventory(profileID: "research") }
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        pending.resume(returning: [
            "scoped": "research", "jobs": [["job_id": "job", "name": "New", "schedule": "daily", "enabled": true]],
        ])
        #expect(await cancelled.value == false)
        await survivor.value
        #expect(control.cronJobs.first?.name == "New")
        #expect(client.calls.filter { $0.0 == "RPC" }.count == 1)
    }

    @Test func rejectedInventoryPreservesCachedJobs() async {
        let client = LiveRunClient()
        let control = model(client)
        let before = control.cronJobs
        client.rejectInventory = true
        await control.refreshRoutineInventory(profileID: "research")
        #expect(control.cronJobs == before)
        #expect(control.refreshState(for: "cron.jobs")?.error != nil)
    }

    @Test func visibleReadbackObservesExternalExecutionWithoutTriggering() async throws {
        let client = LiveRunClient()
        client.status = "running"
        client.timestamp = "2026-10-29T09:00:00Z"
        let control = model(client)
        #expect(await control.refreshRoutineProgress(jobID: "job", profileID: "research"))
        let reference = control.routineReference(for: try #require(control.cronJobs.first))
        #expect(reference.running)
        #expect(!control.canTriggerRoutine(reference))
        for _ in 0..<100 where !client.calls.contains(where: { $0.0 == "GET" }) { await Task.yield() }
        #expect(client.calls.contains { $0.0 == "GET" && $0.1.contains("/job/runs?") })
        #expect(!client.calls.contains { $0.0 == "POST" })
    }
}
