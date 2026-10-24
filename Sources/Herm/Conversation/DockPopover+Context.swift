import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension DockPopover {
    /// Fullscreen has a dedicated navigation rail. Unlike the compact session
    /// picker popover, it keeps the active queue visible while the user works
    /// through a conversation or task.
    var missionControlQueue: some View {
        MissionControlQueue(
            model: model,
            botMode: botMode,
            workspaceStore: workspaceStore,
            controlCenter: controlCenter,
            agentUpdateService: agentUpdateService,
            navigationState: missionControlNavigation,
            dockThemeStore: dockThemeStore,
            sessionPendingDeletion: $sessionPendingDeletion,
            activeSessionID: model.navigationSessionID,
            activeGlobalTab: fullscreenSurface == .global ? fullscreenGlobalTab : nil,
            isArtifactsActive: fullscreenSurface == .artifacts,
            isBotsActive: fullscreenSurface == .bots,
            isPullRequestsActive: fullscreenSurface == .pullRequests,
            isIssuesActive: fullscreenSurface == .issues,
            onNewConversation: {
                missionControlNavigation.beginNewConversation()
                fullscreenSurface = .conversation
                inspectorScope = .session
                model.newChat()
                model.requestComposerFocus()
            },
            onSelectSession: { session in
                missionControlNavigation.selectSession(session.id)
                fullscreenSurface = .conversation
                inspectorScope = .session
                model.resumeSession(session)
            },
            onSelectTask: { task in
                missionControlNavigation.selectTask(task.id)
                if let sessionID = task.sessionID,
                    let session = model.sessions.first(where: { $0.id == sessionID })
                {
                    fullscreenSurface = .conversation
                    inspectorScope = .session
                    model.resumeSession(session)
                } else {
                    // Workspace tasks without a conversation still have a
                    // useful destination: the global Kanban surface.
                    fullscreenGlobalTab = .kanban
                    fullscreenSurface = .global
                }
            },
            onOpenGlobal: { tab in
                missionControlNavigation.selectGlobal(tab)
                fullscreenGlobalTab = tab
                fullscreenSurface = .global
            },
            onOpenArtifacts: {
                missionControlNavigation.selectArtifacts()
                fullscreenSurface = .artifacts
            },
            onOpenBots: {
                missionControlNavigation.selectBots()
                Task { await botMode.refreshNow(force: true) }
                fullscreenSurface = .bots
            },
            onOpenBotChat: { bot, recent in
                if let recent { openRecentBotSession(bot, recent: recent) } else { openBotChat(bot) }
            },
            onOpenGroupChat: { roomID in
                missionControlNavigation.selection.selectGroupChat(roomID)
                fullscreenSurface = .groupChat(roomID)
            },
            onOpenPullRequests: {
                missionControlNavigation.selectPullRequests()
                fullscreenSurface = .pullRequests
            },
            onOpenIssues: {
                missionControlNavigation.selectIssues()
                fullscreenSurface = .issues
            },
            showsFullscreenToggle: true,
            isFullscreen: isFullscreen,
            onFullscreenToggle: toggleFullscreen,
            onSelectProfile: { botMode.selectProfile($0) },
            onOpenWindow: onOpenWindow,
            isDockedWindow: usesWindowChrome,
            isSidebarCollapsed: $isChatListCollapsed
        )
    }

    func handleProfileScopeChange(_ profileID: String?) {
        let normalized = profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = normalized?.isEmpty == false ? normalized : nil
        if model.profileScopeID == selected, !model.profileScopeUnavailable {
            controlCenter.setProjectProfile(selected)
            return
        }
        model.setProfileScope(selected)
        controlCenter.setProjectProfile(selected)
        missionControlNavigation.clearSelection()
        clearSessionSurfaceSelections()
        cachedProjectName = nil
        cachedSessionRepositoryPath = nil
    }

    var fullscreenGlobalControlSurface: some View {
        WorkspaceActivitySidebar(
            model: model,
            botMode: botMode,
            store: workspaceStore,
            control: controlCenter,
            workflow: developerWorkflow,
            dockThemeStore: dockThemeStore,
            onClose: onClose,
            onRestartDock: {
                // Do not restore the old session's model pin after relaunch.
                // The restart is explicitly a provider/account sync boundary.
                model.newChat()
                agentUpdateService.restartDock()
            },
            onOpenArtifacts: {},
            onSessionOpened: { sessionID in
                missionControlNavigation.openProjectSession(sessionID: sessionID)
                // Global surfaces (such as Projects) own discovery; after a
                // session is chosen, return the user to the shared chat
                // workspace where that session is visible.
                fullscreenSurface = .conversation
            },
            showsHeader: false,
            showsModePicker: false,
            initialMode: fullscreenGlobalTab,
            agentUpdateService: agentUpdateService
        )
    }

    var fullscreenGlobalSurface: some View {
        Group {
            if fullscreenSurface == .pullRequests {
                PullRequestWorkspace(
                    center: pullRequestCenter, projects: controlCenter.projects, onOpenChat: openPullRequestChat
                )
                .environment(\.openGitHubItem, openGitHubReference)
                .id("fullscreen-pull-requests")
            } else if fullscreenSurface == .issues {
                IssueWorkspacePage(center: issueCenter, projects: controlCenter.projects, onOpenChat: openIssueChat)
                    .environment(\.openGitHubItem, openGitHubReference)
                    .id("fullscreen-issues")
            } else if fullscreenSurface == .artifacts {
                ArtifactsInspectorView(model: model, presentation: .page) { session in
                    missionControlNavigation.openSession(session.id)
                    fullscreenSurface = .conversation
                    inspectorScope = .session
                    model.resumeSession(session)
                }
                .id("fullscreen-artifacts")
            } else if fullscreenSurface == .bots {
                BotRosterPage(
                    model: botMode,
                    dockModel: model,
                    onSelectBot: { bot in
                        botMode.selectProfile(bot.id)
                        missionControlNavigation.clearSelection()
                        fullscreenSurface = .conversation
                    },
                    onOpenChat: openBotChat,
                    onOpenRecentSession: openRecentBotSession
                )
                .id("fullscreen-bots")
            } else if case .groupChat(let roomID) = fullscreenSurface {
                GroupChatView(store: botMode.groupChats, botMode: botMode, roomID: roomID) {
                    missionControlNavigation.clearSelection()
                    fullscreenSurface = .conversation
                }
                .id("fullscreen-group-\(roomID)")
            } else {
                fullscreenGlobalControlSurface
            }
        }
    }

    func openMarkdownURL(_ url: URL) {
        guard let reference = GitHubMarkdownLink.reference(for: url) else {
            InAppBrowser.open(url)
            return
        }
        let session = WorkspaceIdentity.session(model)
        guard gitHubInspector.opening[session] == nil else { return }
        Task {
            guard gitHubInspector.opening[session] == nil else { return }
            let opened = await gitHubInspector.open(reference, session: session)
            guard opened, GitHubMarkdownLink.reference(for: url) != nil,
                session == WorkspaceIdentity.session(model)
            else {
                InAppBrowser.open(url)
                return
            }
            inspectorScope = .session
            ensureInspectorPanelVisible()
        }
    }

    func openGitHubReference(_ reference: GitHubItemReference) {
        if reference.kind == .pullRequest {
            missionControlNavigation.selectPullRequests()
            fullscreenSurface = .pullRequests
            Task { await pullRequestCenter.open(reference) }
        } else {
            missionControlNavigation.selectIssues()
            fullscreenSurface = .issues
            Task { await issueCenter.open(reference) }
        }
    }

    func openBotChat(_ bot: BotSummary) {
        let chat = bot.chat ?? BotChatReference(sessionID: BotService.canonicalBotChatTitle, profileID: bot.id)
        missionControlNavigation.openBotChat(sessionID: chat.sessionID)
        fullscreenSurface = .conversation
        inspectorScope = .session
        model.resumeBotChat(bot)
    }

    func openRecentBotSession(_ bot: BotSummary, recent: BotChatReference) {
        missionControlNavigation.openSession(recent.sessionID)
        fullscreenSurface = .conversation
        inspectorScope = .session
        model.resumeSession(
            HermesSession(
                id: recent.sessionID,
                profileID: bot.id,
                title: recent.title ?? "",
                preview: recent.preview ?? "",
                startedAt: recent.lastActive,
                updatedAt: recent.lastActive,
                messageCount: 0,
                source: "hermes-bot",
                isHidden: false
            ))
    }

    func openPullRequestChat(_ pullRequest: PullRequestRecord) {
        let prompt = """
            Review pull request #\(pullRequest.number), \"\(pullRequest.title)\", in \(pullRequest.repository.id).
            PR: \(pullRequest.webURL?.absoluteString ?? "Unavailable")
            Branch: \(pullRequest.headBranch) → \(pullRequest.baseBranch)

            Review risks, test coverage, and findings. Do not modify files unless I ask.
            """
        Task {
            if let linkedID = pullRequestChatLinks.sessionID(for: pullRequest.id),
                let linkedSession = model.sessions.first(where: { $0.id == linkedID })
            {
                missionControlNavigation.openPullRequestChat(sessionID: linkedSession.id)
                model.resumeSession(linkedSession)
            } else {
                pullRequestChatLinks.remove(pullRequestID: pullRequest.id)
                if pullRequest.localPath.isEmpty {
                    model.newChat()
                } else {
                    await model.startNewChat(in: pullRequest.localPath)
                }
                if let createdID = model.sessionID {
                    pullRequestChatLinks.save(sessionID: createdID, for: pullRequest.id)
                }
                missionControlNavigation.openPullRequestChat(sessionID: model.sessionID)
            }
            model.draft = prompt
            fullscreenSurface = .conversation
            inspectorScope = .session
            model.requestComposerFocus()
        }
    }

    func openIssueChat(_ issue: GitHubIssueRecord) {
        let context = IssueContext(issue: issue)
        Task {
            var sessionID: String?
            if let linkedID = pullRequestChatLinks.sessionID(for: context.id),
                let linkedSession = model.sessions.first(where: { $0.id == linkedID })
            {
                sessionID = linkedSession.id
                model.resumeSession(linkedSession)
            } else {
                pullRequestChatLinks.remove(pullRequestID: context.id)
                if issue.localPath.isEmpty { model.newChat() } else { await model.startNewChat(in: issue.localPath) }
                sessionID = model.sessionID
                if let sessionID { pullRequestChatLinks.save(sessionID: sessionID, for: context.id) }
            }
            missionControlNavigation.openIssueChat(sessionID: sessionID)
            model.draft = context.prompt
            fullscreenSurface = .conversation
            inspectorScope = .session
            model.requestComposerFocus()
        }
    }

    var contextPanel: some View {
        VStack(spacing: 0) {
            if let url = filePreview.url {
                FilePreviewPane(url: url, model: model) { filePreview.url = nil }
            } else if sessionWorkspaceMode.usesContextPreview {
                sessionSurfacePreview
                    .transition(.opacity)
                    .animation(.dockEase(duration: 0.2), value: sessionWorkspaceMode)
            } else {
                if !usesMissionControlLayout && !isNarrowLayout {
                    contextPanelHeader
                }

                // Narrow layout swaps the chat out for the inspector, so offer the way back.
                if isNarrowLayout {
                    HStack {
                        Button {
                            withAnimation(.dockEase(duration: 0.2)) { isNarrowControlVisible = false }
                        } label: {
                            Label("Back to chat", systemImage: "chevron.left")
                                .dockFont(.body, weight: .semibold)
                                .foregroundStyle(Color.dockSecondaryText)
                                .padding(.horizontal, 8)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .accessibilityLabel("Back to chat")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }

                Group {
                    switch inspectorScope {
                    case .global:
                        WorkspaceActivitySidebar(
                            model: model,
                            botMode: botMode,
                            store: workspaceStore,
                            control: controlCenter,
                            workflow: developerWorkflow,
                            dockThemeStore: dockThemeStore,
                            onClose: onClose,
                            onRestartDock: {
                                model.newChat()
                                agentUpdateService.restartDock()
                            },
                            onOpenArtifacts: { inspectorScope = .artifacts },
                            showsHeader: false,
                            initialMode: fullscreenGlobalTab,
                            agentUpdateService: agentUpdateService
                        )
                    case .session:
                        SessionInspector(
                            model: model,
                            botMode: botMode,
                            control: controlCenter,
                            workflow: developerWorkflow,
                            gitHub: gitHubInspector,
                            onOpenPullRequestChat: openPullRequestChat,
                            onOpenIssueChat: openIssueChat,
                            sessionRepositoryPath: activeSessionRepositoryScope?.repositoryPath
                                ?? activeSessionRepositoryPath,
                            sessionProjectIsBound: activeSessionRepositoryPath != nil,
                            showsHeader: false,
                            onToggle: toggleInspectorPanel,
                            headerHeight: usesWindowChrome
                                ? DockWindowChrome.titleRowHeight : conversationMetrics.headerHeight
                        )
                    case .artifacts:
                        ArtifactsInspectorView(model: model, presentation: .inspector)
                    }
                }
                .transition(.opacity)
                .animation(.dockEase(duration: 0.2), value: inspectorScope)
            }
        }
        .background(Color.clear)
        // This task belongs to the shared context panel, not the Global
        // sidebar. The sidebar is removed in Session scope, but the session
        // inspector still needs the same repository projection loaded.
        .task(id: activeSessionRepositoryIdentity) {
            // Capture the resolved path at the start of the task. Project
            // membership can transiently disappear during a refresh after
            // this task has been scheduled; that must not turn a valid
            // session repository into nil.
            let repositoryPath = liveSessionRepositoryPath ?? cachedSessionRepositoryPath
            guard let repositoryPath else { return }
            if let liveSessionRepositoryPath { cachedSessionRepositoryPath = liveSessionRepositoryPath }
            await developerWorkflow.setActiveRepository(
                path: activeWorktreePath ?? repositoryPath,
                preferences: repositoryPreferences,
                control: controlCenter
            )
        }
        .onAppear {
            refreshCachedProjectName()
            cacheSessionRepositoryPath()
            synchronizeSessionMetadataFromControlCenter()
        }
    }

    @ViewBuilder
    var sessionSurfacePreview: some View {
        switch sessionWorkspaceMode {
        case .explorer:
            if let explorerSelection,
                let activeScope = activeSessionRepositoryScope,
                explorerSelection.scope == activeScope
            {
                RepositoryCodeWorkspaceView(
                    repositoryPath: explorerSelection.scope.repositoryPath,
                    document: explorerSelection.document,
                    onClose: { self.explorerSelection = nil },
                    onSave: { draft in
                        guard self.activeSessionRepositoryScope == explorerSelection.scope else { return false }
                        guard
                            await RepositoryService.saveDocument(
                                path: explorerSelection.scope.repositoryPath, filePath: explorerSelection.document.path,
                                contents: draft)
                        else { return false }
                        await refreshSessionWorkflow()
                        self.explorerSelection = ScopedRepositoryDocument(
                            scope: explorerSelection.scope,
                            document: RepositoryFileDocument(
                                path: explorerSelection.document.path, contents: draft,
                                byteCount: draft.lengthOfBytes(using: .utf8))
                        )
                        return true
                    },
                    isStandalonePane: !isNarrowLayout
                )
            } else {
                SessionSurfacePreviewPlaceholder(
                    icon: .folder,
                    title: "No file open",
                    detail: "Select a file in the explorer to open it here."
                )
            }
        case .sourceControl:
            SessionChangeDiffPreview(
                file: selectedChange?.file,
                diff: selectedChangeDiff,
                isLoading: isLoadingChangeDiff
            )
        case .pullRequests:
            PullRequestDetailView(center: sessionPullRequestCenter, onOpenChat: openPullRequestChat, isInspector: true)
        case .issues:
            IssueDetailView(center: sessionIssueCenter, onOpenChat: openIssueChat, isInspector: true)
        case .chat, .voice:
            EmptyView()
        }
    }

    var contextPanelHeader: some View {
        HStack(spacing: 12) {
            Text("INSPECTOR")
                .dockFont(.metadata, weight: .bold)
                .tracking(1.05)
                .foregroundStyle(Color.dockMetadataText)

            Spacer(minLength: 8)

            scopePicker
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .dockPaneTint(Color.dockSurface2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    var contextProjectPath: String? {
        guard let sessionID = model.sessionID,
            let project = controlCenter.project(forSessionID: sessionID),
            project.name != "__no_project__",
            !project.name.isEmpty
        else { return nil }
        return project.name
    }

    var contextProjectName: String? {
        let path = contextProjectPath
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    var activeSessionRepositoryPath: String? {
        liveSessionRepositoryPath ?? cachedSessionRepositoryPath
    }

    var liveSessionRepositoryPath: String? {
        // The sidebar attaches projects under the stored session id, while a
        // resumed chat may stream under a runtime alias; check both.
        workspaceStore.projectPath(forSessionID: model.navigationSessionID)
            ?? workspaceStore.resolvedProjectPath(
                forSessionID: model.sessionID,
                hermesProjectPath: model.sessionID.flatMap { controlCenter.project(forSessionID: $0)?.name },
                createdSessionProjectPath: model.sessionID.flatMap { model.createdSessionProjectPaths[$0] }
            )
    }

    var activeSessionRepositoryIdentity: String? {
        activeSessionRepositoryScope?.identity
    }

    var activeSessionRepositoryScope: SessionRepositoryScope? {
        guard let sessionID = model.sessionID,
            let path = activeSessionRepositoryPath
        else { return nil }
        return SessionRepositoryScope(sessionID: sessionID, repositoryPath: activeWorktreePath ?? path)
    }

    /// The worktree the session is viewing, inside the bound folder. A removed
    /// or outside worktree falls back to the bound folder.
    var activeWorktreePath: String? {
        guard let path = workspaceStore.worktreePath(forSessionID: model.sessionID),
            let root = activeSessionRepositoryPath,
            path != root,
            RepositoryWorktreeSummary.isPath(path, within: root),
            FileManager.default.fileExists(atPath: path)
        else { return nil }
        return path
    }

    /// View-only: the agent keeps its own cwd.
    func selectWorktree(_ path: String) {
        guard let sessionID = model.sessionID else { return }
        workspaceStore.setWorktreePath(
            path == activeSessionRepositoryPath ? nil : path, forSessionID: sessionID,
            title: model.currentSessionTitle ?? "Untitled task")
    }

    /// Updates the cached project name from the live computed value.
    /// Called whenever the session or project membership changes.
    func refreshCachedProjectName() {
        if let contextProjectName {
            cachedProjectName = contextProjectName
        }
    }

    func cacheSessionRepositoryPath() {
        if let liveSessionRepositoryPath {
            cachedSessionRepositoryPath = liveSessionRepositoryPath
        }
    }

    func synchronizeSessionMetadataFromControlCenter() {
        guard let sessionID = model.sessionID,
            let summary = controlCenter.sessionSummary(for: sessionID)
        else { return }
        model.updateCurrentSessionTitle(summary.title)
    }

    var scopePicker: some View {
        HStack(spacing: 0) {
            // The fullscreen right region is an inspector for the active
            // center surface, never a competing global workspace.
            let scopes: [InspectorScope] =
                usesMissionControlLayout || isNarrowLayout
                ? [.session, .artifacts]
                : InspectorScope.allCases
            ForEach(scopes) { scope in
                Button {
                    withAnimation(.dockEase(duration: 0.18)) {
                        inspectorScope = scope
                    }
                } label: {
                    Text(scope.rawValue)
                        .dockFont(.navigation, weight: inspectorScope == scope ? .semibold : .regular)
                        .foregroundStyle(inspectorScope == scope ? Color.dockPrimaryText : Color.dockSecondaryText)
                        .frame(width: 82, height: 34)
                        .background {
                            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 2, style: .continuous)
                                .fill(inspectorScope == scope ? Color.dockAccent.opacity(0.10) : Color.clear)
                        }
                        .overlay(alignment: .bottom) {
                            if inspectorScope == scope {
                                Color.dockAccent.frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .accessibilityLabel("Show \(scope.rawValue) inspector")
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector scope")
    }

    func synchronizeWorkspace(status: HermesStatus? = nil) {
        guard let sessionID = model.sessionID else { return }
        let title =
            model.currentSessionTitle
            ?? model.messages.first(where: { $0.role == .user })?.text
            ?? "Current Hermes task"
        let task = workspaceStore.ensureTask(title: title, sessionID: sessionID)

        switch status ?? model.status {
        case .working:
            workspaceStore.updateStatus(.inProgress, for: task.id)
        case .needsApproval:
            workspaceStore.updateStatus(.awaitingApproval, for: task.id)
        case .needsClarification:
            workspaceStore.updateStatus(.awaitingApproval, for: task.id)
        case .idle where task.status == .inProgress || task.status == .awaitingApproval:
            workspaceStore.updateStatus(.readyForReview, for: task.id)
        case .idle, .offline:
            break
        }
    }

    var header: some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        return GeometryReader { geometry in
            let showsInspector = geometry.size.width >= 440
            HStack(spacing: 4) {
                // Leading like a native toolbar title; actions sit at the trailing edge.
                if hidesChatList {
                    DockSidebarToggle(isCollapsed: $isChatListCollapsed)
                }
                sessionIdentity(style: style)
                Spacer(minLength: 12)

                if sessionWorkspaceMode == .chat, !model.messageNavigatorItems.isEmpty {
                    // Pinned messages open from the "…" menu; the popover anchors here.
                    Color.clear.frame(width: 0, height: 0)
                        .popover(isPresented: $isShowingMessagePins, arrowEdge: .bottom) {
                            MessagePinsView(model: model) { pin in
                                let sessionID = model.sessionID
                                Task { @MainActor in
                                    guard let id = await model.messageID(forPin: pin), model.sessionID == sessionID
                                    else { return }
                                    isShowingMessagePins = false
                                    pinnedMessageJumpID = id
                                }
                            }
                            .task { await model.refreshMessagePins() }
                        }
                    // Search lives in the "…" menu; this keeps ⌘F working.
                    Button("") { isShowingMessageSearch.toggle() }
                        .keyboardShortcut("f", modifiers: .command)
                        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                }

                sessionModeSwitcher(style: style)

                sessionViewMenu(includesInspector: !showsInspector, style: style)
                    .fixedSize()

                if showsInspector && !inspectorHasOwnToggle {
                    DockSidebarToggle(
                        isCollapsed: !inspectorPanelIsVisible, edge: .trailing, action: toggleInspectorPanel)
                }
            }
            .padding(.leading, hidesChatList ? DockWindowChrome.sidebarToggleLeading : 12)
            .padding(.trailing, 12)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: usesWindowChrome ? DockWindowChrome.titleRowHeight : conversationMetrics.headerHeight)
        .background { if usesWindowChrome { TitlebarDoubleClickArea() } }
        .background(usesWindowChrome ? Color.dockSidebar : Color.dockCanvas)
        .overlay(alignment: .bottom) { if usesWindowChrome { DockWindowChrome.titleRowSeparator } }
    }
}
