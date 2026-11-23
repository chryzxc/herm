import AppKit
import SwiftUI

extension DockPopover {
    @ViewBuilder var workspaceStatusFooter: some View {
        if let status = panelPresentation.islandStatus {
            WorkspaceStatusBar(
                status: statusModel, edgeState: status, interruptions: status.interruptions,
                isFloating: !usesWindowChrome, isCompact: isNarrowLayout,
                terminalScope: statusTerminalScope,
                performAction: performStatusAction, openSettings: openStatusBarSettings
            )
            .onAppear {
                statusModel.attach(
                    edge: status, model: workspaceModel, control: controlCenter, pullRequests: pullRequestCenter)
            }
        }
    }

    func toggleStatusActivity() {
        if panelPresentation.islandStatus != nil,
            StatusBarPreferences.shared.isVisible(inFloatingPanel: !usesWindowChrome)
        {
            statusModel.toggleActivity()
        } else {
            statusModel.isTrayPresented = false
            performStatusAction(.tab(.usage))
        }
    }

    /// Routes a status bar item to the page that owns what it counts.
    private func performStatusAction(_ action: StatusBarEntry.Action) {
        switch action {
        case .task(let task): openStatusTask(task)
        case .tab(let tab): openWorkspaceGlobal(tab)
        case .pullRequests: leaveIntegrations { selectGitHubSection(.pullRequests) }
        case .url(let url): NSWorkspace.shared.open(url)
        case .calendar(let item): SystemCalendarService.open(item)
        case .routine(let routine): leaveIntegrations { controlCenter.requestAutomation(routine) }
        case .terminal(let identity, let tabID, let shellID):
            guard let scope = statusTerminalScope, scope.identity == identity,
                let tabs = TerminalWorkspaceStore.shared.tabs(identity: identity, directory: scope.directory)
                    .first(where: { $0.extraID == tabID })?.tabs,
                tabs.sessions.contains(where: { $0.id == shellID })
            else { return }
            tabs.selectedID = shellID
            inspectorScope = .session
            sessionInspectorTabRequest = .init(session: identity, section: .terminal, terminalTabID: tabID)
            ensureInspectorPanelVisible()
        case .tray, .preview, .none: break
        }
    }

    private var statusTerminalScope: WorkspaceStatusModel.TerminalScope? {
        guard hostPresentation.isVisible, !isGlobalSurfaceActive, !model.isRestoringSession,
            model.navigationSessionID != nil, BackendReach.access(.localPreviews) == .direct
        else { return nil }
        let path = activeSessionRepositoryScope?.repositoryPath ?? activeSessionRepositoryPath
        guard let directory = model.sessionWorkspace?.cwd ?? path else { return nil }
        let repository = developerWorkflow.repository
        let matches =
            repository.path == path && repository.isGitRepository && !repository.isStale
            && repository.statusError == nil
        return WorkspaceStatusModel.TerminalScope(
            identity: WorkspaceIdentity.session(model), directory: directory,
            repositoryID: matches ? repository.repositoryID : nil,
            fingerprint: matches ? developerWorkflow.repositoryFingerprint : nil)
    }

    private func openStatusBarSettings() {
        UserDefaults.standard.set(SettingsCategory.statusBar.rawValue, forKey: "herm.settings.category")
        onOpenSettings()
    }

    /// Opens what a status bar item counts, through the same owners the sidebar uses.
    private func openStatusTask(_ task: EdgeNotchTask) {
        if task.isFailure, let session = task.session {
            panelPresentation.islandStatus?.interruptions.clearFailure(
                owner: session.id, profileID: session.profileID)
        }
        leaveIntegrations {
            if let card = task.kanbanTask {
                controlCenter.revealKanbanTask(card)
                sessionNavNavigation.selectGlobal(.kanban)
                fullscreenGlobalTab = .kanban
                fullscreenSurface = .global
            } else if let routine = task.routine {
                controlCenter.requestAutomation(routine)
            } else if let session = task.session {
                sessionNavNavigation.selectSession(session.id)
                fullscreenSurface = .conversation
                inspectorScope = .session
                openSessionInWorkspace(session)
            } else {
                // The open session's own row.
                fullscreenSurface = .conversation
            }
        }
    }
}
