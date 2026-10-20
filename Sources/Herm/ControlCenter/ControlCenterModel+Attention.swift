import Foundation
import Combine

extension ControlCenterModel {
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
    func scheduleEventRefresh() {
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

    func persistPresentationState() {
        let values = knownAttention.reduce(into: [String: String]()) { result, entry in
            guard entry.value.state == .dismissed || entry.value.state == .resolved || entry.value.state == .snoozed else { return }
            result[entry.key] = entry.value.state.rawValue
        }
        presentationDefaults.set(values, forKey: presentationKey)
    }

    static func isPlaceholderAttentionDetail(_ detail: String) -> Bool {
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
        let sorted = next.sorted { lhs, rhs in
            let lhsRank = Self.attentionRank(lhs)
            let rhsRank = Self.attentionRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.createdAt > rhs.createdAt
        }
        // Runs on every gateway event; an unchanged list must not republish
        // and re-render every view observing the control center.
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
    func resolveProjectMembership(for sessionID: String?) {
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

    func establishFocusIfNeeded() {
        guard currentFocus == nil, let session = activeSessions.first else { return }
        focus(sessionID: session.id)
    }
}
