import Foundation

struct HermesSessionWorkspace: Equatable {
    let cwd: String
    var repositoryPath: String?
    var branch: String?
    var terminalBackend: String?
}

extension DockModel {
    static let sessionWorkspaceBusyMessage = "Stop the current turn before moving this chat."

    /// Hermes refuses to move a session while its turn runs.
    var canMoveSessionWorkspace: Bool {
        sessionID != nil && !isSending && status != .working && status != .needsClarification
    }

    /// Moves this chat to `path` with `session.cwd.set`. Hermes pins a folder
    /// chosen this way, so the agent's own worktree moves stop following it.
    @discardableResult
    func moveSessionWorkspace(to path: String) async -> Bool {
        guard let owner = sessionID else { return false }
        guard canMoveSessionWorkspace else {
            reportAttachmentError(Self.sessionWorkspaceBusyMessage)
            return false
        }
        var params: [String: Any] = ["session_id": owner, "cwd": path]
        if let profileID = sessionProfileID ?? profileScopeID, !profileID.isEmpty { params["profile"] = profileID }
        do {
            let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionCwdSet.rawValue, params: params)
            guard sessionID == owner else { return false }
            applySessionWorkspace(result, owner: owner, force: true)
            // The chosen path is a verified worktree root; keep the folder row
            // mounted instead of waiting for the asynchronous root probe.
            let target = URL(fileURLWithPath: path).standardizedFileURL.path
            if var workspace = sessionWorkspace, workspace.cwd == target, workspace.repositoryPath == nil,
                GatewayConnectionStore.isLocalBackend,
                workspace.terminalBackend == nil || workspace.terminalBackend == "local"
            {
                workspace.repositoryPath = target
                sessionWorkspace = workspace
            }
            return true
        } catch {
            guard sessionID == owner else { return false }
            let code = ((error as NSError).userInfo["HermesRPCCode"] as? NSNumber)?.intValue
            reportAttachmentError(
                code == 4009
                    ? Self.sessionWorkspaceBusyMessage
                    : HermesDiagnosticsService.safeSummary(error.localizedDescription))
            return false
        }
    }

    /// Projects only directory facts belonging to the selected Hermes session.
    func retrySessionWorkspace() {
        guard let workspace = sessionWorkspace, let sessionID else { return }
        var result: [String: Any] = ["cwd": workspace.cwd]
        result["branch"] = workspace.branch
        result["terminal_backend"] = workspace.terminalBackend
        applySessionWorkspace(result, owner: sessionID, force: true)
    }

    func applySessionWorkspace(_ result: [String: Any], owner: String?, force: Bool = false) {
        guard let owner, owner == sessionID else { return }
        let info = result["info"] as? [String: Any] ?? [:]
        if let stored = (result["stored_session_id"] as? String) ?? (info["stored_session_id"] as? String),
            !stored.isEmpty, let selected = navigationSessionID, stored != selected, stored != owner
        {
            return
        }
        if let profile = (result["profile"] as? String) ?? (info["profile_name"] as? String),
            !profile.isEmpty, profile != (sessionProfileID ?? profileScopeID ?? "default")
        {
            return
        }
        let raw = (result["cwd"] as? String) ?? (info["cwd"] as? String)
        let branch = (result["branch"] as? String) ?? (info["branch"] as? String)
        let backend =
            (result["terminal_backend"] as? String) ?? (info["terminal_backend"] as? String)
            ?? sessionWorkspace?.terminalBackend
        guard let raw, !raw.isEmpty else {
            if let backend, let workspace = sessionWorkspace, backend != workspace.terminalBackend {
                applySessionWorkspace(["cwd": workspace.cwd, "terminal_backend": backend], owner: owner)
                return
            }
            if var workspace = sessionWorkspace {
                workspace.branch = branch ?? workspace.branch
                workspace.terminalBackend = backend ?? workspace.terminalBackend
                if workspace != sessionWorkspace { sessionWorkspace = workspace }
            }
            return
        }
        sessionWorkspaceRevision &+= 1
        guard raw.hasPrefix("/") else {
            sessionWorkspace = HermesSessionWorkspace(
                cwd: raw, repositoryPath: nil, branch: branch, terminalBackend: backend)
            return
        }
        let cwd = URL(fileURLWithPath: raw).standardizedFileURL.path
        if var workspace = sessionWorkspace, workspace.cwd == cwd, !force,
            backend == nil || backend == workspace.terminalBackend
        {
            workspace.branch = branch ?? workspace.branch
            workspace.terminalBackend = backend ?? workspace.terminalBackend
            if workspace != sessionWorkspace { sessionWorkspace = workspace }
            if workspace.repositoryPath != nil || !GatewayConnectionStore.isLocalBackend
                || (workspace.terminalBackend != nil && workspace.terminalBackend != "local")
            {
                return
            }
        }
        if let previous = sessionWorkspace, previous.cwd != cwd, let id = navigationSessionID {
            let origin = QuickDestination(profileID: sessionProfileID, sessionID: id)
            DeveloperWorkflowModel.shared.turnBaselines.removeValue(forKey: origin.sessionKey)
            ObservedRequestChanges.shared.discard(origin)
        }
        sessionWorkspace = HermesSessionWorkspace(
            cwd: cwd, repositoryPath: nil, branch: branch, terminalBackend: backend)
        guard GatewayConnectionStore.isLocalBackend, backend == nil || backend == "local" else { return }
        let generation = sessionResumeGeneration
        Task { [weak self] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue,
                FileManager.default.isReadableFile(atPath: cwd)
            else { return }
            let root = await RepositoryService.worktreeRoot(path: cwd) ?? cwd
            guard let self, self.sessionID == owner, self.sessionResumeGeneration == generation,
                var workspace = self.sessionWorkspace, workspace.cwd == cwd,
                workspace.terminalBackend == nil || workspace.terminalBackend == "local",
                GatewayConnectionStore.isLocalBackend
            else { return }
            workspace.repositoryPath = root
            self.sessionWorkspace = workspace
        }
    }
}
