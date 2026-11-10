import SwiftUI

extension DockPopover {
    var richGenerationContext: RichGenerationContext {
        guard !model.isRestoringSession else {
            return RichGenerationContext(profileID: model.sessionProfileID, sessionID: model.navigationSessionID)
        }
        return richHostRouter.generationContext()
    }

    private var richCalendarItems: [CalendarItem] {
        CalendarAgenda.automationItems(controlCenter.cronJobs)
            + CalendarAgenda.taskItems(controlCenter.globalKanbanTasks)
    }

    var richHostRouter: RichHostActionRouter {
        let destination = RichReplyContext.destination(for: model)
        let prs = sessionPullRequestCenter
        let issues = sessionIssueCenter
        let control = controlCenter
        let dock = model
        let scope = destination.sessionID.map { ProfileScopedID(profileID: destination.profileID, resourceID: $0) }
        func isCurrent() -> Bool {
            let current = RichReplyContext.destination(for: model)
            return current.sessionID == destination.sessionID && current.profileID == destination.profileID
        }
        let projectPath = activeSessionRepositoryScope?.repositoryPath ?? activeSessionRepositoryPath
        let directory =
            model.sessionWorkspace?.cwd ?? projectPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        let workspaceKey = WorkspaceIdentity.session(model) + ":" + (projectPath == nil ? "home" : directory)
        return RichHostActionRouter(
            scope: scope, openSource: openRichSource,
            terminal: scope == nil || (model.sessionWorkspace != nil && projectPath == nil)
                ? nil
                : .init(directory: directory) { command in
                    guard isCurrent(), !model.isRestoringSession,
                        (activeSessionRepositoryScope?.repositoryPath ?? activeSessionRepositoryPath) == projectPath,
                        (model.sessionWorkspace?.cwd ?? projectPath
                            ?? FileManager.default.homeDirectoryForCurrentUser.path)
                            == directory
                    else {
                        throw QuickDraftError.message(
                            "The session or working directory changed. Review the command again.")
                    }
                    try TerminalWorkspaceStore.shared.workspace(key: workspaceKey)
                        .runInNewShell(command, directory: directory)
                    showSessionRailInspector(.terminal)
                },
            features: [
                .init(kind: .pullRequest, ids: { [weak prs] in prs?.records.map(\.id) ?? [] }) { id in
                    guard isCurrent(), let record = sessionPullRequestCenter.records.first(where: { $0.id == id })
                    else { return nil }
                    return .init(title: record.title, detail: "Last loaded pull request · \(record.state)") {
                        guard isCurrent() else { return }
                        sessionPullRequestCenter.selectedID = record.id
                        showSessionRailInspector(.pullRequests)
                    }
                },
                .init(kind: .issue, ids: { [weak issues] in issues?.records.map(\.id) ?? [] }) { id in
                    guard isCurrent(), let record = sessionIssueCenter.records.first(where: { $0.id == id }) else {
                        return nil
                    }
                    return .init(title: record.title, detail: "Last loaded issue · \(record.state)") {
                        guard isCurrent() else { return }
                        sessionIssueCenter.selectedIssueID = record.id
                        showSessionRailInspector(.issues)
                    }
                },
                .init(
                    kind: .kanban,
                    ids: { [weak control] in
                        control?.capabilityAvailable("kanban") == true ? control?.kanbanTasks.map(\.id) ?? [] : []
                    }
                ) { id in
                    guard isCurrent(), controlCenter.capabilityAvailable("kanban"),
                        let record = controlCenter.kanbanTasks.first(where: { $0.id == id })
                    else { return nil }
                    return .init(title: record.title, detail: "Last loaded task · \(record.status)") {
                        guard isCurrent(), controlCenter.capabilityAvailable("kanban") else { return }
                        controlCenter.revealKanbanTask(record)
                        openRichGlobal(.kanban)
                    }
                },
                .init(
                    kind: .calendar,
                    ids: { [weak control] in
                        guard let control else { return [] }
                        return
                            (CalendarAgenda.automationItems(control.cronJobs)
                            + CalendarAgenda.taskItems(control.globalKanbanTasks)).map(\.id)
                    }
                ) { id in
                    guard isCurrent(), let item = richCalendarItems.first(where: { $0.id == id }) else { return nil }
                    return .init(title: item.title, detail: CalendarItem.when(item)) {
                        guard isCurrent() else { return }
                        openRichGlobal(.calendar)
                    }
                },
                .init(kind: .usage, ids: { [weak control] in control?.tokenUsage == nil ? [] : ["usage"] }) { id in
                    guard isCurrent(), id == "usage", let usage = controlCenter.tokenUsage else { return nil }
                    return .init(
                        title: "Usage · past \(usage.days) days",
                        detail: "\(usage.apiCalls) API calls · \(usage.sessions) sessions · last loaded report"
                    ) {
                        guard isCurrent() else { return }
                        openRichGlobal(.usage)
                    }
                },
                .init(kind: .trace, ids: { [weak dock] in dock?.navigationSessionID.map { [$0] } ?? [] }) { id in
                    guard isCurrent(), id == model.navigationSessionID else { return nil }
                    return .init(
                        title: model.currentSessionTitle ?? "Session execution",
                        detail: "Open the existing Timeline projection"
                    ) {
                        guard isCurrent() else { return }
                        NotificationCenter.default.post(name: .hermOpenRichTrace, object: scope)
                        ensureInspectorPanelVisible()
                    }
                },
            ])
    }

    private func openRichGlobal(_ tab: ControlTab) {
        sessionNavNavigation.selectGlobal(tab)
        fullscreenGlobalTab = tab
        fullscreenSurface = .global
        inspectorScope = .global
        ensureInspectorPanelVisible()
    }

    private func openRichSource(_ reference: RichArtifactReference) async throws {
        let current = RichReplyContext.destination(for: model)
        if current.sessionID != reference.sessionID || current.profileID != reference.profileID {
            guard
                let session = model.sessions.first(where: {
                    $0.id == reference.sessionID && $0.profileID == reference.profileID
                })
            else {
                throw QuickDraftError.message(
                    "The source session is unavailable. Refresh the session inventory and retry.")
            }
            model.resumeSession(session)
        }
        let generation = model.sessionResumeGeneration
        for _ in 0..<120 where model.isRestoringSession {
            try await Task.sleep(for: .milliseconds(50))
            guard generation == model.sessionResumeGeneration else { throw CancellationError() }
        }
        guard generation == model.sessionResumeGeneration,
            model.navigationSessionID == reference.sessionID,
            (model.sessionProfileID ?? model.profileScopeID) == reference.profileID,
            let rowID = reference.rowID, rowID > 0
        else { throw QuickDraftError.message("The source reply is unavailable in this session.") }
        _ = await model.loadTranscriptHistory(through: rowID)
        guard generation == model.sessionResumeGeneration,
            let id = model.storedMessageReferences.first(where: {
                reference.messageUID == nil ? $0.value.rowID == rowID : $0.value.uid == reference.messageUID
            })?.key
        else { throw QuickDraftError.message("The source reply could not be loaded.") }
        fullscreenSurface = .conversation
        sessionWorkspaceMode = .chat
        pinnedMessageJumpID = id
    }
}

extension Notification.Name {
    static let hermOpenRichTrace = Notification.Name("herm.open-rich-trace")
}
