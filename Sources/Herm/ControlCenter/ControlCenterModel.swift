import Foundation
import Combine

@MainActor
final class ControlCenterModel: ObservableObject {
    let pet = HermesPetModel()
    let gatewayService = HermesGatewayLifecycleModel()
    enum KanbanRefreshTrigger {
        case user
        case background
    }

    private enum KanbanRefreshScope: Hashable {
        case aggregate
        case visible

        var isAggregate: Bool {
            if case .aggregate = self { return true }
            return false
        }
    }
    nonisolated static func safeUserDiagnostic(_ raw: String) -> String {
        HermesDiagnosticsService.safeSummary(raw)
    }

    @Published private(set) var attention: [AttentionItem] = []
    @Published private(set) var reminders: [ReminderSummary] = []
    @Published private(set) var cronJobs: [CronSummary] = []
    @Published private(set) var cronRuns: [CronRunSummary] = []
    @Published private(set) var cronHistoryAvailable = false
    /// Per-job history. The global `cronRuns` feed is capped, so high-frequency
    /// jobs crowd daily/weekly jobs out of it entirely.
    @Published private(set) var cronRunsByJob: [String: [CronRunSummary]] = [:]
    @Published private(set) var mcpServers: [MCPServerSummary] = []
    @Published private(set) var mcpTestResults: [String: String] = [:]
    @Published private(set) var mcpInventoryAvailable = false
    @Published private(set) var commandAllowlistEntries: [String]?
    @Published private(set) var activeSessions: [SessionSummary] = []
    @Published private(set) var latestActivities: [LatestActivityItem] = []
    @Published private(set) var currentFocus: ControlReference?
    @Published private(set) var activeAgents: [AgentSummary] = []
    @Published private(set) var delegationPaused = false
    @Published private(set) var processes: [ProcessSummary] = []
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var projectIDBySessionID: [String: String] = [:]
    /// Memberships resolved from `projects.project_sessions`. The project tree
    /// may omit these IDs on later refreshes, so retain them separately from
    /// the transient tree projection.
    private var resolvedProjectIDBySessionID: [String: String] = [:]
    @Published private(set) var searchResults: [ControlSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var kanbanTasks: [KanbanTaskSummary] = []
    /// Canonical unfiltered aggregate, independent of the board page's visible filters.
    @Published private(set) var globalKanbanTasks: [KanbanTaskSummary] = []
    @Published private(set) var globalKanbanIsCurrent = false
    @Published var requestedKanbanTask: KanbanTaskSummary?
    @Published private(set) var sessionKanbanTasks: [KanbanTaskSummary] = []
    @Published private(set) var sessionKanbanSessionID: String?
    @Published private(set) var kanbanDetail: KanbanTaskDetail?
    @Published private(set) var kanbanDetailTaskIdentity: KanbanTaskIdentity?
    @Published private(set) var kanbanDetailError: String?
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
    @Published private(set) var tokenUsage: TokenUsageReport?
    private var tokenUsageGeneration = UUID()
    private var tokenUsageModelRows: [String: Any] = [:]
    @Published private(set) var providerQuotas: [ProviderQuotaSnapshot] = []
    /// Snapshots exactly as the providers reported them. `providerQuotas` is
    /// derived from these plus the user's nicknames and display order, so a
    /// rename or reorder never needs another provider read.
    private var reportedProviderQuotas: [ProviderQuotaSnapshot] = []
    /// Safe per-provider diagnostics from the last quota refresh, keyed by
    /// catalog provider id. Providers without an entry connected successfully;
    /// missing providers render disabled with their diagnostic, never invented.
    @Published private(set) var providerQuotaDiagnostics: [String: String] = [:]
    @Published private(set) var kanbanDiagnostics: [KanbanDiagnosticSummary] = []
    @Published private(set) var kanbanAttachments: [KanbanAttachmentSummary] = []
    /// Keyed task detail for inspectors that sit beside the Kanban page (the
    /// 3D office). Separate from `kanbanDetail`, so the two never clobber.
    @Published private(set) var kanbanTaskInspections: [KanbanTaskIdentity: KanbanTaskInspection] = [:]
    @Published private(set) var promptBudget: PromptBudgetSummary?
    @Published private(set) var projectFacts: ProjectFactsSummary?
    @Published private(set) var verification: VerificationSummary?
    @Published private(set) var appearanceProjection: AppearanceCLIProjection.Inventory?
    @Published private(set) var appearanceProjectionAvailable = false
    @Published private(set) var insightsSummary: HermesInsightsSummary?
    @Published private(set) var checkpoints: [HermesCheckpointSummary] = []
    @Published private(set) var restoreCheckpoints: [RestoreCheckpoint] = []
    @Published private(set) var restoreCheckpointState: RestoreCheckpointState = .idle
    @Published private(set) var checkpointDiff: String?
    @Published private(set) var isLoadingCheckpoints = false
    @Published private(set) var emergencyStopActive: Bool?
    @Published private(set) var emergencyStopMessage: String?
    @Published private(set) var developmentContext: RepositorySnapshot?
    @Published private(set) var loadingKanbanDetailTaskID: String?
    @Published private(set) var isCreatingKanbanTask = false
    @Published private(set) var projectSessions: [SessionSummary] = []
    /// Authoritative session rows keyed by project. Unlike `projects.tree`,
    /// this projection contains every session in a project, not just a count
    /// or a short preview.
    @Published private(set) var projectSessionsByProjectID: [String: [SessionSummary]] = [:]
    @Published private(set) var isRefreshingProjectNavigation = false
    private var didLoadInitialProjectNavigation = false
    @Published private(set) var selectedProjectID: String?
    /// Profile scope used exclusively by the Projects projection and its
    /// mutations. Other Control tabs remain gateway-global by design.
    @Published private(set) var projectProfileID: String?
    @Published private(set) var projectProfileScopeUnavailable = false
    /// Keeps the Projects detail view stable while its background projection is
    /// refreshing. A selected project can briefly be absent from a partial
    /// `projects.tree` response, but that must not dismiss the user's detail.
    @Published private(set) var selectedProject: ProjectSummary?
    @Published private(set) var capabilities: [CapabilityState] = []
    private var capabilitySnapshotGeneratedAt: Date = .distantPast
    @Published private(set) var diagnostics: [HermesDiagnostic] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var pendingActionIDs: Set<String> = []
    @Published private(set) var lastError: String?
    /// Failures of quota-card actions (such as removing a Hermes-pooled
    /// account), keyed by provider id and shown on that card.
    @Published private(set) var providerQuotaActionErrors: [String: String] = [:]
    /// `provider/id` of each pooled credential Hermes currently selects.
    @Published private(set) var hermesActiveCredentialKeys: Set<String> = []
    @Published private(set) var projectionRefreshStates: [String: ProjectionRefreshState] = [:]
    @Published private(set) var projectionStates: [String: HermesProjectionState<Int>] = [:]

    /// Presentation-only invalidation for the left navigation rail. The
    /// control center still publishes its complete object change stream to
    /// destinations that need it, while the rail listens to this narrow set.
    var sidebarPresentationChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            $attention.map { _ in () }.eraseToAnyPublisher(),
            $activeSessions.map { _ in () }.eraseToAnyPublisher(),
            $latestActivities.map { _ in () }.eraseToAnyPublisher(),
            $projects.map { _ in () }.eraseToAnyPublisher(),
            $projectIDBySessionID.map { _ in () }.eraseToAnyPublisher(),
            $projectSessionsByProjectID.map { _ in () }.eraseToAnyPublisher(),
            $projectProfileID.map { _ in () }.eraseToAnyPublisher(),
            $isRefreshing.map { _ in () }.eraseToAnyPublisher(),
            $isRefreshingProjectNavigation.map { _ in () }.eraseToAnyPublisher()
        ).eraseToAnyPublisher()
    }

    /// Installs deterministic navigation data for local scroll profiling. It
    /// never runs in production because the caller gates it on the debug flag.
    func installScrollPerformanceFixture(_ fixture: ScrollPerformanceFixture) {
        let sessions = fixture.sessions.map {
            SessionSummary(
                id: $0.id,
                title: $0.title,
                state: "completed",
                preview: $0.preview,
                updatedAt: $0.updatedAt,
                profileID: $0.profileID
            )
        }
        let projectsPerGroup = max(1, fixture.projectCount)
        projects = (0..<projectsPerGroup).map { index in
            let members = sessions.enumerated().compactMap { offset, session in
                offset % projectsPerGroup == index ? session.id : nil
            }
            return ProjectSummary(
                id: "scroll-fixture-project-\(index)",
                name: "Fixture project \(index)",
                repoCount: 1,
                sessionCount: members.count,
                sessionIDs: Set(members),
                preview: "Performance fixture",
                isActive: index == 0
            )
        }
        projectIDBySessionID = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { offset, session in
            (session.id, "scroll-fixture-project-\(offset % projectsPerGroup)")
        })
        projectSessionsByProjectID = Dictionary(grouping: sessions) { session in
            projectIDBySessionID[session.id] ?? "scroll-fixture-project-0"
        }
        activeSessions = Array(sessions.prefix(24))
    }

    private weak var dockModel: DockModel?
    private var rpc: HermesControlRPC?
    /// Desktop-parity editor for Hermes `config.yaml`, over the same backend.
    lazy var configEditor = HermesConfigEditor { [weak self] in self?.rpc }
    private var cli: HermesCLIAdapter?
    private var refreshTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var initialProjectNavigationTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var clientBindingGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var aggregateKanbanRefreshGeneration = UUID()
    private var visibleKanbanRefreshGeneration = UUID()
    private var kanbanRefreshInFlight: Set<KanbanRefreshScope> = []
    private var sessionKanbanRefreshGeneration = UUID()
    private var sessionKanbanTask: Task<Void, Never>?
    private var sessionKanbanRequest: SessionKanbanProjectionRequest?
    private var sessionKanbanRefreshPending = false
    private var sessionKanbanBoardSlug: String?
    /// Last successful session Activity snapshots. Session navigation swaps the
    /// published projection, but must not make already loaded work disappear
    /// while the same read-only query refreshes in the background.
    private var sessionKanbanTasksByRequest: [SessionKanbanProjectionRequest: [KanbanTaskSummary]] = [:]
    private var kanbanBoardsGeneration = UUID()
    private var kanbanStatsGeneration = UUID()
    private var kanbanAssigneesGeneration = UUID()
    private var kanbanDetailGeneration = UUID()
    private var kanbanTaskInspectionGenerations: [KanbanTaskIdentity: UUID] = [:]
    private var kanbanTaskInspectionOrder: [KanbanTaskIdentity] = []
    private var kanbanDiagnosticsGeneration = UUID()
    private var kanbanAttachmentsGeneration = UUID()
    private var promptBudgetGeneration = UUID()
    private var projectFactsGeneration = UUID()
    private var verificationGeneration = UUID()
    private var appearanceProjectionGeneration = UUID()
    private var checkpointsGeneration = UUID()
    private let restoreCheckpointCoordinator = RestoreCheckpointCoordinator()
    private var projectSessionsGeneration = UUID()
    private var projectNavigationRefreshGeneration: UUID?
    private var pendingProjectNavigationSessions: [String: [SessionSummary]] = [:]
    private var completedProjectNavigationIDs: Set<String> = []
    private var projectNavigationRefreshIDs: Set<String> = []
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
    let providerNicknameStore = ProviderNicknameStore()
    private static let providerQuotaOrderKey = "dock.quota.displayOrder"
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

    /// Read-only presentation projection of the latest capability probe.
    /// The probe remains the sole source of capability state.
    var capabilitySnapshot: CapabilitySnapshot {
        CapabilitySnapshot(states: capabilities, generatedAt: capabilitySnapshotGeneratedAt)
    }

    func capabilityAvailable(_ id: String) -> Bool {
        capabilities.first(where: { $0.id == id })?.isAvailable == true
    }

    /// The capability probe can time out while `cron.manage list` itself works;
    /// a successful job listing over the same RPC proves cron control.
    var cronControlAvailable: Bool {
        guard rpc != nil else { return false }
        return capabilityAvailable("rpc-scheduling") || refreshState(for: "cron.jobs")?.lastSuccess != nil
    }

    /// The workspace store owns repository selection. The control center keeps
    /// only this rendered snapshot for its Today projection.
    func setDevelopmentContextProjection(_ snapshot: RepositorySnapshot?) {
        developmentContext = snapshot
        refreshVerification()
    }

    #if DEBUG
    /// Test-only injection point for exercising rendered Kanban states without
    /// starting the gateway refresh loop.
    internal func setKanbanTasksForTesting(_ tasks: [KanbanTaskSummary]) {
        kanbanTasks = tasks
    }
    #endif

    var isKanbanRefreshPending: Bool {
        pendingActionIDs.contains(visibleKanbanRefreshActionID)
            || pendingActionIDs.contains(aggregateKanbanRefreshActionID)
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

    func projectSessionsProjectionKey(for projectID: String) -> String {
        "projects.sessions.\(projectID)"
    }

    func projectionState(for projection: String) -> HermesProjectionState<Int>? {
        projectionStates[projection]
    }

    private func isCurrentRefresh(_ generation: UInt64, clientIdentity: ObjectIdentifier?) -> Bool {
        refreshGeneration == generation &&
            dockModel.map { ObjectIdentifier($0.controlRPCClient) } == clientIdentity
    }

    private func isCurrentClient(_ identity: ObjectIdentifier?, bindingGeneration: UInt64? = nil) -> Bool {
        if let identity {
            guard dockModel.map({ ObjectIdentifier($0.controlRPCClient) }) == identity else { return false }
        } else if dockModel != nil {
            return false
        }
        return bindingGeneration.map { $0 == clientBindingGeneration } ?? true
    }

    private func beginProjectionRefresh(_ projection: String) {
        let previous = projectionRefreshStates[projection]
        projectionRefreshStates[projection] = ProjectionRefreshState(
            lastSuccess: previous?.lastSuccess,
            error: previous?.error,
            isStale: previous?.lastSuccess != nil,
            isRefreshing: true
        )
        if let previousState = projectionStates[projection] {
            switch previousState {
            case .ready(let count), .stale(let count, _):
                projectionStates[projection] = .stale(count, safeMessage: "Hermes projection is refreshing. Refresh to try again.")
            default:
                projectionStates[projection] = .loading
            }
        } else {
            projectionStates[projection] = .loading
        }
    }

    func recordProjectionSuccess(_ projection: String, count: Int? = nil) {
        let resolvedCount = count ?? projectionCount(projection)
        projectionRefreshStates[projection] = ProjectionRefreshState(lastSuccess: .now, error: nil, isStale: false, isRefreshing: false)
        projectionStates[projection] = resolvedCount == 0 ? .empty : .ready(resolvedCount)
    }

    /// Publishes an explicit capability boundary when this model has no Hermes
    /// gateway to query. This is distinct from a failed request and keeps the
    /// UI from presenting an unsupported projection as an empty result.
    func recordProjectionUnavailable(_ projection: String) {
        projectionRefreshStates[projection] = ProjectionRefreshState(lastSuccess: nil, error: nil, isStale: false, isRefreshing: false)
        projectionStates[projection] = .unavailable(safeMessage: "Hermes projection is unavailable because this capability is not supported or authorized. Reconnect Hermes and retry.")
    }

    func recordProjectionFailure(_ projection: String, error: String) {
        let previous = projectionRefreshStates[projection]
        projectionRefreshStates[projection] = ProjectionRefreshState(
            lastSuccess: previous?.lastSuccess,
            error: HermesDiagnosticsService.safeSummary(error),
            isStale: previous?.lastSuccess != nil,
            isRefreshing: false
        )
        let safeMessage = "Hermes projection is unavailable. Refresh to try again."
        let capabilityDenied = ["unsupported", "unauthorized", "forbidden", "denied"]
            .contains { error.localizedCaseInsensitiveContains($0) }
        if capabilityDenied {
            projectionStates[projection] = .unavailable(safeMessage: "Hermes projection is unavailable because this capability is not supported or authorized. Reconnect Hermes and retry.")
            return
        }
        if let previousState = projectionStates[projection] {
            switch previousState {
            case .ready(let count), .stale(let count, _):
                projectionStates[projection] = .stale(count, safeMessage: safeMessage)
            case .empty:
                projectionStates[projection] = .stale(0, safeMessage: safeMessage)
            default:
                projectionStates[projection] = .failed(safeMessage: safeMessage)
            }
        } else {
            projectionStates[projection] = .failed(safeMessage: safeMessage)
        }
    }

    private func projectionCount(_ projection: String) -> Int {
        switch projection {
        case "sessions": return activeSessions.count
        case "projects.sessions": return projectSessions.count
        case "projects": return projects.count
        case "agents": return activeAgents.count
        case "processes": return processes.count
        case "latest.activity": return latestActivities.count
        case "cron.jobs": return cronJobs.count
        case "reminders": return reminders.count
        case "kanban.global": return globalKanbanTasks.count
        default: return 0
        }
    }

    func cronActionID(_ action: String, job: CronSummary) -> String { "cron.\(action):\(job.id)" }
    func kanbanActionID(_ action: KanbanTaskAction, task: KanbanTaskSummary) -> String { "kanban.\(action.rawValue):\(task.id)" }
    func kanbanActionID(_ action: KanbanMutationKind, task: KanbanTaskSummary) -> String { "kanban.\(action.rawValue):\(task.id)" }
    func attentionActionID(_ action: AttentionAction, item: AttentionItem) -> String { "attention.\(action.rawValue):\(item.id)" }
    func reminderActionID(_ reminder: ReminderSummary) -> String { "reminder.complete:\(reminder.id)" }
    func mcpTestActionID(_ server: MCPServerSummary) -> String { "mcp.test:\(server.id)" }
    var reloadMCPActionID: String { "mcp.reload" }
    var refreshKanbanActionID: String { "kanban.refresh" }
    private var aggregateKanbanRefreshActionID: String { "kanban.refresh.aggregate" }
    private var visibleKanbanRefreshActionID: String { "kanban.refresh.visible" }
    var refreshKanbanBoardsActionID: String { "kanban.boards.refresh" }
    var emergencyStopActionID: String { "dispatch.pause" }
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
        if !capabilities.isEmpty {
            capabilitySnapshotGeneratedAt = .now
        }
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
                    let result = try await rpc.cron(action: "list")
                    var jobs = Self.parseCronJobs(result)
                    if let sessions = try? await rpc.sessions(limit: 200) {
                        jobs = Self.attachLatestCronSessions(to: jobs, from: sessions)
                    }
                    guard self.isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
                    cronJobs = jobs
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

    /// Every quota service the Dock reads, by stable reader id.
    private static let quotaReaders: [(id: String, read: @Sendable () async throws -> [String: Any])] = [
        ("codex-hermes", CodexQuotaService.readHermes),
        ("opencode", OpenCodeQuotaService.read),
        ("glm", GLMQuotaService.read),
        ("claude", ClaudeQuotaService.read),
        ("antigravity", AntigravityQuotaService.read)
    ]

    /// The reader that last reported each snapshot's provider id.
    private var providerQuotaReaderIDs: [String: String] = [:]

    func quotaReaderID(for providerID: String) -> String? { providerQuotaReaderIDs[providerID] }

    /// Loads the stored Codex account quota through Codex's authenticated usage endpoint,
    /// independently of the active Hermes provider/model. Each provider is
    /// published as soon as its read returns, so one slow service never holds
    /// back the rest. `readerIDs` limits the read to those services and keeps
    /// every other provider's last reading.
    func refreshProviderQuota(only readerIDs: Set<String>? = nil) {
        let generation = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        providerQuotaGeneration = generation
        guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else {
            providerQuotas = []
            reportedProviderQuotas = []
            return
        }
        beginProjectionRefresh("provider.quota")
        let readers = Self.quotaReaders.filter { readerIDs?.contains($0.id) ?? true }
        Task { @MainActor in
            var diagnostics = readerIDs == nil ? [:] : providerQuotaDiagnostics
            var seen = Set<String>()
            var errors: [String] = []
            await withTaskGroup(of: (String, QuotaReadResult).self) { group in
                for reader in readers {
                    group.addTask { await (reader.id, Self.readQuota(reader.read)) }
                }
                for await (readerID, result) in group {
                    guard generation == providerQuotaGeneration,
                          self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { continue }
                    let previous = reportedProviderQuotas.filter { providerQuotaReaderIDs[$0.provider] == readerID }
                    diagnostics[readerID] = nil
                    if let error = result.error {
                        // A failed read keeps the last reading rather than
                        // dropping the provider until the next success.
                        diagnostics[readerID] = error
                        errors.append(error)
                        seen.formUnion(previous.map(\.provider))
                        continue
                    }
                    let snapshots = Self.providerQuotaSnapshots(readerID: readerID, raw: result.value)
                    for snapshot in snapshots { providerQuotaReaderIDs[snapshot.provider] = readerID }
                    seen.formUnion(snapshots.map(\.provider))
                    guard snapshots != previous else { continue }
                    let replaced = Set(previous.map(\.provider))
                    reportedProviderQuotas = reportedProviderQuotas.filter { !replaced.contains($0.provider) } + snapshots
                    applyProviderQuotaPresentation()
                }
            }
            guard generation == providerQuotaGeneration else { return }
            guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else {
                // Rebound mid-read: clear the spinner or every later poll,
                // which skips while a read is in flight, would stall.
                recordProjectionFailure("provider.quota", error: "Quota read was interrupted.")
                return
            }
            if providerQuotaDiagnostics != diagnostics { providerQuotaDiagnostics = diagnostics }
            if readerIDs == nil, reportedProviderQuotas.contains(where: { !seen.contains($0.provider) }) {
                reportedProviderQuotas.removeAll { !seen.contains($0.provider) }
                applyProviderQuotaPresentation()
            }
            if !seen.isEmpty {
                refreshHermesActiveCredentials()
                recordProjectionSuccess("provider.quota")
            } else {
                recordProjectionFailure("provider.quota", error: errors.first ?? "Provider quota data is unavailable.")
            }
        }
    }

    /// Codex through Hermes may report several pooled accounts at once.
    private static func providerQuotaSnapshots(readerID: String, raw: [String: Any]?) -> [ProviderQuotaSnapshot] {
        guard let raw else { return [] }
        if readerID == "codex-hermes", let accounts = raw["_accounts"] as? [[String: Any]] {
            return accounts.compactMap(parseProviderQuota)
        }
        return parseProviderQuota(raw).map { [$0] } ?? []
    }

    /// Saves (or removes, when nil) a user-entered API key for an API-key
    /// provider and immediately re-reads quota with it.
    func saveProviderAPIKey(_ key: String?, for descriptor: QuotaProviderDescriptor) {
        guard let storageKey = descriptor.storageKey else { return }
        ProviderKeyStore().save(key, storageKey: storageKey)
        refreshProviderQuota()
    }
    
    /// Rebuilds `providerQuotas` from the last reported snapshots, applying
    /// nicknames and the saved display order without re-reading providers.
    private func applyProviderQuotaPresentation() {
        let named = reportedProviderQuotas.map { snapshot in
            ProviderQuotaSnapshot(
                provider: snapshot.provider,
                displayName: providerNicknameStore.nickname(for: snapshot.provider) ?? snapshot.displayName,
                model: snapshot.model,
                updatedAt: snapshot.updatedAt,
                windows: snapshot.windows,
                safeDetail: snapshot.safeDetail,
                hermesCredential: snapshot.hermesCredential
            )
        }
        providerQuotas = QuotaWorkspacePresentation.ordered(named, savedOrder: providerQuotaOrder)
    }

    /// Sets a custom display name (nickname) for a provider. Persists across
    /// app launches. An empty or whitespace-only name restores the default.
    func setProviderNickname(_ nickname: String, for providerID: String) {
        providerNicknameStore.setNickname(nickname, for: providerID)
        applyProviderQuotaPresentation()
    }

    /// Gets the custom display name for a provider, or nil if not set.
    func getProviderNickname(for providerID: String) -> String? {
        providerNicknameStore.nickname(for: providerID)
    }

    /// The name the provider itself reports, ignoring any nickname.
    func reportedProviderName(for providerID: String) -> String? {
        reportedProviderQuotas.first(where: { $0.provider == providerID })?.displayName
    }

    /// Removes the custom nickname for a provider (reverts to default).
    func removeProviderNickname(for providerID: String) {
        providerNicknameStore.removeNickname(for: providerID)
        applyProviderQuotaPresentation()
    }

    /// The user's saved order of connected quota providers, keyed by the
    /// reported provider id so individual Hermes accounts (`codex-hermes-<pool entry id>`) can be
    /// ordered independently.
    var providerQuotaOrder: [String] {
        presentationDefaults.stringArray(forKey: Self.providerQuotaOrderKey) ?? []
    }

    /// Moves `providerID` into the position currently held by `targetID` and
    /// persists the resulting order.
    func moveProviderQuota(_ providerID: String, to targetID: String) {
        let current = providerQuotas.map(\.provider)
        let reordered = QuotaWorkspacePresentation.moving(providerID, to: targetID, in: current)
        guard reordered != current else { return }
        saveProviderQuotaOrder(reordered)
    }

    /// Moves a provider one position up (`offset: -1`) or down (`offset: 1`).
    func moveProviderQuota(_ providerID: String, by offset: Int) {
        let current = providerQuotas.map(\.provider)
        guard let index = current.firstIndex(of: providerID) else { return }
        let target = index + offset
        guard current.indices.contains(target) else { return }
        moveProviderQuota(providerID, to: current[target])
    }

    private func saveProviderQuotaOrder(_ ids: [String]) {
        // Keep ids of providers that are temporarily disconnected, after the
        // visible ones, so reconnecting does not lose their saved position.
        let retained = providerQuotaOrder.filter { !ids.contains($0) }
        presentationDefaults.set(ids + retained, forKey: Self.providerQuotaOrderKey)
        applyProviderQuotaPresentation()
    }

    static func hermesCredentialRemovalActionID(_ providerID: String) -> String {
        "quota.hermesCredential.remove.\(providerID)"
    }

    /// Re-reads which pooled credential Hermes would pick next (the `←` row of
    /// `hermes auth list`), keyed `provider/id`. Under `round_robin` that is the
    /// account next in line, since Hermes rotates the order after each pick.
    func refreshHermesActiveCredentials() {
        guard let cli, reportedProviderQuotas.contains(where: { $0.hermesCredential != nil }) else { return }
        Task {
            await restoreHermesPrimaryCredentials(cli)
            guard let result = try? await cli.authList(), result.succeeded else { return }
            let active = Self.hermesActiveCredentialKeys(fromAuthList: result.stdout)
            if active != hermesActiveCredentialKeys { hermesActiveCredentialKeys = active }
        }
    }

    private static let hermesPrimaryCredentialsKey = "quota.hermesPrimaryCredentials"

    /// Primary picked through Make primary, `provider -> pool entry id`.
    private var hermesPrimaryCredentials: [String: String] {
        get { presentationDefaults.dictionary(forKey: Self.hermesPrimaryCredentialsKey) as? [String: String] ?? [:] }
        set { presentationDefaults.set(newValue, forKey: Self.hermesPrimaryCredentialsKey) }
    }

    /// Hermes saves a pool with each process's in-memory priorities, so a
    /// gateway or session that loaded the pool before Make primary writes the
    /// old order back on its next flush (token refresh, rotation). Re-apply the
    /// user's pick whenever it has slipped, but only under `fill_first`, where
    /// order is meant to be stable; a pick whose account is gone is forgotten.
    private func restoreHermesPrimaryCredentials(_ cli: HermesCLIAdapter) async {
        let pins = hermesPrimaryCredentials
        guard !pins.isEmpty else { return }
        if configEditor.state == .idle { await configEditor.load() }
        guard configEditor.state == .ready else { return }
        let credentials = reportedProviderQuotas.compactMap(\.hermesCredential)
        let plan = Self.hermesPrimaryRestorePlan(pins: pins, credentials: credentials) {
            self.configEditor.value("credential_pool_strategies.\($0)") as? String
        }
        if plan.forget.isEmpty == false {
            hermesPrimaryCredentials = pins.filter { !plan.forget.contains($0.key) }
        }
        for credential in plan.restore {
            _ = try? await cli.authPriority(provider: credential.provider, credentialID: credential.id, priority: 0)
        }
    }

    nonisolated static func hermesPrimaryRestorePlan(
        pins: [String: String],
        credentials: [HermesPooledCredential],
        strategy: (String) -> String?
    ) -> (restore: [HermesPooledCredential], forget: Set<String>) {
        var restore: [HermesPooledCredential] = []
        var forget = Set<String>()
        for (provider, id) in pins {
            let pool = credentials.filter { $0.provider == provider }
            // No cards for the provider yet (read failed): keep the pin, decide next refresh.
            guard !pool.isEmpty else { continue }
            guard let pinned = pool.first(where: { $0.id == id }) else { forget.insert(provider); continue }
            let current = strategy(provider) ?? "fill_first"
            if current == "fill_first", pinned.position != 1 { restore.append(pinned) }
        }
        return (restore, forget)
    }

    func isHermesPinnedPrimary(_ credential: HermesPooledCredential) -> Bool {
        hermesPrimaryCredentials[credential.provider] == credential.id
    }

    func isHermesActiveCredential(_ credential: HermesPooledCredential) -> Bool {
        hermesActiveCredentialKeys.contains("\(credential.provider)/\(credential.id)")
    }

    /// Parses `hermes auth list`: `<provider> (N credentials):` headers, then
    /// entry rows carrying `id=<id>` and a trailing `←` on the selected one.
    nonisolated static func hermesActiveCredentialKeys(fromAuthList output: String) -> Set<String> {
        var provider = ""
        var keys = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            if !line.hasPrefix(" "), let header = line.split(separator: " ").first, line.hasSuffix("credentials):") {
                provider = String(header)
            } else if line.contains("←"),
                      let id = line.split(separator: " ").first(where: { $0.hasPrefix("id=") })?.dropFirst(3), !id.isEmpty {
                keys.insert("\(provider)/\(id)")
            }
        }
        return keys
    }

    static func hermesCredentialPrimaryActionID(_ providerID: String) -> String {
        "quota.hermesCredential.primary.\(providerID)"
    }

    /// Moves a pooled account to the front of Hermes' pool order through
    /// `hermes auth priority <provider> <id> 0`. Under `round_robin` Hermes
    /// rotates the order after each pick, so it only stays first until then.
    func makeHermesPooledCredentialPrimary(for providerID: String) {
        guard let credential = reportedProviderQuotas.first(where: { $0.provider == providerID })?.hermesCredential else { return }
        guard let cli else {
            providerQuotaActionErrors[providerID] = "Hermes is not connected, so the account order could not be changed."
            return
        }
        let actionID = Self.hermesCredentialPrimaryActionID(providerID)
        guard beginAction(actionID) else { return }
        providerQuotaActionErrors[providerID] = nil
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.authPriority(provider: credential.provider, credentialID: credential.id, priority: 0)
                guard result.succeeded else {
                    let message = Self.safeUserDiagnostic(result.stderr)
                    providerQuotaActionErrors[providerID] = message.isEmpty ? "Hermes could not reorder this account." : message
                    return
                }
                hermesPrimaryCredentials[credential.provider] = credential.id
                refreshProviderQuota()
            } catch {
                providerQuotaActionErrors[providerID] = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Removes a Hermes-pooled account from Hermes itself through
    /// `hermes auth remove`, so Hermes stops rotating through it too. The Dock
    /// only forgets its own nickname and position after Hermes succeeds.
    func removeHermesPooledCredential(for providerID: String) {
        guard let credential = reportedProviderQuotas.first(where: { $0.provider == providerID })?.hermesCredential else { return }
        guard let cli else {
            providerQuotaActionErrors[providerID] = "Hermes is not connected, so the account could not be removed."
            return
        }
        let actionID = Self.hermesCredentialRemovalActionID(providerID)
        guard beginAction(actionID) else { return }
        providerQuotaActionErrors[providerID] = nil
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.authRemove(provider: credential.provider, credentialID: credential.id)
                guard result.succeeded else {
                    let message = Self.safeUserDiagnostic(result.stderr)
                    providerQuotaActionErrors[providerID] = message.isEmpty ? "Hermes could not remove this account." : message
                    return
                }
                providerNicknameStore.removeNickname(for: providerID)
                presentationDefaults.set(providerQuotaOrder.filter { $0 != providerID }, forKey: Self.providerQuotaOrderKey)
                reportedProviderQuotas.removeAll { $0.provider == providerID }
                applyProviderQuotaPresentation()
                refreshProviderQuota()
            } catch {
                providerQuotaActionErrors[providerID] = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Saves the user's preferred catalog order (used for providers without a
    /// saved display position).
    func setProviderOrder(_ providerIDs: [String]) {
        QuotaProviderCatalog.saveProviderOrder(providerIDs)
        applyProviderQuotaPresentation()
    }

    /// Gets the current provider display order based on user preferences.
    func getProviderOrder() -> [String] {
        QuotaProviderCatalog.orderedProviderIDs()
    }

    /// Launches the provider's desktop app so the user can sign in; quota is
    /// re-read shortly afterwards, once the app's local service is up.
    func openProviderApplication(named applicationName: String) {
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", applicationName]
            try? process.run()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self.refreshProviderQuota()
        }
    }

    private nonisolated static func readQuota(_ read: @Sendable () async throws -> [String: Any]) async -> QuotaReadResult {
        do { return QuotaReadResult(value: try await read(), error: nil) }
        catch { return QuotaReadResult(value: nil, error: Self.safeUserDiagnostic(error.localizedDescription)) }
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
                    lastError = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes could not run the scheduled job." : Self.safeUserDiagnostic(result.stderr)
                    return
                }
                refreshCronRuns()
                refresh()
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func refreshCronRuns(refreshGeneration: UInt64? = nil, clientIdentity: ObjectIdentifier? = nil) {
        guard let cli else { return }
        let resolvedClientIdentity = clientIdentity ?? dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let bindingGeneration = self.clientBindingGeneration
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
                let result = try await cli.cronRuns()
                guard generation == cronRunsGeneration, isCurrent() else { return }
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
                guard generation == cronRunsGeneration, isCurrent() else { return }
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
        let key = cronRunsProjectionKey(jobID: jobID)
        guard projectionRefreshStates[key]?.isRefreshing != true else { return }
        beginProjectionRefresh(key)
        Task {
            do {
                let result = try await cli.cronRuns(limit: 50, jobID: jobID)
                guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                guard result.succeeded else {
                    let message = Self.safeUserDiagnostic(result.stderr)
                    recordProjectionFailure(key, error: message.isEmpty ? "Hermes automation history is temporarily unavailable." : message)
                    return
                }
                cronRunsByJob[jobID] = Self.parseCronRuns(result.stdout)
                recordProjectionSuccess(key)
            } catch {
                guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                recordProjectionFailure(key, error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Report files are Hermes-private implementation detail. Keep report
    /// display unavailable until Hermes exposes a structured report operation.
    func refreshCronReports() {
        // Intentionally empty.
    }

    func refreshCommandAllowlist() {
        guard let cli else { return }
        Task {
            do {
                let result = try await cli.configGetCommandAllowlist()
                commandAllowlistEntries = result.succeeded ? Self.parseCommandAllowlist(result.stdout) : nil
            } catch {
                commandAllowlistEntries = nil
            }
        }
    }

    nonisolated static func parseCommandAllowlist(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]", trimmed != "null" else { return [] }
        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return array
        }
        return trimmed.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("- ") else { return nil }
            var entry = String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("'"), entry.hasSuffix("'"), entry.count >= 2 {
                entry = String(entry.dropFirst().dropLast())
            }
            return entry.isEmpty ? nil : entry
        }
    }

    func refreshAppearanceProjection(refreshGeneration: UInt64? = nil, clientIdentity: ObjectIdentifier? = nil) {
        guard let cli else { return }
        let resolvedClientIdentity = clientIdentity ?? dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let bindingGeneration = self.clientBindingGeneration
        guard isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration) else { return }
        let isCurrent: () -> Bool = {
            if let refreshGeneration {
                return self.isCurrentRefresh(refreshGeneration, clientIdentity: resolvedClientIdentity)
            }
            return self.isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration)
        }
        let generation = UUID()
        appearanceProjectionGeneration = generation
        Task {
            do {
                async let skins = cli.skinList()
                async let pets = cli.installedPetsList()
                let skinResult = try await skins
                let petResult = try await pets
                guard generation == appearanceProjectionGeneration, isCurrent() else { return }
                guard skinResult.succeeded, petResult.succeeded else {
                    appearanceProjectionAvailable = appearanceProjection != nil
                    return
                }
                appearanceProjection = AppearanceCLIProjection.inventory(
                    skinsOutput: skinResult.stdout,
                    petsOutput: petResult.stdout
                )
                appearanceProjectionAvailable = true
            } catch {
                guard generation == appearanceProjectionGeneration, isCurrent() else { return }
                appearanceProjectionAvailable = appearanceProjection != nil
            }
        }
    }

    func engageEmergencyStop(reason: String? = nil) {
        guard let cli else { return }
        let actionID = emergencyStopActionID
        guard beginAction(actionID) else { return }
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.emergencyStop(reason: reason)
                guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                guard result.succeeded else {
                    emergencyStopMessage = HermesDiagnosticsService.safeSummary(result.stderr).isEmpty ? "Hermes could not engage the emergency stop." : HermesDiagnosticsService.safeSummary(result.stderr)
                    return
                }
                emergencyStopActive = true
                emergencyStopMessage = "New Hermes work is paused. In-flight work continues."
            } catch {
                guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                emergencyStopMessage = HermesDiagnosticsService.safeSummary(error.localizedDescription)
            }
        }
    }

    func releaseEmergencyStop() {
        guard let cli else { return }
        let actionID = emergencyStopActionID
        guard beginAction(actionID) else { return }
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.resumeEmergencyStop()
                guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                guard result.succeeded else {
                    emergencyStopMessage = HermesDiagnosticsService.safeSummary(result.stderr).isEmpty ? "Hermes could not resume dispatch." : HermesDiagnosticsService.safeSummary(result.stderr)
                    return
                }
                emergencyStopActive = false
                emergencyStopMessage = "Hermes dispatch resumed."
            } catch {
                guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                emergencyStopMessage = HermesDiagnosticsService.safeSummary(error.localizedDescription)
            }
        }
    }

    func refreshInsights(refreshGeneration: UInt64? = nil, clientIdentity: ObjectIdentifier? = nil) {
        guard let rpc else { return }
        let resolved = clientIdentity ?? dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let binding = clientBindingGeneration
        guard isCurrentClient(resolved, bindingGeneration: binding) else { return }
        Task {
            do {
                let result = try await rpc.insights(days: 30)
                guard refreshGeneration.map({ self.isCurrentRefresh($0, clientIdentity: resolved) }) ?? self.isCurrentClient(resolved, bindingGeneration: binding) else { return }
                guard let days = result["days"] as? Int, let sessions = result["sessions"] as? Int, let messages = result["messages"] as? Int,
                      (1...90).contains(days), sessions >= 0, messages >= 0 else { return }
                insightsSummary = HermesInsightsSummary(days: days, sessions: sessions, messages: messages)
            } catch {
                return
            }
        }
    }

    func refreshMCPInventory(refreshGeneration: UInt64? = nil, clientIdentity: ObjectIdentifier? = nil) {
        guard let cli else { return }
        let resolvedClientIdentity = clientIdentity ?? dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let bindingGeneration = self.clientBindingGeneration
        guard isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration) else { return }
        let isCurrent: () -> Bool = {
            if let refreshGeneration {
                return self.isCurrentRefresh(refreshGeneration, clientIdentity: resolvedClientIdentity)
            }
            return self.isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration)
        }
        beginProjectionRefresh("mcp.inventory")
        let generation = UUID()
        mcpInventoryGeneration = generation
        Task {
            do {
                let result = try await cli.mcpList()
                guard generation == mcpInventoryGeneration, isCurrent() else { return }
                mcpInventoryAvailable = result.succeeded
                guard mcpInventoryAvailable else {
                    let message = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes MCP inventory is temporarily unavailable." : Self.safeUserDiagnostic(result.stderr)
                    recordProjectionFailure("mcp.inventory", error: message)
                    lastError = message
                    return
                }
                mcpServers = Self.parseMCPServers(result.stdout)
                recordProjectionSuccess("mcp.inventory")
            } catch {
                guard generation == mcpInventoryGeneration, isCurrent() else { return }
                mcpInventoryAvailable = false
                let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
                let output = HermesDiagnosticsService.safeSummary(result.succeeded ? result.stdout : Self.safeUserDiagnostic(result.stderr))
                mcpTestResults[server.id] = result.succeeded
                    ? (output.isEmpty ? "Connection succeeded." : output)
                    : (output.isEmpty ? "Connection failed." : output)
            } catch {
                mcpTestResults[server.id] = Self.safeUserDiagnostic(error.localizedDescription)
            }
        }
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
            _ = try await rpc.createCron(name: cleanName, schedule: originalSchedule, prompt: cleanPrompt)
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
        Task {
            defer { finishAction(actionID) }
            do {
                guard let rpc else { return }
                _ = try await rpc.removeCron(jobID: job.id)
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
        let projectionKey = projectSessionsProjectionKey(for: project.id)
        guard let rpc else {
            recordProjectionUnavailable(projectionKey)
            return
        }
        let generation = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        projectSessionsGeneration = generation
        currentFocus = ControlReference(source: .hermesProject, sourceID: project.id, projectID: project.id)
        selectedProjectID = project.id
        selectedProject = project
        projectSessions = projectSessionsByProjectID[project.id] ?? []
        beginProjectionRefresh(projectionKey)
        let profileID = projectProfileID
        Task {
            do {
                let result = try await rpc.projectSessions(projectID: project.id, profileID: profileID)
                guard generation == projectSessionsGeneration,
                      selectedProjectID == project.id,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                projectSessions = Self.parseProjectSessions(result)
                projectSessionsByProjectID[project.id] = projectSessions
                recordProjectionSuccess(projectionKey, count: projectSessions.count)
                for session in projectSessions {
                    projectIDBySessionID[session.id] = project.id
                    resolvedProjectIDBySessionID[session.id] = project.id
                }
            } catch {
                guard generation == projectSessionsGeneration,
                      selectedProjectID == project.id,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                recordProjectionFailure(projectionKey, error: error.localizedDescription)
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Selects the project that owns a newly-created project chat without
    /// depending on a later tree refresh to restore the user's navigation.
    /// The path is the same authoritative directory sent to Hermes when the
    /// session was created; matching by path avoids changing other projects.
    func selectProject(forPath path: String) {
        guard let project = Self.projectMatchingPath(path, projects: projects) else { return }
        selectedProjectID = project.id
        selectedProject = project
        projectSessions = projectSessionsByProjectID[project.id] ?? []
        refreshProjectNavigation(refreshProjects: false)
    }

    static func projectMatchingPath(_ path: String, projects: [ProjectSummary]) -> ProjectSummary? {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !normalizedPath.isEmpty else { return nil }
        return projects.first {
            $0.isRenderableProject
                && URL(fileURLWithPath: $0.name).standardizedFileURL.path == normalizedPath
        }
    }

    static func projectSessionsAfterNavigationRefresh(
        projectID: String,
        selectedProjectID: String?,
        refreshedSessions: [SessionSummary]
    ) -> [SessionSummary]? {
        guard selectedProjectID == projectID else { return nil }
        return refreshedSessions
    }

    /// Explicit user action for the navigation rail. Automatic message and
    /// activity events must not replace the visible project projection.
    func refreshProjectNavigation() {
        refreshProjectNavigation(refreshProjects: true)
    }

    private func refreshProjectNavigation(refreshProjects: Bool) {
        guard !projectProfileScopeUnavailable else {
            projectSessionsByProjectID = [:]
            isRefreshingProjectNavigation = false
            return
        }
        guard !isRefreshingProjectNavigation else { return }
        let navigationProjects = projects.filter { $0.name != "__no_project__" }
        guard !navigationProjects.isEmpty else { return }
        let profileID = projectProfileID
        isRefreshingProjectNavigation = true
        let generation = UUID()
        projectNavigationRefreshIDs = Set(navigationProjects.map(\.id))
        projectNavigationRefreshGeneration = generation
        pendingProjectNavigationSessions = [:]
        completedProjectNavigationIDs = []
        if refreshProjects { refresh() }
        for project in navigationProjects {
            let projectID = project.id
            guard let rpc else {
                completeProjectNavigationRefresh(projectID, generation: generation)
                continue
            }
            Task { @MainActor [weak self] in
                let sessions = try? await rpc.projectSessions(projectID: projectID, profileID: profileID)
                guard let self,
                      self.projectNavigationRefreshGeneration == generation else { return }
                if let sessions {
                    self.pendingProjectNavigationSessions[projectID] = Self.parseProjectSessions(sessions)
                }
                self.completeProjectNavigationRefresh(projectID, generation: generation)
            }
        }
    }

    /// Starts the linked-session projection after the initial project tree is
    /// ready. The tree and its session details are separate gateway calls, so
    /// waiting here avoids leaving every project permanently on a loading row
    /// until the user presses Refresh.
    func startInitialProjectNavigationLoad() {
        guard !projectProfileScopeUnavailable else {
            initialProjectNavigationTask?.cancel()
            initialProjectNavigationTask = nil
            return
        }
        guard !didLoadInitialProjectNavigation,
              initialProjectNavigationTask == nil else { return }
        initialProjectNavigationTask = Task { @MainActor [weak self] in
            for _ in 0..<120 {
                guard let self, !Task.isCancelled else { return }
                if !self.isRefreshing, !self.projects.isEmpty {
                    self.didLoadInitialProjectNavigation = true
                    self.initialProjectNavigationTask = nil
                    self.refreshProjectNavigation(refreshProjects: false)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.initialProjectNavigationTask = nil
        }
    }

    private func completeProjectNavigationRefresh(_ projectID: String, generation: UUID) {
        guard projectNavigationRefreshGeneration == generation else { return }
        completedProjectNavigationIDs.insert(projectID)
        guard completedProjectNavigationIDs == projectNavigationRefreshIDs else { return }

        // Publish one complete snapshot after every request has finished. This
        // prevents the visible list from being rebuilt once per project.
        projectSessionsByProjectID = projectSessionsByProjectID.merging(pendingProjectNavigationSessions) { _, new in new }
        if let selectedProjectID,
           let refreshedSessions = projectSessionsByProjectID[selectedProjectID] {
            projectSessions = refreshedSessions
        }
        pendingProjectNavigationSessions = [:]
        completedProjectNavigationIDs = []
        projectNavigationRefreshIDs = []
        projectNavigationRefreshGeneration = nil
        isRefreshingProjectNavigation = false
    }

    func closeProject() {
        projectSessionsGeneration = UUID()
        selectedProjectID = nil
        selectedProject = nil
        projectSessions = []
    }

    func setActiveProject(_ project: ProjectSummary?) async -> Bool {
        guard capabilityAvailable(HermesFeatureIDs.ID.projectsSetActive.rawValue), let rpc else { return false }
        do {
            _ = try await rpc.setActiveProject(id: project?.id, profileID: projectProfileID)
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func createProject(name: String, folder: String) async -> Bool {
        guard capabilityAvailable(HermesFeatureIDs.ID.projectsCreate.rawValue), let rpc, !name.isEmpty, !folder.isEmpty else { return false }
        do {
            _ = try await rpc.createProject(name: name, folders: [folder], profileID: projectProfileID)
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func addProjectFolder(_ project: ProjectSummary, folder: String) async -> Bool {
        guard capabilityAvailable(HermesFeatureIDs.ID.projectsAddFolder.rawValue), let rpc, !folder.isEmpty else { return false }
        do {
            _ = try await rpc.addProjectFolder(id: project.id, path: folder, profileID: projectProfileID)
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func archiveProject(_ project: ProjectSummary, restore: Bool = false) async -> Bool {
        guard capabilityAvailable(HermesFeatureIDs.ID.projectsArchive.rawValue), let rpc else { return false }
        do {
            _ = try await rpc.archiveProject(id: project.id, restore: restore, profileID: projectProfileID)
            closeProject()
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func deleteProject(_ project: ProjectSummary) async -> Bool {
        guard capabilityAvailable(HermesFeatureIDs.ID.projectsDelete.rawValue), let rpc else { return false }
        do {
            _ = try await rpc.deleteProject(id: project.id, profileID: projectProfileID)
            closeProject()
            refresh()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
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
            if let rpc = self.rpc, let result = try? await rpc.sessions(limit: 100),
               let parsedSessions = Self.parseSessions(result) {
                sessions = parsedSessions
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
                    lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func refreshKanban(filter: KanbanListFilter? = nil) {
        refreshKanban(filter: filter, scope: .visible, trigger: .user)
    }

    private func refreshKanban(
        filter: KanbanListFilter?,
        scope: KanbanRefreshScope,
        trigger: KanbanRefreshTrigger
    ) {
        // A capability probe is advisory and can still be in flight when the
        // Kanban tab first appears. The list request itself is authoritative;
        // do not make the initial load (or an explicit retry) silently fail
        // just because that separate probe has not completed yet.
        guard let cli else {
            recordProjectionUnavailable("kanban.board")
            if scope.isAggregate { recordProjectionUnavailable("kanban.global") }
            if scope.isAggregate { globalKanbanIsCurrent = false }
            return
        }
        let actionID = scope.isAggregate ? aggregateKanbanRefreshActionID : visibleKanbanRefreshActionID
        switch trigger {
        case .user:
            guard beginAction(actionID) else { return }
        case .background:
            // A poll must not replace the generation for an explicit refresh.
            // User refreshes are allowed to supersede a poll, but not vice versa.
            guard !pendingActionIDs.contains(actionID) else { return }
            guard kanbanRefreshInFlight.insert(scope).inserted else { return }
        }
        let hasProjectionState = projectionRefreshStates["kanban.board"] != nil
        let shouldPublishRefreshState = trigger == .user || !hasProjectionState
        if shouldPublishRefreshState {
            beginProjectionRefresh("kanban.board")
        }
        if scope.isAggregate {
            globalKanbanIsCurrent = false
            beginProjectionRefresh("kanban.global")
        }
        let requestedBoardSlug = scope.isAggregate ? nil : selectedKanbanBoardSlug
        // Global aggregation deliberately omits --board; session activity has
        // its own board-aware projection and never uses this request.
        // loading. Clearing here turns a transient refresh race into the
        // false "This board is clear" state seen in the UI; the published
        // replacement below remains generation-checked.
        if let filter, !scope.isAggregate, kanbanFilter != filter {
            kanbanFilter = filter
        }
        let activeFilter = scope.isAggregate ? (filter ?? KanbanListFilter()) : kanbanFilter
        let generation = UUID()
        if scope.isAggregate { aggregateKanbanRefreshGeneration = generation }
        else { visibleKanbanRefreshGeneration = generation }
        Task {
            defer {
                switch trigger {
                case .user: finishAction(actionID)
                case .background: kanbanRefreshInFlight.remove(scope)
                }
            }
            do {
                // `hermes kanban list --json` is the canonical complete board
                // projection. Query it once: splitting an unfiltered board
                // into assumed status lanes delays publication until every
                // request completes and drops any future Hermes status value.
                let result = scope.isAggregate
                    ? try await cli.kanbanListAggregate(filter: activeFilter)
                    : try await cli.kanbanList(boardSlug: requestedBoardSlug, filter: activeFilter)
                let parsed = result.succeeded
                    ? await Self.parseKanbanTasksOffMain(result.stdout, boardSlug: requestedBoardSlug)
                    : nil
                guard result.succeeded else {
                    guard isCurrentKanbanRefresh(generation, scope: scope, boardSlug: requestedBoardSlug) else { return }
                    let message = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes Kanban is unavailable." : Self.safeUserDiagnostic(result.stderr)
                    recordProjectionFailure("kanban.board", error: message)
                    if scope.isAggregate { recordProjectionFailure("kanban.global", error: message) }
                    lastError = message
                    return
                }
                guard isCurrentKanbanRefresh(generation, scope: scope, boardSlug: requestedBoardSlug) else { return }
                guard let parsedTasks = parsed else {
                    let message = "Hermes returned malformed Kanban data."
                    recordProjectionFailure("kanban.board", error: message)
                    if scope.isAggregate { recordProjectionFailure("kanban.global", error: message) }
                    lastError = message
                    return
                }
                var refreshedTasks = parsedTasks
                // A successful `kanban show <id>` in the current session is
                // exact evidence that the card exists even when a stale or
                // filtered list response omitted it. Recover that card by ID;
                // never synthesize cards from titles or assignees.
                if !scope.isAggregate {
                    let knownIDs = Set(refreshedTasks.map(\.id))
                    let observedIDs = dockModel?.observedKanbanTaskIDs ?? []
                    for taskID in observedIDs where !knownIDs.contains(taskID) {
                        guard let shown = try? await cli.kanbanShow(boardSlug: requestedBoardSlug, taskID: taskID),
                              shown.succeeded,
                              let task = Self.parseKanbanTaskSummary(shown.stdout, boardSlug: requestedBoardSlug) else { continue }
                        refreshedTasks.append(task)
                    }
                }
                // Automatic polling commonly returns the same board. Avoid
                // publishing an unchanged array: the Kanban surface observes
                // this model, so an unnecessary publish forces SwiftUI to
                // re-diff every visible lane while the user is scrolling.
                var taskDataChanged = false
                if scope.isAggregate {
                    if globalKanbanTasks != refreshedTasks {
                        globalKanbanTasks = refreshedTasks
                        taskDataChanged = true
                    }
                    globalKanbanIsCurrent = true
                    // Before board inventory has selected a board, the
                    // aggregate is the only valid visible projection.
                    if selectedKanbanBoardSlug == nil, kanbanTasks != refreshedTasks {
                        kanbanTasks = refreshedTasks
                        taskDataChanged = true
                    }
                } else if kanbanTasks != refreshedTasks {
                    kanbanTasks = refreshedTasks
                    taskDataChanged = true
                }
                if shouldPublishRefreshState || taskDataChanged {
                    recordProjectionSuccess("kanban.board")
                }
                if scope.isAggregate { recordProjectionSuccess("kanban.global") }
                if trigger == .user {
                    refreshKanbanSupportingProjections()
                }
            } catch {
                guard isCurrentKanbanRefresh(generation, scope: scope, boardSlug: requestedBoardSlug) else { return }
                let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                recordProjectionFailure("kanban.board", error: message)
                if scope.isAggregate { recordProjectionFailure("kanban.global", error: message) }
                lastError = message
            }
        }
    }

    private func isCurrentKanbanRefresh(_ generation: UUID, scope: KanbanRefreshScope, boardSlug: String?) -> Bool {
        let currentGeneration = scope.isAggregate ? aggregateKanbanRefreshGeneration : visibleKanbanRefreshGeneration
        return generation == currentGeneration && (scope.isAggregate || boardSlug == selectedKanbanBoardSlug)
    }

    private func refreshKanbanSupportingProjections() {
        refreshKanbanStats()
        refreshKanbanAssignees()
        refreshKanbanBoards()
        refreshKanbanDiagnostics()
    }

    /// The global Kanban surface must never inherit a hidden session scope
    /// left behind by the session-activity shortcut. Keep the user's ordinary
    /// status, assignee, mine, archive, and sort choices, but make ownership
    /// explicit at this boundary.
    static func globalKanbanFilter(_ filter: KanbanListFilter) -> KanbanListFilter {
        var global = filter
        global.sessionID = nil
        return global
    }

    static func reconcileProjectRefresh(current: [ProjectSummary], incoming: [ProjectSummary]) -> [ProjectSummary] {
        var seen = Set<String>()
        let deduplicated = incoming.filter { seen.insert($0.id).inserted }
        guard !current.isEmpty else { return deduplicated.sorted { $0.id < $1.id } }

        let currentIDs = current.map(\.id)
        let incomingIDs = deduplicated.map(\.id)
        let incomingByID = Dictionary(deduplicated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rowsUnchanged = current.count == deduplicated.count
            && current.allSatisfy { incomingByID[$0.id] == $0 }
        if rowsUnchanged {
            return current
        }
        if Set(currentIDs) == Set(incomingIDs) {
            return incomingIDs == currentIDs
                ? currentIDs.compactMap { incomingByID[$0] }
                : deduplicated
        }
        let currentIDSet = Set(currentIDs)
        let retained = currentIDs.compactMap { incomingByID[$0] }
        let newProjects = deduplicated
            .filter { !currentIDSet.contains($0.id) }
            .sorted { $0.id < $1.id }
        return retained + newProjects
    }

    /// Refreshes the global Kanban projection. Board inventory and board
    /// selection are global controls, so they must never resurrect a session
    /// filter retained from an Activity shortcut.
    func refreshGlobalKanban(filter: KanbanListFilter? = nil, trigger: KanbanRefreshTrigger = .user) {
        refreshKanban(
            filter: Self.globalKanbanFilter(filter ?? KanbanListFilter()),
            scope: .aggregate,
            trigger: trigger
        )
    }

    /// Refreshes the user-visible Kanban list using the selected board and
    /// explicit UI filters. Unlike aggregate hydration, this preserves a
    /// deliberate session-only filter.
    func refreshVisibleKanban(
        filter: KanbanListFilter? = nil,
        trigger: KanbanRefreshTrigger = .user
    ) {
        refreshKanban(filter: filter ?? kanbanFilter, scope: .visible, trigger: trigger)
    }

    /// Refreshes the Kanban projection for the currently focused session without
    /// mutating the global board projection used by the Kanban tab.
    func refreshSessionKanban(for sessionID: String? = nil) {
        let candidateSessionID = sessionID ?? dockModel?.sessionID
        let requestedSessionID = candidateSessionID == dockModel?.sessionID
            ? dockModel?.kanbanSessionID
            : candidateSessionID
        // Session activity spans boards, independently of the global selector.
        let requestedBoardSlug: String? = nil
        let requested = SessionKanbanProjectionRequest(
            sessionID: requestedSessionID,
            boardSlug: requestedBoardSlug
        )
        if Self.shouldCoalesceSessionKanbanRefresh(
            activeRequest: sessionKanbanRequest,
            hasInFlightTask: sessionKanbanTask != nil,
            requested: requested
        ) {
            sessionKanbanRefreshPending = true
            return
        }
        let generation = UUID()
        let isNewProjection = sessionKanbanSessionID != requestedSessionID || sessionKanbanBoardSlug != requestedBoardSlug
        sessionKanbanTask?.cancel()
        sessionKanbanTask = nil
        sessionKanbanRefreshPending = false
        sessionKanbanRefreshGeneration = generation
        sessionKanbanRequest = requested
        if isNewProjection {
            sessionKanbanTasks = sessionKanbanTasksByRequest[requested] ?? []
        }
        sessionKanbanSessionID = requestedSessionID
        sessionKanbanBoardSlug = requestedBoardSlug
        beginProjectionRefresh("kanban.session")

        guard Self.shouldAttemptSessionKanbanQuery(
            sessionID: requestedSessionID,
            hasCLI: cli != nil
        ),
        let requestedSessionID,
        let cli else {
            recordProjectionFailure("kanban.session", error: "Kanban is unavailable for the current session.")
            return
        }

        // Capture attribution before suspension; another session may become active
        // while list/show requests are in flight.
        let activeAliases = Set((dockModel?.botActivitySessionIDs ?? []).compactMap { $0 })
        let isActiveSession = activeAliases.contains(requestedSessionID)
        let aliases = (isActiveSession ? activeAliases : []).union([requestedSessionID])
        let observedIDs = isActiveSession ? (dockModel?.observedKanbanTaskIDs ?? []) : []
        sessionKanbanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if generation == self.sessionKanbanRefreshGeneration {
                    self.sessionKanbanTask = nil
                    self.sessionKanbanRequest = nil
                    if self.sessionKanbanRefreshPending {
                        self.sessionKanbanRefreshPending = false
                        self.refreshSessionKanban(for: requestedSessionID)
                    }
                }
            }
            do {
                let result = try await cli.kanbanList(
                    boardSlug: requestedBoardSlug,
                    // Finished session cards get archived; keep them in Recent.
                    filter: KanbanListFilter(includeArchived: true, sort: "updated")
                )
                let parsed = result.succeeded
                    ? await Self.parseKanbanTasksOffMain(result.stdout, boardSlug: requestedBoardSlug)
                    : nil
                guard Self.isCurrentSessionKanbanResult(
                    generationMatches: generation == self.sessionKanbanRefreshGeneration,
                    publishedSessionID: self.sessionKanbanSessionID,
                    requestedSessionID: requestedSessionID,
                    publishedBoardSlug: self.sessionKanbanBoardSlug,
                    requestedBoardSlug: requestedBoardSlug
                ) else { return }
                guard result.succeeded else {
                    self.recordProjectionFailure(
                        "kanban.session",
                        error: Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes Kanban is unavailable." : Self.safeUserDiagnostic(result.stderr)
                    )
                    return
                }
                // A card may carry any of the session's aliases (runtime,
                // storage or attribution ID), so match them all.
                guard let parsed else {
                    self.recordProjectionFailure("kanban.session", error: "Hermes returned malformed Kanban data.")
                    return
                }
                var sessionTasks = Self.filterSessionKanbanTasks(
                    parsed,
                    sessionID: requestedSessionID,
                    aliases: aliases,
                    observedIDs: Set(observedIDs)
                )

                // Hermes agents can create a card through the kanban toolset
                // without persisting the originating chat session on the
                // task row. If this session explicitly ran `kanban show
                // <task-id>`, that exact command is stronger attribution
                // evidence than the missing database field. Enrich only
                // those exact IDs; never match by assignee or title.
                // Cards already in the list were judged above; only look up the
                // missing ones, or rehydrating a busy session takes minutes.
                let knownIDs = Set(parsed.map(\.id))
                for taskID in observedIDs where !knownIDs.contains(taskID) {
                    guard let shown = try? await cli.kanbanShow(boardSlug: requestedBoardSlug, taskID: taskID),
                          shown.succeeded,
                          // A card owned by another session (e.g. an id that
                          // merely appeared in `kanban list` output) is not ours.
                          Self.parseKanbanTaskSummary(shown.stdout, boardSlug: requestedBoardSlug)
                            .map({ $0.sessionID.map(aliases.contains) ?? true }) ?? false,
                          let task = Self.parseKanbanTaskSummary(
                            shown.stdout,
                            boardSlug: requestedBoardSlug,
                            sessionID: requestedSessionID
                          ) else { continue }
                    sessionTasks.append(task)
                }
                guard !Task.isCancelled,
                      Self.isCurrentSessionKanbanResult(
                        generationMatches: generation == self.sessionKanbanRefreshGeneration,
                        publishedSessionID: self.sessionKanbanSessionID,
                        requestedSessionID: requestedSessionID,
                        publishedBoardSlug: self.sessionKanbanBoardSlug,
                        requestedBoardSlug: requestedBoardSlug
                      ) else { return }
                self.sessionKanbanTasksByRequest[requested] = sessionTasks
                self.sessionKanbanTasks = sessionTasks
                self.recordProjectionSuccess("kanban.session")
            } catch {
                guard generation == self.sessionKanbanRefreshGeneration,
                      self.sessionKanbanSessionID == requestedSessionID else { return }
                self.recordProjectionFailure("kanban.session", error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    static func shouldCoalesceSessionKanbanRefresh(
        activeRequest: SessionKanbanProjectionRequest?,
        hasInFlightTask: Bool,
        requested: SessionKanbanProjectionRequest
    ) -> Bool {
        hasInFlightTask && activeRequest == requested
    }

    /// A session Activity result belongs to the request that created its
    /// projection. The global board selector is populated asynchronously and
    /// must not invalidate an otherwise current session-scoped list response.
    static func isCurrentSessionKanbanResult(
        generationMatches: Bool,
        publishedSessionID: String?,
        requestedSessionID: String,
        publishedBoardSlug: String?,
        requestedBoardSlug: String?
    ) -> Bool {
        generationMatches
            && publishedSessionID == requestedSessionID
            && publishedBoardSlug == requestedBoardSlug
    }

    /// The read-only list request is authoritative. Capability probes can be
    /// delayed or stale and must not suppress a session-scoped Activity query.
    static func shouldAttemptSessionKanbanQuery(sessionID: String?, hasCLI: Bool) -> Bool {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return hasCLI && !sessionID.isEmpty
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
                    lastError = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes Kanban boards are unavailable." : Self.safeUserDiagnostic(result.stderr)
                    return
                }
                let boards = Self.parseKanbanBoards(result.stdout)
                if kanbanBoards != boards {
                    kanbanBoards = boards
                }
                let previousSelection = selectedKanbanBoardSlug
                if let selected = selectedKanbanBoardSlug,
                   boards.contains(where: { $0.slug == selected && !$0.archived }) {
                    // Preserve an explicitly selected Dock board even when the
                    // shared Hermes default changes elsewhere.
                } else {
                    selectedKanbanBoardSlug = boards.first(where: { $0.isCurrent && !$0.archived })?.slug
                        ?? boards.first(where: { !$0.archived })?.slug
                }
                let inventoryRefreshPlan = Self.boardInventoryRefreshPlan(
                    previousSelection: previousSelection,
                    resolvedSelection: selectedKanbanBoardSlug
                )
                if inventoryRefreshPlan.refreshBoard {
                    // Keep eager aggregate hydration separate from the
                    // visible board-scoped list.
                    refreshVisibleKanban(trigger: .background)
                }
                if inventoryRefreshPlan.refreshSession {
                    refreshSessionKanban(for: dockModel?.kanbanSessionID)
                }
            } catch {
                guard generation == kanbanBoardsGeneration else { return }
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func selectKanbanBoard(_ board: KanbanBoardSummary) {
        guard !board.archived else { return }
        selectKanbanBoard(slug: board.slug)
    }

    private func selectKanbanBoard(slug: String) {
        guard selectedKanbanBoardSlug != slug else { return }
        selectedKanbanBoardSlug = slug
        visibleKanbanRefreshGeneration = UUID()
        kanbanStatsGeneration = UUID()
        kanbanAssigneesGeneration = UUID()
        kanbanDetailGeneration = UUID()
        kanbanDiagnosticsGeneration = UUID()
        kanbanAttachmentsGeneration = UUID()
        kanbanTasks = []
        kanbanDetail = nil
        kanbanDetailTaskIdentity = nil
        kanbanDetailError = nil
        kanbanStats = nil
        kanbanAssignees = []
        kanbanDiagnostics = []
        kanbanAttachments = []
        loadingKanbanDetailTaskID = nil
        refreshVisibleKanban()
        refreshSessionKanban(for: dockModel?.kanbanSessionID)
        refreshKanbanDiagnostics()
    }

    func revealKanbanTask(_ task: KanbanTaskSummary) {
        kanbanFilter = KanbanListFilter()
        if let slug = task.boardSlug, selectedKanbanBoardSlug != slug {
            selectKanbanBoard(slug: slug)
        }
        refreshVisibleKanban(filter: KanbanListFilter())
        requestedKanbanTask = task
    }

    /// Board inventory establishes the global board selector. It must not
    /// restart the independently scoped session Activity request; explicit
    /// user board selection is handled by `selectKanbanBoard(_:)` instead.
    static func boardInventoryRefreshPlan(
        previousSelection: String?,
        resolvedSelection: String?
    ) -> (refreshBoard: Bool, refreshSession: Bool) {
        let selectionChanged = previousSelection != resolvedSelection && resolvedSelection != nil
        return (refreshBoard: selectionChanged, refreshSession: false)
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
            let assignees = Self.parseKanbanAssignees(result.stdout)
            if kanbanAssignees != assignees {
                kanbanAssignees = assignees
            }
        }
    }

    func refreshReadOnlyHealth() {
        guard let cli else { return }
        let generation = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        guard isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
        journeyGeneration = generation
        Task {
            if capabilityAvailable("journey.timeline"),
               let result = try? await cli.journey(), result.succeeded,
               generation == journeyGeneration,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) {
                journeyNodes = Self.parseJourneyNodes(result.stdout)
            }
            if capabilityAvailable("sessions.stats"),
               let result = try? await cli.sessionStats(), generation == journeyGeneration,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) {
                sessionStoreStatus = Self.readOnlyStatus(id: "sessions.stats", title: "Session store", result: result)
            }
            if capabilityAvailable("memory.status"),
               let result = try? await cli.memoryStatus(), generation == journeyGeneration,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) {
                memoryHealthStatus = Self.readOnlyStatus(id: "memory.status", title: "Memory health", result: result)
            }
        }
    }

    func refreshTokenUsage(days: Int) {
        let generation = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        tokenUsageGeneration = generation
        guard let rpc else {
            recordProjectionUnavailable("token.usage")
            return
        }
        beginProjectionRefresh("token.usage")
        Task { @MainActor in
            do {
                let result = try await rpc.usageAnalytics(days: days)
                guard generation == tokenUsageGeneration,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                tokenUsage = Self.parseTokenUsage(result, models: tokenUsageModelRows)
                recordProjectionSuccess("token.usage", count: tokenUsage?.sessions ?? 0)
                // Models is slower (models.dev lookups) and only adds provider
                // pills, so it lands after the dashboard is already drawn.
                guard let modelRows = try? await rpc.modelAnalytics(days: days),
                      generation == tokenUsageGeneration,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                tokenUsageModelRows = modelRows
                tokenUsage = Self.parseTokenUsage(result, models: modelRows)
            } catch {
                guard generation == tokenUsageGeneration else { return }
                recordProjectionFailure("token.usage", error: error.localizedDescription)
            }
        }
    }

    func refreshSessionCockpit(for requestedSessionID: String? = nil) {
        let generation = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
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
            checkpoints = []
            restoreCheckpoints = []
            restoreCheckpointState = .idle
            checkpointDiff = nil
        }
        sessionCockpitSessionID = sessionID
        Task { @MainActor in
            let usage = try? await rpc.sessionUsage(sessionID: sessionID)
            let context = try? await rpc.sessionContextBreakdown(sessionID: sessionID)
            guard generation == sessionCockpitGeneration,
                  sessionCockpitSessionID == sessionID,
                  isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration),
                  (requestedSessionID != nil || dockModel?.sessionID == sessionID) else { return }
            if let usage { sessionUsage = Self.parseSessionUsage(usage) }
            if let context { sessionContext = Self.parseSessionContext(context) }
            if usage != nil || context != nil {
                recordProjectionSuccess("session.cockpit")
            }
        }
        refreshCheckpoints(sessionID: sessionID)
    }

    func refreshCheckpoints(
        sessionID: String? = nil,
        projectID requestedProjectID: String? = nil,
        selectionID requestedSelectionID: String? = nil
    ) {
        guard let rpc, let resolvedSessionID = sessionID ?? dockModel?.sessionID, !resolvedSessionID.isEmpty else {
            checkpoints = []
            restoreCheckpoints = []
            restoreCheckpointState = .idle
            checkpointDiff = nil
            return
        }
        let generation = UUID()
        checkpointsGeneration = generation
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        isLoadingCheckpoints = true
        Task {
            defer {
                if generation == checkpointsGeneration { isLoadingCheckpoints = false }
            }
            guard let result = try? await rpc.listRestoreCheckpoints(sessionID: resolvedSessionID),
                  generation == checkpointsGeneration,
                  isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration),
                  (sessionID != nil || dockModel?.sessionID == resolvedSessionID) else { return }
            checkpoints = Self.parseCheckpoints(result)
            let projectID = requestedProjectID ?? projectIDBySessionID[resolvedSessionID]
            let selectionID = requestedSelectionID ?? currentFocus?.sourceID
            restoreCheckpoints = RestoreCheckpointEligibility.eligible(
                checkpoints.compactMap { row in
                    RestoreCheckpoint(
                        sessionID: resolvedSessionID,
                        projectID: projectID,
                        selectionID: selectionID,
                        hash: row.hash,
                        timestamp: row.timestamp,
                        message: row.message
                    )
                },
                sessionID: resolvedSessionID,
                projectID: projectID,
                selectionID: selectionID
            )
            if checkpoints.isEmpty { checkpointDiff = nil }
        }
    }

    func loadCheckpointDiff(_ checkpoint: HermesCheckpointSummary) {
        guard let rpc, let sessionID = dockModel?.sessionID, !sessionID.isEmpty else { return }
        let generation = checkpointsGeneration
        Task {
            guard let result = try? await rpc.rollbackDiff(sessionID: sessionID, hash: checkpoint.hash),
                  generation == checkpointsGeneration,
                  let diff = result["diff"] as? String, diff.utf8.count <= 4_096 else { return }
            checkpointDiff = diff
        }
    }

    func loadCheckpointDiff(_ checkpoint: RestoreCheckpoint) {
        guard let rpc, let sessionID = dockModel?.sessionID ?? Optional(checkpoint.sessionID), !sessionID.isEmpty else { return }
        let generation = checkpointsGeneration
        Task {
            guard let result = try? await rpc.rollbackDiff(sessionID: sessionID, hash: checkpoint.hash),
                  generation == checkpointsGeneration,
                  let diff = result["diff"] as? String, diff.utf8.count <= 4_096 else { return }
            checkpointDiff = diff
        }
    }

    func restoreCheckpoint(
        _ checkpoint: RestoreCheckpoint,
        projectID requestedProjectID: String? = nil,
        selectionID requestedSelectionID: String? = nil
    ) async -> Bool {
        guard let rpc, let sessionID = dockModel?.sessionID ?? Optional(checkpoint.sessionID), !sessionID.isEmpty,
              dockModel?.status != .working,
              RestoreCheckpointEligibility.isEligible(
                  checkpoint,
                  sessionID: sessionID,
                  projectID: requestedProjectID ?? projectIDBySessionID[sessionID],
                  selectionID: requestedSelectionID ?? currentFocus?.sourceID
              ),
              restoreCheckpointCoordinator.begin(checkpoint) else { return false }
        restoreCheckpointState = restoreCheckpointCoordinator.state
        do {
            let result = try await rpc.restoreCheckpoint(sessionID: sessionID, hash: checkpoint.hash)
            if result["success"] as? Bool == false {
                let message = Self.safeUserDiagnostic(result["error"] as? String ?? "Hermes rejected the checkpoint restore.")
                restoreCheckpointCoordinator.fail(message)
                restoreCheckpointState = restoreCheckpointCoordinator.state
                lastError = message
                return false
            }
            restoreCheckpointCoordinator.succeed()
            restoreCheckpointState = restoreCheckpointCoordinator.state
            refreshCheckpoints(
                sessionID: sessionID,
                projectID: checkpoint.projectID,
                selectionID: checkpoint.selectionID
            )
            return true
        } catch {
            let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            restoreCheckpointCoordinator.fail(message)
            restoreCheckpointState = restoreCheckpointCoordinator.state
            lastError = message
            return false
        }
    }

    func cancelRestoreCheckpoint() {
        restoreCheckpointCoordinator.cancel()
        restoreCheckpointState = restoreCheckpointCoordinator.state
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
                    recordProjectionFailure("kanban.diagnostics", error: Self.safeUserDiagnostic(result.stderr))
                    return
                }
                let diagnostics = Self.parseKanbanDiagnostics(result.stdout, boardSlug: requestedBoardSlug, severity: severity)
                if kanbanDiagnostics != diagnostics {
                    kanbanDiagnostics = diagnostics
                }
                recordProjectionSuccess("kanban.diagnostics")
            } catch {
                guard generation == kanbanDiagnosticsGeneration else { return }
                recordProjectionFailure("kanban.diagnostics", error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func refreshKanbanAttachments(for taskID: String, boardSlug: String? = nil) {
        guard let cli else { return }
        let generation = UUID()
        let requestedBoardSlug = boardSlug ?? selectedKanbanBoardSlug
        kanbanAttachmentsGeneration = generation
        beginProjectionRefresh("kanban.attachments")
        Task {
            do {
                let result = try await cli.kanbanAttachments(boardSlug: requestedBoardSlug, taskID: taskID)
                guard generation == kanbanAttachmentsGeneration,
                      kanbanDetailTaskIdentity == KanbanTaskIdentity(boardSlug: requestedBoardSlug, taskID: taskID) else { return }
                guard result.succeeded,
                      let data = result.stdout.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data) else {
                    recordProjectionFailure("kanban.attachments", error: Self.safeUserDiagnostic(result.stderr))
                    return
                }
                kanbanAttachments = Self.parseKanbanAttachments(value, boardSlug: requestedBoardSlug, taskID: taskID)
                recordProjectionSuccess("kanban.attachments")
            } catch {
                guard generation == kanbanAttachmentsGeneration else { return }
                recordProjectionFailure("kanban.attachments", error: Self.safeUserDiagnostic(error.localizedDescription))
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
                    recordProjectionFailure("prompt.budget", error: Self.safeUserDiagnostic(result.stderr))
                    return
                }
                promptBudget = PromptBudgetSummary(totalTokens: Self.intValue(row["total_tokens"] ?? row["total"]), tokenLimit: Self.optionalIntValue(row["token_limit"] ?? row["context_max"]), percent: Self.doubleValue(row["percent"] ?? row["context_percent"]), model: row["model"] as? String)
                recordProjectionSuccess("prompt.budget")
            } catch {
                guard generation == promptBudgetGeneration else { return }
                recordProjectionFailure("prompt.budget", error: Self.safeUserDiagnostic(error.localizedDescription))
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
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        projectFactsGeneration = factsGeneration
        self.verificationGeneration = verificationGeneration
        let sessionID = requestedSessionID ?? dockModel?.sessionID
        Task { @MainActor in
            do {
                let factsResult = try await rpc.projectFacts(cwd: repository.path)
                guard factsGeneration == self.projectFactsGeneration,
                      self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                projectFacts = Self.parseProjectFacts(factsResult)
            } catch {
                guard factsGeneration == self.projectFactsGeneration,
                      self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                projectFacts = nil
            }
            do {
                let result = try await rpc.verificationStatus(sessionID: sessionID, cwd: repository.path)
                guard verificationGeneration == self.verificationGeneration,
                      self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                verification = Self.parseVerification(result)
            } catch {
                guard verificationGeneration == self.verificationGeneration,
                      self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    func loadKanbanTask(_ task: KanbanTaskSummary) {
        let generation = UUID()
        let requestedBoardSlug = task.boardSlug ?? selectedKanbanBoardSlug
        let identity = KanbanTaskIdentity(boardSlug: requestedBoardSlug, taskID: task.id)
        kanbanDetailGeneration = generation
        kanbanDetailTaskIdentity = identity
        loadingKanbanDetailTaskID = task.id
        kanbanDetail = Self.fallbackKanbanTaskDetail(task, boardSlug: requestedBoardSlug)
        kanbanDetailError = nil
        kanbanAttachmentsGeneration = UUID()
        kanbanAttachments = []
        refreshKanbanAttachments(for: task.id, boardSlug: requestedBoardSlug)
        guard let cli else {
            loadingKanbanDetailTaskID = nil
            kanbanDetailError = "Hermes task details are unavailable. Showing the board summary."
            return
        }
        Task {
            defer {
                if generation == kanbanDetailGeneration {
                    loadingKanbanDetailTaskID = nil
                }
            }
            do {
                let fetched = try await fetchKanbanTaskDetail(task, boardSlug: requestedBoardSlug, cli: cli)
                guard generation == kanbanDetailGeneration else { return }
                if let error = fetched.error {
                    kanbanDetailError = error
                    return
                }
                guard kanbanDetailTaskIdentity == identity, let detail = fetched.detail else { return }
                kanbanDetail = detail
            } catch {
                guard generation == kanbanDetailGeneration,
                      kanbanDetailTaskIdentity == identity else { return }
                kanbanDetailError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Card detail for the session Activity panel and chat kanban notices;
    /// leaves the board's selected `kanbanDetail` untouched.
    func sessionKanbanTaskDetail(_ task: KanbanTaskSummary) async -> KanbanTaskDetail? {
        guard let cli else { return nil }
        return try? await fetchKanbanTaskDetail(task, boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, cli: cli).detail
    }

    /// One `show` round trip, plus `runs` only for Hermes versions whose
    /// `show` omits run history. Returns `error` when `show` itself failed.
    private func fetchKanbanTaskDetail(
        _ task: KanbanTaskSummary,
        boardSlug: String?,
        cli: HermesCLIAdapter
    ) async throws -> (detail: KanbanTaskDetail?, error: String?) {
        let taskResult = try await cli.kanbanShow(boardSlug: boardSlug, taskID: task.id)
        guard taskResult.succeeded else {
            let safeError = HermesDiagnosticsService.safeSummary(taskResult.stderr)
            return (nil, safeError.isEmpty ? "Hermes task details are unavailable. Showing the board summary." : safeError)
        }
        // A successful Hermes version may return a human-readable `show`
        // response instead of structured JSON. The selected card already
        // contains authoritative summary data, so keep Details usable and use
        // the structured response only to enrich it when available.
        var detail = Self.parseKanbanTaskDetail(taskResult.stdout, fallback: task, boardSlug: boardSlug)
            ?? Self.fallbackKanbanTaskDetail(task, boardSlug: boardSlug)
        if detail.runs.isEmpty, capabilityAvailable("kanban.taskRuns") {
            let runsResult = try await cli.kanbanRuns(boardSlug: boardSlug, taskID: task.id)
            if runsResult.succeeded {
                detail = Self.enrichedKanbanTaskDetail(
                    detail,
                    runs: Self.parseKanbanRuns(runsResult.stdout, boardSlug: boardSlug),
                    boardSlug: boardSlug
                ) ?? detail
            }
        }
        return (detail, nil)
    }

    static let kanbanTaskInspectionLimit = 24

    /// Loads detail and attachments for an inspector outside the Kanban page.
    /// The cached entry (or the card summary) stays visible while refreshing.
    func inspectKanbanTask(_ task: KanbanTaskSummary) {
        let identity = KanbanTaskIdentity(boardSlug: task.boardSlug, taskID: task.id)
        var entry = kanbanTaskInspections[identity]
            ?? KanbanTaskInspection(detail: Self.fallbackKanbanTaskDetail(task, boardSlug: task.boardSlug))
        guard let cli else {
            entry.error = "Hermes task details are unavailable. Showing the board summary."
            storeKanbanTaskInspection(entry, for: identity)
            return
        }
        entry.isLoading = true
        entry.error = nil
        storeKanbanTaskInspection(entry, for: identity)
        let generation = UUID()
        kanbanTaskInspectionGenerations[identity] = generation
        Task {
            async let attachmentsResult = try? cli.kanbanAttachments(boardSlug: task.boardSlug, taskID: task.id)
            var next = kanbanTaskInspections[identity] ?? entry
            do {
                let fetched = try await fetchKanbanTaskDetail(task, boardSlug: task.boardSlug, cli: cli)
                if let detail = fetched.detail { next.detail = detail }
                next.error = fetched.error
            } catch {
                next.error = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
            if let result = await attachmentsResult, result.succeeded,
               let data = result.stdout.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) {
                next.attachments = Self.parseKanbanAttachments(value, boardSlug: task.boardSlug, taskID: task.id)
                next.attachmentsAvailable = true
            } else {
                next.attachmentsAvailable = false
            }
            guard kanbanTaskInspectionGenerations[identity] == generation else { return }
            kanbanTaskInspectionGenerations[identity] = nil
            next.isLoading = false
            next.loadedAt = Date()
            storeKanbanTaskInspection(next, for: identity)
        }
    }

    private func storeKanbanTaskInspection(_ entry: KanbanTaskInspection, for identity: KanbanTaskIdentity) {
        kanbanTaskInspectionOrder.removeAll { $0 == identity }
        kanbanTaskInspectionOrder.append(identity)
        var next = kanbanTaskInspections
        next[identity] = entry
        // Bounded LRU. In-flight entries are never evicted.
        while kanbanTaskInspectionOrder.count > Self.kanbanTaskInspectionLimit,
              let index = kanbanTaskInspectionOrder.firstIndex(where: { kanbanTaskInspectionGenerations[$0] == nil }) {
            next[kanbanTaskInspectionOrder.remove(at: index)] = nil
        }
        if next != kanbanTaskInspections { kanbanTaskInspections = next }
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
            let stats = Self.parseKanbanStats(result.stdout)
            if kanbanStats != stats {
                kanbanStats = stats
            }
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
            let result = try await cli.kanbanCreate(
                boardSlug: selectedKanbanBoardSlug,
                title: cleanTitle,
                body: cleanBody.isEmpty ? nil : cleanBody
            )
            guard result.succeeded else {
                lastError = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes Kanban could not create the task." : Self.safeUserDiagnostic(result.stderr)
                return false
            }
            if let sessionID = dockModel?.kanbanSessionID, !sessionID.isEmpty,
               (selectedKanbanBoardSlug ?? "").isEmpty,
               let taskID = Self.kanbanTaskID(fromCreateOutput: result.stdout) {
                try? await cli.kanbanAttributeSession(taskID: taskID, sessionID: sessionID)
            }
            refreshKanban()
            refreshGlobalKanban()
            return true
        } catch {
            lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            return false
        }
    }

    static func kanbanTaskID(fromCreateOutput output: String) -> String? {
        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? String {
            return id
        }
        return output.range(of: #""id"\s*:\s*"(t_[A-Za-z0-9_-]+)""#, options: .regularExpression)
            .flatMap { range in
                String(output[range]).components(separatedBy: "\"").last { !$0.isEmpty && !$0.contains(":") }
            }
    }

    func updateKanbanTask(_ task: KanbanTaskSummary, action: KanbanTaskAction) {
        guard let cli, canMutateKanbanTask(action) else { return }
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
                    lastError = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes Kanban could not update the task." : Self.safeUserDiagnostic(result.stderr)
                    return
                }
                refreshKanban()
                refreshGlobalKanban()
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
                    lastError = Self.safeUserDiagnostic(result.stderr).isEmpty ? "Hermes Kanban could not update the task." : Self.safeUserDiagnostic(result.stderr)
                    return
                }
                refreshKanban()
                loadKanbanTask(request.task)
                refreshGlobalKanban()
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func kanbanMoveActionID(_ task: KanbanTaskSummary) -> String { "kanban.move:\(task.id)" }

    /// Lane drops PATCH the same plugin route the board is read from, so the
    /// board being loaded is the capability.
    /// The capability probe runs through the gateway's shell, which can miss a
    /// `hermes` the CLI adapter does reach. A loaded board proves the adapter works.
    func canMutateKanbanTask(_ action: KanbanTaskAction) -> Bool {
        capabilityAvailable("kanban.\(action.rawValue)") || canMoveKanbanTasks
    }

    var canMoveKanbanTasks: Bool {
        guard cli != nil, let state = refreshState(for: "kanban.board") else { return false }
        return state.lastSuccess != nil && !state.isStale
    }

    /// Drag-to-move for Triage/Todo/Ready. Keep the current card in place until
    /// Hermes accepts the transition, then refresh the authoritative board.
    func moveKanbanTask(_ task: KanbanTaskSummary, to lane: KanbanLane) {
        guard let cli, canMoveKanbanTasks else {
            lastError = "Moving Kanban tasks is unavailable through the installed Hermes."
            return
        }
        guard case .move = KanbanBoardPresentation.dropOutcome(taskStatus: task.status, target: lane) else { return }
        let actionID = kanbanMoveActionID(task)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                _ = try await cli.kanbanMove(boardSlug: task.boardSlug ?? selectedKanbanBoardSlug, taskID: task.id, status: lane.status)
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
            refreshKanban()
            refreshGlobalKanban()
        }
    }

    /// One-step assignment, as in the Hermes desktop assignee menu: reassign
    /// and reclaim a live worker first so a running card can change hands.
    /// `nil` unassigns.
    func assignKanbanTask(_ task: KanbanTaskSummary, to profile: String?) {
        guard let cli, capabilityAvailable(HermesFeatureIDs.ID.kanbanReassign.rawValue) else {
            lastError = "Assigning Kanban tasks is unavailable through the installed Hermes CLI."
            return
        }
        guard task.assignee != profile else { return }
        let actionID = kanbanActionID(.reassign, task: task)
        guard beginAction(actionID) else { return }
        setKanbanTask(task.id) { $0.assignee = profile }
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.kanbanAssign(
                    boardSlug: task.boardSlug ?? selectedKanbanBoardSlug,
                    taskID: task.id,
                    profile: profile ?? "none",
                    reassign: true,
                    reclaim: true
                )
                if !result.succeeded {
                    let message = Self.safeUserDiagnostic(result.stderr)
                    lastError = message.isEmpty ? "Hermes Kanban could not assign the task." : message
                }
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
            refreshKanban()
            refreshGlobalKanban()
        }
    }

    private func setKanbanTask(_ id: String, _ change: (inout KanbanTaskSummary) -> Void) {
        guard let index = kanbanTasks.firstIndex(where: { $0.id == id }) else { return }
        change(&kanbanTasks[index])
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
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.cronEdit(jobID: job.id, changes: changes)
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
                _ = try await dockModel.requestControl(HermesFeatureIDs.ID.sessionActivate, params: ["session_id": session.id])
                focus(sessionID: session.id)
                dockModel.updateCurrentSessionTitle(session.title)
                dockModel.requestComposerFocus()
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func openLatestActivitySession(_ activity: LatestActivityItem) {
        openLatestActivitySession(SessionSummary(
            id: activity.sessionID,
            title: activity.sessionTitle,
            state: activity.state,
            preview: nil
        ))
    }

    func respond(to item: AttentionItem, action: AttentionAction, response: String? = nil) {
        guard dockModel != nil || rpc != nil else { return }
        let reference = item.reference
        let actionID = attentionActionID(action, item: item)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                switch action {
                case .approve:
                    guard let rpc, let dockModel, let sessionID = reference.sessionID, !sessionID.isEmpty else { return }
                    _ = try await rpc.respondToApproval(sessionID: sessionID, choice: "once")
                    dockModel.resolveApproval(for: sessionID)
                case .deny:
                    guard let rpc, let dockModel, let sessionID = reference.sessionID, !sessionID.isEmpty else { return }
                    _ = try await rpc.respondToApproval(sessionID: sessionID, choice: "deny")
                    dockModel.resolveApproval(for: sessionID)
                case .respond:
                    let response = response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !response.isEmpty else { return }
                    let requestID = reference.clarificationRequestID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let rpc, let requestID, !requestID.isEmpty else { return }
                    _ = try await rpc.respondToClarification(requestID: requestID, answer: response)
                case .stop:
                    guard let rpc else { return }
                    _ = try await rpc.interrupt(
                        sessionID: reference.sessionID ?? reference.sourceID,
                        profileID: projectProfileID
                    )
                case .resume:
                    guard let rpc else { return }
                    _ = try await rpc.activate(sessionID: reference.sessionID ?? reference.sourceID)
                case .open:
                    guard let rpc, let dockModel else { return }
                    _ = try await rpc.activate(sessionID: reference.sessionID ?? reference.sourceID)
                    currentFocus = reference
                    dockModel.requestComposerFocus()
                default:
                    break
                }
                markResolved(item.id)
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
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
        guard !HermesHighFrequencyEvent.includes(type) else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        let sessionID = (params["session_id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? dockModel?.sessionID
        guard let sessionID, !sessionID.isEmpty else { return }

        let detail = (payload["message"] as? String)
            ?? (params["message"] as? String)
            ?? (payload["description"] as? String)
            ?? (params["description"] as? String)
            ?? (payload["question"] as? String)
            ?? (params["question"] as? String)
            ?? (payload["text"] as? String)
            ?? (params["text"] as? String)
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
            let choices = ((payload["choices"] as? [String])
                ?? (params["choices"] as? [String])
                ?? (payload["options"] as? [String])
                ?? (params["options"] as? [String]))?.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let requestID = (payload["request_id"] as? String)
                ?? (params["request_id"] as? String)
            upsertAttention(AttentionItem(
                id: "clarification:\(sessionID)",
                reference: ControlReference(
                    source: .hermesClarification,
                    sourceID: sessionID,
                    sessionID: sessionID,
                    clarificationRequestID: requestID
                ),
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
            scheduleEventRefresh()
        }
        rebuildAttention()
    }

    /// Gateway event bursts collapse into one refresh. A refresh already in
    /// flight would otherwise drop the event and leave projects stale.
    private func scheduleEventRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            while self?.isRefreshing == true, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !Task.isCancelled else { return }
            self.eventRefreshTask = nil
            self.refresh()
        }
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
            let incomingRequestID = item.reference.clarificationRequestID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let existingRequestID = existing.reference.clarificationRequestID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if incomingRequestID.isEmpty, !existingRequestID.isEmpty {
                enriched.reference.clarificationRequestID = existingRequestID
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
            sessionKanbanTask = nil
            sessionKanbanRequest = nil
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
                self.recordProjectionFailure("processes", error: Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func project(forSessionID sessionID: String) -> ProjectSummary? {
        if let project = projects.first(where: { $0.isRenderableProject && $0.sessionIDs.contains(sessionID) }) {
            return project
        }
        guard let projectID = projectIDBySessionID[sessionID] else { return nil }
        if let project = projects.first(where: { $0.isRenderableProject && $0.id == projectID }) {
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
        if let path = dockModel?.createdSessionProjectPaths[sessionID],
           let project = projects.first(where: { $0.isRenderableProject && $0.name == path }) {
            projectIDBySessionID[sessionID] = project.id
            resolvedProjectIDBySessionID[sessionID] = project.id
            return
        }
        let generation = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        projectMembershipGeneration = generation
        let candidates = projects
        Task { @MainActor [weak self] in
            guard let self else { return }
            for project in candidates {
                guard generation == projectMembershipGeneration,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                guard let result = try? await rpc.projectSessions(projectID: project.id, profileID: self.projectProfileID) else { continue }
                guard generation == projectMembershipGeneration,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                if Self.parseProjectSessions(result).contains(where: { $0.id == sessionID }) {
                    projectIDBySessionID[sessionID] = project.id
                    resolvedProjectIDBySessionID[sessionID] = project.id
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
            // `cron.manage list` only sends a truncated `prompt_preview`; it is display-only, not editable.
            let prompt = (row["prompt"] as? String) ?? (row["request"] as? String) ?? (row["task"] as? String) ?? (row["prompt_preview"] as? String)
            return CronSummary(
                id: id,
                name: (row["name"] as? String) ?? id,
                // Hermes reports interval jobs as {"kind", "minutes", "display"}.
                schedule: (row["schedule"] as? String)
                    ?? ((row["schedule"] as? [String: Any])?["display"] as? String)
                    ?? (row["schedule_display"] as? String)
                    ?? "Scheduled",
                enabled: (row["enabled"] as? Bool) ?? !(row["paused"] as? Bool ?? false),
                nextRun: row["next_run_at"] as? String ?? row["next_run"] as? String ?? row["nextRun"] as? String,
                sessionID: row["session_id"] as? String ?? row["sessionID"] as? String,
                delivery: row["deliver"] as? String ?? row["delivery"] as? String,
                prompt: prompt,
                report: nil,
                editableFields: editable,
                lastRunAt: row["last_run_at"] as? String,
                lastStatus: row["last_status"] as? String,
                lastError: row["last_error"] as? String,
                details: CronJobDetails(row: row)
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
                editableFields: job.editableFields,
                lastRunAt: job.lastRunAt,
                lastStatus: job.lastStatus,
                lastError: job.lastError,
                details: job.details
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

    private func refreshLatestActivities(
        rpc: HermesControlRPC,
        generation: UInt64,
        clientIdentity: ObjectIdentifier?
    ) async throws {
        var sessionRows: [[String: Any]] = []
        var offset = 0
        var pageCount = 0
        var seenPageSignatures = Set<String>()
        var seenSessionIDs = Set<String>()
        let maximumPageCount = 1_000
        repeat {
            guard pageCount < maximumPageCount else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            let page = try await rpc.sessionPages(limit: 100, offset: offset)
            guard let rows = page["data"] as? [[String: Any]] else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            guard let hasMore = Self.parseHasMore(page) else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            if rows.isEmpty, hasMore {
                throw HermesGateway.GatewayError.malformedResponse
            }
            pageCount += 1
            if !rows.isEmpty, Self.paginationPageIsRepeated(rows, seenSignatures: &seenPageSignatures, seenSessionIDs: &seenSessionIDs) {
                throw HermesGateway.GatewayError.malformedResponse
            }
            sessionRows.append(contentsOf: rows)
            offset += rows.count
            if rows.isEmpty || !hasMore { break }
        } while true

        guard let sessions = Self.parseSessions(["data": sessionRows]) else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        var stepsBySessionID: [String: [SessionActivityStep]] = [:]
        var failedSessionCount = 0

        for start in stride(from: 0, to: sessions.count, by: 8) {
            let end = min(start + 8, sessions.count)
            let batch = Array(sessions[start..<end])
            let fetched = await withTaskGroup(of: (String, [SessionActivityStep], Bool).self, returning: [(String, [SessionActivityStep], Bool)].self) { group in
                for session in batch {
                    group.addTask { [weak self] in
                        guard let self else { return (session.id, [], false) }
                        let result = await self.fetchActivitySteps(rpc: rpc, sessionID: session.id)
                        return (session.id, result.steps, result.succeeded)
                    }
                }

                var values: [(String, [SessionActivityStep], Bool)] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            for (sessionID, steps, succeeded) in fetched {
                stepsBySessionID[sessionID] = steps
                if !succeeded { failedSessionCount += 1 }
            }
        }

        let projectedActivities = GlobalSessionActivityPresentation.latestActivity(
            sessions,
            stepsBySessionID: stepsBySessionID
        )
        if failedSessionCount > 0 {
            throw NSError(
                domain: "HermesControl",
                code: 206,
                userInfo: [NSLocalizedDescriptionKey: "Latest activity is partial: unable to read activity from \(failedSessionCount) session\(failedSessionCount == 1 ? "" : "s")."]
            )
        }
        guard isCurrentRefresh(generation, clientIdentity: clientIdentity) else { return }
        latestActivities = projectedActivities
    }

    private func fetchActivitySteps(rpc: HermesControlRPC, sessionID: String) async -> (steps: [SessionActivityStep], succeeded: Bool) {
        do {
            let result = try await rpc.sessionMessages(sessionID: sessionID)
            guard let steps = Self.parseActivityStepsEnvelope(result) else {
                return ([], false)
            }
            return (steps, true)
        } catch HermesGateway.GatewayError.httpError(404) {
            // A session can be pruned after its list page was read. Omit it
            // from this optional activity timeline rather than failing Today
            // or showing an unrelated Inbox warning.
            return ([], true)
        } catch {
            return ([], false)
        }
    }

    static func parseActivityStepsEnvelope(_ result: [String: Any]) -> [SessionActivityStep]? {
        guard result["messages"] == nil,
              let rows = result["data"] as? [[String: Any]] else {
            return nil
        }
        var steps: [SessionActivityStep] = []
        var seenActivityIDs = Set<String>()
        for row in rows {
            let id: String
            if let stringID = row["id"] as? String {
                id = stringID
            } else if let numericID = row["id"] as? NSNumber, !(row["id"] is Bool) {
                id = numericID.stringValue
            } else {
                return nil
            }
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenActivityIDs.insert(id).inserted else { return nil }
            if let role = row["role"], !(role is String) { return nil }
            if let timestamp = row["timestamp"], activityDate(timestamp) == nil { return nil }
            if let toolName = row["tool_name"], !(toolName is String) { return nil }

            var names: [String] = []
            if let rawToolCalls = row["tool_calls"] {
                guard let toolCalls = rawToolCalls as? [[String: Any]] else { return nil }
                for call in toolCalls {
                    if let function = call["function"] {
                        guard let function = function as? [String: Any] else { return nil }
                        if let name = function["name"], !(name is String) { return nil }
                    }
                    if let name = call["name"], !(name is String) { return nil }
                    let function = call["function"] as? [String: Any]
                    if let name = (function?["name"] as? String) ?? (call["name"] as? String) {
                        names.append(name)
                    }
                }
            }
            if let toolName = row["tool_name"] as? String, !toolName.isEmpty {
                names.append(toolName)
            }
            if names.isEmpty, (row["role"] as? String) == "assistant" {
                names = ["Response"]
            }

            let timestamp = activityDate(row["timestamp"]) ?? .distantPast
            steps.append(contentsOf: names.enumerated().map { nameIndex, name in
                SessionActivityStep(id: "\(id)-\(nameIndex)", name: name, timestamp: timestamp)
            })
        }
        return steps
    }

    static func parseHasMore(_ page: [String: Any]) -> Bool? {
        guard let value = page["has_more"] else { return nil }
        return value as? Bool
    }

    static func paginationPageIsRepeated(
        _ rows: [[String: Any]],
        seenSignatures: inout Set<String>
    ) -> Bool {
        var seenSessionIDs = Set<String>()
        return paginationPageIsRepeated(rows, seenSignatures: &seenSignatures, seenSessionIDs: &seenSessionIDs)
    }

    static func paginationPageIsRepeated(
        _ rows: [[String: Any]],
        seenSignatures: inout Set<String>,
        seenSessionIDs: inout Set<String>
    ) -> Bool {
        guard let signature = paginationPageSignature(rows) else { return false }
        let repeatedPage = !seenSignatures.insert(signature).inserted
        let ids = rows.compactMap { $0["id"] as? String }
        let overlaps = ids.contains { seenSessionIDs.contains($0) }
        seenSessionIDs.formUnion(ids)
        return repeatedPage || overlaps
    }

    static func paginationPageSignature(_ rows: [[String: Any]]) -> String? {
        guard rows.allSatisfy({ $0["id"] is String }) else { return nil }
        return "\(rows.count):" + rows.compactMap { $0["id"] as? String }.joined(separator: "\u{1F}")
    }

    nonisolated private static func activityDate(_ value: Any?) -> Date? {
        if let value, !(value is Bool), let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    static func parseSessions(_ result: [String: Any]) -> [SessionSummary]? {
        let rows: [[String: Any]]
        if let value = result["sessions"] {
            guard let parsed = value as? [[String: Any]] else { return nil }
            rows = parsed
        } else if let value = result["active"] {
            guard let parsed = value as? [[String: Any]] else { return nil }
            rows = parsed
        } else if let value = result["data"] {
            guard let parsed = value as? [[String: Any]] else { return nil }
            rows = parsed
        } else {
            return nil
        }

        var sessions: [SessionSummary] = []
        for row in rows {
            guard let id = row["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isOptionalString(row["title"]),
                  isOptionalString(row["name"]),
                  isOptionalString(row["state"]),
                  isOptionalString(row["status"]),
                  isOptionalString(row["preview"]),
                  isOptionalString(row["last_message"]) else {
                return nil
            }
            let title = (row["title"] as? String) ?? (row["name"] as? String) ?? "Hermes session"
            let state = (row["state"] as? String) ?? (row["status"] as? String) ?? "active"
            let preview = row["preview"] as? String ?? row["last_message"] as? String
            let updatedAt = activityDate(row["updated_at"])
                ?? activityDate(row["last_active"])
                ?? activityDate(row["last_message_at"])
                ?? activityDate(row["started_at"])
            sessions.append(SessionSummary(id: id, title: title, state: state, preview: preview, updatedAt: updatedAt))
        }
        return sessions
    }

    private static func isOptionalString(_ value: Any?) -> Bool {
        value == nil || value is String
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

    /// `models` is `/api/analytics/models`, used only for each model's providers:
    /// the usage payload groups by model alone.
    static func parseTokenUsage(_ result: [String: Any], models modelResult: [String: Any] = [:]) -> TokenUsageReport {
        let totals = result["totals"] as? [String: Any] ?? [:]
        let rows = { (key: String, source: [String: Any]) in source[key] as? [[String: Any]] ?? [] }
        var providers: [String: [String]] = [:]
        for row in rows("models", modelResult) {
            guard let model = row["model"] as? String,
                  let provider = row["provider"] as? String, !provider.isEmpty,
                  providers[model]?.contains(provider) != true else { continue }
            providers[model, default: []].append(provider)
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        // Hermes emits the same task once per model/provider pair; the
        // dashboard reads a task as one line, so merge by name.
        func tasks(_ raw: [[String: Any]]) -> [TokenUsageReport.Task] {
            var order: [String] = []
            var merged: [String: TokenUsageReport.Task] = [:]
            for row in raw {
                let name = (row["task"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "other"
                let previous = merged[name]
                if previous == nil { order.append(name) }
                merged[name] = TokenUsageReport.Task(
                    task: name,
                    inputTokens: (previous?.inputTokens ?? 0) + intValue(row["input_tokens"]),
                    outputTokens: (previous?.outputTokens ?? 0) + intValue(row["output_tokens"]),
                    estimatedCost: (previous?.estimatedCost ?? 0) + (doubleValue(row["estimated_cost"]) ?? 0),
                    apiCalls: (previous?.apiCalls ?? 0) + intValue(row["api_calls"])
                )
            }
            return order.compactMap { merged[$0] }.sorted { $0.totalTokens > $1.totalTokens }
        }
        let skills = result["skills"] as? [String: Any] ?? [:]
        let skillSummary = skills["summary"] as? [String: Any] ?? [:]
        return TokenUsageReport(
            days: intValue(result["period_days"]),
            inputTokens: intValue(totals["total_input"]),
            outputTokens: intValue(totals["total_output"]),
            cacheReadTokens: intValue(totals["total_cache_read"]),
            reasoningTokens: intValue(totals["total_reasoning"]),
            estimatedCost: doubleValue(totals["total_estimated_cost"]) ?? 0,
            actualCost: doubleValue(totals["total_actual_cost"]) ?? 0,
            sessions: intValue(totals["total_sessions"]),
            apiCalls: intValue(totals["total_api_calls"]),
            daily: rows("daily", result).compactMap { row in
                guard let day = (row["day"] as? String).flatMap(dayFormatter.date(from:)) else { return nil }
                return TokenUsageReport.Day(
                    day: day,
                    inputTokens: intValue(row["input_tokens"]),
                    outputTokens: intValue(row["output_tokens"]),
                    cacheReadTokens: intValue(row["cache_read_tokens"]),
                    reasoningTokens: intValue(row["reasoning_tokens"]),
                    estimatedCost: doubleValue(row["estimated_cost"]) ?? 0,
                    sessions: intValue(row["sessions"]),
                    apiCalls: intValue(row["api_calls"])
                )
            },
            models: rows("by_model", result).map { row in
                TokenUsageReport.Model(
                    model: (row["model"] as? String) ?? "unknown",
                    inputTokens: intValue(row["input_tokens"]),
                    outputTokens: intValue(row["output_tokens"]),
                    estimatedCost: doubleValue(row["estimated_cost"]) ?? 0,
                    sessions: intValue(row["sessions"]),
                    apiCalls: intValue(row["api_calls"]),
                    tasks: tasks(rows("aux_tasks", row)),
                    providers: providers[(row["model"] as? String) ?? ""] ?? []
                )
            },
            tasks: tasks(rows("by_task", result)),
            tools: rows("tools", result).map {
                TokenUsageReport.Share(name: ($0["tool"] as? String) ?? "unknown", count: intValue($0["count"]), percentage: doubleValue($0["percentage"]) ?? 0)
            },
            skills: rows("top_skills", skills).map {
                TokenUsageReport.Share(name: ($0["skill"] as? String) ?? "unknown", count: intValue($0["total_count"]), percentage: doubleValue($0["percentage"]) ?? 0)
            },
            skillLoads: intValue(skillSummary["total_skill_loads"]),
            distinctSkills: intValue(skillSummary["distinct_skills_used"])
        )
    }

    static func parseCheckpoints(_ result: [String: Any]) -> [HermesCheckpointSummary] {
        guard result["enabled"] as? Bool == true,
              let rows = result["checkpoints"] as? [[String: Any]], rows.count <= 50 else { return [] }
        return rows.compactMap { row in
            guard let hash = row["hash"] as? String, !hash.isEmpty, hash.count <= 128 else { return nil }
            let timestamp = (row["timestamp"] as? String ?? "").prefix(128)
            let message = (row["message"] as? String ?? "").prefix(512)
            return HermesCheckpointSummary(hash: hash, timestamp: String(timestamp), message: String(message))
        }
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
            safeDetail: boundedQuotaText(result["safe_detail"]),
            hermesCredential: hermesPooledCredential(result["hermes_credential"])
        )
    }

    private static func hermesPooledCredential(_ value: Any?) -> HermesPooledCredential? {
        guard let object = value as? [String: Any],
              let provider = object["provider"] as? String, !provider.isEmpty,
              let id = object["id"] as? String, !id.isEmpty else { return nil }
        return HermesPooledCredential(
            provider: provider,
            id: id,
            label: (object["label"] as? String) ?? id,
            position: (object["position"] as? Int) ?? 0
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

    private static func optionalVerificationExitCode(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            guard type != "c" && type != "B", value.doubleValue.rounded() == value.doubleValue else { return nil }
            return value.intValue
        }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// Large boards take tens of milliseconds to scan and decode; polling on
    /// the main actor made every refresh a visible scroll hitch.
    nonisolated static func parseKanbanTasksOffMain(_ output: String, boardSlug: String?) async -> [KanbanTaskSummary]? {
        await Task.detached(priority: .utility) {
            parseKanbanTasksStrict(output, boardSlug: boardSlug)
        }.value
    }

    static func parseKanbanTasks(_ output: String, boardSlug: String? = nil) -> [KanbanTaskSummary] {
        parseKanbanTasksStrict(output, boardSlug: boardSlug) ?? []
    }

    /// Returns nil when the CLI response is not a top-level task array. The
    /// optional result distinguishes malformed output from a genuine empty
    /// board, whose valid `[]` response must still replace the projection.
    nonisolated static func parseKanbanTasksStrict(_ output: String, boardSlug: String? = nil) -> [KanbanTaskSummary]? {
        // A JSON value starting at a bracket can only end at its matching
        // bracket, so parse one candidate per start. Trying every later
        // closing bracket was quadratic and stalled the main thread for
        // seconds on large boards.
        let bytes = Array(output.utf8)
        var validEmptyRows: [[String: Any]]?
        for start in bytes.indices where bytes[start] == UInt8(ascii: "[") || bytes[start] == UInt8(ascii: "{") {
            guard let end = matchingJSONBracket(in: bytes, from: start),
                  let value = try? JSONSerialization.jsonObject(with: Data(bytes[start...end])),
                  let rows = kanbanTaskRows(from: value) else { continue }
            if !rows.isEmpty { return rows.compactMap { parseKanbanTaskSummary($0, boardSlug: boardSlug) } }
            validEmptyRows = rows
        }
        return validEmptyRows?.compactMap { parseKanbanTaskSummary($0, boardSlug: boardSlug) }
    }

    /// Index of the bracket closing the one at `start`, skipping JSON strings.
    nonisolated private static func matchingJSONBracket(in bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    nonisolated private static func kanbanTaskRows(from value: Any) -> [[String: Any]]? {
        if let rows = value as? [[String: Any]] { return rows }
        if let encoded = value as? String,
           let data = encoded.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data) {
            return kanbanTaskRows(from: nested)
        }
        guard let envelope = value as? [String: Any] else { return nil }
        // Accept only known Hermes relay/list envelopes. Arbitrary objects must
        // remain malformed instead of silently becoming an empty board.
        for key in ["tasks", "items", "data", "result", "payload", "stdout", "output"] {
            if let rows = kanbanTaskRows(from: envelope[key] as Any) { return rows }
        }
        return nil
    }

    static func parseKanbanTaskSummary(
        _ output: String,
        boardSlug: String? = nil,
        sessionID: String? = nil
    ) -> KanbanTaskSummary? {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let row: [String: Any]
        if let dictionary = value as? [String: Any], let task = dictionary["task"] as? [String: Any] {
            row = task
        } else if let dictionary = value as? [String: Any] {
            row = dictionary
        } else {
            return nil
        }
        guard let base = parseKanbanTaskSummary(row, boardSlug: boardSlug, sessionID: sessionID) else { return nil }
        let event = parseLatestKanbanEvent((value as? [String: Any])?["events"])
        return KanbanTaskSummary(
            id: base.id,
            boardSlug: base.boardSlug,
            title: base.title,
            status: base.status,
            detail: base.detail,
            priority: base.priority,
            assignee: base.assignee,
            sessionID: base.sessionID,
            startedAt: base.startedAt,
            completedAt: base.completedAt,
            currentStepKey: base.currentStepKey,
            latestEventKind: event.kind,
            latestEventNote: event.note,
            latestEventAt: event.date,
            modelOverride: base.modelOverride,
            providerOverride: base.providerOverride,
            skills: base.skills,
            workflowTemplateID: base.workflowTemplateID
        )
    }

    nonisolated private static func parseKanbanTaskSummary(
        _ row: [String: Any],
        boardSlug: String?,
        sessionID: String? = nil
    ) -> KanbanTaskSummary? {
        guard let id = (row["id"] as? String) ?? (row["task_id"] as? String),
              let title = (row["title"] as? String) ?? (row["t"] as? String) else { return nil }
        return KanbanTaskSummary(
            id: id,
            boardSlug: boardSlug
                ?? (row["board_slug"] as? String)
                ?? (row["boardSlug"] as? String)
                ?? (row["board"] as? String),
            title: title,
            status: (row["status"] as? String) ?? (row["s"] as? String) ?? "unknown",
            detail: (row["body"] as? String) ?? (row["description"] as? String),
            priority: Self.stringValue(row["priority"] ?? row["p"]),
            assignee: (row["assignee"] as? String) ?? (row["assigned_to"] as? String) ?? (row["a"] as? String),
            sessionID: sessionID ?? (row["session_id"] as? String) ?? (row["sessionID"] as? String),
            startedAt: activityDate(row["started_at"] ?? row["startedAt"]),
            completedAt: activityDate(row["completed_at"] ?? row["completedAt"]),
            currentStepKey: (row["current_step_key"] as? String) ?? (row["currentStepKey"] as? String),
            modelOverride: (row["model_override"] as? String) ?? (row["modelOverride"] as? String) ?? (row["model"] as? String),
            providerOverride: (row["provider_override"] as? String) ?? (row["providerOverride"] as? String) ?? (row["provider"] as? String),
            skills: kanbanStringList(row["skills"]),
            workflowTemplateID: (row["workflow_template_id"] as? String) ?? (row["workflowTemplateID"] as? String)
        )
    }

    private static func parseLatestKanbanEvent(_ value: Any?) -> (kind: String?, note: String?, date: Date?) {
        guard let events = value as? [[String: Any]], !events.isEmpty else { return (nil, nil, nil) }
        let latest = events.max { lhs, rhs in
            (activityDate(lhs["created_at"] ?? lhs["createdAt"]) ?? .distantPast)
                < (activityDate(rhs["created_at"] ?? rhs["createdAt"]) ?? .distantPast)
        } ?? [:]
        return (
            (latest["kind"] as? String) ?? (latest["type"] as? String),
            (latest["note"] as? String)
                ?? ((latest["payload"] as? [String: Any])?["note"] as? String)
                ?? (latest["payload"] as? String),
            activityDate(latest["created_at"] ?? latest["createdAt"])
        )
    }

    /// The session Activity projection is a privacy boundary. Even when the
    /// CLI request carries a session filter, publish only rows that return a
    /// present, exact canonical session identifier.
    static func filterSessionKanbanTasks(_ tasks: [KanbanTaskSummary], sessionID: String, aliases: Set<String> = [], observedIDs: Set<String> = []) -> [KanbanTaskSummary] {
        guard !sessionID.isEmpty else { return [] }
        let ids = aliases.union([sessionID])
        return tasks.filter { $0.sessionID.map(ids.contains) ?? observedIDs.contains($0.id) }
    }

    static func parseKanbanTaskDetail(_ output: String, fallback: KanbanTaskSummary, boardSlug: String? = nil) -> KanbanTaskDetail? {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let source = kanbanTaskDetailRow(from: value) else { return nil }
        guard let id = (source["id"] as? String) ?? (source["task_id"] as? String) else { return nil }
        let resolvedBoardSlug = boardSlug ?? fallback.boardSlug
        var detail = KanbanTaskDetail(
            id: id,
            boardSlug: resolvedBoardSlug,
            title: (source["title"] as? String) ?? fallback.title,
            body: (source["body"] as? String) ?? (source["description"] as? String),
            status: (source["status"] as? String) ?? fallback.status,
            priority: Self.stringValue(source["priority"]) ?? fallback.priority,
            assignee: (source["assignee"] as? String) ?? (source["assigned_to"] as? String) ?? fallback.assignee,
            runs: [],
            modelOverride: (source["model_override"] as? String) ?? (source["modelOverride"] as? String) ?? (source["model"] as? String) ?? fallback.modelOverride,
            providerOverride: (source["provider_override"] as? String) ?? (source["providerOverride"] as? String) ?? (source["provider"] as? String) ?? fallback.providerOverride
        )
        // `show --json` wraps the task with its history; the history may also
        // arrive inline on the task row from relay transports.
        let history = kanbanShowEnvelope(from: value) ?? source
        detail.latestSummary = Self.nonEmpty(history["latest_summary"] as? String)
        detail.result = Self.nonEmpty(source["result"] as? String)
        detail.lastFailureError = Self.nonEmpty(source["last_failure_error"] as? String)
        detail.skills = kanbanStringList(source["skills"])
        detail.workflowTemplateID = Self.nonEmpty(source["workflow_template_id"] as? String)
        detail.currentStepKey = Self.nonEmpty(source["current_step_key"] as? String) ?? fallback.currentStepKey
        detail.workspaceKind = Self.nonEmpty(source["workspace_kind"] as? String)
        detail.workspacePath = Self.nonEmpty(source["workspace_path"] as? String)
        detail.branchName = Self.nonEmpty(source["branch_name"] as? String)
        detail.sessionID = Self.nonEmpty(source["session_id"] as? String) ?? fallback.sessionID
        detail.createdBy = Self.nonEmpty(source["created_by"] as? String)
        detail.createdAt = activityDate(source["created_at"])
        detail.startedAt = activityDate(source["started_at"]) ?? fallback.startedAt
        detail.completedAt = activityDate(source["completed_at"]) ?? fallback.completedAt
        detail.parents = kanbanStringList(history["parents"])
        detail.children = kanbanStringList(history["children"])
        detail.comments = ((history["comments"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, row in
            guard let body = Self.nonEmpty(row["body"] as? String) else { return nil }
            let createdAt = activityDate(row["created_at"])
            return KanbanCommentSummary(
                id: Self.stringValue(row["id"]) ?? "comment-\(index)",
                author: Self.nonEmpty(row["author"] as? String) ?? "Unknown",
                body: body,
                createdAt: createdAt
            )
        }
        detail.events = ((history["events"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, row in
            guard let kind = Self.nonEmpty((row["kind"] as? String) ?? (row["type"] as? String)) else { return nil }
            return KanbanEventSummary(
                id: Self.stringValue(row["id"]) ?? "event-\(index)",
                kind: kind,
                note: kanbanEventNote(row["note"] ?? row["payload"]),
                runID: Self.stringValue(row["run_id"]),
                createdAt: activityDate(row["created_at"])
            )
        }
        detail.runs = ((history["runs"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, row in
            kanbanRunSummary(row, index: index, boardSlug: resolvedBoardSlug)
        }
        return detail
    }

    /// The `show --json` object that carries `task` plus its history.
    private static func kanbanShowEnvelope(from value: Any) -> [String: Any]? {
        if let rows = value as? [[String: Any]] { return rows.first.flatMap { kanbanShowEnvelope(from: $0) } }
        guard let dictionary = value as? [String: Any] else { return nil }
        if dictionary["task"] is [String: Any] { return dictionary }
        for key in ["data", "result", "payload", "output", "stdout"] {
            if let envelope = dictionary[key].flatMap({ kanbanShowEnvelope(from: $0) }) { return envelope }
        }
        return nil
    }

    /// Hermes stores skills and links as JSON arrays; older rows may hold a
    /// comma-separated string.
    nonisolated private static func kanbanStringList(_ value: Any?) -> [String] {
        if let values = value as? [Any] {
            return values.compactMap { stringValue($0).flatMap(nonEmpty) }
        }
        if let string = value as? String {
            if let data = string.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                return kanbanStringList(decoded)
            }
            return string.split(separator: ",").compactMap { nonEmpty(String($0)) }
        }
        return []
    }

    /// Events carry either a plain note or a payload object/JSON string.
    private static func kanbanEventNote(_ value: Any?) -> String? {
        if let string = value as? String {
            if let data = string.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return kanbanEventNote(decoded)
            }
            return nonEmpty(string)
        }
        guard let payload = value as? [String: Any] else { return nil }
        for key in ["note", "reason", "summary", "message", "text", "error"] {
            if let note = nonEmpty(payload[key] as? String) { return note }
        }
        return nil
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func fallbackKanbanTaskDetail(_ task: KanbanTaskSummary, boardSlug: String? = nil) -> KanbanTaskDetail {
        KanbanTaskDetail(
            id: task.id,
            boardSlug: boardSlug ?? task.boardSlug,
            title: task.title,
            body: task.detail,
            status: task.status,
            priority: task.priority,
            assignee: task.assignee,
            runs: [],
            modelOverride: task.modelOverride,
            providerOverride: task.providerOverride
        )
    }

    static func enrichedKanbanTaskDetail(
        _ detail: KanbanTaskDetail?,
        runs: [KanbanRunSummary],
        boardSlug: String?
    ) -> KanbanTaskDetail? {
        guard var detail else { return nil }
        detail.boardSlug = boardSlug
        detail.runs = runs
        return detail
    }

    /// Hermes versions and relay transports have returned task details as a
    /// task object, a one-item array, or a known result envelope. Keep this
    /// normalization local to the parser so the UI does not need to know
    /// which transport shape produced the response.
    private static func kanbanTaskDetailRow(from value: Any) -> [String: Any]? {
        if let rows = value as? [[String: Any]] {
            return rows.first.flatMap { kanbanTaskDetailRow(from: $0) }
        }
        guard let dictionary = value as? [String: Any] else { return nil }
        if let task = dictionary["task"] {
            if let row = kanbanTaskDetailRow(from: task) { return row }
        }
        for key in ["data", "result", "payload", "output", "stdout"] {
            if let row = dictionary[key].flatMap({ kanbanTaskDetailRow(from: $0) }) {
                return row
            }
        }
        return dictionary["id"] != nil || dictionary["task_id"] != nil ? dictionary : nil
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
            kanbanRunSummary(row, index: index, boardSlug: boardSlug)
        }
    }

    /// Hermes run ids are integers; relays may send strings.
    private static func kanbanRunSummary(_ row: [String: Any], index: Int, boardSlug: String?) -> KanbanRunSummary? {
        guard let status = (row["status"] as? String) ?? (row["state"] as? String) else { return nil }
        return KanbanRunSummary(
            id: stringValue(row["id"] ?? row["run_id"]) ?? "run-\(index)",
            boardSlug: boardSlug,
            status: status,
            outcome: row["outcome"] as? String,
            profile: (row["profile"] as? String) ?? (row["assignee"] as? String),
            summary: (row["summary"] as? String) ?? (row["message"] as? String),
            elapsed: (row["elapsed"] as? String) ?? (row["duration"] as? String),
            stepKey: nonEmpty(row["step_key"] as? String),
            error: nonEmpty(row["error"] as? String),
            startedAt: activityDate(row["started_at"]),
            endedAt: activityDate(row["ended_at"])
        )
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
            let row = $0
            let staleReasonValue = row["stale_reason"] as? String ?? row["staleReason"] as? String
            let hasInvalidStaleReason = ["stale_reason", "staleReason"].contains { key in
                guard let rawValue = row[key] else { return false }
                guard let stringValue = rawValue as? String else { return true }
                return VerificationEvidenceText.bounded(stringValue) == nil
            }
            return VerificationEvidenceSummary(
                command: row["command"] as? String,
                canonicalCommand: row["canonical_command"] as? String ?? row["canonicalCommand"] as? String,
                kind: row["kind"] as? String,
                scope: row["scope"] as? String,
                status: row["status"] as? String,
                exitCode: Self.optionalVerificationExitCode(row["exit_code"] ?? row["exitCode"]),
                outputSummary: row["output_summary"] as? String ?? row["outputSummary"] as? String,
                adapter: VerificationEvidenceText.bounded(row["adapter"] as? String ?? row["tool_identifier"] as? String ?? row["toolIdentifier"] as? String),
                capturedAt: Self.optionalISO8601Date(row["captured_at"] ?? row["capturedAt"]),
                repositoryIdentity: VerificationEvidenceText.bounded(row["repository_identity"] as? String ?? row["repositoryIdentity"] as? String),
                commitFingerprint: VerificationEvidenceText.bounded(row["commit_fingerprint"] as? String ?? row["commitFingerprint"] as? String),
                targetFingerprint: VerificationEvidenceText.bounded(row["target_fingerprint"] as? String ?? row["targetFingerprint"] as? String),
                diffFingerprint: VerificationEvidenceText.bounded(row["diff_fingerprint"] as? String ?? row["diffFingerprint"] as? String),
                rulesScopeDetail: VerificationEvidenceText.bounded(row["rules_scope_detail"] as? String ?? row["rulesScopeDetail"] as? String ?? row["rules"] as? String),
                staleReason: VerificationEvidenceText.bounded(staleReasonValue),
                hasInvalidStaleReason: hasInvalidStaleReason
            )
        }
        return VerificationSummary(state: state, evidence: evidence)
    }

    private static func optionalISO8601Date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    static func parseKanbanAttachments(_ value: Any, boardSlug: String?, taskID: String) -> [KanbanAttachmentSummary] {
        let rows = (value as? [[String: Any]]) ?? ((value as? [String: Any])?["attachments"] as? [[String: Any]]) ?? []
        return rows.enumerated().map { index, row in
            let name = (row["name"] as? String) ?? (row["filename"] as? String) ?? "Attachment"
            let fallback = [boardSlug ?? "default", taskID, name, String(index)].joined(separator: ":")
            return KanbanAttachmentSummary(
                id: Self.stringValue(row["id"]) ?? fallback,
                name: name,
                kind: row["kind"] as? String ?? row["mime_type"] as? String ?? row["content_type"] as? String,
                sizeBytes: Self.optionalIntValue(row["size"] ?? row["size_bytes"]),
                uploadedBy: Self.nonEmpty(row["uploaded_by"] as? String),
                createdAt: activityDate(row["created_at"]),
                storedPath: Self.nonEmpty(row["stored_path"] as? String)
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
        let output = result.succeeded ? result.stdout : Self.safeUserDiagnostic(result.stderr)
        let detail = HermesDiagnosticsService.safeSummary(output)
        return HermesReadOnlyStatus(
            id: id,
            title: title,
            detail: detail.isEmpty ? (result.succeeded ? "Available" : "Unavailable") : detail,
            isAvailable: result.succeeded
        )
    }

    nonisolated private static func stringValue(_ value: Any?) -> String? {
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
            let title = (row["title"] as? String) ?? (row["name"] as? String) ?? "Hermes session"
            let state = (row["state"] as? String) ?? (row["status"] as? String) ?? "active"
            let preview = row["preview"] as? String ?? row["last_message"] as? String
            let updatedAt = activityDate(row["updated_at"])
                ?? activityDate(row["last_active"])
                ?? activityDate(row["last_message_at"])
                ?? activityDate(row["started_at"])
            return SessionSummary(id: id, title: title, state: state, preview: preview, updatedAt: updatedAt)
        }
    }

}
