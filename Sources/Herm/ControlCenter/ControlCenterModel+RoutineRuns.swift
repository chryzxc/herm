import Foundation

extension ControlCenterModel {
    func resetRoutineRunState() {
        routineInventoryTask?.cancel()
        routineInventoryTask = nil
        routineInventoryToken = UUID()
        routineInventoryConsumers = 0
        routineRunRequestIDs = []
        uncertainRoutineIDs = []
    }

    func refreshRoutineInventory(profileID: String?, includeSessions: Bool = false, fresh: Bool = false) async {
        guard let service = routineService(profileID: profileID) else { return }
        let binding = clientBindingGeneration
        let previousProfile = routineProfileID
        let generation = refreshGeneration
        let token: UUID
        let task: Task<[CronSummary], Error>
        if !fresh, let existing = routineInventoryTask, routineInventoryProfileID == profileID {
            token = routineInventoryToken
            task = existing
        } else {
            routineInventoryTask?.cancel()
            token = UUID()
            routineInventoryToken = token
            routineInventoryConsumers = 0
            routineInventoryProfileID = profileID
            beginProjectionRefresh("cron.jobs")
            task = Task { @MainActor in
                var jobs = try await service.routineJobs()
                if includeSessions, let rpc,
                    let sessions = try? await rpc.sessions(limit: 200, profileID: profileID)
                {
                    jobs = Self.attachLatestCronSessions(to: jobs, from: sessions)
                } else {
                    jobs = jobs.map { job in
                        guard job.sessionID == nil,
                            let sessionID = cronJobs.first(where: { $0.id == job.id })?.sessionID,
                            routineProfileID == profileID
                        else { return job }
                        var copy = CronSummary(
                            id: job.id, name: job.name, schedule: job.schedule, enabled: job.enabled,
                            nextRun: job.nextRun, sessionID: sessionID, delivery: job.delivery, prompt: job.prompt,
                            report: job.report, editableFields: job.editableFields, lastRunAt: job.lastRunAt,
                            lastStatus: job.lastStatus, lastError: job.lastError, details: job.details)
                        copy.owner = job.owner
                        return copy
                    }
                }
                return jobs
            }
            routineInventoryTask = task
        }
        routineInventoryConsumers += 1
        defer {
            if routineInventoryToken == token {
                routineInventoryConsumers -= 1
                if routineInventoryConsumers == 0 {
                    routineInventoryTask = nil
                    routineInventoryToken = UUID()
                }
            }
        }
        do {
            let jobs = try await task.value
            guard !Task.isCancelled, routineInventoryToken == token, clientBindingGeneration == binding,
                refreshGeneration == generation, routineProfileID == previousProfile,
                dockModel == nil || dockModel?.profileScopeID == profileID
            else { return }
            if routineProfileID != profileID {
                cronRunsByJob = [:]
                cronRuns = []
            }
            routineProfileID = profileID
            cronJobs = jobs
            triggeredRoutineIDs = triggeredRoutineIDs.filter { id in
                guard let job = jobs.first(where: { "routine/\(profileID ?? "")/\($0.id)" == id }) else {
                    return true
                }
                return (job.lastRunAt ?? "") == triggeredRoutineRevisions[id]
                    || ["running", "pending", "claimed"].contains(job.lastStatus ?? "")
                    || routineRunRequestIDs.contains(id)
                    || uncertainRoutineIDs.contains(id)
            }
            recordProjectionSuccess("cron.jobs")
            routineInventoryTask = nil
            routineInventoryToken = UUID()
        } catch {
            guard !Task.isCancelled, routineInventoryToken == token, clientBindingGeneration == binding,
                refreshGeneration == generation, routineProfileID == previousProfile,
                dockModel == nil || dockModel?.profileScopeID == profileID
            else { return }
            let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            recordProjectionFailure("cron.jobs", error: message)
            lastError = message
            routineInventoryTask = nil
            routineInventoryToken = UUID()
        }
    }

    @discardableResult
    func refreshRoutineProgress(jobID: String, profileID: String?) async -> Bool {
        let binding = clientBindingGeneration
        guard routineProfileID == profileID else { return false }
        refreshCronRuns(jobID: jobID)
        await refreshRoutineInventory(profileID: profileID)
        guard !Task.isCancelled, clientBindingGeneration == binding, routineProfileID == profileID else { return false }
        if !cronJobs.contains(where: { $0.id == jobID }), refreshState(for: "cron.jobs")?.error == nil {
            recordProjectionFailure("cron.jobs", error: "This automation is no longer available.")
            return false
        }
        return true
    }

    func routineFeedback(_ reference: RoutineReference) -> String? {
        if let error = routineActionErrors[reference.id] { return error }
        if refreshState(for: "cron.jobs")?.error != nil { return "Not current" }
        if reference.running { return "Running" }
        if routineRunRequestIDs.contains(reference.id) { return "Starting…" }
        return nil
    }

    func routineReference(for job: CronSummary) -> RoutineReference {
        RoutineReference(
            profileID: profileForRoutine(job), job: job,
            run: cronRunsByJob[job.id]?.first ?? cronRuns.first { $0.jobID == job.id })
    }
}
