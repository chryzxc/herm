import Foundation

@MainActor
final class ControlCenterModel: ObservableObject {
    @Published private(set) var attention: [AttentionItem] = []
    @Published private(set) var reminders: [ReminderSummary] = []
    @Published private(set) var cronJobs: [CronSummary] = []
    @Published private(set) var cronRuns: [CronRunSummary] = []
    @Published private(set) var cronHistoryAvailable = false
    @Published private(set) var mcpServers: [MCPServerSummary] = []
    @Published private(set) var mcpTestResults: [String: String] = [:]
    @Published private(set) var mcpInventoryAvailable = false
    @Published private(set) var activeSessions: [SessionSummary] = []
    @Published private(set) var currentFocus: ControlReference?
    @Published private(set) var activeAgents: [AgentSummary] = []
    @Published private(set) var delegationPaused = false
    @Published private(set) var processes: [ProcessSummary] = []
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var projectIDBySessionID: [String: String] = [:]
    @Published private(set) var searchResults: [ControlSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var kanbanTasks: [KanbanTaskSummary] = []
    @Published private(set) var sessionKanbanTasks: [KanbanTaskSummary] = []
    @Published private(set) var sessionKanbanSessionID: String?
    @Published private(set) var kanbanDetail: KanbanTaskDetail?
    @Published private(set) var kanbanStats: KanbanStatsSummary?
    @Published private(set) var kanbanAssignees: [String] = []
    @Published private(set) var kanbanBoards: [KanbanBoardSummary] = []
    @Published private(set) var selectedKanbanBoardSlug: String?
    @Published private(set) var kanbanFilter = KanbanListFilter()
    @Published private(set) var journeyNodes: [HermesJourneyNode] = []
    @Published private(set) var sessionStoreStatus: HermesReadOnlyStatus?
    @Published private(set) var memoryHealthStatus: HermesReadOnlyStatus?
    @Published private(set) var sessionUsage: SessionUsageSummary?
    @Published private(set) var sessionContext: SessionContextSummary?
    @Published private(set) var providerQuota: ProviderQuotaSnapshot?
    @Published private(set) var providerQuotas: [ProviderQuotaSnapshot] = []
    @Published private(set) var kanbanDiagnostics: [KanbanDiagnosticSummary] = []
    @Published private(set) var kanbanAttachments: [KanbanAttachmentSummary] = []
    @Published private(set) var promptBudget: PromptBudgetSummary?
    @Published private(set) var projectFacts: ProjectFactsSummary?
    @Published private(set) var verification: VerificationSummary?
    @Published private(set) var developmentContext: RepositorySnapshot?
    @Published private(set) var isLoadingKanbanDetail = false
    @Published private(set) var isCreatingKanbanTask = false
    @Published private(set) var projectSessions: [SessionSummary] = []
    @Published private(set) var selectedProjectID: String?
    /// Keeps the Projects detail view stable while its background projection is
    /// refreshing. A selected project can briefly be absent from a partial
    /// `projects.tree` response, but that must not dismiss the user's detail.
    @Published private(set) var selectedProject: ProjectSummary?
    @Published private(set) var capabilities: [CapabilityState] = []
    @Published private(set) var diagnostics: [HermesDiagnostic] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var pendingActionIDs: Set<String> = []
    @Published private(set) var lastError: String?
    @Published private(set) var projectionRefreshStates: [String: ProjectionRefreshState] = [:]

    private weak var dockModel: DockModel?
    private var rpc: HermesControlRPC?
    private var cli: HermesCLIAdapter?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var kanbanRefreshGeneration = UUID()
    private var kanbanProjectionBoardSlug: String?
    private var sessionKanbanRefreshGeneration = UUID()
    private var sessionKanbanTask: Task<Void, Never>?
    private var sessionKanbanBoardSlug: String?
    private var kanbanBoardsGeneration = UUID()
    private var kanbanStatsGeneration = UUID()
    private var kanbanAssigneesGeneration = UUID()
    private var kanbanDetailGeneration = UUID()
    private var kanbanDiagnosticsGeneration = UUID()
    private var kanbanAttachmentsGeneration = UUID()
    private var promptBudgetGeneration = UUID()
    private var projectFactsGeneration = UUID()
    private var verificationGeneration = UUID()
    private var projectSessionsGeneration = UUID()
    private var projectMembershipGeneration = UUID()
    private var cronRunsGeneration = UUID()
    private var mcpInventoryGeneration = UUID()
    private var journeyGeneration = UUID()
    private var sessionCockpitGeneration = UUID()
    private var providerQuotaGeneration = UUID()
    private var sessionCockpitSessionID: String?
    private var sessionProcessesGeneration = UUID()
    private var knownAttention: [String: AttentionItem] = [:]
    private var eventSubscription: UUID?
    private let capabilityService = HermesCapabilityService()
    private let diagnosticsService = HermesDiagnosticsService()
    private var remindersAdapter: AppleRemindersAdapter?
    private let presentationDefaults = UserDefaults.standard
    private let presentationKey = "hermes.control.attention.presentation.v1"
    private let snoozeKey = "hermes.control.attention.snooze.v1"
    private struct QuotaReadResult: @unchecked Sendable {
        let value: [String: Any]?
        let error: String?
    }

    var todaySnapshot: TodaySnapshot {
        TodaySnapshot(
            currentFocus: currentFocus,
            attention: attention,
            dueReminders: reminders,
            activeSessions: activeSessions,
            activeAgents: activeAgents,
            scheduledJobs: cronJobs,
            developmentContext: developmentContext
        )
    }

    func capabilityAvailable(_ id: String) -> Bool {
        capabilities.first(where: { $0.id == id })?.isAvailable == true
    }

    /// The workspace store owns repository selection. The control center keeps
    /// only this rendered snapshot for its Today projection.
    func setDevelopmentContextProjection(_ snapshot: RepositorySnapshot?) {
        developmentContext = snapshot
        refreshVerification()
    }

    func isActionPending(_ id: String) -> Bool {
        pendingActionIDs.contains(id)
    }

    func sessionSteerActionID(_ sessionID: String) -> String {
        "session.steer:\(sessionID)"
    }

    func refreshState(for projection: String) -> ProjectionRefreshState? {
        projectionRefreshStates[projection]
    }

    private func beginProjectionRefresh(_ projection: String) {
        let previous = projectionRefreshStates[projection]
        projectionRefreshStates[projection] = ProjectionRefreshState(
            lastSuccess: previous?.lastSuccess,
            error: previous?.error,
            isStale: previous?.lastSuccess != nil,
            isRefreshing: true
        )
    }

    private func recordProjectionSuccess(_ projection: String) {
        projectionRefreshStates[projection] = ProjectionRefreshState(lastSuccess: .now, error: nil, isStale: false, isRefreshing: false)
    }

    private func recordProjectionFailure(_ projection: String, error: String) {
        let previous = projectionRefreshStates[projection]
        projectionRefreshStates[projection] = ProjectionRefreshState(
            lastSuccess: previous?.lastSuccess,
            error: error,
            isStale: previous?.lastSuccess != nil,
            isRefreshing: false
        )
    }

    func cronActionID(_ action: String, job: CronSummary) -> String { "cron.\(action):\(job.id)" }
    func kanbanActionID(_ action: KanbanTaskAction, task: KanbanTaskSummary) -> String { "kanban.\(action.rawValue):\(task.id)" }
    func kanbanActionID(_ action: KanbanMutationKind, task: KanbanTaskSummary) -> String { "kanban.\(action.rawValue):\(task.id)" }
    func attentionActionID(_ action: AttentionAction, item: AttentionItem) -> String { "attention.\(action.rawValue):\(item.id)" }
    func reminderActionID(_ reminder: ReminderSummary) -> String { "reminder.complete:\(reminder.id)" }
    func mcpTestActionID(_ server: MCPServerSummary) -> String { "mcp.test:\(server.id)" }
    var reloadMCPActionID: String { "mcp.reload" }
    var refreshKanbanActionID: String { "kanban.refresh" }
    var refreshKanbanBoardsActionID: String { "kanban.boards.refresh" }

    private func beginAction(_ id: String) -> Bool {
        guard !pendingActionIDs.contains(id) else { return false }
        pendingActionIDs.insert(id)
        return true
    }

    private func finishAction(_ id: String) {
        pendingActionIDs.remove(id)
    }

    init(rpc: HermesControlRPC? = nil, capabilities: [CapabilityState] = []) {
        self.rpc = rpc
        self.cli = rpc.map(HermesCLIAdapter.init)
        self.capabilities = capabilities
        let stored = presentationDefaults.dictionary(forKey: presentationKey) as? [String: String] ?? [:]
        let storedSnoozes = presentationDefaults.dictionary(forKey: snoozeKey) as? [String: Double] ?? [:]
        for (id, rawState) in stored {
            if let state = AttentionState(rawValue: rawState) {
                let snoozedUntil = storedSnoozes[id].map(Date.init(timeIntervalSince1970:))
                let effectiveState: AttentionState = state == .snoozed && (snoozedUntil ?? .distantPast) <= .now ? .open : state
                knownAttention[id] = AttentionItem(
                    id: id,
                    reference: Self.restoredAttentionReference(for: id),
                    kind: .completed,
                    title: "Previously reviewed item",
                    detail: "This item will return if Hermes reports it again.",
                    createdAt: Date.distantPast,
                    state: effectiveState,
                    actions: [.open]
                )
            }
        }
    }

    /// Presentation state only stores the stable attention ID. Reconstruct the
    /// original source reference so actions on a restored row still target the
    /// Hermes session that produced it.
    static func restoredAttentionReference(for id: String) -> ControlReference {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return ControlReference(source: .hermesSession, sourceID: id, sessionID: id)
        }

        let sourceID = parts[1]
        switch parts[0] {
        case "approval":
            return ControlReference(source: .hermesApproval, sourceID: sourceID, sessionID: sourceID)
        case "clarification":
            return ControlReference(source: .hermesClarification, sourceID: sourceID, sessionID: sourceID)
        case "failure", "completed":
            return ControlReference(source: .hermesSession, sourceID: sourceID, sessionID: sourceID)
        case "reminder":
            return ControlReference(source: .appleReminder, sourceID: sourceID)
        case "cron":
            return ControlReference(source: .hermesCronJob, sourceID: sourceID)
        case "project":
            return ControlReference(source: .hermesProject, sourceID: sourceID, projectID: sourceID)
        default:
            return ControlReference(source: .hermesSession, sourceID: sourceID, sessionID: sourceID)
        }
    }

    func attention(for sessionID: String?) -> [AttentionItem] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        return attention.filter { $0.reference.sessionID == sessionID }
    }

    func openAttention(for sessionID: String?) -> [AttentionItem] {
        attention(for: sessionID).filter { $0.state == .open }
    }

    func bind(to model: DockModel) {
        if dockModel !== model, let eventSubscription {
            dockModel?.eventRouter.unsubscribe(eventSubscription)
            self.eventSubscription = nil
            capabilityService.invalidate()
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
    }

    func refresh(forceCapabilities: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        rebuildAttention()
        if remindersAdapter != nil { beginProjectionRefresh("reminders") }
        if rpc != nil { ["cron.jobs", "sessions", "agents", "processes", "projects"].forEach(beginProjectionRefresh) }
        if dockModel != nil { beginProjectionRefresh("core") }

        Task { [weak self] in
            guard let self else { return }
            defer { isRefreshing = false }
            var remindersAvailable = false
            if let remindersAdapter {
                do {
                    reminders = try await remindersAdapter.today()
                    remindersAvailable = true
                    reconcileReminderAttention()
                    recordProjectionSuccess("reminders")
                } catch {
                    let message = error.localizedDescription
                    recordProjectionFailure("reminders", error: message)
                    lastError = message
                }
            }

            if let rpc {
                let sessionID = dockModel?.sessionID ?? ""
                do {
                    let result = try await rpc.cron(action: "list")
                    var jobs = Self.parseCronJobs(result)
                    if let sessions = try? await rpc.sessions(limit: 200) {
                        jobs = Self.attachLatestCronSessions(to: jobs, from: sessions)
                    }
                    cronJobs = jobs
                    recordProjectionSuccess("cron.jobs")
                } catch {
                    let message = error.localizedDescription
                    recordProjectionFailure("cron.jobs", error: message)
                    lastError = message
                }

                do {
                    let result = try await rpc.activeSessions()
                    activeSessions = Self.parseSessions(result)
                    establishFocusIfNeeded()
                    recordProjectionSuccess("sessions")
                } catch {
                    let message = error.localizedDescription
                    recordProjectionFailure("sessions", error: message)
                    lastError = message
                }

                do {
                    let result = try await rpc.delegationStatus()
                    activeAgents = Self.parseAgents(result)
                    delegationPaused = result["paused"] as? Bool ?? delegationPaused
                    recordProjectionSuccess("agents")
                } catch {
                    let message = error.localizedDescription
                    recordProjectionFailure("agents", error: message)
                    lastError = message
                }

                if !sessionID.isEmpty {
                    do {
                        let result = try await rpc.processes(sessionID: sessionID)
                        if dockModel?.sessionID == sessionID {
                            processes = Self.parseProcesses(result)
                            recordProjectionSuccess("processes")
                        }
                    } catch {
                        let message = error.localizedDescription
                        recordProjectionFailure("processes", error: message)
                        lastError = message
                    }
                }

                refreshMCPInventory()

                do {
                    let result = try await rpc.projectsTree()
                    let refreshedProjects = Self.parseProjects(result)
                    projects = refreshedProjects
                    let validProjectIDs = Set(refreshedProjects.map(\.id))
                    // A compact tree response may provide only session counts.
                    // Keep memberships already verified through
                    // `projects.project_sessions` as long as their project is
                    // still present, then enrich them with inline rows.
                    var memberships = projectIDBySessionID.filter { validProjectIDs.contains($0.value) }
                    for project in refreshedProjects {
                        for sessionID in project.sessionIDs {
                            memberships[sessionID] = project.id
                        }
                    }
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
                    recordProjectionSuccess("projects")
                } catch {
                    let message = error.localizedDescription
                    recordProjectionFailure("projects", error: message)
                    lastError = message
                }
            }
            refreshCronRuns()

            if let dockModel {
                capabilities = await capabilityService.probe(
                    client: dockModel.controlRPCClient,
                    remindersAvailable: remindersAvailable,
                    sessionID: dockModel.sessionID,
                    forceRefresh: forceCapabilities
                )
                if forceCapabilities || diagnostics.isEmpty {
                    diagnostics = await diagnosticsService.read(client: dockModel.controlRPCClient)
                }
                if forceCapabilities || sessionStoreStatus == nil || memoryHealthStatus == nil {
                    refreshReadOnlyHealth()
                }
                refreshSessionCockpit(for: dockModel.sessionID)
                refreshProviderQuota()
                refreshPromptBudget()
                refreshVerification()
                recordProjectionSuccess("core")
            }
        }
    }

    /// Loads the stored Codex account quota through Codex's authenticated usage endpoint,
    /// independently of the active Hermes provider/model.
    func refreshProviderQuota() {
        let generation = UUID()
        providerQuotaGeneration = generation
        guard dockModel != nil else {
            providerQuota = nil
            providerQuotas = []
            return
        }
        beginProjectionRefresh("provider.quota")
        Task { @MainActor in
            async let codexResult = Self.readQuota(CodexQuotaService.read)
            async let openCodeResult = Self.readQuota(OpenCodeQuotaService.read)
            async let glmResult = Self.readQuota(GLMQuotaService.read)
            async let claudeResult = Self.readQuota(ClaudeQuotaService.read)
            let results = await [codexResult, openCodeResult, glmResult, claudeResult]
            guard generation == providerQuotaGeneration else { return }
            let snapshots = results.compactMap { result -> ProviderQuotaSnapshot? in
                guard let raw = result.value else { return nil }
                return Self.parseProviderQuota(raw)
            }
            if !snapshots.isEmpty {
                providerQuotas = snapshots
                providerQuota = snapshots.first(where: { $0.provider == "codex" })
                recordProjectionSuccess("provider.quota")
            } else {
                providerQuota = nil
                providerQuotas = []
                let errors = results.compactMap(\.error)
                recordProjectionFailure("provider.quota", error: errors.first ?? "Provider quota data is unavailable.")
            }
        }
    }

    private nonisolated static func readQuota(_ read: @Sendable () async throws -> [String: Any]) async -> QuotaReadResult {
        do { return QuotaReadResult(value: try await read(), error: nil) }
        catch { return QuotaReadResult(value: nil, error: error.localizedDescription) }
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
                lastError = error.localizedDescription
            }
        }
    }

    func reminder(withID id: String) -> ReminderSummary? {
        reminders.first(where: { $0.id == id })
    }

    private func reconcileReminderAttention() {
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
        guard let cli, capabilityAvailable("cron.runNow") else {
            lastError = "Run-now is unavailable through the installed Hermes CLI."
            return
        }
        let actionID = cronActionID("run", job: job)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.cronRun(jobID: job.id)
                guard result.succeeded else {
                    lastError = result.stderr.isEmpty ? "Hermes could not run the scheduled job." : result.stderr
                    return
                }
                refreshCronRuns()
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshCronRuns() {
        guard let cli else { return }
        beginProjectionRefresh("cron.history")
        let generation = UUID()
        cronRunsGeneration = generation
        Task {
            do {
                let result = try await cli.cronRuns()
                guard generation == cronRunsGeneration else { return }
                cronHistoryAvailable = result.succeeded
                guard cronHistoryAvailable else {
                    let message = result.stderr.isEmpty ? "Hermes cron history is temporarily unavailable." : result.stderr
                    recordProjectionFailure("cron.history", error: message)
                    lastError = message
                    return
                }
                cronRuns = Self.parseCronRuns(result.stdout)
                recordProjectionSuccess("cron.history")
            } catch {
                guard generation == cronRunsGeneration else { return }
                cronHistoryAvailable = false
                let message = error.localizedDescription
                recordProjectionFailure("cron.history", error: message)
                lastError = message
            }
        }
    }

    /// Report files are Hermes-private implementation detail. Keep report
    /// display unavailable until Hermes exposes a structured report operation.
    func refreshCronReports() {
        // Intentionally empty.
    }

    func refreshMCPInventory() {
        guard let cli else { return }
        beginProjectionRefresh("mcp.inventory")
        let generation = UUID()
        mcpInventoryGeneration = generation
        Task {
            do {
                let result = try await cli.mcpList()
                guard generation == mcpInventoryGeneration else { return }
                mcpInventoryAvailable = result.succeeded
                guard mcpInventoryAvailable else {
                    let message = result.stderr.isEmpty ? "Hermes MCP inventory is temporarily unavailable." : result.stderr
                    recordProjectionFailure("mcp.inventory", error: message)
                    lastError = message
                    return
                }
                mcpServers = Self.parseMCPServers(result.stdout)
                recordProjectionSuccess("mcp.inventory")
            } catch {
                guard generation == mcpInventoryGeneration else { return }
                mcpInventoryAvailable = false
                let message = error.localizedDescription
                recordProjectionFailure("mcp.inventory", error: message)
                lastError = message
            }
        }
    }

    func testMCP(_ server: MCPServerSummary) {
        guard let cli, capabilityAvailable("mcp.test") else {
            mcpTestResults[server.id] = "MCP testing is unavailable through the installed Hermes CLI."
            return
        }
        let actionID = mcpTestActionID(server)
        guard beginAction(actionID) else { return }
        mcpTestResults[server.id] = "Testing connection…"
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.mcpTest(name: server.name)
                let output = HermesDiagnosticsService.safeSummary(result.succeeded ? result.stdout : result.stderr)
                mcpTestResults[server.id] = result.succeeded
                    ? (output.isEmpty ? "Connection succeeded." : output)
                    : (output.isEmpty ? "Connection failed." : output)
            } catch {
                mcpTestResults[server.id] = error.localizedDescription
            }
        }
    }

    func createCron(name: String, schedule: String, prompt: String) async -> Bool {
        guard rpc != nil, capabilityAvailable("rpc-scheduling") else {
            lastError = "Cron control is unavailable through this Hermes gateway."
            return false
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSchedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanSchedule.isEmpty, !cleanPrompt.isEmpty else {
            lastError = "Name, schedule, and request are required to create an automation."
            return false
        }
        guard CronSchedule.isValid(cleanSchedule) else {
            lastError = "Schedule must be a 5-field cron expression (minute hour day month weekday)."
            return false
        }
        let actionID = "cron.create"
        guard beginAction(actionID) else { return false }
        defer { finishAction(actionID) }
        do {
            guard let rpc else { return false }
            _ = try await rpc.createCron(name: cleanName, schedule: cleanSchedule, prompt: cleanPrompt)
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func removeCron(_ job: CronSummary) {
        guard rpc != nil, capabilityAvailable("rpc-scheduling") else {
            lastError = "Cron control is unavailable through this Hermes gateway."
            return
        }
        let actionID = cronActionID("remove", job: job)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                guard let rpc else { return }
                _ = try await rpc.removeCron(jobID: job.id)
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openCronSession(_ job: CronSummary) {
        guard let sessionID = job.sessionID, let dockModel else { return }
        dockModel.resumeSession(HermesSession(
            id: sessionID,
            title: "Cron · \(job.name)",
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
        let result = try await rpc.sessionMessages(sessionID: request.sessionID)
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
        return CronReportRequest(job: job, sessionID: sessionID)
    }

    func openProject(_ project: ProjectSummary) {
        guard rpc != nil else { return }
        let generation = UUID()
        projectSessionsGeneration = generation
        currentFocus = ControlReference(source: .hermesProject, sourceID: project.id, projectID: project.id)
        selectedProjectID = project.id
        selectedProject = project
        projectSessions = []
        Task {
            do {
                let result = try await rpc?.projectSessions(projectID: project.id)
                guard let result else { throw HermesGateway.GatewayError.malformedResponse }
                guard generation == projectSessionsGeneration, selectedProjectID == project.id else { return }
                projectSessions = Self.parseProjectSessions(result)
                for session in projectSessions {
                    projectIDBySessionID[session.id] = project.id
                }
            } catch {
                guard generation == projectSessionsGeneration, selectedProjectID == project.id else { return }
                lastError = error.localizedDescription
            }
        }
    }

    func closeProject() {
        projectSessionsGeneration = UUID()
        selectedProjectID = nil
        selectedProject = nil
        projectSessions = []
    }

    func search(_ query: String) {
        searchGeneration = UUID()
        let generation = searchGeneration
        searchTask?.cancel()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            isSearching = false
            searchResults = []
            return
        }

        let localSessions = activeSessions
        let localAttention = attention
        let localReminders = reminders
        let localProjects = projects
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            var sessions = localSessions
            if let rpc = self.rpc, let result = try? await rpc.sessions(limit: 100) {
                sessions = Self.parseSessions(result)
            }
            guard !Task.isCancelled, self.searchGeneration == generation else { return }
            self.searchResults = Self.makeSearchResults(
                query: normalized,
                sessions: sessions,
                attention: localAttention,
                reminders: localReminders,
                projects: localProjects
            )
            self.isSearching = false
        }
    }

    func openSearchResult(_ result: ControlSearchResult) {
        switch result.reference.source {
        case .hermesSession, .hermesApproval, .hermesClarification, .hermesAgentRun:
            guard let rpc else { return }
            Task {
                do {
                    _ = try await rpc.activate(sessionID: result.reference.sessionID ?? result.reference.sourceID)
                    currentFocus = result.reference
                    dockModel?.requestComposerFocus()
                } catch {
                    lastError = error.localizedDescription
                }
            }
        case .hermesProject:
            if let project = projects.first(where: { $0.id == result.reference.sourceID }) {
                openProject(project)
            }
        case .hermesCronJob, .appleReminder:
            break
        }
    }

    func reloadMCP() {
        guard let rpc, let sessionID = dockModel?.sessionID else {
            lastError = "Open a Hermes session before reloading MCP tools."
            return
        }
        guard beginAction(reloadMCPActionID) else { return }
        Task {
            defer { finishAction(reloadMCPActionID) }
            do {
                _ = try await rpc.reloadMCP(sessionID: sessionID)
                dockModel?.refreshRuntimeConfiguration()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshKanban(filter: KanbanListFilter? = nil) {
        guard let cli, capabilityAvailable("kanban") else { return }
        guard beginAction(refreshKanbanActionID) else { return }
        beginProjectionRefresh("kanban.board")
        let requestedFilter = filter ?? kanbanFilter
        let requestedBoardSlug = selectedKanbanBoardSlug
        let projectionChanged = requestedFilter != kanbanFilter || requestedBoardSlug != kanbanProjectionBoardSlug
        if projectionChanged {
            kanbanTasks = []
        }
        if let filter { kanbanFilter = filter }
        let activeFilter = kanbanFilter
        let generation = UUID()
        kanbanRefreshGeneration = generation
        Task {
            defer { finishAction(refreshKanbanActionID) }
            do {
                let result = try await cli.kanbanList(boardSlug: requestedBoardSlug, filter: activeFilter)
                guard result.succeeded else {
                    guard generation == kanbanRefreshGeneration,
                          requestedBoardSlug == selectedKanbanBoardSlug else { return }
                    let message = result.stderr.isEmpty ? "Hermes Kanban is unavailable." : result.stderr
                    recordProjectionFailure("kanban.board", error: message)
                    lastError = message
                    return
                }
                guard generation == kanbanRefreshGeneration,
                      requestedBoardSlug == selectedKanbanBoardSlug else { return }
                kanbanProjectionBoardSlug = requestedBoardSlug
                kanbanTasks = Self.parseKanbanTasks(result.stdout, boardSlug: requestedBoardSlug)
                recordProjectionSuccess("kanban.board")
                refreshKanbanStats()
                refreshKanbanAssignees()
                refreshKanbanBoards()
                refreshKanbanDiagnostics()
            } catch {
                guard generation == kanbanRefreshGeneration else { return }
                let message = error.localizedDescription
                recordProjectionFailure("kanban.board", error: message)
                lastError = message
            }
        }
    }

    /// Refreshes the Kanban projection for the currently focused session without
    /// mutating the global board projection used by the Kanban tab.
    func refreshSessionKanban(for sessionID: String? = nil) {
        let candidateSessionID = sessionID ?? dockModel?.sessionID
        let requestedSessionID = candidateSessionID == dockModel?.sessionID
            ? dockModel?.kanbanSessionID
            : candidateSessionID
        let requestedBoardSlug = selectedKanbanBoardSlug
        let generation = UUID()
        let isNewProjection = sessionKanbanSessionID != requestedSessionID || sessionKanbanBoardSlug != requestedBoardSlug
        sessionKanbanTask?.cancel()
        sessionKanbanRefreshGeneration = generation
        if isNewProjection {
            sessionKanbanTasks = []
        }
        sessionKanbanSessionID = requestedSessionID
        sessionKanbanBoardSlug = requestedBoardSlug
        beginProjectionRefresh("kanban.session")

        guard let requestedSessionID,
              !requestedSessionID.isEmpty,
              let cli,
              capabilityAvailable("kanban") else {
            recordProjectionFailure("kanban.session", error: "Kanban is unavailable for the current session.")
            return
        }

        sessionKanbanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await cli.kanbanList(
                    boardSlug: requestedBoardSlug,
                    filter: KanbanListFilter(sessionID: requestedSessionID, sort: "updated")
                )
                guard generation == self.sessionKanbanRefreshGeneration,
                      self.sessionKanbanSessionID == requestedSessionID,
                      requestedBoardSlug == self.selectedKanbanBoardSlug else { return }
                guard result.succeeded else {
                    self.recordProjectionFailure(
                        "kanban.session",
                        error: result.stderr.isEmpty ? "Hermes Kanban is unavailable." : result.stderr
                    )
                    self.sessionKanbanTask = nil
                    return
                }
                self.sessionKanbanTasks = Self.parseKanbanTasks(result.stdout, boardSlug: requestedBoardSlug)
                self.sessionKanbanTask = nil
                self.recordProjectionSuccess("kanban.session")
            } catch {
                guard generation == self.sessionKanbanRefreshGeneration,
                      self.sessionKanbanSessionID == requestedSessionID else { return }
                self.sessionKanbanTask = nil
                self.recordProjectionFailure("kanban.session", error: error.localizedDescription)
            }
        }
    }

    func refreshKanbanBoards() {
        guard let cli, capabilityAvailable("kanban.boards") else { return }
        guard beginAction(refreshKanbanBoardsActionID) else { return }
        let generation = UUID()
        kanbanBoardsGeneration = generation
        Task {
            defer { finishAction(refreshKanbanBoardsActionID) }
            do {
                let result = try await cli.kanbanBoards()
                guard generation == kanbanBoardsGeneration else { return }
                guard result.succeeded else {
                    lastError = result.stderr.isEmpty ? "Hermes Kanban boards are unavailable." : result.stderr
                    return
                }
                let boards = Self.parseKanbanBoards(result.stdout)
                kanbanBoards = boards
                let previousSelection = selectedKanbanBoardSlug
                if let selected = selectedKanbanBoardSlug,
                   boards.contains(where: { $0.slug == selected && !$0.archived }) {
                    // Preserve an explicitly selected Dock board even when the
                    // shared Hermes default changes elsewhere.
                } else {
                    selectedKanbanBoardSlug = boards.first(where: { $0.isCurrent && !$0.archived })?.slug
                        ?? boards.first(where: { !$0.archived })?.slug
                }
                if previousSelection != selectedKanbanBoardSlug,
                   selectedKanbanBoardSlug != nil {
                    refreshKanban()
                    if let sessionID = currentFocus?.sessionID {
                        refreshSessionKanban(for: sessionID)
                    }
                }
            } catch {
                guard generation == kanbanBoardsGeneration else { return }
                lastError = error.localizedDescription
            }
        }
    }

    func selectKanbanBoard(_ board: KanbanBoardSummary) {
        guard !board.archived, selectedKanbanBoardSlug != board.slug else { return }
        selectedKanbanBoardSlug = board.slug
        kanbanRefreshGeneration = UUID()
        kanbanStatsGeneration = UUID()
        kanbanAssigneesGeneration = UUID()
        kanbanDetailGeneration = UUID()
        kanbanDiagnosticsGeneration = UUID()
        kanbanAttachmentsGeneration = UUID()
        kanbanTasks = []
        kanbanDetail = nil
        kanbanStats = nil
        kanbanAssignees = []
        kanbanDiagnostics = []
        kanbanAttachments = []
        isLoadingKanbanDetail = false
        refreshKanban()
        if let sessionID = currentFocus?.sessionID {
            refreshSessionKanban(for: sessionID)
        }
        refreshKanbanDiagnostics()
    }

    private func refreshKanbanAssignees() {
        guard let cli, capabilityAvailable("kanban.assignees") else { return }
        let generation = UUID()
        let requestedBoardSlug = selectedKanbanBoardSlug
        kanbanAssigneesGeneration = generation
        Task {
            guard let result = try? await cli.kanbanAssignees(boardSlug: requestedBoardSlug),
                  result.succeeded,
                  generation == kanbanAssigneesGeneration,
                  requestedBoardSlug == selectedKanbanBoardSlug else { return }
            kanbanAssignees = Self.parseKanbanAssignees(result.stdout)
        }
    }

    func refreshReadOnlyHealth() {
        guard let cli else { return }
        let generation = UUID()
        journeyGeneration = generation
        Task {
            if capabilityAvailable("journey.timeline"),
               let result = try? await cli.journey(), result.succeeded,
               generation == journeyGeneration {
                journeyNodes = Self.parseJourneyNodes(result.stdout)
            }
            if capabilityAvailable("sessions.stats"),
               let result = try? await cli.sessionStats(), generation == journeyGeneration {
                sessionStoreStatus = Self.readOnlyStatus(id: "sessions.stats", title: "Session store", result: result)
            }
            if capabilityAvailable("memory.status"),
               let result = try? await cli.memoryStatus(), generation == journeyGeneration {
                memoryHealthStatus = Self.readOnlyStatus(id: "memory.status", title: "Memory health", result: result)
            }
        }
    }

    func refreshSessionCockpit(for requestedSessionID: String? = nil) {
        let generation = UUID()
        sessionCockpitGeneration = generation
        let sessionID = requestedSessionID ?? dockModel?.sessionID
        guard capabilityAvailable("rpc-sessions"), let rpc, let sessionID, !sessionID.isEmpty else {
            sessionCockpitSessionID = nil
            sessionUsage = nil
            sessionContext = nil
            return
        }
        if sessionCockpitSessionID != sessionID {
            sessionUsage = nil
            sessionContext = nil
        }
        sessionCockpitSessionID = sessionID
        Task { @MainActor in
            let usage = try? await rpc.sessionUsage(sessionID: sessionID)
            let context = try? await rpc.sessionContextBreakdown(sessionID: sessionID)
            guard generation == sessionCockpitGeneration,
                  sessionCockpitSessionID == sessionID,
                  (requestedSessionID != nil || dockModel?.sessionID == sessionID) else { return }
            if let usage { sessionUsage = Self.parseSessionUsage(usage) }
            if let context { sessionContext = Self.parseSessionContext(context) }
            if usage != nil || context != nil {
                recordProjectionSuccess("session.cockpit")
            }
        }
    }

    func steerActiveSession(_ text: String) async -> SessionTextActionResult? {
        guard let dockModel,
              dockModel.status == .working,
              capabilityAvailable("rpc-sessions"),
              let rpc,
              let sessionID = dockModel.sessionID,
              !sessionID.isEmpty else { return nil }
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        let actionID = sessionSteerActionID(sessionID)
        guard beginAction(actionID) else { return nil }
        defer { finishAction(actionID) }
        do {
            let result = try await rpc.steer(sessionID: sessionID, text: cleanText)
            guard dockModel.sessionID == sessionID else { return nil }
            guard let rawStatus = result["status"] as? String,
                  let status = SessionTextActionStatus(rawValue: rawStatus.lowercased()) else {
                lastError = "Hermes returned an invalid steering response."
                return nil
            }
            guard status == .queued || status == .rejected else {
                lastError = "Hermes returned an invalid steering status."
                return nil
            }
            let action = SessionTextActionResult(status: status, text: cleanText)
            if !action.wasAccepted { lastError = "Hermes rejected the steering correction." }
            return action
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func refreshKanbanDiagnostics(severity: String? = nil) {
        guard let cli, capabilityAvailable("kanban") else { return }
        let generation = UUID()
        let requestedBoardSlug = selectedKanbanBoardSlug
        kanbanDiagnosticsGeneration = generation
        beginProjectionRefresh("kanban.diagnostics")
        Task {
            do {
                let result = try await cli.kanbanDiagnostics(boardSlug: requestedBoardSlug, severity: severity)
                guard generation == kanbanDiagnosticsGeneration,
                      requestedBoardSlug == selectedKanbanBoardSlug else { return }
                guard result.succeeded else {
                    recordProjectionFailure("kanban.diagnostics", error: result.stderr)
                    return
                }
                kanbanDiagnostics = Self.parseKanbanDiagnostics(result.stdout, boardSlug: requestedBoardSlug, severity: severity)
                recordProjectionSuccess("kanban.diagnostics")
            } catch {
                guard generation == kanbanDiagnosticsGeneration else { return }
                recordProjectionFailure("kanban.diagnostics", error: error.localizedDescription)
            }
        }
    }

    func refreshKanbanAttachments(for taskID: String) {
        guard let cli else { return }
        let generation = UUID()
        let requestedBoardSlug = selectedKanbanBoardSlug
        kanbanAttachmentsGeneration = generation
        beginProjectionRefresh("kanban.attachments")
        Task {
            do {
                let result = try await cli.kanbanAttachments(boardSlug: requestedBoardSlug, taskID: taskID)
                guard generation == kanbanAttachmentsGeneration,
                      requestedBoardSlug == selectedKanbanBoardSlug else { return }
                guard result.succeeded,
                      let data = result.stdout.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data) else {
                    recordProjectionFailure("kanban.attachments", error: result.stderr)
                    return
                }
                kanbanAttachments = Self.parseKanbanAttachments(value, boardSlug: requestedBoardSlug, taskID: taskID)
                recordProjectionSuccess("kanban.attachments")
            } catch {
                guard generation == kanbanAttachmentsGeneration else { return }
                recordProjectionFailure("kanban.attachments", error: error.localizedDescription)
            }
        }
    }

    func refreshPromptBudget() {
        guard let cli else { return }
        let generation = UUID()
        promptBudgetGeneration = generation
        beginProjectionRefresh("prompt.budget")
        Task {
            do {
                let result = try await cli.promptSize()
                guard generation == promptBudgetGeneration else { return }
                guard result.succeeded,
                      let data = result.stdout.data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    recordProjectionFailure("prompt.budget", error: result.stderr)
                    return
                }
                promptBudget = PromptBudgetSummary(totalTokens: Self.intValue(row["total_tokens"] ?? row["total"]), tokenLimit: Self.optionalIntValue(row["token_limit"] ?? row["context_max"]), percent: Self.doubleValue(row["percent"] ?? row["context_percent"]), model: row["model"] as? String)
                recordProjectionSuccess("prompt.budget")
            } catch {
                guard generation == promptBudgetGeneration else { return }
                recordProjectionFailure("prompt.budget", error: error.localizedDescription)
            }
        }
    }

    func refreshVerification(for requestedSessionID: String? = nil) {
        guard let rpc, let repository = developmentContext, !repository.path.isEmpty else {
            projectFacts = nil
            verification = VerificationSummary(state: .notApplicable, evidence: nil)
            return
        }
        let factsGeneration = UUID()
        let verificationGeneration = UUID()
        projectFactsGeneration = factsGeneration
        self.verificationGeneration = verificationGeneration
        let sessionID = requestedSessionID ?? dockModel?.sessionID
        Task { @MainActor in
            do {
                let factsResult = try await rpc.projectFacts(cwd: repository.path)
                guard factsGeneration == self.projectFactsGeneration else { return }
                projectFacts = Self.parseProjectFacts(factsResult)
            } catch {
                projectFacts = nil
            }
            do {
                let result = try await rpc.verificationStatus(sessionID: sessionID, cwd: repository.path)
                guard verificationGeneration == self.verificationGeneration else { return }
                verification = Self.parseVerification(result)
            } catch {
                verification = VerificationSummary(state: .unknown, evidence: nil)
            }
        }
    }

    func startBackgroundTask(_ prompt: String, kind: HermesBackgroundTaskKind = .general) async -> Bool {
        guard capabilityAvailable("gateway"), let rpc, let dockModel, let sessionID = dockModel.sessionID, !sessionID.isEmpty else {
            lastError = capabilityAvailable("gateway")
                ? "Open a Hermes session before starting a background task."
                : "Background tasks are unavailable in this Hermes installation."
            return false
        }
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return false }
        do {
            let result = try await rpc.startBackgroundPrompt(sessionID: sessionID, text: cleanPrompt)
            guard let taskID = result["task_id"] as? String, !taskID.isEmpty else {
                lastError = "Hermes did not return a background task ID."
                return false
            }
            dockModel.registerBackgroundTask(id: taskID, prompt: cleanPrompt, parentSessionID: sessionID, kind: kind)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func renameActiveSession(_ title: String) async -> Bool {
        guard let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty else { return false }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        do {
            _ = try await rpc.setSessionTitle(sessionID: sessionID, title: clean)
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func redirectActiveSession(_ text: String) async -> SessionTextActionResult? {
        guard let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        do {
            let result = try await rpc.redirect(sessionID: sessionID, text: clean)
            guard let raw = result["status"] as? String,
                  let status = SessionTextActionStatus(rawValue: raw.lowercased()),
                  let acceptedStatus = [SessionTextActionStatus.queued, .redirected, .rejected].first(where: { $0 == status }) else {
                lastError = "Hermes returned an invalid redirect response."
                return nil
            }
            let response = SessionTextActionResult(status: acceptedStatus, text: clean)
            if !response.wasAccepted { lastError = "Hermes rejected the redirect." }
            return response
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func undoActiveSession() async -> Bool {
        guard let rpc, let dockModel, let sessionID = dockModel.sessionID, !sessionID.isEmpty else { return false }
        do {
            _ = try await rpc.undo(sessionID: sessionID)
            dockModel.resumeSession(HermesSession(id: sessionID, title: dockModel.currentSessionTitle ?? "Hermes session", preview: "", startedAt: nil, messageCount: 0, source: "hermes"))
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func compressActiveSession(focusTopic: String? = nil) async -> Bool {
        guard capabilityAvailable("rpc-sessions"), let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty else {
            lastError = "Session compression is unavailable in this Hermes installation."
            return false
        }
        do {
            _ = try await rpc.compress(sessionID: sessionID, focusTopic: focusTopic)
            refreshSessionCockpit()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func branchActiveSession(name: String? = nil) async -> Bool {
        guard capabilityAvailable("rpc-sessions"), let rpc, let dockModel, let sessionID = dockModel.sessionID, !sessionID.isEmpty else {
            lastError = "Session branching is unavailable in this Hermes installation."
            return false
        }
        do {
            let result = try await rpc.branch(sessionID: sessionID, name: name)
            if let branchID = result["session_id"] as? String {
                dockModel.resumeSession(HermesSession(id: branchID, title: name ?? "Hermes branch", preview: "", startedAt: nil, messageCount: 0, source: "branch"))
            }
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func pauseDelegation(_ paused: Bool) async -> Bool {
        guard let rpc else { return false }
        do {
            let result = try await rpc.pauseDelegation(paused)
            delegationPaused = result["paused"] as? Bool ?? paused
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func interruptSubagent(_ subagentID: String) async -> Bool {
        guard let rpc else { return false }
        do {
            let result = try await rpc.interruptSubagent(subagentID: subagentID)
            guard result["found"] as? Bool != false else {
                lastError = "Hermes could not find that subagent."
                return false
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func killProcess(_ process: ProcessSummary) async -> Bool {
        guard rpc != nil, capabilityAvailable("rpc-activity") else {
            lastError = "Process control is unavailable through this Hermes gateway."
            return false
        }
        let actionID = "process.kill:\(process.id)"
        guard beginAction(actionID) else { return false }
        defer { finishAction(actionID) }
        guard let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty else { return false }
        do {
            _ = try await rpc.killProcess(sessionID: sessionID, processID: process.id)
            refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func loadKanbanTask(_ task: KanbanTaskSummary) {
        guard let cli else { return }
        let generation = UUID()
        kanbanDetailGeneration = generation
        isLoadingKanbanDetail = true
        kanbanDetail = nil
        let requestedBoardSlug = task.boardSlug ?? selectedKanbanBoardSlug
        kanbanAttachmentsGeneration = UUID()
        kanbanAttachments = []
        refreshKanbanAttachments(for: task.id)
        Task {
            defer {
                if generation == kanbanDetailGeneration {
                    isLoadingKanbanDetail = false
                }
            }
            do {
                let taskResult = try await cli.kanbanShow(boardSlug: requestedBoardSlug, taskID: task.id)
                guard taskResult.succeeded,
                      var detail = Self.parseKanbanTaskDetail(taskResult.stdout, fallback: task, boardSlug: requestedBoardSlug) else {
                    guard generation == kanbanDetailGeneration else { return }
                    lastError = taskResult.stderr.isEmpty ? "Hermes Kanban task details are unavailable." : taskResult.stderr
                    return
                }

                let runsResult = capabilityAvailable("kanban.taskRuns") ? try await cli.kanbanRuns(boardSlug: requestedBoardSlug, taskID: task.id) : nil
                if let runsResult, runsResult.succeeded {
                    detail = KanbanTaskDetail(
                        id: detail.id,
                        boardSlug: requestedBoardSlug,
                        title: detail.title,
                        body: detail.body,
                        status: detail.status,
                        priority: detail.priority,
                        assignee: detail.assignee,
                        runs: Self.parseKanbanRuns(runsResult.stdout, boardSlug: requestedBoardSlug)
                    )
                }
                guard generation == kanbanDetailGeneration,
                      requestedBoardSlug == selectedKanbanBoardSlug else { return }
                kanbanDetail = detail
            } catch {
                guard generation == kanbanDetailGeneration,
                      requestedBoardSlug == selectedKanbanBoardSlug else { return }
                lastError = error.localizedDescription
            }
        }
    }

    private func refreshKanbanStats() {
        guard let cli, capabilityAvailable("kanban.stats") else { return }
        let generation = UUID()
        let requestedBoardSlug = selectedKanbanBoardSlug
        kanbanStatsGeneration = generation
        Task {
            guard let result = try? await cli.kanbanStats(boardSlug: requestedBoardSlug),
                  result.succeeded,
                  generation == kanbanStatsGeneration,
                  requestedBoardSlug == selectedKanbanBoardSlug else { return }
            kanbanStats = Self.parseKanbanStats(result.stdout)
        }
    }

    func createKanbanTask(title: String, body: String) async -> Bool {
        guard let cli, capabilityAvailable("kanban.create") else {
            lastError = "Kanban is unavailable because Hermes Control is not connected."
            return false
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            lastError = "Enter a Kanban task title before creating it."
            return false
        }
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        isCreatingKanbanTask = true
        defer { isCreatingKanbanTask = false }
        do {
            let result = try await cli.kanbanCreate(boardSlug: selectedKanbanBoardSlug, title: cleanTitle, body: cleanBody.isEmpty ? nil : cleanBody)
            guard result.succeeded else {
                lastError = result.stderr.isEmpty ? "Hermes Kanban could not create the task." : result.stderr
                return false
            }
            refreshKanban()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func updateKanbanTask(_ task: KanbanTaskSummary, action: KanbanTaskAction) {
        guard let cli, capabilityAvailable("kanban.\(action.rawValue)") else { return }
        let actionID = kanbanActionID(action, task: task)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                let result: HermesCLIResult
                switch action {
                case .complete: result = try await cli.kanbanComplete(boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id)
                case .block: result = try await cli.kanbanBlock(boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id)
                case .unblock: result = try await cli.kanbanUnblock(boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id)
                case .archive: result = try await cli.kanbanArchive(boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id)
                }
                guard result.succeeded else {
                    lastError = result.stderr.isEmpty ? "Hermes Kanban could not update the task." : result.stderr
                    return
                }
                refreshKanban()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func mutateKanban(_ request: KanbanMutationRequest) {
        guard let cli, capabilityAvailable(request.kind.capabilityID) else {
            lastError = "\(request.kind.title.capitalized) is unavailable through the installed Hermes CLI."
            return
        }
        let value = request.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            lastError = "Enter a value before updating this Kanban task."
            return
        }
        let actionID = kanbanActionID(request.kind, task: request.task)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                let result: HermesCLIResult
                switch request.kind {
                case .comment:
                    result = try await cli.kanbanComment(boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id, text: value)
                case .schedule:
                    result = try await cli.kanbanSchedule(boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id, reason: value)
                case .assign:
                    result = try await cli.kanbanAssign(boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id, profile: value, reassign: false, reclaim: false)
                case .reassign:
                    result = try await cli.kanbanAssign(boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id, profile: value, reassign: true, reclaim: request.reclaimFirst)
                case .promote:
                    result = try await cli.kanbanPromote(boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id, reason: value)
                case .reclaim:
                    result = try await cli.kanbanReclaim(boardSlug: request.task.boardSlug ?? selectedKanbanBoardSlug, taskID: request.task.id, reason: value)
                }
                guard result.succeeded else {
                    lastError = result.stderr.isEmpty ? "Hermes Kanban could not update the task." : result.stderr
                    return
                }
                refreshKanban()
                loadKanbanTask(request.task)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func editCron(_ job: CronSummary, draft: CronEditDraft) {
        guard let cli, capabilityAvailable("cron.edit") else {
            lastError = "Cron editing is unavailable through the installed Hermes CLI."
            return
        }
        let changes = draft.changes(comparedTo: job).filter { job.editableFields.contains($0.key) }
        guard !changes.isEmpty else {
            lastError = "Change at least one scheduled-job field before saving."
            return
        }
        guard changes.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            lastError = "Scheduled-job fields cannot be empty in the Dock."
            return
        }
        if let schedule = changes[.schedule], !CronSchedule.isValid(schedule) {
            lastError = "Schedule must be a 5-field cron expression (minute hour day month weekday)."
            return
        }
        let actionID = cronActionID("edit", job: job)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.cronEdit(jobID: job.id, changes: changes)
                guard result.succeeded else {
                    lastError = result.stderr.isEmpty ? "Hermes could not edit the scheduled job." : result.stderr
                    return
                }
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func openProjectSession(_ session: SessionSummary) {
        guard let dockModel else { return }
        dockModel.resumeSession(HermesSession(
            id: session.id,
            title: session.title,
            preview: session.displayPreview ?? "",
            startedAt: nil,
            messageCount: 0,
            source: "project"
        ))
        focus(sessionID: session.id)
        dockModel.requestComposerFocus()
    }

    /// Active-session projections are live Hermes sessions, not necessarily
    /// persisted sessions accepted by `session.resume`. Activate them through
    /// the same RPC path used by the other live-work controls.
    func openLatestActivitySession(_ session: SessionSummary) {
        guard let dockModel else { return }
        Task {
            do {
                _ = try await dockModel.requestControl("session.activate", params: ["session_id": session.id])
                focus(sessionID: session.id)
                dockModel.updateCurrentSessionTitle(session.title)
                dockModel.requestComposerFocus()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func respond(to item: AttentionItem, action: AttentionAction, response: String? = nil) {
        guard let dockModel else { return }
        let reference = item.reference
        let actionID = attentionActionID(action, item: item)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                switch action {
                case .approve:
                    guard let rpc, let sessionID = reference.sessionID, !sessionID.isEmpty else { return }
                    _ = try await rpc.respondToApproval(sessionID: sessionID, choice: "once")
                    dockModel.resolveApproval(for: sessionID)
                case .deny:
                    guard let rpc, let sessionID = reference.sessionID, !sessionID.isEmpty else { return }
                    _ = try await rpc.respondToApproval(sessionID: sessionID, choice: "deny")
                    dockModel.resolveApproval(for: sessionID)
                case .respond:
                    let response = response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !response.isEmpty else { return }
                    guard let rpc else { return }
                    _ = try await rpc.respondToClarification(sessionID: reference.sessionID ?? reference.sourceID, response: response)
                case .stop:
                    guard let rpc else { return }
                    _ = try await rpc.interrupt(sessionID: reference.sessionID ?? reference.sourceID)
                case .resume:
                    guard let rpc else { return }
                    _ = try await rpc.activate(sessionID: reference.sessionID ?? reference.sourceID)
                case .open:
                    guard let rpc else { return }
                    _ = try await rpc.activate(sessionID: reference.sessionID ?? reference.sourceID)
                    currentFocus = reference
                    dockModel.requestComposerFocus()
                default:
                    break
                }
                markResolved(item.id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func markResolved(_ id: String) {
        guard let index = attention.firstIndex(where: { $0.id == id }) else { return }
        attention[index].state = .resolved
        knownAttention[id] = attention[index]
        persistPresentationState()
    }

    func dismiss(_ id: String) {
        guard let index = attention.firstIndex(where: { $0.id == id }) else { return }
        attention[index].state = .dismissed
        knownAttention[id] = attention[index]
        persistPresentationState()
        rebuildAttention()
    }

    func snooze(_ id: String, for duration: TimeInterval = 60 * 60) {
        guard let index = attention.firstIndex(where: { $0.id == id }) else { return }
        attention[index].state = .snoozed
        knownAttention[id] = attention[index]
        let until = Date().addingTimeInterval(duration)
        var snoozes = presentationDefaults.dictionary(forKey: snoozeKey) as? [String: Double] ?? [:]
        snoozes[id] = until.timeIntervalSince1970
        presentationDefaults.set(snoozes, forKey: snoozeKey)
        persistPresentationState()
        rebuildAttention()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, let item = self.knownAttention[id], item.state == .snoozed else { return }
            var reopened = item
            reopened.state = .open
            self.knownAttention[id] = reopened
            var current = self.presentationDefaults.dictionary(forKey: self.snoozeKey) as? [String: Double] ?? [:]
            current.removeValue(forKey: id)
            self.presentationDefaults.set(current, forKey: self.snoozeKey)
            self.persistPresentationState()
            self.rebuildAttention()
        }
    }

    /// Converts the shared Hermes event stream into stable attention records.
    /// The event's session/source identifier is the identity; display text may
    /// be enriched by later partial events without creating another row.
    func ingestEvent(_ type: String, params: [String: Any]) {
        let payload = params["payload"] as? [String: Any] ?? [:]
        let sessionID = (params["session_id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? dockModel?.sessionID
        guard let sessionID, !sessionID.isEmpty else { return }

        let detail = (payload["message"] as? String)
            ?? (payload["description"] as? String)
            ?? (payload["question"] as? String)
            ?? (payload["text"] as? String)
            ?? "Hermes reported \(type)."
        switch type {
        case "approval.request":
            let approval = ApprovalPresentation.from(payload: payload)
            upsertAttention(AttentionItem(
                id: "approval:\(sessionID)",
                reference: ControlReference(source: .hermesApproval, sourceID: sessionID, sessionID: sessionID),
                kind: .approval,
                title: approval.title,
                detail: approval.detail,
                createdAt: Date(),
                state: .open,
                actions: [.approve, .deny, .stop]
            ))
        case "clarification.request", "clarify.request":
            let choices = (payload["choices"] as? [String])?.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            upsertAttention(AttentionItem(
                id: "clarification:\(sessionID)",
                reference: ControlReference(source: .hermesClarification, sourceID: sessionID, sessionID: sessionID),
                kind: .clarification,
                title: "Hermes needs clarification",
                detail: detail,
                createdAt: Date(),
                state: .open,
                actions: [.respond, .open, .stop],
                choices: choices
            ))
        case "error":
            upsertAttention(AttentionItem(
                id: "failure:\(sessionID)",
                reference: ControlReference(source: .hermesSession, sourceID: sessionID, sessionID: sessionID),
                kind: .failure,
                title: "Hermes work failed",
                detail: detail,
                createdAt: Date(),
                state: .open,
                actions: [.resume, .stop]
            ))
        case "message.complete":
            if let existing = knownAttention["failure:\(sessionID)"] {
                var resolved = existing
                resolved.state = .resolved
                knownAttention[resolved.id] = resolved
            }
        default:
            break
        }
        if ["message.complete", "sessions.changed", "cron.changed", "process.changed"].contains(type) {
            refresh()
        }
        rebuildAttention()
    }

    private func upsertAttention(_ item: AttentionItem) {
        if let existing = knownAttention[item.id], existing.state == .dismissed || existing.state == .resolved {
            var preserved = item
            preserved.state = existing.state
            knownAttention[item.id] = preserved
        } else if let existing = knownAttention[item.id] {
            var enriched = item
            enriched.createdAt = existing.createdAt
            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                enriched.title = existing.title
            }
            if Self.isPlaceholderAttentionDetail(item.detail) {
                enriched.detail = existing.detail
            }
            if item.actions.isEmpty {
                enriched.actions = existing.actions
            }
            knownAttention[item.id] = enriched
        } else {
            knownAttention[item.id] = item
        }
    }

    private func persistPresentationState() {
        let values = knownAttention.reduce(into: [String: String]()) { result, entry in
            guard entry.value.state == .dismissed || entry.value.state == .resolved || entry.value.state == .snoozed else { return }
            result[entry.key] = entry.value.state.rawValue
        }
        presentationDefaults.set(values, forKey: presentationKey)
    }

    private static func isPlaceholderAttentionDetail(_ detail: String) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized == "hermes wants to perform an action."
            || normalized.hasPrefix("hermes reported ")
    }

    func rebuildAttention() {
        var next: [AttentionItem] = []
        // A completed response is already visible in the conversation and is
        // not an action item. Keep NEEDS ME reserved for work that requires a
        // decision, response, recovery, or explicit completion.
        knownAttention = knownAttention.filter { $0.value.kind != .completed }
        if let dockModel {
            if dockModel.status != .offline {
                knownAttention.removeValue(forKey: "failure:hermes")
            }
            if let sessionID = dockModel.sessionID, dockModel.approvalText == nil {
                knownAttention.removeValue(forKey: "approval:\(sessionID)")
            }
            if let approval = dockModel.approvalText, let sessionID = dockModel.sessionID,
               knownAttention["approval:\(sessionID)"]?.state != .resolved,
               knownAttention["approval:\(sessionID)"]?.state != .dismissed {
                upsertAttention(AttentionItem(
                    id: "approval:\(sessionID)",
                    reference: ControlReference(source: .hermesApproval, sourceID: sessionID, sessionID: sessionID),
                    kind: .approval,
                    title: dockModel.approvalTitle ?? "Hermes needs approval",
                    detail: approval,
                    createdAt: Date(),
                    state: .open,
                    actions: [.approve, .deny, .stop]
                ))
            }
            if dockModel.status == .offline {
                upsertAttention(AttentionItem(
                    id: "failure:hermes",
                    reference: ControlReference(source: .hermesSession, sourceID: dockModel.sessionID ?? "hermes"),
                    kind: .failure,
                    title: "Hermes is offline",
                    detail: "Reconnect Hermes to continue the active conversation.",
                    createdAt: Date(),
                    state: .open,
                    actions: [.open]
                ))
            }
        }
        next = knownAttention.values.filter { saved in
            saved.state != .resolved && saved.state != .dismissed && saved.state != .snoozed && !next.contains(where: { $0.id == saved.id })
        }
        attention = next.sorted { lhs, rhs in
            let lhsRank = Self.attentionRank(lhs)
            let rhsRank = Self.attentionRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.createdAt > rhs.createdAt
        }
    }

    static func attentionRank(_ item: AttentionItem) -> Int {
        switch item.kind {
        case .approval: 0
        case .failure: 1
        case .clarification: 2
        case .reminder: item.detail.localizedCaseInsensitiveContains("OVERDUE") ? 3 : 4
        case .completed: 5
        }
    }

    func focus(sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else {
            sessionKanbanTask?.cancel()
            sessionKanbanRefreshGeneration = UUID()
            sessionKanbanSessionID = nil
            sessionKanbanBoardSlug = nil
            sessionKanbanTasks = []
            return
        }
        if currentFocus?.sessionID != sessionID {
            // Repository context is scoped to a Hermes session. Clear the
            // previous projection before the sidebar asynchronously inspects
            // the newly selected session's attached repository.
            developmentContext = nil
        }
        currentFocus = ControlReference(source: .hermesSession, sourceID: sessionID, sessionID: sessionID)
        resolveProjectMembership(for: sessionID)
        refreshSessionScopedProjections(for: sessionID)
    }

    /// Refreshes data whose meaning is owned by the selected session. The
    /// broad control-center refresh can already be running when the user
    /// switches sessions, so this path must not wait for that refresh or leave
    /// the previous session's projection visible in the Session tab.
    private func refreshSessionScopedProjections(for sessionID: String) {
        let generation = UUID()
        sessionProcessesGeneration = generation
        processes = []
        refreshSessionKanban(for: sessionID)
        refreshSessionCockpit(for: sessionID)
        refreshVerification(for: sessionID)

        guard capabilityAvailable("rpc-sessions"), let rpc else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await rpc.processes(sessionID: sessionID)
                guard generation == self.sessionProcessesGeneration,
                      self.currentFocus?.sessionID == sessionID else { return }
                self.processes = Self.parseProcesses(result)
                self.recordProjectionSuccess("processes")
            } catch {
                guard generation == self.sessionProcessesGeneration,
                      self.currentFocus?.sessionID == sessionID else { return }
                self.processes = []
                self.recordProjectionFailure("processes", error: error.localizedDescription)
            }
        }
    }

    func project(forSessionID sessionID: String) -> ProjectSummary? {
        if let project = projects.first(where: { $0.sessionIDs.contains(sessionID) }) {
            return project
        }
        guard let projectID = projectIDBySessionID[sessionID] else { return nil }
        if let project = projects.first(where: { $0.id == projectID }) {
            return project
        }

        // The Projects tab gets its authoritative membership from the
        // selected project's session projection. The compact project list can
        // lag behind that projection and may not yet contain the session ID.
        // Reuse the selected project in that case instead of making the
        // session inspector resolve membership through a second path.
        if selectedProject?.id == projectID {
            return selectedProject
        }
        return nil
    }

    /// Returns the freshest session metadata available from the project or
    /// active-session projections. Project sessions often have a newer title
    /// than the generic session list, so consumers should prefer this when a
    /// session is already attached to a project.
    func sessionSummary(for sessionID: String) -> SessionSummary? {
        projectSessions.first(where: { $0.id == sessionID })
            ?? activeSessions.first(where: { $0.id == sessionID })
    }

    /// The project tree sometimes reports counts without embedding session
    /// rows. Resolve the active session through the supported per-project
    /// projection so session UI can always display its real owner.
    private func resolveProjectMembership(for sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty,
              project(forSessionID: sessionID) == nil,
              let rpc, !projects.isEmpty else { return }
        let generation = UUID()
        projectMembershipGeneration = generation
        let candidates = projects
        Task { @MainActor [weak self] in
            guard let self else { return }
            for project in candidates {
                guard generation == projectMembershipGeneration else { return }
                guard let result = try? await rpc.projectSessions(projectID: project.id) else { continue }
                guard generation == projectMembershipGeneration else { return }
                if Self.parseProjectSessions(result).contains(where: { $0.id == sessionID }) {
                    projectIDBySessionID[sessionID] = project.id
                    return
                }
            }
        }
    }

    func focusTitle(_ reference: ControlReference) -> String {
        switch reference.source {
        case .hermesProject:
            return projects.first(where: { $0.id == reference.sourceID })?.name ?? "Hermes project"
        case .appleReminder:
            return reminders.first(where: { $0.id == reference.sourceID })?.title ?? "Apple Reminder"
        default:
            let sessionID = reference.sessionID ?? reference.sourceID
            return activeSessions.first(where: { $0.id == sessionID })?.title
                ?? dockModel?.currentSessionTitle
                ?? "Hermes session"
        }
    }

    func focusDetail(_ reference: ControlReference) -> String {
        switch reference.source {
        case .hermesProject:
            return projects.first(where: { $0.id == reference.sourceID })?.preview ?? "Hermes project context"
        case .appleReminder:
            return reminders.first(where: { $0.id == reference.sourceID })?.list ?? "Apple Reminder"
        default:
            let sessionID = reference.sessionID ?? reference.sourceID
            return activeSessions.first(where: { $0.id == sessionID })?.preview
                ?? activeSessions.first(where: { $0.id == sessionID })?.state.uppercased()
                ?? "HERMES SESSION"
        }
    }

    private func establishFocusIfNeeded() {
        guard currentFocus == nil, let session = activeSessions.first else { return }
        focus(sessionID: session.id)
    }

    static func parseCronJobs(_ result: [String: Any]) -> [CronSummary] {
        let rows = (result["jobs"] as? [[String: Any]]) ?? (result["cron"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            let id = (row["job_id"] as? String) ?? (row["id"] as? String) ?? (row["name"] as? String)
            guard let id else { return nil }
            var editable: Set<CronEditField> = []
            if row["name"] as? String != nil { editable.insert(.name) }
            if row["schedule"] as? String != nil { editable.insert(.schedule) }
            if (row["prompt"] as? String) != nil || (row["request"] as? String) != nil || (row["task"] as? String) != nil { editable.insert(.prompt) }
            return CronSummary(
                id: id,
                name: (row["name"] as? String) ?? id,
                schedule: (row["schedule"] as? String) ?? "Scheduled",
                enabled: (row["enabled"] as? Bool) ?? !(row["paused"] as? Bool ?? false),
                nextRun: row["next_run_at"] as? String ?? row["next_run"] as? String ?? row["nextRun"] as? String,
                sessionID: row["session_id"] as? String ?? row["sessionID"] as? String,
                delivery: row["deliver"] as? String ?? row["delivery"] as? String,
                prompt: (row["prompt"] as? String) ?? (row["request"] as? String) ?? (row["task"] as? String),
                report: nil,
                editableFields: editable
            )
        }
    }

    static func attachLatestCronSessions(to jobs: [CronSummary], from result: [String: Any]) -> [CronSummary] {
        let rows = (result["sessions"] as? [[String: Any]]) ?? []
        return jobs.map { job in
            let prefix = "cron_\(job.id)_"
            let sessionID = rows.first { row in
                let source = (row["source"] as? String)?.lowercased()
                let id = row["id"] as? String
                return source == "cron" && id?.hasPrefix(prefix) == true
            }?["id"] as? String
            guard let sessionID else { return job }
            return CronSummary(
                id: job.id,
                name: job.name,
                schedule: job.schedule,
                enabled: job.enabled,
                nextRun: job.nextRun,
                sessionID: sessionID,
                delivery: job.delivery,
                prompt: job.prompt,
                report: job.report,
                editableFields: job.editableFields
            )
        }
    }

    static func parseCronReport(_ result: [String: Any], job: CronSummary, sessionID: String) -> CronReportDetail? {
        let rows = result["messages"] as? [[String: Any]] ?? []
        for row in rows.reversed() {
            let role = (row["role"] as? String)?.lowercased() ?? ""
            guard role == "assistant" || role == "hermes" else { continue }
            let text = cronReportText(row["text"] ?? row["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return CronReportDetail(id: sessionID, jobID: job.id, title: job.name, markdown: text)
        }
        return nil
    }

    private static func cronReportText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                (part["text"] as? String) ?? (part["content"] as? String)
            }.joined()
        }
        return ""
    }

    private static func parseSessions(_ result: [String: Any]) -> [SessionSummary] {
        let rows = (result["sessions"] as? [[String: Any]]) ?? (result["active"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return SessionSummary(
                id: id,
                title: (row["title"] as? String) ?? (row["name"] as? String) ?? "Hermes session",
                state: (row["state"] as? String) ?? (row["status"] as? String) ?? "active",
                preview: row["preview"] as? String ?? row["last_message"] as? String
            )
        }
    }

    private static func parseProcesses(_ result: [String: Any]) -> [ProcessSummary] {
        let rows = (result["processes"] as? [[String: Any]]) ?? (result["items"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = (row["id"] as? String) ?? (row["pid"] as? String) else { return nil }
            return ProcessSummary(
                id: id,
                name: (row["name"] as? String) ?? (row["command"] as? String) ?? "Hermes process",
                state: (row["state"] as? String) ?? (row["status"] as? String) ?? "running",
                detail: row["detail"] as? String ?? row["command"] as? String
            )
        }
    }

    static func parseAgents(_ result: [String: Any]) -> [AgentSummary] {
        let rows = (result["active"] as? [[String: Any]]) ?? (result["agents"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            let id = (row["subagent_id"] as? String) ?? (row["id"] as? String)
            guard let id else { return nil }
            let state = DockModel.canonicalAgentStatus(
                (row["status"] as? String) ?? (row["state"] as? String)
            ) ?? "running"
            guard AgentActivityPresentation.isActiveStatus(state) else { return nil }
            return AgentSummary(
                id: id,
                name: (row["name"] as? String) ?? (row["role"] as? String) ?? id,
                state: state,
                sessionID: row["session_id"] as? String ?? row["sessionID"] as? String
            )
        }
    }

    static func makeSearchResults(
        query: String,
        sessions: [SessionSummary],
        attention: [AttentionItem],
        reminders: [ReminderSummary],
        projects: [ProjectSummary]
    ) -> [ControlSearchResult] {
        let normalized = query.localizedLowercase
        var results: [ControlSearchResult] = []
        func matches(_ title: String, _ detail: String) -> Bool {
            title.localizedLowercase.contains(normalized) || detail.localizedLowercase.contains(normalized)
        }

        results += sessions.compactMap { session in
            guard matches(session.title, session.preview ?? session.state) else { return nil }
            return ControlSearchResult(
                id: "session:\(session.id)",
                reference: ControlReference(source: .hermesSession, sourceID: session.id, sessionID: session.id),
                title: session.title,
                detail: session.preview ?? session.state,
                sourceLabel: "HERMES SESSION"
            )
        }
        results += attention.compactMap { item in
            guard matches(item.title, item.detail) else { return nil }
            return ControlSearchResult(id: "attention:\(item.id)", reference: item.reference, title: item.title, detail: item.detail, sourceLabel: "INBOX")
        }
        results += reminders.compactMap { reminder in
            let detail = reminder.list ?? "Apple Reminder"
            guard matches(reminder.title, detail) else { return nil }
            return ControlSearchResult(
                id: "reminder:\(reminder.id)",
                reference: ControlReference(source: .appleReminder, sourceID: reminder.id),
                title: reminder.title,
                detail: detail,
                sourceLabel: "APPLE REMINDER"
            )
        }
        results += projects.compactMap { project in
            guard matches(project.name, project.preview ?? "Hermes project") else { return nil }
            return ControlSearchResult(
                id: "project:\(project.id)",
                reference: ControlReference(source: .hermesProject, sourceID: project.id, projectID: project.id),
                title: project.name,
                detail: project.preview ?? "Hermes project",
                sourceLabel: "HERMES PROJECT"
            )
        }
        return results.sorted { lhs, rhs in
            if lhs.sourceLabel != rhs.sourceLabel { return lhs.sourceLabel < rhs.sourceLabel }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func parseSessionUsage(_ result: [String: Any]) -> SessionUsageSummary {
        SessionUsageSummary(
            calls: intValue(result["calls"]),
            inputTokens: intValue(result["input"] ?? result["input_tokens"]),
            outputTokens: intValue(result["output"] ?? result["output_tokens"]),
            totalTokens: intValue(result["total"] ?? result["total_tokens"]),
            contextUsed: optionalIntValue(result["context_used"]),
            contextMax: optionalIntValue(result["context_max"]),
            contextPercent: doubleValue(result["context_percent"]),
            model: result["model"] as? String
        )
    }

    static func parseSessionContext(_ result: [String: Any]) -> SessionContextSummary {
        let rows = (result["categories"] as? [[String: Any]] ?? []).enumerated().map { index, row in
            SessionContextCategory(
                id: (row["id"] as? String) ?? (row["name"] as? String) ?? "category-\(index)",
                label: (row["label"] as? String) ?? (row["name"] as? String) ?? "Category \(index + 1)",
                tokens: intValue(row["tokens"] ?? row["count"]),
                percent: doubleValue(row["percent"])
            )
        }
        return SessionContextSummary(
            categories: rows,
            contextUsed: intValue(result["context_used"]),
            contextMax: intValue(result["context_max"]),
            contextPercent: doubleValue(result["context_percent"]),
            estimatedTotal: intValue(result["estimated_total"]),
            model: result["model"] as? String
        )
    }

    static func parseProviderQuota(_ result: [String: Any]) -> ProviderQuotaSnapshot? {
        guard let provider = (result["provider"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provider.isEmpty,
              let updatedString = result["updated_at"] as? String,
              let updatedAt = QuotaJSON.iso8601Date(updatedString) else { return nil }
        let displayName = ((result["display_name"] as? String) ?? provider).trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = (result["windows"] as? [[String: Any]] ?? []).prefix(5).compactMap { row -> ProviderQuotaWindow? in
            guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return nil }
            let rawPercent = doubleValue(row["remaining_percent"])
            if row["remaining_percent"] != nil && (rawPercent == nil || !(0...100).contains(rawPercent!)) { return nil }
            let percent = rawPercent
            let resetsAt = (row["resets_at"] as? String).flatMap(QuotaJSON.iso8601Date)
            return ProviderQuotaWindow(
                id: id,
                label: label,
                remainingPercent: percent,
                remainingDisplay: boundedQuotaText(row["remaining_display"]),
                limitDisplay: boundedQuotaText(row["limit_display"]),
                resetsAt: resetsAt,
                resetsDisplay: boundedQuotaText(row["resets_display"])
            )
        }
        var unique: [ProviderQuotaWindow] = []
        var seen = Set<String>()
        for row in rows where seen.insert(row.id).inserted { unique.append(row) }
        return ProviderQuotaSnapshot(
            provider: provider,
            displayName: displayName,
            model: boundedQuotaText(result["model"]),
            updatedAt: updatedAt,
            windows: unique,
            safeDetail: boundedQuotaText(result["safe_detail"])
        )
    }

    private static func boundedQuotaText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 160 else { return nil }
        return clean
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func optionalIntValue(_ value: Any?) -> Int? {
        guard value != nil else { return nil }
        return intValue(value)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func parseKanbanTasks(_ output: String, boardSlug: String? = nil) -> [KanbanTaskSummary] {
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = (row["id"] as? String) ?? (row["task_id"] as? String),
                  let title = row["title"] as? String else { return nil }
            return KanbanTaskSummary(
                id: id,
                boardSlug: boardSlug,
                title: title,
                status: (row["status"] as? String) ?? "unknown",
                detail: (row["body"] as? String) ?? (row["description"] as? String),
                priority: Self.stringValue(row["priority"]),
                assignee: (row["assignee"] as? String) ?? (row["assigned_to"] as? String)
            )
        }
    }

    static func parseKanbanTaskDetail(_ output: String, fallback: KanbanTaskSummary, boardSlug: String? = nil) -> KanbanTaskDetail? {
        guard let data = output.data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let source = (row["task"] as? [String: Any]) ?? row
        guard let id = (source["id"] as? String) ?? (source["task_id"] as? String) else { return nil }
        return KanbanTaskDetail(
            id: id,
            boardSlug: boardSlug ?? fallback.boardSlug,
            title: (source["title"] as? String) ?? fallback.title,
            body: (source["body"] as? String) ?? (source["description"] as? String),
            status: (source["status"] as? String) ?? fallback.status,
            priority: Self.stringValue(source["priority"]) ?? fallback.priority,
            assignee: (source["assignee"] as? String) ?? (source["assigned_to"] as? String) ?? fallback.assignee,
            runs: []
        )
    }

    static func parseKanbanRuns(_ output: String, boardSlug: String? = nil) -> [KanbanRunSummary] {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if let array = value as? [[String: Any]] {
            rows = array
        } else if let dictionary = value as? [String: Any], let array = dictionary["runs"] as? [[String: Any]] {
            rows = array
        } else {
            return []
        }
        return rows.enumerated().compactMap { index, row in
            let id = (row["id"] as? String) ?? (row["run_id"] as? String) ?? "run-\(index)"
            guard let status = (row["status"] as? String) ?? (row["state"] as? String) else { return nil }
            return KanbanRunSummary(
                id: id,
                boardSlug: boardSlug,
                status: status,
                outcome: row["outcome"] as? String,
                profile: (row["profile"] as? String) ?? (row["assignee"] as? String),
                summary: (row["summary"] as? String) ?? (row["message"] as? String),
                elapsed: (row["elapsed"] as? String) ?? (row["duration"] as? String)
            )
        }
    }

    static func parseKanbanStats(_ output: String) -> KanbanStatsSummary? {
        guard let data = output.data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let source = (row["counts"] as? [String: Any])
            ?? (row["by_status"] as? [String: Any])
            ?? row
        let counts = source.reduce(into: [String: Int]()) { result, entry in
            if let number = entry.value as? NSNumber { result[entry.key] = number.intValue }
        }
        return counts.isEmpty ? nil : KanbanStatsSummary(counts: counts)
    }

    static func parseKanbanBoards(_ output: String) -> [KanbanBoardSummary] {
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let slug = row["slug"] as? String, !slug.isEmpty else { return nil }
            let rawCounts = row["counts"] as? [String: Any] ?? [:]
            let counts = rawCounts.reduce(into: [String: Int]()) { result, entry in
                if let number = entry.value as? NSNumber { result[entry.key] = number.intValue }
            }
            return KanbanBoardSummary(
                slug: slug,
                name: (row["name"] as? String) ?? slug,
                description: (row["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isCurrent: row["is_current"] as? Bool ?? false,
                archived: row["archived"] as? Bool ?? false,
                total: (row["total"] as? NSNumber)?.intValue ?? counts.values.reduce(0, +),
                counts: counts
            )
        }
    }

    static func parseKanbanAssignees(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [Any]
        if let array = value as? [Any] {
            rows = array
        } else if let dictionary = value as? [String: Any] {
            rows = (dictionary["assignees"] as? [Any]) ?? []
        } else {
            return []
        }
        return Array(Set(rows.compactMap { row in
            if let value = row as? String { return value }
            guard let row = row as? [String: Any] else { return nil }
            return (row["name"] as? String) ?? (row["profile"] as? String) ?? (row["id"] as? String)
        })).sorted()
    }

    static func parseKanbanDiagnostics(_ output: String, boardSlug: String?, severity: String? = nil) -> [KanbanDiagnosticSummary] {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["diagnostics"] as? [[String: Any]]) ?? []
        return rows.enumerated().compactMap { index, row in
            let rowSeverity = (row["severity"] as? String) ?? "warning"
            guard severity == nil || severity == rowSeverity else { return nil }
            let taskID = row["task_id"] as? String ?? row["taskID"] as? String
            let title = (row["title"] as? String) ?? "Kanban diagnostic"
            let fallback = [boardSlug ?? "default", taskID ?? "all", rowSeverity, title, String(index)].joined(separator: ":")
            return KanbanDiagnosticSummary(
                id: (row["id"] as? String) ?? fallback,
                severity: rowSeverity,
                title: title,
                detail: (row["detail"] as? String) ?? (row["message"] as? String) ?? "",
                taskID: taskID
            )
        }
    }

    static func parseProjectFacts(_ result: [String: Any]) -> ProjectFactsSummary? {
        guard let facts = result["facts"] as? [String: Any] else { return nil }
        return ProjectFactsSummary(
            root: facts["root"] as? String,
            manifests: facts["manifests"] as? [String] ?? [],
            packageManagers: (facts["packageManagers"] as? [String]) ?? (facts["package_managers"] as? [String]) ?? [],
            verifyCommands: (facts["verifyCommands"] as? [String]) ?? (facts["verify_commands"] as? [String]) ?? [],
            contextFiles: (facts["contextFiles"] as? [String]) ?? (facts["context_files"] as? [String]) ?? []
        )
    }

    static func parseVerification(_ result: [String: Any]) -> VerificationSummary {
        guard let verification = result["verification"] as? [String: Any] else {
            return VerificationSummary(state: .unknown, evidence: nil)
        }
        let state = VerificationState(rawValue: (verification["status"] as? String ?? "unknown")) ?? .unknown
        let evidenceRow = verification["evidence"] as? [String: Any]
        let evidence = evidenceRow.map {
            VerificationEvidenceSummary(
                command: $0["command"] as? String,
                canonicalCommand: $0["canonical_command"] as? String ?? $0["canonicalCommand"] as? String,
                kind: $0["kind"] as? String,
                scope: $0["scope"] as? String,
                status: $0["status"] as? String,
                exitCode: Self.optionalIntValue($0["exit_code"] ?? $0["exitCode"]),
                outputSummary: $0["output_summary"] as? String ?? $0["outputSummary"] as? String
            )
        }
        return VerificationSummary(state: state, evidence: evidence)
    }

    static func parseKanbanAttachments(_ value: Any, boardSlug: String?, taskID: String) -> [KanbanAttachmentSummary] {
        let rows = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["attachments"] as? [[String: Any]]) ?? []
        return rows.enumerated().map { index, row in
            let name = (row["name"] as? String) ?? (row["filename"] as? String) ?? "Attachment"
            let fallback = [boardSlug ?? "default", taskID, name, String(index)].joined(separator: ":")
            return KanbanAttachmentSummary(
                id: (row["id"] as? String) ?? fallback,
                name: name,
                kind: row["kind"] as? String ?? row["mime_type"] as? String,
                sizeBytes: Self.optionalIntValue(row["size"] ?? row["size_bytes"])
            )
        }
    }

    static func parseJourneyNodes(_ output: String) -> [HermesJourneyNode] {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = value["nodes"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return HermesJourneyNode(
                id: id,
                label: (row["label"] as? String) ?? id,
                kind: (row["kind"] as? String) ?? "node",
                category: row["category"] as? String,
                state: row["state"] as? String,
                useCount: (row["useCount"] as? NSNumber)?.intValue
            )
        }
    }

    static func readOnlyStatus(id: String, title: String, result: HermesCLIResult) -> HermesReadOnlyStatus {
        let output = result.succeeded ? result.stdout : result.stderr
        let detail = HermesDiagnosticsService.safeSummary(output)
        return HermesReadOnlyStatus(
            id: id,
            title: title,
            detail: detail.isEmpty ? (result.succeeded ? "Available" : "Unavailable") : detail,
            isAvailable: result.succeeded
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func parseCronRuns(_ output: String) -> [CronRunSummary] {
        var runs: [CronRunSummary] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                guard !runs.isEmpty else { continue }
                let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { continue }
                let current = runs.removeLast()
                let error = [current.error, message].compactMap { $0 }.joined(separator: "\n")
                runs.append(CronRunSummary(
                    id: current.id,
                    status: current.status,
                    jobID: current.jobID,
                    source: current.source,
                    claimedAt: current.claimedAt,
                    error: error,
                    sessionID: current.sessionID
                ))
                continue
            }
            let columns = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 2,
                  !raw.localizedCaseInsensitiveContains("No cron execution attempts") else { continue }
            let metadata = columns.dropFirst(2)
            let jobID = metadata.first(where: { $0.hasPrefix("job=") }).map { String($0.dropFirst(4)) }
            let source = metadata.first(where: { $0.hasPrefix("source=") }).map { String($0.dropFirst(7)) }
            let claimedAt = metadata.first(where: { !$0.contains("=") }).map(String.init)
            runs.append(CronRunSummary(
                id: String(columns[0]),
                status: String(columns[1]),
                jobID: jobID,
                source: source,
                claimedAt: claimedAt,
                error: nil,
                sessionID: cronSessionID(jobID: jobID, claimedAt: claimedAt)
            ))
        }
        return runs
    }

    private static func cronSessionID(jobID: String?, claimedAt: String?) -> String? {
        guard let jobID, let claimedAt, claimedAt.count >= 19 else { return nil }
        let localTimestamp = String(claimedAt.prefix(19))
        let date = localTimestamp.prefix(10).replacingOccurrences(of: "-", with: "")
        let time = localTimestamp.dropFirst(11).prefix(8).replacingOccurrences(of: ":", with: "")
        guard date.count == 8, time.count == 6 else { return nil }
        return "cron_\(jobID)_\(date)_\(time)"
    }

    static func parseMCPServers(_ output: String) -> [MCPServerSummary] {
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        return clean.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  !text.localizedCaseInsensitiveContains("MCP Servers:"),
                  !text.localizedCaseInsensitiveContains("No MCP servers configured"),
                  !text.hasPrefix("─") else { return nil }

            let columns = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 4,
                  columns[0].lowercased() != "name",
                  let toolMarkerIndex = columns.firstIndex(where: { $0 == "all" || $0 == "selected" || $0 == "excluded" }) else { return nil }

            let toolIndex = columns[toolMarkerIndex] == "all" ? toolMarkerIndex : toolMarkerIndex - 1
            guard toolIndex > 1, toolMarkerIndex + 1 < columns.count else { return nil }

            let name = columns[0]
            let transport = columns[1..<toolIndex].joined(separator: " ")
            let tools = columns[toolIndex...toolMarkerIndex].joined(separator: " ")
            let status = columns[(toolMarkerIndex + 1)...].joined(separator: " ").lowercased()
            return MCPServerSummary(
                id: name,
                name: name,
                transport: transport,
                tools: tools,
                isEnabled: !status.contains("disabled")
            )
        }
    }

    static func reminderAttention(for reminder: ReminderSummary) -> AttentionItem {
        let detail = [reminder.isOverdue ? "OVERDUE" : nil, reminder.list].compactMap { $0 }.joined(separator: "  ·  ")
        return AttentionItem(
            id: "reminder:\(reminder.id)",
            reference: ControlReference(source: .appleReminder, sourceID: reminder.id),
            kind: .reminder,
            title: reminder.title,
            detail: detail.isEmpty ? "Apple Reminder" : detail,
            createdAt: reminder.dueDate ?? Date(),
            state: .open,
            actions: [.complete, .dismiss]
        )
    }

    static func parseProjects(_ result: [String: Any]) -> [ProjectSummary] {
        let activeID = result["active_id"] as? String
        let rows = (result["projects"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let repos = (row["repos"] as? [[String: Any]]) ?? (row["repositories"] as? [[String: Any]]) ?? []
            let sessions = (row["sessions"] as? [[String: Any]]) ?? (row["preview_sessions"] as? [[String: Any]]) ?? []
            let declaredSessionCount = (row["session_count"] as? NSNumber)?.intValue
            // Projects can return session records inside their repository lanes,
            // while `session_count` is absent or stale. Preserve a larger
            // declared total but never hide the sessions that are present.
            let projectSessions = parseProjectSessions(row)
            let sessionCount = max(max(declaredSessionCount ?? 0, sessions.count), projectSessions.count)
            return ProjectSummary(
                id: id,
                name: (row["name"] as? String) ?? id,
                repoCount: (row["repo_count"] as? NSNumber)?.intValue ?? repos.count,
                sessionCount: sessionCount,
                sessionIDs: Set(projectSessions.map(\.id)),
                preview: (sessions.first?["preview"] as? String) ?? (sessions.first?["title"] as? String),
                isActive: (row["active"] as? Bool) ?? (id == activeID)
            )
        }
    }

    static func parseProjectSessions(_ result: [String: Any]) -> [SessionSummary] {
        var rows: [[String: Any]] = []

        func walk(_ value: Any) {
            if let row = value as? [String: Any] {
                let looksLikeSession = row["state"] != nil || row["status"] != nil || row["preview"] != nil || row["last_message"] != nil
                if row["id"] is String && looksLikeSession {
                    rows.append(row)
                }
                row.values.forEach(walk)
            } else if let values = value as? [Any] {
                values.forEach(walk)
            }
        }

        walk(result)
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["id"] as? String, seen.insert(id).inserted else { return nil }
            return SessionSummary(
                id: id,
                title: (row["title"] as? String) ?? (row["name"] as? String) ?? "Hermes session",
                state: (row["state"] as? String) ?? (row["status"] as? String) ?? "active",
                preview: row["preview"] as? String ?? row["last_message"] as? String
            )
        }
    }

}
