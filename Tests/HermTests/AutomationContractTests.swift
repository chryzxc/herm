import Foundation
import Testing

@testable import Herm

@MainActor
private final class AutomationClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rpcResult: [String: Any] = [:]
    var httpResult: [String: Any] = [:]
    var calls: [(String, String, [String: Any], TimeInterval?)] = []
    var pendingRead: CheckedContinuation<[String: Any], Error>?
    var suspendReads = false
    var pendingInventory: CheckedContinuation<[String: Any], Error>?
    var suspendInventory = false
    var pendingTrigger: CheckedContinuation<Void, Never>?
    var suspendTriggers = false
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(("RPC", method, params, nil))
        if suspendInventory { return try await withCheckedThrowingContinuation { pendingInventory = $0 } }
        return rpcResult
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        calls.append(("GET", path, [:], nil))
        if suspendReads { return try await withCheckedThrowingContinuation { pendingRead = $0 } }
        return httpResult
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        calls.append((method, path, body, nil))
        return httpResult
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String:
        Any]
    {
        calls.append((method, path, body, timeout))
        if suspendTriggers { await withCheckedContinuation { pendingTrigger = $0 } }
        return httpResult
    }
}

@MainActor
struct AutomationContractTests {
    private func control(_ client: AutomationClient) -> ControlCenterModel {
        ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "rpc-scheduling", title: "Cron", detail: "Available", isAvailable: true, recovery: nil)
            ])
    }
    private var job: CronSummary {
        var job = CronSummary(id: "job", name: "Review", schedule: "0 9 * * *", enabled: true, nextRun: nil)
        job.owner = CronOwner(profileID: "research")
        return job
    }
    private var detail: [String: Any] {
        [
            "id": "job", "name": "Review", "schedule": ["kind": "cron", "expr": "0 9 * * *", "display": "Every day"],
            "prompt": String(repeating: "A complete instruction. ", count: 20), "deliver": "local", "model": "old",
            "provider": "configured",
        ]
    }
    private func refuses(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected Hermes rejection")
        } catch {}
    }

    @Test func reportLoadsThroughTheRealNormalizedHTTPEnvelope() async throws {
        let client = AutomationClient()
        client.httpResult = ["messages": [["role": "assistant", "content": "# Completed report"]]]
        let model = control(client)
        let report = try await model.cronReport(
            for: CronReportRequest(profileID: "research", job: job, sessionID: "actual-session"))
        #expect(report.markdown == "# Completed report")
        #expect(client.calls.first?.1.contains("profile=research") == true)
    }

    @Test func creationAndRemovalRequirePositiveMatchingAcknowledgments() async {
        let client = AutomationClient()
        client.rpcResult = ["success": false, "error": "Invalid schedule"]
        let model = control(client)
        #expect(await model.createCron(name: "Review", schedule: "invalid", prompt: "Review") == false)
        #expect(model.lastError == "Invalid schedule")
        #expect(!model.isActionPending("cron.create"))
        await refuses { _ = try await HermesControlRPC(client: client).removeCron(jobID: "job", profileID: "research") }
        client.rpcResult = ["success": true, "removed_job": ["id": "other-job"]]
        await refuses { _ = try await HermesControlRPC(client: client).removeCron(jobID: "job", profileID: "research") }
        client.rpcResult = [:]
        #expect(await model.createCron(name: "Review", schedule: "daily", prompt: "Review") == false)
    }

    @Test func triggerUsesOwnedHTTPWithLongTimeoutAndNeverFallsBackToShell() async throws {
        let client = AutomationClient()
        client.httpResult = detail
        try await HermesWorkflowRPC(client: client, profileID: "research").runRoutine("job")
        #expect(client.calls.count == 1)
        #expect(client.calls.first?.0 == "POST")
        #expect(client.calls.first?.1 == "/api/cron/jobs/job/trigger?profile=research")
        #expect(client.calls.first?.3 == 86_400)
        client.httpResult = ["success": false]
        await refuses { try await HermesWorkflowRPC(client: client, profileID: "research").runRoutine("job") }
        #expect(client.calls.allSatisfy { $0.0 == "POST" })
        #expect(
            try HermesControlRPC.cronPath(jobID: "job", suffix: "/trigger", profileID: nil)
                == "/api/cron/jobs/job/trigger")
    }

    @Test func confirmedRunRefreshesBeforeTriggerCompletes() async throws {
        let client = AutomationClient()
        client.rpcResult = [
            "scoped": "research",
            "jobs": [["job_id": "job", "name": "Review", "schedule": "daily", "enabled": true]],
        ]
        client.httpResult = detail
        client.suspendTriggers = true
        let model = control(client)
        model.routineProfileID = "research"
        model.cronJobs = [job]
        model.runCronNow(job)
        let reference = RoutineReference(profileID: "research", job: job, run: nil)
        #expect(model.routineFeedback(reference) == "Starting…")
        #expect(!model.canTriggerRoutine(reference))
        model.runCronNow(job)
        for _ in 0..<1_000 where client.pendingTrigger == nil { await Task.yield() }
        let pending = try #require(client.pendingTrigger)
        for _ in 0..<1_000 { await Task.yield() }
        #expect(model.routineActions.contains("routine/research/job"))
        #expect(client.calls.filter { $0.0 == "POST" }.count == 1)
        #expect(client.calls.filter { $0.1 == "cron.manage" }.count > 1)
        #expect(client.calls.contains { $0.0 == "GET" && $0.1.contains("/job/runs?") })
        pending.resume()
        for _ in 0..<1_000 where model.routineActions.contains("routine/research/job") { await Task.yield() }
    }

    @Test func obsoleteInventoryCannotPublishAndConcurrentReadsCoalesce() async throws {
        let client = AutomationClient()
        client.suspendInventory = true
        let model = control(client)
        model.routineProfileID = "research"
        model.cronJobs = [job]
        let first = Task { await model.refreshRoutineInventory(profileID: "research") }
        for _ in 0..<1_000 where client.pendingInventory == nil { await Task.yield() }
        let pending = try #require(client.pendingInventory)
        let second = Task { await model.refreshRoutineInventory(profileID: "research") }
        for _ in 0..<100 { await Task.yield() }
        #expect(client.calls.filter { $0.0 == "RPC" }.count == 1)
        model.routineProfileID = "other"
        pending.resume(returning: ["scoped": "research", "jobs": []])
        await first.value
        await second.value
        #expect(model.routineProfileID == "other")
        #expect(model.cronJobs == [job])
    }

    @Test func currentRunningJobOutranksOlderCompletedHistory() {
        let current = CronSummary(
            id: "job", name: "Review", schedule: "daily", enabled: true, nextRun: nil,
            lastRunAt: "2026-10-29T09:00:00Z", lastStatus: "running")
        let older = CronRunSummary(
            id: "older", status: "completed", jobID: current.id, source: "cron",
            claimedAt: "2026-10-28T09:00:00Z", error: nil)
        #expect(AutomationWorkspaceRowPresentation.make(job: current, latestRun: older).result == .running)
    }

    @Test func executionStatusUsesNewestEvidenceAndPreservesActivePausedRuns() {
        let cases: [(Bool, String?, String?, String, String?, AutomationWorkspaceRowPresentation.Result)] = [
            (true, "running", "2026-10-29T09:00:00Z", "completed", "2026-10-28T09:00:00Z", .running),
            (true, "running", "2026-10-29T09:00:00Z", "completed", "2026-10-30T09:00:00Z", .succeeded),
            (true, "pending", "2026-10-29T09:00:00Z", "completed", "2026-10-29T09:00:00Z", .running),
            (false, "claimed", nil, "completed", nil, .running),
            (false, "completed", nil, "running", nil, .running),
            (false, "completed", nil, "completed", nil, .paused),
            (true, "finished", nil, "finished", nil, .unknown),
        ]
        for (enabled, status, jobDate, runStatus, runDate, expected) in cases {
            let job = CronSummary(
                id: "job", name: "Review", schedule: "daily", enabled: enabled, nextRun: nil,
                lastRunAt: jobDate, lastStatus: status)
            let run = CronRunSummary(
                id: "run", status: runStatus, jobID: job.id, source: "cron",
                claimedAt: runDate, error: nil)
            #expect(AutomationWorkspaceRowPresentation.make(job: job, latestRun: run).result == expected)
            #expect(RoutineReference(profileID: nil, job: job, run: run).running == (expected == .running))
        }
    }

    @Test func editingLoadsFullInstructionsAndOnlySendsChangedFields() async throws {
        let client = AutomationClient()
        client.httpResult = detail
        let rpc = HermesControlRPC(client: client)
        let loaded = try await rpc.cronJob(job, profileID: "research")
        #expect(loaded.prompt?.count ?? 0 > 100)
        #expect(loaded.schedule == "0 9 * * *")
        #expect(loaded.owner?.profileID == "research")
        var draft = CronEditDraft(job: loaded)
        draft.configuration.model = ""
        try await rpc.updateCron(loaded, draft: draft, profileID: "research")
        let updates = try #require(client.calls.last?.2["updates"] as? [String: Any])
        #expect(updates.count == 2)
        #expect(updates["model"] is NSNull)
        #expect(updates["provider"] is NSNull)
        #expect(client.calls.last?.1 == "/api/cron/jobs/job?profile=research")
        client.httpResult = ["id": "job", "schedule": "daily", "prompt_preview": "Truncated…"]
        await refuses { _ = try await rpc.cronJob(job, profileID: "research") }
    }

    @Test func configuredCreationSendsBackendFieldsToTheCapturedProfile() async {
        let client = AutomationClient()
        client.httpResult = detail
        let model = control(client)
        model.routineProfileID = "research"
        let configuration = CronConfigurationDraft(
            delivery: "telegram", workdir: "/tmp/work", model: "configured-model", provider: "configured-provider")
        #expect(
            await model.createCron(name: "Review", schedule: "daily", prompt: "Review", configuration: configuration))
        let call = client.calls.first { $0.0 == "POST" }
        #expect(call?.1 == "/api/cron/jobs?profile=research")
        #expect(call?.2["deliver"] as? String == "telegram")
        #expect(call?.2["model"] as? String == "configured-model")
        #expect(call?.2["workdir"] as? String == "/tmp/work")
    }

    @Test func structuredRunsUseRealIdentitiesAndKeepScriptPreviewsWithoutInventingSuccess() throws {
        let rows: [[String: Any]] = [
            [
                "id": "cron_job_20261018_090005", "source": "cron", "started_at": 1_792_287_005,
                "ended_at": 1_792_287_050,
            ],
            [
                "id": "cron_output:job:20261018_090100", "source": "cron_output", "started_at": 1_792_287_060,
                "ended_at": 1_792_287_060, "preview": "Script wrote the daily report",
            ],
        ]
        let runs = try ControlCenterModel.parseStructuredCronRuns(["runs": rows], jobID: "job")
        #expect(runs[0].sessionID == "cron_job_20261018_090005")
        #expect(runs[1].sessionID == nil)
        #expect(runs[1].outputPreview == "Script wrote the daily report")
        #expect(AutomationWorkspaceRowPresentation.result(for: runs[0]) == .unknown)
        let ledger = ControlCenterModel.parseCronRuns("attempt completed job=job source=cron 2026-10-18T09:00:00Z")
        #expect(ledger.first?.sessionID == nil)
    }

    @Test func staleRunResponseCannotReplaceAnotherProfilesHistory() async throws {
        let client = AutomationClient()
        client.suspendReads = true
        let model = control(client)
        model.routineProfileID = "research"
        let oldKey = model.cronRunsProjectionKey(jobID: "job")
        model.refreshCronRuns(jobID: "job")
        for _ in 0..<100 where client.pendingRead == nil { await Task.yield() }
        let pending = try #require(client.pendingRead)
        model.routineProfileID = "coding"
        #expect(model.cronRunsProjectionKey(jobID: "job") != oldKey)
        pending.resume(returning: ["runs": [["id": "old", "source": "cron", "started_at": 1]]])
        for _ in 0..<10 { await Task.yield() }
        #expect(model.cronRunsByJob["job"] == nil)
    }
    @Test func pauseAndResumeRequireTheRequestedStateAndProfile() async throws {
        let client = AutomationClient()
        let service = HermesWorkflowRPC(client: client, profileID: "research")
        client.rpcResult = ["success": true, "job": ["job_id": "job", "enabled": false]]
        try await service.setRoutinePaused("job", paused: true)
        #expect(client.calls.last?.2["profile"] as? String == "research")
        #expect(client.calls.last?.2["action"] as? String == "pause")
        client.rpcResult = ["success": true, "job": ["job_id": "job", "enabled": true]]
        try await service.setRoutinePaused("job", paused: false)
        #expect(client.calls.last?.2["action"] as? String == "resume")
        await refuses { try await service.setRoutinePaused("job", paused: true) }
    }

    @Test func rejectedEditPreservesTheDraftAndClearsPendingState() async throws {
        let client = AutomationClient()
        client.httpResult = detail
        let model = control(client)
        let loaded = try await model.loadCronDetail(job)
        var draft = CronEditDraft(job: loaded)
        draft.prompt = "An edited instruction that must survive failure"
        client.httpResult = ["success": false, "error": "Denied"]
        #expect(await model.editCron(loaded, draft: draft) == false)
        #expect(draft.prompt == "An edited instruction that must survive failure")
        #expect(model.lastError != nil)
        #expect(!model.isActionPending(model.cronActionID("edit", job: job)))
    }

    @Test func malformedHistoryPreservesTheLastSuccessfulProjection() async throws {
        let client = AutomationClient()
        client.httpResult = ["runs": [["id": "cron_other_20261018_090005", "source": "cron", "started_at": 100]]]
        let model = control(client)
        let cached = CronRunSummary(
            id: "cached", status: "completed", jobID: "job", source: "cron", claimedAt: nil, error: nil)
        model.cronRunsByJob["job"] = [cached]
        model.refreshCronRuns(jobID: "job")
        let key = model.cronRunsProjectionKey(jobID: "job")
        for _ in 0..<100 where model.refreshState(for: key)?.isRefreshing == true { await Task.yield() }
        #expect(model.cronRunsByJob["job"] == [cached])
        #expect(model.refreshState(for: key)?.error != nil)
    }

    @Test func rejectedOrUnscopedInventoriesNeverLookLikeSuccessfulEmptyLists() async {
        let client = AutomationClient()
        let rpc = HermesControlRPC(client: client)
        client.rpcResult = ["success": false, "error": "Not connected"]
        await refuses { _ = try await rpc.cron(action: "list") }
        client.rpcResult = ["jobs": [], "scoped": "coding"]
        await refuses { _ = try await rpc.cron(action: "list", profileID: "research") }
    }

}
