import Foundation
import Combine

extension ControlCenterModel {
    func bind(to model: DockModel) {
        pet.bind(to: model)
        if dockModel !== model {
            refreshGeneration &+= 1
            clientBindingGeneration &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            initialProjectNavigationTask?.cancel()
            initialProjectNavigationTask = nil
            searchTask?.cancel()
            searchTask = nil
            sessionKanbanTask?.cancel()
            sessionKanbanTask = nil
            sessionKanbanRequest = nil
            isRefreshing = false
            attention = []
            reminders = []
            cronJobs = []
            routineProfileID = nil
            routineActions = []
            unavailableRoutineActions = []
            routineActionErrors = [:]
            triggeredRoutineIDs = []
            triggeredRoutineRevisions = [:]
            cronRuns = []
            cronRunsByJob = [:]
            cronHistoryAvailable = false
            mcpServers = []
            mcpTestResults = [:]
            mcpInventoryAvailable = false
            commandAllowlistEntries = nil
            activeSessions = []
            latestActivities = []
            currentFocus = nil
            activeAgents = []
            delegationPaused = false
            processes = []
            projects = []
            projectProfileID = nil
            projectIDBySessionID = [:]
            resolvedProjectIDBySessionID = [:]
            searchResults = []
            isSearching = false
            kanbanTasks = []
            globalKanbanTasks = []
            globalKanbanIsCurrent = false
            requestedKanbanTask = nil
            sessionKanbanTasks = []
            sessionKanbanSessionID = nil
            sessionKanbanTasksByRequest = [:]
            kanbanDetail = nil
            kanbanDetailTaskIdentity = nil
            kanbanDetailError = nil
            kanbanTaskInspections = [:]
            kanbanTaskInspectionGenerations = [:]
            kanbanTaskInspectionOrder = []
            kanbanStats = nil
            kanbanAssignees = []
            kanbanBoards = []
            selectedKanbanBoardSlug = nil
            journeyNodes = []
            sessionStoreStatus = nil
            memoryHealthStatus = nil
            sessionUsage = nil
            yearActivity = nil
            yearActivityGeneration = UUID()
            tokenUsageGeneration = UUID()
            tokenUsageTask?.cancel()
            tokenUsageTask = nil
            tokenUsageDays = nil
            spendRefreshTask?.cancel()
            spendRefreshTask = nil
            tokenUsage = nil
            tokenUsageModelRows = [:]
            sessionContext = nil
            sessionCockpitSessionID = nil
            providerQuotas = []
            reportedProviderQuotas = []
            kanbanDiagnostics = []
            kanbanAttachments = []
            promptBudget = nil
            projectFacts = nil
            verification = nil
            appearanceProjection = nil
            appearanceProjectionAvailable = false
            insightsSummary = nil
            checkpoints = []
            restoreCheckpoints = []
            restoreCheckpointState = .idle
            checkpointDiff = nil
            isLoadingCheckpoints = false
            emergencyStopActive = nil
            emergencyStopMessage = nil
            developmentContext = nil
            projectSessions = []
            projectSessionsByProjectID = [:]
            isRefreshingProjectNavigation = false
            didLoadInitialProjectNavigation = false
            projectNavigationRefreshGeneration = nil
            pendingProjectNavigationSessions = [:]
            completedProjectNavigationIDs = []
            projectNavigationRefreshIDs = []
            selectedProjectID = nil
            selectedProject = nil
            capabilities = []
            capabilitySnapshotGeneratedAt = .distantPast
            diagnostics = []
            lastError = nil
            pendingActionIDs = []
            knownAttention = [:]
            sessionCockpitGeneration = UUID()
            providerQuotaGeneration = UUID()
            journeyGeneration = UUID()
            projectFactsGeneration = UUID()
            verificationGeneration = UUID()
            projectSessionsGeneration = UUID()
            projectMembershipGeneration = UUID()
            cronRunsGeneration = UUID()
            mcpInventoryGeneration = UUID()
            promptBudgetGeneration = UUID()
            aggregateKanbanRefreshGeneration = UUID()
            visibleKanbanRefreshGeneration = UUID()
            queuedVisibleKanbanFilter = nil
            kanbanRefreshInFlight = []
            sessionKanbanRefreshGeneration = UUID()
            kanbanBoardsGeneration = UUID()
            kanbanStatsGeneration = UUID()
            kanbanAssigneesGeneration = UUID()
            kanbanDetailGeneration = UUID()
            kanbanDiagnosticsGeneration = UUID()
            kanbanAttachmentsGeneration = UUID()
            sessionProcessesGeneration = UUID()
            projectionRefreshStates.removeAll()
            projectionStates.removeAll()
            if let eventSubscription {
                dockModel?.eventRouter.unsubscribe(eventSubscription)
                self.eventSubscription = nil
                capabilityService.invalidate()
            }
        }
        dockModel = model
        rpc = HermesControlRPC(client: model.controlRPCClient)
        cli = HermesCLIAdapter(rpc: HermesControlRPC(client: model.controlRPCClient))
        remindersAdapter = AppleRemindersAdapter(client: model.controlRPCClient)
        focus(sessionID: model.sessionID)
        if eventSubscription == nil {
            eventSubscription = model.eventRouter.subscribe { [weak self] type, params in
                self?.ingestEvent(type, params: params)
            }
        }
        rebuildAttention()
        // Bind is the earliest point the CLI client exists. Start the global
        // board projection here so the left Kanban never depends on a tab or
        // Activity action to receive its first task list.
        refreshGlobalKanban()
    }

    /// Re-home only the profile-owned Projects projection. The old snapshot is
    /// cleared before the new request starts so rows from another Bot can
    /// never remain visible under the new header.
    func setProjectProfile(_ profileID: String?) {
        let normalized = profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = normalized?.isEmpty == false ? normalized : nil
        let nextUnavailable = next == nil
        guard projectProfileID != next || projectProfileScopeUnavailable != nextUnavailable else { return }
        projectProfileID = next
        projectProfileScopeUnavailable = nextUnavailable
        projectNavigationRefreshGeneration = nil
        projectNavigationRefreshIDs = []
        pendingProjectNavigationSessions = [:]
        completedProjectNavigationIDs = []
        projectSessionsGeneration = UUID()
        projectMembershipGeneration = UUID()
        projects = []
        projectIDBySessionID = [:]
        resolvedProjectIDBySessionID = [:]
        projectSessionsByProjectID = [:]
        selectedProjectID = nil
        selectedProject = nil
        isRefreshingProjectNavigation = false
        refresh()
    }

    func refresh(forceCapabilities: Bool = false) {
        guard !isRefreshing else { return }
        let generation = refreshGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        isRefreshing = true
        lastError = nil
        rebuildAttention()
        // The left Kanban is a global Control projection. Hydrate it with the
        // shared refresh so a relaunch or tab restoration cannot leave its
        // cards empty merely because no view-local change event fired.
        refreshGlobalKanban()
        if remindersAdapter != nil { beginProjectionRefresh("reminders") }
        if rpc != nil { ["cron.jobs", "sessions", "latest.activity", "agents", "processes", "projects"].forEach(beginProjectionRefresh) }
        if dockModel != nil { beginProjectionRefresh("core") }
        if rpc == nil {
            ["cron.jobs", "sessions", "latest.activity", "agents", "projects"].forEach(recordProjectionUnavailable)
        }
        if dockModel == nil { recordProjectionUnavailable("core") }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrentRefresh(generation, clientIdentity: clientIdentity) {
                    self.isRefreshing = false
                    self.refreshTask = nil
                }
            }
            var remindersAvailable = false
            if let remindersAdapter {
                do {
                    let fetchedReminders = try await remindersAdapter.today()
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    reminders = fetchedReminders
                    remindersAvailable = true
                    reconcileReminderAttention()
                    recordProjectionSuccess("reminders")
                } catch {
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                    recordProjectionFailure("reminders", error: message)
                    lastError = message
                }
            }

            if let rpc {
                let sessionID = dockModel?.sessionID ?? ""
                do {
                    let scope = dockModel?.profileScopeID
                    let result = try await rpc.cron(action: "list", profileID: scope)
                    var jobs = Self.parseCronJobs(result)
                    if let sessions = try? await rpc.sessions(limit: 200, profileID: scope) {
                        jobs = Self.attachLatestCronSessions(to: jobs, from: sessions)
                    }
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    guard dockModel?.profileScopeID == scope else { return }
                    if routineProfileID != scope { cronRunsByJob = [:]; cronRuns = [] }
                    routineProfileID = scope
                    cronJobs = jobs.map { job in var job = job; job.owner = CronOwner(profileID: scope); return job }
                    triggeredRoutineIDs = triggeredRoutineIDs.filter { id in
                        guard let prior = jobs.first(where: { "routine/\(scope ?? "")/\($0.id)" == id }) else { return false }
                        return (prior.lastRunAt ?? "") == triggeredRoutineRevisions[id]
                            || ["running", "pending", "claimed"].contains(prior.lastStatus ?? "")
                    }
                    recordProjectionSuccess("cron.jobs")
                } catch {
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                    recordProjectionFailure("cron.jobs", error: message)
                    lastError = message
                }

                do {
                    let result = try await rpc.activeSessions()
                    guard let parsedSessions = Self.parseSessions(result) else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    activeSessions = parsedSessions
                    establishFocusIfNeeded()
                    recordProjectionSuccess("sessions")
                } catch {
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                    recordProjectionFailure("sessions", error: message)
                    lastError = message
                }

                do {
                    try await refreshLatestActivities(rpc: rpc, generation: generation, clientIdentity: clientIdentity)
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    recordProjectionSuccess("latest.activity")
                } catch {
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                    recordProjectionFailure("latest.activity", error: message)
                }

                do {
                    let result = try await rpc.delegationStatus()
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    activeAgents = Self.parseAgents(result)
                    delegationPaused = result["paused"] as? Bool ?? delegationPaused
                    recordProjectionSuccess("agents")
                } catch {
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                    recordProjectionFailure("agents", error: message)
                    lastError = message
                }

                if !sessionID.isEmpty {
                    do {
                        let result = try await rpc.processes(sessionID: sessionID)
                        guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                        if dockModel?.sessionID == sessionID {
                            processes = Self.parseProcesses(result)
                            recordProjectionSuccess("processes")
                        }
                    } catch {
                        guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                        let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                        recordProjectionFailure("processes", error: message)
                        lastError = message
                    }
                }

                refreshMCPInventory(refreshGeneration: generation, clientIdentity: clientIdentity)
                refreshCommandAllowlist()
                refreshAppearanceProjection(refreshGeneration: generation, clientIdentity: clientIdentity)
                refreshInsights(refreshGeneration: generation, clientIdentity: clientIdentity)

                if projectProfileScopeUnavailable {
                    projects = []
                    projectIDBySessionID = [:]
                    resolvedProjectIDBySessionID = [:]
                    projectSessionsByProjectID = [:]
                    selectedProject = nil
                    recordProjectionSuccess("projects")
                } else {
                do {
                    let result = try await rpc.projectsTree(profileID: projectProfileID)
                    let parsedProjects = Self.parseProjects(result)
                    let refreshedProjects = Self.reconcileProjectRefresh(current: projects, incoming: parsedProjects)
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    projects = refreshedProjects
                    let validProjectIDs = Set(refreshedProjects.map(\.id))
                    projectSessionsByProjectID = projectSessionsByProjectID.filter { validProjectIDs.contains($0.key) }
                    // A compact tree response may provide only session counts.
                    // Keep memberships already verified through
                    // `projects.project_sessions` as long as their project is
                    // still present, then enrich them with inline rows.
                    var memberships = resolvedProjectIDBySessionID.filter { validProjectIDs.contains($0.value) }
                    for project in refreshedProjects {
                        for sessionID in project.sessionIDs {
                            memberships[sessionID] = project.id
                        }
                    }
                    resolvedProjectIDBySessionID = memberships
                    projectIDBySessionID = memberships
                    if let selectedProjectID,
                       let refreshedSelection = refreshedProjects.first(where: { $0.id == selectedProjectID }) {
                        selectedProject = refreshedSelection
                    }
                    // The projects projection can complete after focus was
                    // set (or before a dock model is bound). Resolve against
                    // the focused session, which is the authoritative UI
                    // selection for this model.
                    resolveProjectMembership(for: currentFocus?.sessionID)
                    if !refreshedProjects.isEmpty, projectProfileID != nil {
                        refreshProjectNavigation(refreshProjects: false)
                    }
                    recordProjectionSuccess("projects")
                } catch {
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                    recordProjectionFailure("projects", error: message)
                    lastError = message
                }
                }
            }
            refreshCronRuns(refreshGeneration: generation, clientIdentity: clientIdentity)

            if let dockModel {
                let probedCapabilities = await capabilityService.probe(
                    client: dockModel.controlRPCClient,
                    remindersAvailable: remindersAvailable,
                    sessionID: dockModel.sessionID,
                    forceRefresh: forceCapabilities
                )
                guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                capabilities = probedCapabilities
                capabilitySnapshotGeneratedAt = .now
                // Activity may mount before the bounded capability probe finishes.
                // Refresh here, at the ownership boundary, so a successful Kanban
                // probe immediately hydrates the focused session projection rather
                // than leaving the renderer to wait for its next polling interval.
                if capabilityAvailable("kanban"), let sessionID = dockModel.kanbanSessionID {
                    refreshSessionKanban(for: sessionID)
                }
                if forceCapabilities || diagnostics.isEmpty {
                    let refreshedDiagnostics = await diagnosticsService.read(client: dockModel.controlRPCClient)
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    diagnostics = refreshedDiagnostics
                }
                if forceCapabilities || sessionStoreStatus == nil || memoryHealthStatus == nil {
                    refreshReadOnlyHealth()
                }
                refreshSessionCockpit(for: dockModel.sessionID)
                // Provider quota is refreshed when the Quota tab is opened. Antigravity
                // quota scans for a running language server, so it stays lazy instead
                // of adding subprocess churn to every startup.
                refreshPromptBudget()
                refreshVerification()
                recordProjectionSuccess("core")
            }
        }
    }
}
