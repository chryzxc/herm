import Foundation
import Combine

@MainActor
final class ControlCenterModel: ObservableObject {
    var interruptionCoordinator: HermInterruptionCoordinator? { dockModel?.interruptionCoordinator }
    let pet = HermesPetModel()
    @Published var integrationDestination: IntegrationDestination?
    @Published var requestedRepositoryReview: QuickDestination?
    @Published var requestedAutomationDidNavigate = false
    @Published var requestedAutomationOwner: CronOwner?
    @Published var automationNavigationError: String?
    @Published var requestedAutomationJobID: String?
    @Published var routineProfileID: String?
    @Published var routineActions = Set<String>()
    @Published var unavailableRoutineActions = Set<String>()
    @Published var routineActionErrors: [String: String] = [:]
    var triggeredRoutineIDs = Set<String>()
    var triggeredRoutineRevisions: [String: String] = [:]
    var routineReportClient: HermesControlRPC? { rpc }
    let gatewayService = HermesGatewayLifecycleModel()
    @Published var attention: [AttentionItem] = []
    @Published var reminders: [ReminderSummary] = []
    var lastCreatedCronJobID: String?
    @Published var cronJobs: [CronSummary] = []
    @Published var cronRuns: [CronRunSummary] = []
    @Published var cronHistoryAvailable = false
    /// Per-job history. The global `cronRuns` feed is capped, so high-frequency
    /// jobs crowd daily/weekly jobs out of it entirely.
    @Published var cronRunsByJob: [String: [CronRunSummary]] = [:]
    @Published var mcpServers: [MCPServerSummary] = []
    @Published var mcpTestResults: [String: String] = [:]
    @Published var mcpInventoryAvailable = false
    @Published var commandAllowlistEntries: [String]?
    @Published var activeSessions: [SessionSummary] = []
    @Published var latestActivities: [LatestActivityItem] = []
    @Published var currentFocus: ControlReference?
    @Published var activeAgents: [AgentSummary] = []
    @Published var delegationPaused = false
    @Published var processes: [ProcessSummary] = []
    @Published var projects: [ProjectSummary] = []
    @Published var projectIDBySessionID: [String: String] = [:]
    /// Memberships resolved from `projects.project_sessions`. The project tree
    /// may omit these IDs on later refreshes, so retain them separately from
    /// the transient tree projection.
    var resolvedProjectIDBySessionID: [String: String] = [:]
    @Published var searchResults: [ControlSearchResult] = []
    @Published var isSearching = false
    @Published var kanbanTasks: [KanbanTaskSummary] = []
    /// Canonical unfiltered aggregate, independent of the board page's visible filters.
    @Published var globalKanbanTasks: [KanbanTaskSummary] = []
    @Published var globalKanbanIsCurrent = false
    @Published var requestedKanbanTask: KanbanTaskSummary?
    @Published var sessionKanbanTasks: [KanbanTaskSummary] = []
    @Published var sessionKanbanSessionID: String?
    @Published var kanbanDetail: KanbanTaskDetail?
    @Published var kanbanDetailTaskIdentity: KanbanTaskIdentity?
    @Published var kanbanDetailError: String?
    @Published var kanbanStats: KanbanStatsSummary?
    @Published var kanbanAssignees: [String] = []
    @Published var kanbanBoards: [KanbanBoardSummary] = []
    @Published var selectedKanbanBoardSlug: String?
    @Published var kanbanFilter = KanbanListFilter()
    @Published var journeyNodes: [HermesJourneyNode] = []
    @Published var sessionStoreStatus: HermesReadOnlyStatus?
    @Published var memoryHealthStatus: HermesReadOnlyStatus?
    @Published var sessionUsage: SessionUsageSummary?
    @Published var sessionContext: SessionContextSummary?
    /// A year of daily usage for the heatmap, independent of the range picker.
    @Published var yearActivity: [TokenUsageReport.Day] = []
    var tokenUsageGeneration = UUID()
    var tokenUsageModelRows: [String: Any] = [:]
    @Published var workCalendar: WorkCalendarIndex?
    /// Fetched sessions/commits/usage per month start; Kanban and cron runs are
    /// folded in from the live projections at build time.
    var workCalendarSources: [Date: (sessions: [SessionSummary], commits: [WorkCommit], pullRequests: [WorkPullRequest], usage: [TokenUsageReport.Day])] = [:]
    var workCalendarMonth: Date?
    /// Paths each cached month's git read covered, so newly seen worktrees trigger one re-read.
    var workCalendarPaths: [Date: Set<String>] = [:]
    var workCalendarRepoPaths: [String] = []
    var workCalendarGeneration = UUID()
    @Published var providerQuotas: [ProviderQuotaSnapshot] = []
    /// Hermes' provider catalog (Settings → Providers); nil until first loaded.
    /// It is the source of truth for which quota providers the Quota page offers.
    @Published var hermesProviderRows: [HermesProviderRow]?
    /// Snapshots exactly as the providers reported them. `providerQuotas` is
    /// derived from these plus the user's nicknames and display order, so a
    /// rename or reorder never needs another provider read.
    var reportedProviderQuotas: [ProviderQuotaSnapshot] = []
    /// Safe per-provider diagnostics from the last quota refresh, keyed by
    /// catalog provider id. Providers without an entry connected successfully;
    /// missing providers render disabled with their diagnostic, never invented.
    @Published var providerQuotaDiagnostics: [String: String] = [:]
    @Published var kanbanDiagnostics: [KanbanDiagnosticSummary] = []
    @Published var kanbanAttachments: [KanbanAttachmentSummary] = []
    /// Keyed task detail for inspectors that sit beside the Kanban page (the
    /// 3D office). Separate from `kanbanDetail`, so the two never clobber.
    @Published var kanbanTaskInspections: [KanbanTaskIdentity: KanbanTaskInspection] = [:]
    @Published var promptBudget: PromptBudgetSummary?
    @Published var projectFacts: ProjectFactsSummary?
    @Published var verification: VerificationSummary?
    @Published var appearanceProjection: AppearanceCLIProjection.Inventory?
    @Published var appearanceProjectionAvailable = false
    @Published var insightsSummary: HermesInsightsSummary?
    @Published var checkpoints: [HermesCheckpointSummary] = []
    @Published var restoreCheckpoints: [RestoreCheckpoint] = []
    @Published var restoreCheckpointState: RestoreCheckpointState = .idle
    @Published var checkpointDiff: String?
    @Published var isLoadingCheckpoints = false
    @Published var emergencyStopActive: Bool?
    @Published var emergencyStopMessage: String?
    @Published var developmentContext: RepositorySnapshot?
    @Published var loadingKanbanDetailTaskID: String?
    @Published var isCreatingKanbanTask = false
    @Published var projectSessions: [SessionSummary] = []
    /// Authoritative session rows keyed by project. Unlike `projects.tree`,
    /// this projection contains every session in a project, not just a count
    /// or a short preview.
    @Published var projectSessionsByProjectID: [String: [SessionSummary]] = [:]
    @Published var isRefreshingProjectNavigation = false
    var didLoadInitialProjectNavigation = false
    @Published var selectedProjectID: String?
    /// Profile scope used exclusively by the Projects projection and its
    /// mutations. Other Control tabs remain gateway-global by design.
    @Published var projectProfileID: String?
    @Published var projectProfileScopeUnavailable = false
    /// Keeps the Projects detail view stable while its background projection is
    /// refreshing. A selected project can briefly be absent from a partial
    /// `projects.tree` response, but that must not dismiss the user's detail.
    @Published var selectedProject: ProjectSummary?
    @Published var capabilities: [CapabilityState] = []
    var capabilitySnapshotGeneratedAt: Date = .distantPast
    @Published var diagnostics: [HermesDiagnostic] = []
    @Published var isRefreshing = false
    @Published var pendingActionIDs: Set<String> = []
    @Published var lastError: String?
    /// Failures of quota-card actions (such as removing a Hermes-pooled
    /// account), keyed by provider id and shown on that card.
    @Published var providerQuotaActionErrors: [String: String] = [:]
    /// `provider/id` of each pooled credential Hermes currently selects.
    @Published var hermesActiveCredentialKeys: Set<String> = []
    @Published var projectionRefreshStates: [String: ProjectionRefreshState] = [:]
    @Published var projectionStates: [String: HermesProjectionState<Int>] = [:]

    weak var dockModel: DockModel?
    var kanbanChatSyncAnchor: UUID?
    var kanbanChatSyncSessionID: String?
    var kanbanChatSyncedEventAt: [String: Date?] = [:]
    /// Last `kanban show` per card, keyed by its `latestEventAt`; survives anchor resets.
    var kanbanChatDetailCache: [String: (eventAt: Date?, detail: KanbanTaskDetail)] = [:]
    /// Feed session ID → its Hermes source, and every session already judged.
    var kanbanChatFeeds: [String: String] = [:]
    var kanbanChatCheckedSessionIDs: Set<String> = []
    var rpc: HermesControlRPC?
    /// Desktop-parity editor for Hermes `config.yaml`, over the same backend.
    lazy var configEditor = HermesConfigEditor { [weak self] in self?.rpc }
    var cli: HermesCLIAdapter?
    var refreshTask: Task<Void, Never>?
    var eventRefreshTask: Task<Void, Never>?
    var initialProjectNavigationTask: Task<Void, Never>?
    var refreshGeneration: UInt64 = 0
    var clientBindingGeneration: UInt64 = 0
    var searchTask: Task<Void, Never>?
    var searchGeneration = UUID()
    var aggregateKanbanRefreshGeneration = UUID()
    var visibleKanbanRefreshGeneration = UUID()
    var queuedVisibleKanbanFilter: KanbanListFilter?
    var hasKanbanReadInFlight: Bool { !kanbanRefreshInFlight.isEmpty }
    var kanbanRefreshInFlight: Set<KanbanRefreshScope> = []
    var providerQuotaReadsInFlight = 0
    var sessionKanbanRefreshGeneration = UUID()
    var sessionKanbanTask: Task<Void, Never>?
    var sessionKanbanRequest: SessionKanbanProjectionRequest?
    var sessionKanbanRefreshPending = false
    var sessionKanbanBoardSlug: String?
    /// Last successful session Activity snapshots. Session navigation swaps the
    /// published projection, but must not make already loaded work disappear
    /// while the same read-only query refreshes in the background.
    var sessionKanbanTasksByRequest: [SessionKanbanProjectionRequest: [KanbanTaskSummary]] = [:]
    /// Observed card IDs (`board|id`) whose `kanban show` returned no usable
    /// card. Each lookup spawns a Hermes CLI process, so polling must not
    /// retry them on every refresh.
    // ponytail: cleared only on app restart; add expiry if a missed card can later appear.
    var unrecoverableKanbanTaskIDs: Set<String> = []
    var kanbanBoardsGeneration = UUID()
    var kanbanStatsGeneration = UUID()
    var kanbanAssigneesGeneration = UUID()
    var kanbanDetailGeneration = UUID()
    var kanbanTaskInspectionGenerations: [KanbanTaskIdentity: UUID] = [:]
    var kanbanTaskInspectionOrder: [KanbanTaskIdentity] = []
    var kanbanDiagnosticsGeneration = UUID()
    var kanbanAttachmentsGeneration = UUID()
    var promptBudgetGeneration = UUID()
    var projectFactsGeneration = UUID()
    var verificationGeneration = UUID()
    var appearanceProjectionGeneration = UUID()
    var checkpointsGeneration = UUID()
    let restoreCheckpointCoordinator = RestoreCheckpointCoordinator()
    var projectSessionsGeneration = UUID()
    var projectNavigationRefreshGeneration: UUID?
    var pendingProjectNavigationSessions: [String: [SessionSummary]] = [:]
    var completedProjectNavigationIDs: Set<String> = []
    var projectNavigationRefreshIDs: Set<String> = []
    var projectMembershipGeneration = UUID()
    var cronRunsGeneration = UUID()
    var mcpInventoryGeneration = UUID()
    var journeyGeneration = UUID()
    var sessionCockpitGeneration = UUID()
    var providerQuotaGeneration = UUID()
    var sessionCockpitSessionID: String?
    var sessionProcessesGeneration = UUID()
    var knownAttention: [String: AttentionItem] = [:]
    var eventSubscription: UUID?
    let capabilityService = HermesCapabilityService()
    let diagnosticsService = HermesDiagnosticsService()
    var remindersAdapter: AppleRemindersAdapter?
    let presentationDefaults = UserDefaults.standard
    let providerNicknameStore = ProviderNicknameStore()
    static let providerQuotaOrderKey = "dock.quota.displayOrder"
    let presentationKey = "hermes.control.attention.presentation.v1"
    let snoozeKey = "hermes.control.attention.snooze.v1"
    /// The mutating project RPCs have no capability probe (and `rpc-projects` can be
    /// unavailable when the probe times out), so attempt them whenever Hermes is
    /// connected and surface the RPC's own error on failure.
    var projectMutationsAvailable: Bool { rpc != nil }

    #if DEBUG
    #endif

    var reloadMCPActionID: String { "mcp.reload" }
    var refreshKanbanActionID: String { "kanban.refresh" }
    var aggregateKanbanRefreshActionID: String { "kanban.refresh.aggregate" }
    var visibleKanbanRefreshActionID: String { "kanban.refresh.visible" }
    var refreshKanbanBoardsActionID: String { "kanban.boards.refresh" }
    var emergencyStopActionID: String { "dispatch.pause" }
    @Published var tokenUsage: TokenUsageReport? {
        didSet { applyProviderQuotaPresentation() }
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

    /// Every quota service the Dock reads, by stable reader id.
    static let quotaReaders: [(id: String, read: @Sendable () async throws -> [String: Any])] = [
        ("codex-hermes", CodexQuotaService.readHermes),
        ("hermes-pool", HermesPoolQuotaService.read),
        ("opencode", OpenCodeQuotaService.read),
        ("glm", GLMQuotaService.read),
        ("deepseek", DeepSeekQuotaService.read),
        ("kimi", KimiQuotaService.read),
        ("openrouter", OpenRouterQuotaService.read),
        ("claude", ClaudeQuotaService.read),
        ("antigravity", AntigravityQuotaService.read)
    ]

    /// The reader that last reported each snapshot's provider id.
    var providerQuotaReaderIDs: [String: String] = [:]

    static let hermesPrimaryCredentialsKey = "quota.hermesPrimaryCredentials"

    static let kanbanTaskInspectionLimit = 24

}
