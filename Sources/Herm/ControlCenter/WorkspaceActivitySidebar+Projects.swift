import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceActivitySidebar {
    var projectsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            projectionRefreshNotice("projects")
            if let project = control.selectedProject {
                HStack {
                    Button {
                        control.closeProject()
                        selectedProjectSessionID = nil
                    } label: {
                        DockIconLabel("PROJECTS", icon: .caretLeft)
                    }
                    .buttonStyle(.dockCompact)
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockAccent)
                    Spacer()
                    if let path = selectedProjectFolderPath {
                        Button {
                            startNewChat(in: path)
                        } label: {
                            DockIconLabel("NEW CHAT", icon: .notePencil)
                                .dockFont(.compactStatus, weight: .semibold)
                        }
                        .buttonStyle(.dockCompact)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(model.isRestoringSession || model.isCreatingSession)
                        .help("Start a new chat in this project")
                    }
                }
                selectedProjectSummary(project)
                let projectSessionsProjectionKey = control.projectSessionsProjectionKey(for: project.id)
                if control.projectSessions.isEmpty {
                    if let refresh = control.refreshState(for: projectSessionsProjectionKey), refresh.isStale {
                        emptyState(
                            icon: .warning, title: "Sessions stale",
                            detail: "The last project session snapshot could not be refreshed. Retry to update it.")
                    } else if let refresh = control.refreshState(for: projectSessionsProjectionKey),
                        refresh.error != nil
                    {
                        emptyState(
                            icon: .warning, title: "Sessions unavailable",
                            detail: "Hermes could not load this project's sessions. Retry to try again.")
                    } else {
                        emptyState(
                            icon: .chats, title: "No sessions in this project",
                            detail: "No grouped sessions were found for this project.")
                    }
                } else {
                    HStack {
                        sectionLabel("SESSIONS")
                        Spacer()
                        Text("\(control.projectSessions.count)")
                            .dockFont(.body, weight: .semibold)
                            .foregroundStyle(Color.dockAccent)
                    }
                    ForEach(control.projectSessions) { session in
                        let lifecycle = SessionLifecyclePresentation.status(
                            for: session, refresh: control.refreshState(for: projectSessionsProjectionKey))
                        Button {
                            selectedProjectSessionID = session.id
                            openProjectSession(session)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Circle().fill(sessionLifecycleColor(lifecycle)).frame(width: 6, height: 6)
                                    Text(session.title)
                                        .dockFont(.body, weight: .semibold)
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(2)
                                    Spacer()
                                    Text(lifecycle.label.uppercased())
                                        .dockFont(.body, weight: .semibold)
                                        .foregroundStyle(sessionLifecycleColor(lifecycle))
                                    DockIcon(.caretRight)
                                        .dockFont(.compactStatus, weight: .bold)
                                        .foregroundStyle(Color.dockAccent)
                                }
                                if let preview = session.displayPreview {
                                    Text(preview)
                                        .dockFont(.body)
                                        .foregroundStyle(Color.dockMetadataText)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dockListRow()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .accessibilityLabel(
                            SessionLifecyclePresentation.accessibilityLabel(
                                for: session, refresh: control.refreshState(for: projectSessionsProjectionKey)))
                    }
                }
                if selectedProjectSessionID != nil {
                    projectChangesContent
                }
            } else if control.projects.isEmpty {
                HStack {
                    sectionLabel("PROJECTS  ·  0")
                    Spacer()
                    projectDirectoryActions
                }
                emptyState(
                    icon: .folder, title: "No projects",
                    detail: "Projects will appear here when project contexts are available.")
            } else {
                HStack {
                    sectionLabel("PROJECTS  ·  \(control.projects.count)")
                    Spacer()
                    projectDirectoryActions
                }
                ForEach(control.projects.prefix(projectsDisplayLimit)) { project in
                    Button {
                        openProject(project)
                    } label: {
                        HStack(spacing: 10) {
                            DockIcon(project.isActive ? .folder : .folder)
                                .dockFont(.body, weight: .medium)
                                .foregroundStyle(project.isActive ? Color.dockAccent : Color.dockSecondaryText)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(projectDisplayName(project))
                                    .dockFont(.body, weight: .semibold)
                                    .foregroundStyle(Color.dockPrimaryText)
                                    .lineLimit(1)
                                Text(projectMetadata(project))
                                    .dockFont(.body)
                                    .foregroundStyle(Color.dockMetadataText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if project.isActive {
                                Text("ACTIVE")
                                    .dockFont(.body, weight: .semibold)
                                    .tracking(0.5)
                                    .foregroundStyle(Color.dockSuccess)
                            }
                            DockIcon(.caretRight)
                                .dockFont(.body, weight: .semibold)
                                .foregroundStyle(Color.dockAccent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                }
                if control.projects.count > projectsDisplayLimit {
                    Button {
                        projectsDisplayLimit += Self.projectsPageSize
                    } label: {
                        DockIconLabel(
                            "SHOW MORE (\(control.projects.count - projectsDisplayLimit) REMAINING)", icon: .caretDown
                        )
                        .dockFont(.compactStatus, weight: .semibold)
                        .tracking(0.4)
                    }
                    .buttonStyle(.dockCompact)
                    .foregroundStyle(Color.dockAccent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
            }
        }
        .onChange(of: control.projects.count) { _, _ in
            projectsDisplayLimit = max(projectsDisplayLimit, Self.projectsPageSize)
        }
    }

    var addProjectDirectoryButton: some View {
        Button {
            chooseProjectDirectory()
        } label: {
            DockIconLabel("ADD DIRECTORY", icon: .folderPlus)
                .dockFont(.compactStatus, weight: .semibold)
                .tracking(0.4)
        }
        .buttonStyle(.dockCompact)
        .foregroundStyle(Color.dockAccent)
        .help("Start a new chat in a directory")
    }

    var projectDirectoryActions: some View {
        HStack(spacing: 10) {
            addProjectDirectoryButton
            if control.projectMutationsAvailable {
                Button("CREATE PROJECT") { chooseProjectForCreation() }
                    .buttonStyle(.dockCompact)
                    .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.dockAccent)
                    .help("Create a Hermes project from a folder")
            }
        }
    }

    func startNewChat(in path: String) {
        store.attachProject(at: path)
        control.closeProject()
        selectedMode = .kanban
        Task { @MainActor in
            await model.startNewChat(in: path)
            if let sessionID = model.sessionID {
                control.selectProject(forPath: path)
                control.focus(sessionID: sessionID)
            }
            model.requestComposerFocus()
        }
    }

    func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project directory"
        panel.message = "Select the folder to use as the working directory for a new Hermes chat."
        panel.prompt = "Use Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // Hermes itself is a status-bar-level panel. Match that level and
        // explicitly order the picker above it without collapsing Hermes.
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startNewChat(in: url.standardizedFileURL.path)
    }

    func chooseProjectForCreation() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project directory"
        panel.message = "Select the folder to add as a Hermes project."
        panel.prompt = "Create Project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runAboveHerm() == .OK, let url = panel.url else { return }
        pendingProjectFolder = url.standardizedFileURL
        isShowingProjectCreationConfirmation = true
    }

    func selectedProjectSummary(_ project: ProjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                DockIcon(project.isActive ? .folder : .folder)
                    .dockFont(.navigation, weight: .medium)
                    .foregroundStyle(project.isActive ? Color.dockAccent : Color.dockSecondaryText)
                Text(projectDisplayName(project))
                    .dockFont(size: 15, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
            }
            if project.name != "__no_project__" {
                Text(project.name)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                if !project.isActive, control.projectMutationsAvailable {
                    Button("SET ACTIVE") { requestProjectMutation(.activate) }
                        .foregroundStyle(Color.dockAccent)
                }
                if control.projectMutationsAvailable {
                    Button("ARCHIVE") { requestProjectMutation(.archive) }
                        .foregroundStyle(Color.dockWarning)
                }
                if control.projectMutationsAvailable {
                    Button("DELETE") { requestProjectMutation(.delete) }
                        .foregroundStyle(Color.dockDestructive)
                }
            }
            .buttonStyle(.dockCompact)
            .dockFont(.compactStatus, weight: .semibold, design: .monospaced)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    func projectDisplayName(_ project: ProjectSummary) -> String {
        guard project.name != "__no_project__" else { return "Unassigned sessions" }
        let path = URL(fileURLWithPath: project.name)
        return path.lastPathComponent.isEmpty ? project.name : path.lastPathComponent
    }

    func projectMetadata(_ project: ProjectSummary) -> String {
        let folderLabel = project.repoCount == 1 ? "1 folder" : "\(project.repoCount) folders"
        let sessionLabel = project.sessionCount == 1 ? "1 session" : "\(project.sessionCount) sessions"
        let counts = "\(folderLabel)  ·  \(sessionLabel)"
        guard project.name != "__no_project__" else { return counts }
        return "\(counts)  ·  \(project.name)"
    }

    func projectMutationMessage(_ mutation: ProjectMutation, project: ProjectSummary) -> String {
        switch mutation {
        case .activate: "Hermes will make \(projectDisplayName(project)) the active project."
        case .archive:
            "Hermes will archive \(projectDisplayName(project)) and remove it from active project navigation."
        case .delete: "Hermes will permanently delete \(projectDisplayName(project)) from Hermes project storage."
        }
    }

    func requestProjectMutation(_ mutation: ProjectMutation) {
        pendingProjectMutation = mutation
        isShowingProjectMutationConfirmation = true
    }

    var selectedProjectFolderPath: String? {
        guard let project = control.selectedProject,
            project.name != "__no_project__",
            project.name.hasPrefix("/"),
            FileManager.default.fileExists(atPath: project.name)
        else { return nil }
        return project.name
    }

    func openProject(_ project: ProjectSummary) {
        control.openProject(project)
        guard project.name != "__no_project__",
            project.name.hasPrefix("/"),
            FileManager.default.fileExists(atPath: project.name)
        else { return }
        store.attachProject(at: project.name)
    }

    func openProjectSession(_ session: SessionSummary) {
        if let path = selectedProjectFolderPath {
            store.attachProject(at: path, toSessionID: session.id)
        }
        control.openProjectSession(session)
        onSessionOpened(session.id)
    }

    var projectChangesContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("LOCAL CHANGES")
            if workflow.repository.isGitRepository {
                HStack(spacing: 8) {
                    todayMetric("STAGED", value: workflow.changes?.stagedCount ?? 0, color: .dockAccent)
                    todayMetric(
                        "UNSTAGED", value: workflow.changes?.unstagedCount ?? 0, color: DockCategoryTone.modified.color)
                    todayMetric("UNTRACKED", value: workflow.changes?.untrackedCount ?? 0, color: .dockSecondaryText)
                    todayMetric(
                        "CONFLICTS", value: workflow.changes?.conflictedCount ?? 0,
                        color: (workflow.changes?.conflictedCount ?? 0) > 0 ? .dockDestructive : .dockSuccess)
                }
                Text(
                    workflow.repository.changedFiles == 0
                        ? "CLEAN WORKING TREE"
                        : "\(workflow.repository.changedFiles) CHANGED FILE\(workflow.repository.changedFiles == 1 ? "" : "S") · \(workflow.repository.branch)"
                )
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(
                    workflow.repository.changedFiles == 0 ? Color.dockSuccess : DockCategoryTone.modified.color)
                HStack(spacing: 10) {
                    Button("OPEN SOURCE CONTROL") { select(.changes) }
                    Button(
                        commandCenterPreferences.isWatchingRepository(workflow.repository.repositoryID)
                            ? "STOP WATCHING" : "WATCH REPOSITORY"
                    ) {
                        workflow.toggleWatching(preferences: commandCenterPreferences, control: control)
                    }
                    Button("REFRESH") { Task { await refreshRepository() } }
                }
                .buttonStyle(.dockCompact)
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(Color.dockAccent)
            } else {
                Text("No local project folder is attached to the active session.")
                    .dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
                Button("SELECT PROJECT FOLDER") {
                    showingRepositoryPicker = true
                }
                .buttonStyle(.dockCompact)
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(Color.dockAccent)
            }
        }
        .padding(12)
        .dockGlassPane()
    }
}
