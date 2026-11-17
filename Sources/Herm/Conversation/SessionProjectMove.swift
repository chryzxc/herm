import Foundation

/// The one "Add/Move to project" action shared by every conversation entrance
/// (rows, pinned rows, project groups, picker, header and split menus).
@MainActor
enum SessionProjectMove {
    /// Moves the stored Hermes session into `target` and updates the local
    /// link and project projections so labels and lists follow at once.
    @discardableResult
    static func perform(
        _ session: HermesSession, to target: SidebarProjectTarget,
        model: DockModel, control: ControlCenterModel, store: WorkspaceStore
    ) async -> Bool {
        guard await model.moveSessionToProject(session, path: target.path) else { return false }
        // The local link outranks Hermes membership in the sidebar, so it follows the move.
        store.ensureTask(title: session.displayTitle, sessionID: session.id)
        store.attachProject(at: target.path, toSessionID: session.id)
        var ids = [session.id]
        // A resumed chat can run under a runtime id that differs from its stored row id.
        if session.id == model.navigationSessionID, let alias = model.sessionID, alias != session.id {
            ids.append(alias)
        }
        control.didMoveSession(ids, toProjectPath: target.path)
        _ = model.loadSessions(quiet: true)
        return true
    }

    /// Whether a conversation in this status must not be moved.
    static func isBlocked(status: SidebarSessionStatus) -> Bool {
        status == .working || status == .needsApproval || status == .needsClarification
    }

    /// The project a conversation shows under: Hermes membership, else its local link.
    static func currentProjectID(_ sessionID: String, control: ControlCenterModel, store: WorkspaceStore) -> String? {
        if let id = control.project(forSessionID: sessionID)?.id { return id }
        guard let path = store.projectPathsBySessionID[sessionID] else { return nil }
        return ControlCenterModel.projectMatchingPath(path, projects: control.projects)?.id
    }

    /// Projects a conversation can move to, for entrances without a sidebar snapshot.
    static func targets(
        projects: [ProjectSummary], excluding sessionID: String, control: ControlCenterModel,
        store: WorkspaceStore
    ) -> [SidebarProjectTarget] {
        let current = currentProjectID(sessionID, control: control, store: store)
        return projects.filter { $0.isRenderableProject && $0.id != current }.map {
            SidebarProjectTarget(title: SessionNavSidebarSnapshot.projectDisplayName($0.name), path: $0.name)
        }
    }
}
