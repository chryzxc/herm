import Foundation
import Testing

@testable import Herm

@MainActor
private final class AutomationRunProbeClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var inventoryStatus = "ok"
    var inventoryRevision = "2026-10-29T09:00:00Z"
    var inventoryReads = 0
    var triggerCount = 0
    var pendingTrigger: CheckedContinuation<[String: Any], Error>?
    var historyFails = false

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "cron.manage" else { return [:] }
        inventoryReads += 1
        return [
            "scoped": "research",
            "jobs": [
                [
                    "job_id": "job", "name": "Review", "schedule": "daily", "enabled": true,
                    "last_run_at": inventoryRevision, "last_status": inventoryStatus,
                ]
            ],
        ]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if historyFails { throw URLError(.notConnectedToInternet) }
        return ["runs": []]
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        try await sendHTTP(method, path: path, body: body, timeout: 86_400)
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String:
        Any]
    {
        triggerCount += 1
        return try await withCheckedThrowingContinuation { pendingTrigger = $0 }
    }
}

@MainActor
struct AutomationRunResponsivenessTests {
    @Test func staleHistoryDoesNotClaimRunningAndRecovers() async throws {
        let client = AutomationRunProbeClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let job = CronSummary(id: "job", name: "Review", schedule: "daily", enabled: true, nextRun: nil)
        model.routineProfileID = "research"
        model.cronJobs = [job]
        model.cronRunsByJob[job.id] = [
            CronRunSummary(
                id: "run", status: "running", jobID: job.id, source: "cron", claimedAt: nil, error: nil)
        ]
        client.historyFails = true
        model.refreshCronRuns(jobID: job.id)
        let key = model.cronRunsProjectionKey(jobID: job.id)
        for _ in 0..<10_000 where model.refreshState(for: key)?.isRefreshing == true { await Task.yield() }
        #expect(model.refreshState(for: key)?.error != nil)
        #expect(model.routineFeedback(model.routineReference(for: job)) == "Status unavailable. Refresh to check.")
        client.historyFails = false
        model.refreshCronRuns(jobID: job.id)
        for _ in 0..<10_000 where model.refreshState(for: key)?.isRefreshing == true { await Task.yield() }
        #expect(model.refreshState(for: key)?.error == nil)
        #expect(model.routineFeedback(model.routineReference(for: job)) == nil)
    }

    @Test func uncertainSubmissionRequiresReview() async throws {
        let client = AutomationRunProbeClient()
        let model = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-scheduling", title: "Cron", detail: "Available", isAvailable: true, recovery: nil)
            ])
        let job = CronSummary(id: "job", name: "Review", schedule: "daily", enabled: true, nextRun: nil)
        model.routineProfileID = "research"
        model.cronJobs = [job]
        let reference = RoutineReference(profileID: "research", job: job, run: nil)
        model.runCronNow(job)
        for _ in 0..<10_000 where client.pendingTrigger == nil { await Task.yield() }
        let pending = try #require(client.pendingTrigger)
        client.pendingTrigger = nil
        pending.resume(throwing: URLError(.timedOut))
        for _ in 0..<10_000 where model.routineRunRequestIDs.contains(reference.id) { await Task.yield() }
        #expect(model.uncertainRoutineIDs.contains(reference.id))
        #expect(model.routineNeedsReview(reference))
        #expect(!model.canTriggerRoutine(reference))
        let originalRevision = try #require(model.triggeredRoutineRevisions[reference.id])
        client.inventoryRevision = "2026-10-30T09:00:00Z"
        await model.refreshRoutineInventory(profileID: "research", fresh: true)
        let updated = try #require(model.cronJobs.first)
        #expect(updated.lastRunAt == client.inventoryRevision)
        #expect(updated.lastRunAt != originalRevision)
        let updatedReference = model.routineReference(for: updated)
        #expect(model.routineNeedsReview(updatedReference))
        #expect(!model.canTriggerRoutine(updatedReference))
        model.runCronNow(updated)
        await Task.yield()
        #expect(client.triggerCount == 1)
        await model.confirmRoutineReview(updatedReference)
        #expect(!model.uncertainRoutineIDs.contains(reference.id))
        #expect(!model.routineNeedsReview(updatedReference))
        #expect(model.canTriggerRoutine(model.routineReference(for: try #require(model.cronJobs.first))))
        #expect(client.triggerCount == 1)
    }
    @Test func runReservesImmediatelyAndReadsLiveStatusBeforeTriggerReturns() async throws {
        let client = AutomationRunProbeClient()
        let model = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-scheduling", title: "Cron", detail: "Available", isAvailable: true, recovery: nil)
            ])
        var job = CronSummary(
            id: "job", name: "Review", schedule: "daily", enabled: true, nextRun: nil,
            lastRunAt: "2026-10-28T09:00:00Z", lastStatus: "ok")
        job.owner = CronOwner(profileID: "research")
        model.routineProfileID = "research"
        model.cronJobs = [job]
        let reference = RoutineReference(profileID: "research", job: job, run: nil)

        model.runCronNow(job)
        #expect(!model.canTriggerRoutine(reference), "Run must reserve the selected job before returning to the UI")
        #expect(model.routineFeedback(reference) == "Starting automation…")
        for _ in 0..<1_000 where client.pendingTrigger == nil { await Task.yield() }
        let pending = try #require(client.pendingTrigger)
        client.inventoryStatus = "running"
        try await Task.sleep(for: .milliseconds(3_500))
        #expect(client.inventoryReads > 1, "Inventory must refresh independently of the pending trigger response")
        #expect(model.cronJobs.first?.lastStatus == "running")
        #expect(model.routineFeedback(model.routineReference(for: try #require(model.cronJobs.first))) == "Running")
        #expect(client.triggerCount == 1)

        client.inventoryStatus = "completed"
        #expect(await model.refreshRoutineProgress(jobID: job.id, profileID: "research"))
        let finished = try #require(model.cronJobs.first)
        #expect(finished.lastStatus == "completed")
        #expect(!model.routineReference(for: finished).running)

        pending.resume(returning: ["id": "job", "prompt": "Review", "schedule": "daily"])
        client.pendingTrigger = nil
        for _ in 0..<1_000 where model.routineActions.contains(reference.id) { await Task.yield() }
    }
}
