import Combine
import Foundation

extension ControlCenterModel {
    enum KanbanRefreshTrigger {
        case user
        case background
    }

    enum KanbanRefreshScope: Hashable {
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

    func quotaReading(for provider: String?) -> (
        snapshot: ProviderQuotaSnapshot, window: ProviderQuotaWindow, remaining: Double
    )? {
        QuotaWorkspacePresentation.reading(providerQuotas, for: provider)
    }

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

    /// Values read by the workspace shell; child surfaces observe their own state.
    func makeWorkspacePresentationChanges() -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            $capabilities.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $activeSessions.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $projectSessions.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $projects.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $projectIDBySessionID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $projectSessionsByProjectID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $projectProfileID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $integrationDestination.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $requestedAutomationJobID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $requestedAutomationOwner.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $requestedAutomationDidNavigate.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $requestedRepositoryReview.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $automationNavigationError.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $cronJobs.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $globalKanbanTasks.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $kanbanTasks.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $tokenUsage.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ).receive(on: RunLoop.main).eraseToAnyPublisher()
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
        projectIDBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.enumerated().map { offset, session in
                (session.id, "scroll-fixture-project-\(offset % projectsPerGroup)")
            })
        projectSessionsByProjectID = Dictionary(grouping: sessions) { session in
            projectIDBySessionID[session.id] ?? "scroll-fixture-project-0"
        }
        activeSessions = Array(sessions.prefix(24))
    }

    struct QuotaReadResult: @unchecked Sendable {
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

    /// Test-only injection point for exercising rendered Kanban states without
    /// starting the gateway refresh loop.
    internal func setKanbanTasksForTesting(_ tasks: [KanbanTaskSummary]) {
        kanbanTasks = tasks
    }

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

    func isCurrentRefresh(_ generation: UInt64, clientIdentity: ObjectIdentifier?) -> Bool {
        refreshGeneration == generation && dockModel.map { ObjectIdentifier($0.controlRPCClient) } == clientIdentity
    }

    func isCurrentClient(_ identity: ObjectIdentifier?, bindingGeneration: UInt64? = nil) -> Bool {
        if let identity {
            guard dockModel.map({ ObjectIdentifier($0.controlRPCClient) }) == identity else { return false }
        } else if dockModel != nil {
            return false
        }
        return bindingGeneration.map { $0 == clientBindingGeneration } ?? true
    }

    func beginProjectionRefresh(_ projection: String) {
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
                projectionStates[projection] = .stale(
                    count, safeMessage: "Hermes projection is refreshing. Refresh to try again.")
            default:
                projectionStates[projection] = .loading
            }
        } else {
            projectionStates[projection] = .loading
        }
    }

    func recordProjectionSuccess(_ projection: String, count: Int? = nil) {
        let resolvedCount = count ?? projectionCount(projection)
        projectionRefreshStates[projection] = ProjectionRefreshState(
            lastSuccess: .now, error: nil, isStale: false, isRefreshing: false)
        projectionStates[projection] = resolvedCount == 0 ? .empty : .ready(resolvedCount)
    }

    /// Publishes an explicit capability boundary when this model has no Hermes
    /// gateway to query. This is distinct from a failed request and keeps the
    /// UI from presenting an unsupported projection as an empty result.
    func recordProjectionUnavailable(_ projection: String) {
        projectionRefreshStates[projection] = ProjectionRefreshState(
            lastSuccess: nil, error: nil, isStale: false, isRefreshing: false)
        projectionStates[projection] = .unavailable(
            safeMessage:
                "Hermes projection is unavailable because this capability is not supported or authorized. Reconnect Hermes and retry."
        )
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
            projectionStates[projection] = .unavailable(
                safeMessage:
                    "Hermes projection is unavailable because this capability is not supported or authorized. Reconnect Hermes and retry."
            )
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

    func projectionCount(_ projection: String) -> Int {
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

    func kanbanActionID(_ action: KanbanTaskAction, task: KanbanTaskSummary) -> String {
        "kanban.\(action.rawValue):\(task.id)"
    }

    func kanbanActionID(_ action: KanbanMutationKind, task: KanbanTaskSummary) -> String {
        "kanban.\(action.rawValue):\(task.id)"
    }

    func attentionActionID(_ action: AttentionAction, item: AttentionItem) -> String {
        "attention.\(action.rawValue):\(item.id)"
    }

    func reminderActionID(_ reminder: ReminderSummary) -> String { "reminder.complete:\(reminder.id)" }

    func mcpTestActionID(_ server: MCPServerSummary) -> String { "mcp.test:\(server.id)" }

    func beginAction(_ id: String) -> Bool {
        guard !pendingActionIDs.contains(id) else { return false }
        pendingActionIDs.insert(id)
        return true
    }

    func finishAction(_ id: String) {
        pendingActionIDs.remove(id)
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
}
