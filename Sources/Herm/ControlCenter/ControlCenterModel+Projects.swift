import Combine
import Foundation

extension ControlCenterModel {
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
                    isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration)
                else { return }
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
                    isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration)
                else { return }
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

    func refreshProjectNavigation(refreshProjects: Bool) {
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
                    self.projectNavigationRefreshGeneration == generation
                else { return }
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
            initialProjectNavigationTask == nil
        else { return }
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

    func completeProjectNavigationRefresh(_ projectID: String, generation: UUID) {
        guard projectNavigationRefreshGeneration == generation else { return }
        completedProjectNavigationIDs.insert(projectID)
        guard completedProjectNavigationIDs == projectNavigationRefreshIDs else { return }

        // Publish one complete snapshot after every request has finished. This
        // prevents the visible list from being rebuilt once per project.
        projectSessionsByProjectID = projectSessionsByProjectID.merging(pendingProjectNavigationSessions) { _, new in
            new
        }
        if let selectedProjectID,
            let refreshedSessions = projectSessionsByProjectID[selectedProjectID]
        {
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
        guard projectMutationsAvailable, let rpc else { return false }
        do {
            _ = try await rpc.setActiveProject(id: project?.id, profileID: projectProfileID)
            refresh()
            return true
        } catch {
            reportActionError(
                "Could not select project",
                message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            return false
        }
    }

    func createProject(name: String, folder: String?) async -> Bool {
        guard let rpc else {
            reportActionError("Could not create project", message: "Hermes is not connected.")
            return false
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let folders = folder.map { $0.isEmpty ? [] : [$0] } ?? []
        do {
            _ = try await rpc.createProject(name: name, folders: folders, profileID: projectProfileID)
            // `refresh()` is a no-op while one is in flight, which would leave the
            // new project out of the list until the next manual refresh.
            for _ in 0..<40 where isRefreshing { try? await Task.sleep(for: .milliseconds(250)) }
            refresh()
            return true
        } catch {
            reportActionError(
                "Could not create project",
                message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            return false
        }
    }

    func addProjectFolder(_ project: ProjectSummary, folder: String) async -> Bool {
        guard let rpc else {
            reportActionError("Could not add project folder", message: "Hermes is not connected.")
            return false
        }
        guard !folder.isEmpty else { return false }
        do {
            _ = try await rpc.addProjectFolder(id: project.id, path: folder, profileID: projectProfileID)
            refresh()
            return true
        } catch {
            reportActionError(
                "Could not add project folder",
                message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            return false
        }
    }

    func archiveProject(_ project: ProjectSummary, restore: Bool = false) async -> Bool {
        guard projectMutationsAvailable, let rpc else { return false }
        do {
            _ = try await rpc.archiveProject(id: project.id, restore: restore, profileID: projectProfileID)
            closeProject()
            refresh()
            return true
        } catch {
            reportActionError(
                "Could not archive or restore project",
                message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            return false
        }
    }

    func deleteProject(_ project: ProjectSummary) async -> Bool {
        guard projectMutationsAvailable, let rpc else { return false }
        do {
            _ = try await rpc.deleteProject(id: project.id, profileID: projectProfileID)
            closeProject()
            refresh()
            return true
        } catch {
            reportActionError(
                "Could not delete project",
                message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
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
                let parsedSessions = Self.parseSessions(result)
            {
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
                    lastError = HermesDiagnosticsService.safeSummary(
                        Self.safeUserDiagnostic(error.localizedDescription))
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

    func openProjectSession(_ session: SessionSummary) {
        guard let dockModel else { return }
        dockModel.resumeSession(
            HermesSession(
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
                _ = try await dockModel.requestControl(
                    HermesFeatureIDs.ID.sessionActivate, params: ["session_id": session.id])
                focus(sessionID: session.id)
                dockModel.updateCurrentSessionTitle(session.title)
                dockModel.requestComposerFocus()
            } catch {
                lastError = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func openLatestActivitySession(_ activity: LatestActivityItem) {
        openLatestActivitySession(
            SessionSummary(
                id: activity.sessionID,
                title: activity.sessionTitle,
                state: activity.state,
                preview: nil
            ))
    }
}
