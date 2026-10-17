import Foundation
import Combine

extension ControlCenterModel {
    var routineReferences: [RoutineReference] {
        cronJobs.map { job in RoutineReference(profileID: routineProfileID, job: job,
            run: (cronRunsByJob[job.id] ?? cronRuns.filter { $0.jobID == job.id }).first) }
    }

    func profileForRoutine(_ job: CronSummary) -> String? {
        if let owner = job.owner { return owner.profileID }
        return routineProfileID
    }

    func requestAutomation(_ reference: RoutineReference) {
        requestedAutomationDidNavigate = false
        requestedAutomationOwner = CronOwner(profileID: reference.profileID)
        requestedAutomationJobID = reference.job.id
        automationNavigationError = nil
    }

    func requestedAutomationMatchesInventory() -> Bool {
        guard let owner = requestedAutomationOwner else { return true }
        return (owner.profileID ?? "default") == (routineProfileID ?? "default")
    }

    func routineService(profileID: String?) -> HermesWorkflowRPC? {
        rpc?.workflow(profileID: profileID)
    }

    func canTriggerRoutine(_ reference: RoutineReference) -> Bool {
        capabilityAvailable("cron.runNow") && !unavailableRoutineActions.contains("run") && !reference.running && !routineActions.contains(reference.id) && !triggeredRoutineIDs.contains(reference.id)
    }

    func routineNeedsReview(_ reference: RoutineReference) -> Bool { triggeredRoutineIDs.contains(reference.id) && !routineActions.contains(reference.id) }

    func confirmRoutineReview(_ reference: RoutineReference) async {
        guard routineNeedsReview(reference), let service = routineService(profileID: reference.profileID) else { return }
        routineActions.insert(reference.id); defer { routineActions.remove(reference.id) }
        do {
            let jobs = try await service.routineJobs()
            guard let job = jobs.first(where: { $0.id == reference.job.id }), !["running", "pending", "claimed"].contains(job.lastStatus ?? "") else {
                throw QuickDraftError.message("This routine still has a known active run. Inspect Automation.")
            }
            triggeredRoutineIDs.remove(reference.id); triggeredRoutineRevisions.removeValue(forKey: reference.id)
            routineActionErrors[reference.id] = "Review recorded. Starting another run remains a separate confirmed action."
            if reference.profileID == routineProfileID { cronJobs = jobs }
        } catch { routineActionErrors[reference.id] = Self.safeUserDiagnostic(error.localizedDescription) }
    }

    func recoverRoutine(_ reference: RoutineReference, run: Bool, paused: Bool = false) async {
        guard !routineActions.contains(reference.id), let service = routineService(profileID: reference.profileID) else { return }
        if run, !canTriggerRoutine(reference) { return }
        routineActions.insert(reference.id); routineActionErrors[reference.id] = nil
        defer { routineActions.remove(reference.id) }
        do {
            let jobs = try await service.routineJobs()
            guard let current = jobs.first(where: { $0.id == reference.job.id }), !run || !["running", "pending", "claimed"].contains(current.lastStatus ?? "") else { throw HermesGateway.GatewayError.malformedResponse }
            if run {
                triggeredRoutineIDs.insert(reference.id)
                triggeredRoutineRevisions[reference.id] = reference.job.lastRunAt ?? ""
                try await service.runRoutine(reference.job.id)
            }
            else { try await service.setRoutinePaused(reference.job.id, paused: paused) }
            let fresh = try await service.routineJobs()
            if reference.profileID == routineProfileID { cronJobs = fresh }
            refreshCronRuns()
        } catch {
            if BotService.isUnsupportedMethod(error) { unavailableRoutineActions.insert(run ? "run" : paused ? "pause" : "resume") }
            DebugLog.write("workflow: routine mutation failed or uncertain")
            routineActionErrors[reference.id] = run ? "The new run could not be confirmed. Review Automation before triggering again." : Self.safeUserDiagnostic(error.localizedDescription)
        }
    }

    func completeReminder(_ reminder: ReminderSummary) {
        guard let dockModel else { return }
        let actionID = reminderActionID(reminder)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                try await dockModel.submitControlPrompt("Using the apple-reminders skill, complete exactly this Apple Reminder and no other reminder. Reminder id: \(reminder.id). Title: \(reminder.title). Report the result after the source confirms completion.")
                try? await Task.sleep(for: .milliseconds(600))
                refresh()
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func reminder(withID id: String) -> ReminderSummary? {
        reminders.first(where: { $0.id == id })
    }

    func reconcileReminderAttention() {
        let currentIDs = Set(reminders.map(\.id))
        for id in knownAttention.keys.filter({ $0.hasPrefix("reminder:") }) {
            let reminderID = String(id.dropFirst("reminder:".count))
            if !currentIDs.contains(reminderID) {
                knownAttention.removeValue(forKey: id)
            }
        }
        for reminder in reminders {
            upsertAttention(Self.reminderAttention(for: reminder))
        }
        rebuildAttention()
    }

    func runCronNow(_ job: CronSummary) {
        let reference = RoutineReference(profileID: profileForRoutine(job), job: job, run: cronRunsByJob[job.id]?.first ?? cronRuns.first { $0.jobID == job.id })
        guard canTriggerRoutine(reference) else { lastError = "Run-now is unavailable or a run needs review."; return }
        Task { await recoverRoutine(reference, run: true) }
    }

    func refreshCronRuns(refreshGeneration: UInt64? = nil, clientIdentity: ObjectIdentifier? = nil) {
        guard let cli else { return }
        let resolvedClientIdentity = clientIdentity ?? dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let bindingGeneration = self.clientBindingGeneration
        let profile = routineProfileID
        guard isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration) else { return }
        let isCurrent: () -> Bool = {
            if let refreshGeneration {
                return self.isCurrentRefresh(refreshGeneration, clientIdentity: resolvedClientIdentity)
            }
            return self.isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration)
        }
        beginProjectionRefresh("cron.history")
        let generation = UUID()
        cronRunsGeneration = generation
        Task {
            do {
                let result = try await cli.cronRuns(profileID: profile)
                guard generation == cronRunsGeneration, isCurrent(), routineProfileID == profile else { return }
                cronHistoryAvailable = result.succeeded
                guard cronHistoryAvailable else {
                    let message = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes automation history is temporarily unavailable." : Self.safeUserDiagnostic(result.stderr)
                    recordProjectionFailure("cron.history", error: message)
                    lastError = message
                    return
                }
                cronRuns = Self.parseCronRuns(result.stdout)
                recordProjectionSuccess("cron.history")
            } catch {
                guard generation == cronRunsGeneration, isCurrent(), routineProfileID == profile else { return }
                cronHistoryAvailable = false
                let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                recordProjectionFailure("cron.history", error: message)
                lastError = message
            }
        }
    }

    func cronRunsProjectionKey(jobID: String) -> String { "cron.history.\(jobID)" }

    func refreshCronRuns(jobID: String) {
        guard let cli else { return }
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let bindingGeneration = clientBindingGeneration
        let profile = routineProfileID
        let key = cronRunsProjectionKey(jobID: jobID)
        guard projectionRefreshStates[key]?.isRefreshing != true else { return }
        beginProjectionRefresh(key)
        Task {
            do {
                let result = try await cli.cronRuns(limit: 50, jobID: jobID, profileID: profile)
                guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration), routineProfileID == profile else { return }
                guard result.succeeded else {
                    let message = Self.safeUserDiagnostic(result.stderr)
                    recordProjectionFailure(key, error: message.isEmpty ? "Hermes automation history is temporarily unavailable." : message)
                    return
                }
                cronRunsByJob[jobID] = Self.parseCronRuns(result.stdout)
                recordProjectionSuccess(key)
            } catch {
                guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration), routineProfileID == profile else { return }
                recordProjectionFailure(key, error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Report files are Hermes-private implementation detail. Keep report
    /// display unavailable until Hermes exposes a structured report operation.
    func refreshCronReports() {
        // Intentionally empty.
    }

    func createCron(name: String, schedule: String, prompt: String) async -> Bool {
        guard cronControlAvailable else {
            lastError = "Automation control is unavailable through this Hermes gateway."
            return false
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalSchedule = schedule
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !originalSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cleanPrompt.isEmpty else {
            lastError = "Name, schedule, and request are required to create an automation."
            return false
        }
        guard CronSchedule.isValid(originalSchedule) else {
            lastError = "Schedule cannot be empty or contain control characters."
            return false
        }
        let actionID = "cron.create"
        guard beginAction(actionID) else { return false }
        defer { finishAction(actionID) }
        do {
            guard let rpc else { return false }
            _ = try await rpc.createCron(name: cleanName, schedule: originalSchedule, prompt: cleanPrompt, profileID: routineProfileID)
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func removeCron(_ job: CronSummary) {
        guard cronControlAvailable else {
            lastError = "Automation control is unavailable through this Hermes gateway."
            return
        }
        let actionID = cronActionID("remove", job: job)
        guard beginAction(actionID) else { return }
        let profile = profileForRoutine(job)
        Task {
            defer { finishAction(actionID) }
            do {
                guard let rpc else { return }
                _ = try await rpc.removeCron(jobID: job.id, profileID: profile)
                refresh()
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func openCronSession(_ job: CronSummary) {
        guard let sessionID = job.sessionID, let dockModel else { return }
        dockModel.resumeSession(HermesSession(
            id: sessionID,
            profileID: profileForRoutine(job),
            title: "Automation · \(job.name)",
            preview: "",
            startedAt: nil,
            messageCount: 0,
            source: "cron"
        ))
        focus(sessionID: sessionID)
        dockModel.requestComposerFocus()
    }

    func cronReport(for request: CronReportRequest) async throws -> CronReportDetail {
        guard let rpc else {
            throw NSError(
                domain: "HermesControl",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Hermes has not recorded a report session for this job."]
            )
        }
        let result = try await rpc.sessionMessages(sessionID: request.sessionID, profileID: request.profileID)
        guard let report = Self.parseCronReport(result, job: request.job, sessionID: request.sessionID) else {
            throw NSError(
                domain: "HermesControl",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "The run completed without a readable report body."]
            )
        }
        return report
    }

    func cronReportRequest(for run: CronRunSummary) -> CronReportRequest? {
        guard let jobID = run.jobID,
              let sessionID = run.sessionID,
              let job = cronJobs.first(where: { $0.id == jobID }) else { return nil }
        return CronReportRequest(profileID: profileForRoutine(job), job: job, sessionID: sessionID)
    }

    func editCron(_ job: CronSummary, draft: CronEditDraft) {
        guard let cli, capabilityAvailable("cron.edit") else {
            lastError = "Automation editing is unavailable through the installed Hermes CLI."
            return
        }
        let changes = draft.changes(comparedTo: job).filter { job.editableFields.contains($0.key) }
        guard !changes.isEmpty else {
            lastError = "Change at least one scheduled-job field before saving."
            return
        }
        guard changes.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            lastError = "Scheduled-job fields cannot be empty in Herm."
            return
        }
        if let schedule = changes[.schedule], !CronSchedule.isValid(schedule) {
            lastError = "Schedule must use five fields: minute, hour, day, month, and weekday."
            return
        }
        let actionID = cronActionID("edit", job: job)
        guard beginAction(actionID) else { return }
        let profile = profileForRoutine(job)
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.cronEdit(jobID: job.id, changes: changes, profileID: profile)
                guard result.succeeded else {
                    lastError = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes could not edit the scheduled job." : Self.safeUserDiagnostic(result.stderr)
                    return
                }
                refresh()
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }
}
