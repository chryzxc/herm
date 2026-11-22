import Combine
import Foundation

extension ControlCenterModel {
    func respond(to item: AttentionItem, action: AttentionAction, response: String? = nil) {
        guard dockModel != nil || rpc != nil else { return }
        let reference = item.reference
        if let dockModel, !dockModel.sessionActionsReady {
            let sessionID = reference.sessionID ?? reference.sourceID
            let selected =
                dockModel.currentSessionIDs.contains(sessionID)
                || dockModel.rowSessionID(sessionID) == dockModel.navigationSessionID
            if selected {
                switch action {
                case .approve, .deny, .respond, .stop, .resume, .open: return
                case .dismiss, .complete: break
                }
            }
        }
        let actionID = attentionActionID(action, item: item)
        guard beginAction(actionID) else { return }
        Task {
            defer { finishAction(actionID) }
            do {
                switch action {
                case .approve, .deny:
                    guard let rpc, let dockModel, let sessionID = reference.sessionID, !sessionID.isEmpty else {
                        return
                    }
                    guard
                        try await respondToControlApproval(
                            rpc: rpc, model: dockModel, sessionID: sessionID,
                            choice: action == .approve ? ApprovalChoice.once : ApprovalChoice.deny)
                    else { return }
                case .respond:
                    let response = response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !response.isEmpty else { return }
                    let requestID = reference.clarificationRequestID?.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let rpc, let requestID, !requestID.isEmpty else { return }
                    _ = try await rpc.respondToClarification(requestID: requestID, answer: response)
                case .stop:
                    guard let rpc else { return }
                    let result = try await rpc.interrupt(
                        sessionID: reference.sessionID ?? reference.sourceID,
                        profileID: projectProfileID
                    )
                    guard DockModel.interruptWasAccepted(result) else {
                        throw QuickDraftError.message("Hermes did not confirm stopping this turn. Refresh its state.")
                    }
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

    private func respondToControlApproval(
        rpc: HermesControlRPC, model: DockModel, sessionID: String, choice: String
    ) async throws -> Bool {
        let pending = model.pendingApprovalsBySessionID[sessionID]
        let recordID = pending.flatMap { model.conversationApprovalID(sessionID: sessionID, pending: $0) }
        let record = recordID.flatMap { id in model.conversationApprovals.first { $0.id == id } }
        let answer = record?.target.flatMap { model.attentionAnswers[$0] } ?? record?.legacyAnswer
        guard answer?.blocksSubmission != true else { return false }
        func setAnswer(_ answer: AttentionAnswerState) {
            if let target = record?.target {
                model.attentionAnswers[target] = answer
            } else if let recordID {
                model.setLegacyApprovalAnswer(answer, id: recordID)
            }
        }
        setAnswer(.sending(choice))
        do {
            let result = try await rpc.respondToApproval(sessionID: sessionID, choice: choice)
            guard model.pendingApprovalsBySessionID[sessionID] == pending,
                pending.flatMap({ model.conversationApprovalID(sessionID: sessionID, pending: $0) }) == recordID
            else { return false }
            guard let resolved = result["resolved"] as? Int, resolved >= 0 else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            if let recordID {
                model.resolveApproval(for: sessionID, resumesWork: resolved > 0, recordID: recordID)
            }
            return true
        } catch {
            if model.pendingApprovalsBySessionID[sessionID] == pending,
                pending.flatMap({ model.conversationApprovalID(sessionID: sessionID, pending: $0) }) == recordID
            {
                setAnswer(.failure(error, choice: choice))
            }
            throw error
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
        switch type {
        case "tool.call", "tool.start", "tool.use", "tool_use", "tool.result", "tool_result", "tool.complete",
            "tool_complete":
            // Tool progress carries no attention transition. Avoid rebuilding the inbox on each call or result.
            return
        default:
            break
        }
        let payload = params["payload"] as? [String: Any] ?? [:]
        let sessionID =
            (params["session_id"] as? String)
            ?? (payload["session_id"] as? String)
            ?? dockModel?.sessionID
        guard let sessionID, !sessionID.isEmpty else { return }

        let detail =
            (payload["message"] as? String)
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
            // A new request reopens the session's item; an earlier decision must not hide it.
            if let state = knownAttention["approval:\(sessionID)"]?.state, state == .resolved || state == .dismissed {
                knownAttention.removeValue(forKey: "approval:\(sessionID)")
            }
            upsertAttention(
                AttentionItem(
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
            let rawChoices =
                (payload["choices"] as? [String])
                ?? (params["choices"] as? [String])
                ?? (payload["options"] as? [String])
                ?? (params["options"] as? [String])
            let choices = rawChoices?.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let requestID =
                (payload["request_id"] as? String)
                ?? (params["request_id"] as? String)
            upsertAttention(
                AttentionItem(
                    id: "clarification:\(sessionID)",
                    reference: ControlReference(
                        source: .hermesClarification,
                        sourceID: sessionID,
                        sessionID: sessionID,
                        clarificationRequestID: requestID
                    ),
                    kind: .clarification,
                    title: "Herm needs clarification",
                    detail: detail,
                    createdAt: Date(),
                    state: .open,
                    actions: [.respond, .open, .stop],
                    choices: choices
                ))
        case "error":
            upsertAttention(
                AttentionItem(
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
            scheduleEventRefresh(type)
        }
        rebuildAttention()
    }

    /// Gateway event bursts collapse into one refresh. A refresh already in
    /// flight would otherwise drop the event and leave projects stale.
    func scheduleEventRefresh(_ type: String) {
        pendingEventRefreshes.insert(type)
        guard eventRefreshTask == nil else { return }
        eventRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                while self?.isRefreshing == true, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard let self, !Task.isCancelled else { return }
                let events = self.pendingEventRefreshes
                self.pendingEventRefreshes.removeAll()
                let needsOverview = self.visibleSidebarTabs.values.contains(.core)
                let needsProjects = self.visibleSidebarTabs.values.contains(.projects)
                if events.contains("sessions.changed"), needsOverview || needsProjects {
                    self.refresh()
                    while self.isRefreshing, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                } else {
                    self.inFlightEventRefreshes = events
                    let generation = self.refreshGeneration
                    if events.contains("message.complete") || events.contains("process.changed")
                        || events.contains("sessions.changed")
                    {
                        await self.refreshEventSessions()
                    }
                    if generation != self.refreshGeneration {
                        self.inFlightEventRefreshes.removeAll()
                        continue
                    }
                    if events.contains("sessions.changed") || (events.contains("message.complete") && needsProjects) {
                        await self.refreshEventActivity()
                    }
                    if generation != self.refreshGeneration {
                        self.inFlightEventRefreshes.removeAll()
                        continue
                    }
                    guard !Task.isCancelled else { return }
                    if events.contains("message.complete"), self.isLatestActivityRequested {
                        self.refreshLatestActivityProjection()
                    }
                    if needsOverview {
                        await self.refreshEventDelegation()
                    }
                    if generation != self.refreshGeneration {
                        self.inFlightEventRefreshes.removeAll()
                        continue
                    }
                    if let dock = self.dockModel, dock.presentationDemand.hasVisibleHost {
                        self.refreshSessionCockpit(for: dock.sessionID, quiet: true)
                        self.refreshPromptBudget(quiet: true)
                        self.refreshVerification()
                    }
                    if events.contains("process.changed"), let sessionID = self.processSessionID {
                        await self.refreshFocusedProcesses(for: sessionID, generation: self.sessionProcessesGeneration)?
                            .value
                    }
                    if events.contains("cron.changed") {
                        await self.refreshRoutineInventory(
                            profileID: self.dockModel?.profileScopeID, includeSessions: true)
                        self.refreshCronRuns()
                    }
                    self.inFlightEventRefreshes.removeAll()
                }
                guard !Task.isCancelled else { return }
                if self.pendingEventRefreshes.isEmpty {
                    self.eventRefreshTask = nil
                    return
                }
            }
        }
    }

    func refreshEventDelegation() async {
        guard let rpc else { return }
        let generation = refreshGeneration
        let identity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        do {
            let result = try await rpc.delegationStatus()
            guard !Task.isCancelled, isCurrentRefresh(generation, clientIdentity: identity) else { return }
            let agents = Self.parseAgents(result)
            if activeAgents != agents { activeAgents = agents }
            let paused = result["paused"] as? Bool ?? delegationPaused
            if delegationPaused != paused { delegationPaused = paused }
            let state = refreshState(for: "agents")
            if state?.lastSuccess == nil || state?.error != nil || state?.isStale == true || state?.isRefreshing == true
            {
                recordProjectionSuccess("agents")
            }
        } catch {
            guard !Task.isCancelled, isCurrentRefresh(generation, clientIdentity: identity) else { return }
            recordProjectionFailure("agents", error: Self.safeUserDiagnostic(error.localizedDescription))
        }
    }

    /// Event refreshes do not toggle loading state for an already current snapshot.
    func refreshEventSessions() async {
        guard let rpc else { return }
        let generation = refreshGeneration
        let identity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        do {
            let result = try await rpc.activeSessions()
            guard let sessions = Self.parseSessions(result) else { throw HermesGateway.GatewayError.malformedResponse }
            guard !Task.isCancelled, isCurrentRefresh(generation, clientIdentity: identity) else { return }
            let changed = activeSessions != sessions
            if changed { activeSessions = sessions }
            establishFocusIfNeeded()
            let state = refreshState(for: "sessions")
            if changed || state?.lastSuccess == nil || state?.error != nil || state?.isRefreshing == true
                || state?.isStale == true
            {
                recordProjectionSuccess("sessions")
            }
        } catch {
            guard !Task.isCancelled, isCurrentRefresh(generation, clientIdentity: identity) else { return }
            recordProjectionFailure("sessions", error: Self.safeUserDiagnostic(error.localizedDescription))
        }
    }

    /// Keep project navigation current without rereading the activity archive.
    func refreshEventActivity() async {
        guard let rpc, dockModel != nil else { return }
        let generation = refreshGeneration
        let identity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let profile = projectProfileID
        do {
            if !projectProfileScopeUnavailable {
                let tree = try await rpc.projectsTree(profileID: profile)
                guard !Task.isCancelled, isCurrentRefresh(generation, clientIdentity: identity),
                    projectProfileID == profile
                else { return }
                let refreshed = Self.reconcileProjectRefresh(current: projects, incoming: Self.parseProjects(tree))
                if refreshed != projects {
                    refresh()
                    return
                }
                if profile != nil {
                    for project in refreshed where projectSessionsByProjectID[project.id] != nil {
                        let result = try await rpc.projectSessions(projectID: project.id, profileID: profile)
                        guard !Task.isCancelled, isCurrentRefresh(generation, clientIdentity: identity),
                            projectProfileID == profile
                        else { return }
                        let rows = Self.parseProjectSessions(result)
                        if projectSessionsByProjectID[project.id] != rows {
                            projectSessionsByProjectID[project.id] = rows
                            if selectedProjectID == project.id { projectSessions = rows }
                        }
                    }
                }
                let state = refreshState(for: "projects")
                if state?.lastSuccess == nil || state?.error != nil || state?.isRefreshing == true
                    || state?.isStale == true
                {
                    recordProjectionSuccess("projects")
                }
            }
        } catch {
            guard !Task.isCancelled, isCurrentRefresh(generation, clientIdentity: identity),
                projectProfileID == profile
            else { return }
            recordProjectionFailure("projects", error: Self.safeUserDiagnostic(error.localizedDescription))
            return
        }
    }

    func upsertAttention(_ item: AttentionItem) {
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
            let incomingRequestID =
                item.reference.clarificationRequestID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let existingRequestID =
                existing.reference.clarificationRequestID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if incomingRequestID.isEmpty, !existingRequestID.isEmpty {
                enriched.reference.clarificationRequestID = existingRequestID
            }
            knownAttention[item.id] = enriched
        } else {
            knownAttention[item.id] = item
        }
    }

    func persistPresentationState() {
        let values = knownAttention.reduce(into: [String: String]()) { result, entry in
            guard entry.value.state == .dismissed || entry.value.state == .resolved || entry.value.state == .snoozed
            else { return }
            result[entry.key] = entry.value.state.rawValue
        }
        presentationDefaults.set(values, forKey: presentationKey)
    }

    static func isPlaceholderAttentionDetail(_ detail: String) -> Bool {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized == "herm wants to perform an action."
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
                knownAttention["approval:\(sessionID)"]?.state != .dismissed
            {
                upsertAttention(
                    AttentionItem(
                        id: "approval:\(sessionID)",
                        reference: ControlReference(source: .hermesApproval, sourceID: sessionID, sessionID: sessionID),
                        kind: .approval,
                        title: dockModel.approvalTitle ?? "Herm needs approval",
                        detail: approval,
                        createdAt: Date(),
                        state: .open,
                        actions: [.approve, .deny, .stop]
                    ))
            }
            if dockModel.status == .offline {
                upsertAttention(
                    AttentionItem(
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
            saved.state != .resolved && saved.state != .dismissed && saved.state != .snoozed
                && !next.contains(where: { $0.id == saved.id })
        }
        let sorted = next.sorted { lhs, rhs in
            let lhsRank = Self.attentionRank(lhs)
            let rhsRank = Self.attentionRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.createdAt > rhs.createdAt
        }
        // Avoid re-rendering every observer of the control center when the list is unchanged.
        if sorted != attention { attention = sorted }
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
            clearProcessFocus()
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
    func refreshSessionScopedProjections(for sessionID: String) {
        let generation = UUID()
        sessionProcessesGeneration = generation
        if processSessionID != sessionID {
            verifiedProcessSessionID = nil
            installCapabilities(capabilities)
        }
        processSessionID = sessionID
        processes = []
        refreshSessionKanban(for: sessionID)
        refreshSessionCockpit(for: sessionID)
        refreshVerification(for: sessionID)

        refreshFocusedProcesses(for: sessionID, generation: generation)
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
    func resolveProjectMembership(for sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty,
            project(forSessionID: sessionID) == nil,
            let rpc, !projects.isEmpty
        else { return }
        if let path = dockModel?.createdSessionProjectPaths[sessionID],
            let project = projects.first(where: { $0.isRenderableProject && $0.name == path })
        {
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
                    isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration)
                else { return }
                guard
                    let result = try? await rpc.projectSessions(projectID: project.id, profileID: self.projectProfileID)
                else { continue }
                guard generation == projectMembershipGeneration,
                    isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration)
                else { return }
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

    func establishFocusIfNeeded() {
        guard dockModel == nil, currentFocus == nil, let session = activeSessions.first else { return }
        focus(sessionID: session.id)
    }
}
