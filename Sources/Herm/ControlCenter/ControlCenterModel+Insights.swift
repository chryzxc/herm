import Foundation
import Combine

extension ControlCenterModel {
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

    /// Loads one month of work for the Calendar tab. A month already fetched
    /// is rebuilt from cache unless `force` is set.
    func refreshWorkCalendar(month: Date, repoPaths: [String], force: Bool = false) {
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        workCalendarMonth = monthStart
        workCalendarRepoPaths = repoPaths
        if globalKanbanTasks.isEmpty { refreshGlobalKanban(trigger: .background) }
        if cronRuns.isEmpty { refreshCronRuns() }
        if !force, workCalendarSources[monthStart] != nil {
            rebuildWorkCalendar()
            return
        }
        let generation = UUID()
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        workCalendarGeneration = generation
        guard let rpc else {
            recordProjectionUnavailable("work.calendar")
            return
        }
        beginProjectionRefresh("work.calendar")
        let paths = workCalendarRepoPaths(monthStart: monthStart, monthEnd: monthEnd)
        workCalendarPaths[monthStart] = paths
        Task { @MainActor in
            do {
                async let commits = RepositoryService.commits(paths: paths, since: monthStart, until: monthEnd)
                async let pullRequests = GitHubCodeHostService().mergedPullRequests(since: monthStart, until: monthEnd)
                let sessions = try await Self.workCalendarSessions(rpc: rpc, since: monthStart)
                // Usage is best-effort: older Hermes builds lack the web server.
                let usageDays = (calendar.dateComponents([.day], from: monthStart, to: Date()).day ?? -1) + 1
                var usage: [TokenUsageReport.Day] = []
                if (1...365).contains(usageDays), let result = try? await rpc.usageAnalytics(days: usageDays) {
                    usage = Self.parseTokenUsage(result).daily
                }
                let fetched = (sessions: sessions, commits: await commits, pullRequests: await pullRequests, usage: usage)
                guard generation == workCalendarGeneration,
                      isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                workCalendarSources[monthStart] = fetched
                rebuildWorkCalendar()
                recordProjectionSuccess("work.calendar", count: workCalendar?.activeDays ?? 0)
            } catch {
                guard generation == workCalendarGeneration else { return }
                recordProjectionFailure("work.calendar", error: error.localizedDescription)
            }
        }
    }

    /// Hermes' projects are the working directories its sessions ran in, the same list the PR center reads.
    /// Kanban tasks add the worktrees they actually ran in, which often belong to repos no session is wired to.
    func workCalendarRepoPaths(monthStart: Date, monthEnd: Date) -> Set<String> {
        let taskPaths = globalKanbanTasks.compactMap { task -> String? in
            guard let at = task.completedAt ?? task.startedAt, at >= monthStart, at < monthEnd else { return nil }
            return task.workspacePath
        }
        return Set(workCalendarRepoPaths + projects.filter(\.isRenderableProject).map(\.name) + taskPaths).filter { !$0.isEmpty }
    }

    /// Re-folds the live Kanban and cron projections into the cached month.
    /// Projects or task worktrees that landed after the git read trigger one re-read.
    func rebuildWorkCalendar() {
        guard let month = workCalendarMonth, let sources = workCalendarSources[month] else { return }
        let monthEnd = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month
        if !workCalendarRepoPaths(monthStart: month, monthEnd: monthEnd).isSubset(of: workCalendarPaths[month] ?? []) {
            refreshWorkCalendar(month: month, repoPaths: workCalendarRepoPaths, force: true)
        }
        let index = WorkCalendarIndex.build(
            month: month,
            sessions: sources.sessions,
            tasks: globalKanbanTasks,
            commits: sources.commits,
            pullRequests: sources.pullRequests,
            runs: cronRuns,
            usage: sources.usage
        )
        if index != workCalendar { workCalendar = index }
    }

    /// Pages `/api/sessions` newest-first and stops at the first page that
    /// reaches past `since`, so a month view never reads the whole history.
    static func workCalendarSessions(rpc: HermesControlRPC, since: Date) async throws -> [SessionSummary] {
        var sessions: [SessionSummary] = []
        var offset = 0
        for _ in 0..<50 {
            let page = try await rpc.sessionPages(limit: 100, offset: offset, order: "recent")
            guard let rows = page["data"] as? [[String: Any]] else { throw HermesGateway.GatewayError.malformedResponse }
            var reachedPast = false
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                let date = activityDate(row["last_activity_at"]) ?? activityDate(row["updated_at"])
                    ?? activityDate(row["last_active"]) ?? activityDate(row["started_at"])
                guard let date else { continue }
                if date < since { reachedPast = true; continue }
                let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat"
                sessions.append(SessionSummary(id: id, title: title, state: row["state"] as? String ?? "idle",
                                               preview: row["preview"] as? String, updatedAt: date))
            }
            offset += rows.count
            if rows.isEmpty || reachedPast || parseHasMore(page) != true { break }
        }
        return sessions
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
}
