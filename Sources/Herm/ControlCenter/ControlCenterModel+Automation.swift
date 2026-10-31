import Combine
import Foundation

extension ControlCenterModel {
    var routineReferences: [RoutineReference] {
        cronJobs.map { job in
            RoutineReference(
                profileID: routineProfileID, job: job,
                run: (cronRunsByJob[job.id] ?? cronRuns.filter { $0.jobID == job.id }).first)
        }
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
        (cronControlAvailable || capabilityAvailable("cron.runNow")) && !unavailableRoutineActions.contains("run")
            && !reference.running && !routineActions.contains(reference.id)
            && !routineRunRequestIDs.contains(reference.id)
            && !triggeredRoutineIDs.contains(reference.id)
    }

    func routineNeedsReview(_ reference: RoutineReference) -> Bool {
        triggeredRoutineIDs.contains(reference.id) && !routineActions.contains(reference.id)
    }

    func confirmRoutineReview(_ reference: RoutineReference) async {
        guard routineNeedsReview(reference), let service = routineService(profileID: reference.profileID) else {
            return
        }
        routineActions.insert(reference.id)
        defer { routineActions.remove(reference.id) }
        do {
            let jobs = try await service.routineJobs()
            guard let job = jobs.first(where: { $0.id == reference.job.id }),
                !["running", "pending", "claimed"].contains(job.lastStatus ?? "")
            else {
                throw QuickDraftError.message("This routine still has a known active run. Inspect Automation.")
            }
            triggeredRoutineIDs.remove(reference.id)
            uncertainRoutineIDs.remove(reference.id)
            triggeredRoutineRevisions.removeValue(forKey: reference.id)
            routineActionErrors[reference.id] =
                "Review recorded. Starting another run remains a separate confirmed action."
            if reference.profileID == routineProfileID {
                await refreshRoutineInventory(profileID: reference.profileID, fresh: true)
            }
        } catch {
            routineActionErrors[reference.id] = Self.safeUserDiagnostic(error.localizedDescription)
            DockActionErrorCenter.shared.report("Could not review routine", error: error)
        }
    }

    func recoverRoutine(_ reference: RoutineReference, run: Bool, paused: Bool = false, reserved: Bool = false) async {
        guard !routineActions.contains(reference.id), let service = routineService(profileID: reference.profileID)
        else {
            if reserved { routineRunRequestIDs.remove(reference.id) }
            return
        }
        if run, !reserved, !canTriggerRoutine(reference) { return }
        let bindingGeneration = clientBindingGeneration
        if run { routineRunRequestIDs.insert(reference.id) }
        routineActions.insert(reference.id)
        routineActionErrors[reference.id] = nil
        defer {
            if clientBindingGeneration == bindingGeneration {
                routineActions.remove(reference.id)
                if run { routineRunRequestIDs.remove(reference.id) }
            }
        }
        var triggerSent = false
        do {
            let jobs = try await service.routineJobs()
            guard clientBindingGeneration == bindingGeneration else { return }
            guard let current = jobs.first(where: { $0.id == reference.job.id }),
                !run || !["running", "pending", "claimed"].contains(current.lastStatus ?? "")
            else { throw HermesGateway.GatewayError.malformedResponse }
            if run {
                triggeredRoutineIDs.insert(reference.id)
                triggeredRoutineRevisions[reference.id] = current.lastRunAt ?? ""
                triggerSent = true
                let monitor = Task {
                    while !Task.isCancelled, clientBindingGeneration == bindingGeneration,
                        routineProfileID == reference.profileID
                    {
                        guard await refreshRoutineProgress(jobID: reference.job.id, profileID: reference.profileID)
                        else { return }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    }
                }
                defer { monitor.cancel() }
                try await service.runRoutine(reference.job.id)
            } else {
                try await service.setRoutinePaused(reference.job.id, paused: paused)
            }
            guard clientBindingGeneration == bindingGeneration else { return }
            if reference.profileID == routineProfileID {
                await refreshRoutineInventory(profileID: reference.profileID, fresh: true)
                refreshCronRuns()
                refreshCronRuns(jobID: reference.job.id)
            }
        } catch {
            guard clientBindingGeneration == bindingGeneration else { return }
            if run && triggerSent { uncertainRoutineIDs.insert(reference.id) }
            if BotService.isUnsupportedMethod(error) {
                unavailableRoutineActions.insert(run ? "run" : paused ? "pause" : "resume")
            }
            DebugLog.write("workflow: routine mutation failed or uncertain")
            routineActionErrors[reference.id] =
                run && triggerSent
                ? "The new run could not be confirmed. Review Automation before triggering again."
                : Self.safeUserDiagnostic(error.localizedDescription)
            DockActionErrorCenter.shared.report(
                "Routine action failed", message: routineActionErrors[reference.id] ?? "")
        }
    }

    func completeReminder(_ reminder: ReminderSummary) {
        guard let dockModel else { return }
        let actionID = reminderActionID(reminder)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                try await dockModel.submitControlPrompt(
                    "Using the apple-reminders skill, complete exactly this Apple Reminder and no other reminder. Reminder id: \(reminder.id). Title: \(reminder.title). Report the result after the source confirms completion."
                )
                try? await Task.sleep(for: .milliseconds(600))
                refresh()
            } catch {
                reportActionError(
                    "Could not complete reminder",
                    message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
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
        let reference = RoutineReference(
            profileID: profileForRoutine(job), job: job,
            run: cronRunsByJob[job.id]?.first ?? cronRuns.first { $0.jobID == job.id })
        guard canTriggerRoutine(reference) else {
            reportActionError("Could not run automation", message: "Run-now is unavailable or a run needs review.")
            return
        }
        routineRunRequestIDs.insert(reference.id)
        Task { await recoverRoutine(reference, run: true, reserved: true) }
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
                    let message =
                        Self.safeUserDiagnostic(result.stderr).isEmpty
                        ? "Hermes automation history is temporarily unavailable."
                        : Self.safeUserDiagnostic(result.stderr)
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

    func cronRunsProjectionKey(jobID: String) -> String { "cron.history.\(routineProfileID ?? "")/\(jobID)" }

    func refreshCronRuns(jobID: String) {
        guard let rpc else { return }
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let bindingGeneration = clientBindingGeneration
        let profile = routineProfileID
        let key = cronRunsProjectionKey(jobID: jobID)
        guard projectionRefreshStates[key]?.isRefreshing != true else { return }
        beginProjectionRefresh(key)
        Task {
            do {
                let runs = try await rpc.cronJobRuns(jobID: jobID, profileID: profile)
                guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration), routineProfileID == profile
                else { return }
                cronRunsByJob[jobID] = runs
                recordProjectionSuccess(key)
            } catch {
                guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration), routineProfileID == profile
                else { return }
                recordProjectionFailure(key, error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Report files are Hermes-private implementation detail. Keep report
    /// display unavailable until Hermes exposes a structured report operation.
    func refreshCronReports() {
        // Intentionally empty.
    }

    /// Delivery destinations and model overrides for the create form. A failed read yields an empty list, so the
    /// form offers only `local` and the default model rather than inventing choices.
    func cronDeliveryTargets(profileID: String?) async -> [CronDeliveryTarget] {
        (try? await rpc?.cronDeliveryTargets(profileID: profileID)) ?? []
    }

    func cronBlueprints(profileID: String?) async -> [CronBlueprint] {
        (try? await rpc?.cronBlueprints(profileID: profileID)) ?? []
    }

    /// Creates a job from a blueprint's filled slots. Slot errors from Hermes (HTTP 422) are shown as sent.
    func createCronFromBlueprint(_ blueprint: CronBlueprint, values: [String: String], profileID: String? = nil) async
        -> Bool
    {
        guard cronControlAvailable, let rpc else {
            reportActionError(
                "Could not create automation", message: "Automation control is unavailable through this Hermes gateway."
            )
            return false
        }
        let actionID = "cron.create"
        guard beginAction(actionID) else { return false }
        let viewedProfile = routineProfileID
        let profile = profileID ?? viewedProfile
        let bindingGeneration = clientBindingGeneration
        defer { if clientBindingGeneration == bindingGeneration { finishAction(actionID) } }
        lastCreatedCronJobID = nil
        lastError = nil
        do {
            let created = try await rpc.instantiateCronBlueprint(
                key: blueprint.key, values: values, profileID: profile)
            if clientBindingGeneration == bindingGeneration, routineProfileID == viewedProfile {
                lastCreatedCronJobID = created.id
                if profile == viewedProfile {
                    cronJobs.removeAll { $0.id == created.id }
                    cronJobs.append(created)
                }
                refresh()
            }
            return true
        } catch {
            if clientBindingGeneration == bindingGeneration {
                reportActionError(
                    "Could not create automation",
                    message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            }
            return false
        }
    }

    func cronModelProviders(profileID: String?) async -> [CronModelProvider] {
        (try? await rpc?.cronModelProviders()) ?? []
    }

    /// `profileID` creates the job under another bot's profile; nil keeps the profile the list is showing.
    func createCron(
        name: String, schedule: String, prompt: String, configuration: CronConfigurationDraft? = nil,
        profileID: String? = nil
    ) async -> Bool {
        guard cronControlAvailable else {
            reportActionError(
                "Could not create automation", message: "Automation control is unavailable through this Hermes gateway."
            )
            return false
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalSchedule = schedule
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalSchedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cleanPrompt.isEmpty else {
            reportActionError(
                "Could not create automation",
                message: "Schedule and request are required to create an automation.")
            return false
        }
        guard CronSchedule.isValid(originalSchedule) else {
            reportActionError(
                "Could not create automation", message: "Schedule cannot be empty or contain control characters.")
            return false
        }
        let actionID = "cron.create"
        guard beginAction(actionID) else { return false }
        let viewedProfile = routineProfileID
        let profile = profileID ?? viewedProfile
        let bindingGeneration = clientBindingGeneration
        defer { if clientBindingGeneration == bindingGeneration { finishAction(actionID) } }
        lastCreatedCronJobID = nil
        lastError = nil
        do {
            guard let rpc else { return false }
            if let configuration {
                let created = try await rpc.createCron(
                    name: cleanName, schedule: originalSchedule, prompt: cleanPrompt, configuration: configuration,
                    profileID: profile)
                if clientBindingGeneration == bindingGeneration, routineProfileID == viewedProfile {
                    lastCreatedCronJobID = created.id
                    if profile == viewedProfile {
                        cronJobs.removeAll { $0.id == created.id }
                        cronJobs.append(created)
                    }
                }
            } else {
                let result = try await rpc.createCron(
                    name: cleanName, schedule: originalSchedule, prompt: cleanPrompt, profileID: profile)
                if clientBindingGeneration == bindingGeneration, routineProfileID == viewedProfile {
                    lastCreatedCronJobID = result["job_id"] as? String
                }
            }
            if clientBindingGeneration == bindingGeneration, routineProfileID == viewedProfile { refresh() }
            return true
        } catch {
            if clientBindingGeneration == bindingGeneration {
                reportActionError(
                    "Could not create automation",
                    message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            }
            return false
        }
    }

    func removeCron(_ job: CronSummary) {
        guard cronControlAvailable, let rpc else {
            reportActionError(
                "Could not delete automation", message: "Automation control is unavailable through this Hermes gateway."
            )
            return
        }
        let bindingGeneration = clientBindingGeneration
        let actionID = cronActionID("remove", job: job)
        guard beginAction(actionID) else { return }
        let profile = profileForRoutine(job)
        let referenceID = RoutineReference(profileID: profile, job: job, run: nil).id
        routineActionErrors[referenceID] = nil
        Task {
            guard clientBindingGeneration == bindingGeneration else { return }
            defer { if clientBindingGeneration == bindingGeneration { finishAction(actionID) } }
            do {
                _ = try await rpc.removeCron(jobID: job.id, profileID: profile)
                guard clientBindingGeneration == bindingGeneration else { return }
                refresh()
            } catch {
                guard clientBindingGeneration == bindingGeneration else { return }
                let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                routineActionErrors[referenceID] = message
                reportActionError("Could not delete automation", message: message)
            }
        }
    }

    func openCronSession(_ job: CronSummary) {
        guard let sessionID = job.sessionID, let dockModel else { return }
        dockModel.resumeSession(
            HermesSession(
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
            let job = cronJobs.first(where: { $0.id == jobID })
        else { return nil }
        return CronReportRequest(profileID: profileForRoutine(job), job: job, sessionID: sessionID)
    }

    func loadCronDetail(_ job: CronSummary) async throws -> CronSummary {
        guard let rpc else { throw HermesGateway.GatewayError.disconnected }
        return try await rpc.cronJob(job, profileID: profileForRoutine(job))
    }

    func editCron(_ job: CronSummary, draft: CronEditDraft) async -> Bool {
        guard let rpc else {
            reportActionError(
                "Could not edit automation", message: "Automation editing is unavailable through this Hermes gateway.")
            return false
        }
        let changes = draft.changes(comparedTo: job)
        guard !changes.isEmpty else {
            reportActionError("Could not edit automation", message: "Change at least one field before saving.")
            return false
        }
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            CronSchedule.isValid(draft.schedule),
            changes[.prompt]?.trimmingCharacters(in: .whitespacesAndNewlines) != "" || job.details.noAgent == true
                || !job.details.skills.isEmpty,
            !draft.configuration.delivery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            reportActionError(
                "Could not edit automation", message: "Name, schedule, delivery, and agent request cannot be empty.")
            return false
        }
        let actionID = cronActionID("edit", job: job)
        guard beginAction(actionID) else { return false }
        defer { finishAction(actionID) }
        let profile = profileForRoutine(job)
        let bindingGeneration = clientBindingGeneration
        do {
            try await rpc.updateCron(job, draft: draft, profileID: profile)
            if clientBindingGeneration == bindingGeneration, routineProfileID == profile { refresh() }
            return true
        } catch {
            reportActionError(
                "Could not edit automation",
                message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            return false
        }
    }
}
