import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension DockPopover {
    func leaveIntegrations(_ action: @escaping () -> Void) {
        if let state = sessionNavNavigation.integrationsWorkspace {
            state.requestNavigation(action)
        } else {
            action()
        }
    }

    /// Fullscreen has a dedicated navigation rail. Unlike the compact session
    /// picker popover, it keeps the active queue visible while the user works
    /// through a conversation or task.
    var sessionNavQueue: some View {
        SessionNavQueue(
            model: model,
            botMode: botMode,
            workspaceStore: workspaceStore,
            controlCenter: controlCenter,
            agentUpdateService: agentUpdateService,
            navigationState: sessionNavNavigation,
            dockThemeStore: dockThemeStore,
            sessionPendingDeletion: $sessionPendingDeletion,
            activeSessionID: model.navigationSessionID,
            activeGlobalTab: fullscreenSurface == .global ? fullscreenGlobalTab : nil,
            isArtifactsActive: fullscreenSurface == .artifacts,
            isBotsActive: fullscreenSurface == .bots,
            isPullRequestsActive: fullscreenSurface == .pullRequests,
            isIssuesActive: fullscreenSurface == .issues,
            onNewConversation: startNewConversation,
            onSelectSession: { session in
                leaveIntegrations {
                    sessionNavNavigation.selectSession(session.id)
                    fullscreenSurface = .conversation
                    inspectorScope = .session
                    model.resumeSession(session)
                }
            },
            onSelectTask: { task in
                leaveIntegrations {
                    sessionNavNavigation.selectTask(task.id)
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
                }
            },
            onOpenGlobal: { tab in
                leaveIntegrations {
                    sessionNavNavigation.selectGlobal(tab)
                    fullscreenGlobalTab = tab
                    fullscreenSurface = .global
                }
            },
            onOpenArtifacts: {
                leaveIntegrations {
                    sessionNavNavigation.selectArtifacts()
                    fullscreenSurface = .artifacts
                }
            },
            onOpenBots: { leaveIntegrations { openBotsPage() } },
            onOpenBotChat: { bot, recent in
                leaveIntegrations {
                    if let recent { openRecentBotSession(bot, recent: recent) } else { openBotChat(bot) }
                }
            },
            onOpenPullRequests: {
                leaveIntegrations {
                    sessionNavNavigation.selectPullRequests()
                    fullscreenSurface = .pullRequests
                }
            },
            onOpenIssues: {
                leaveIntegrations {
                    sessionNavNavigation.selectIssues()
                    fullscreenSurface = .issues
                }
            },
            onOpenTiles: {
                leaveIntegrations {
                    sessionNavNavigation.clearSelection()
                    fullscreenSurface = .chatGrid
                }
            },
            onShowBots: {
                // Land on a bot's main chat rather than carrying the open session across.
                let visible = botMode.bots.filter { !$0.isHidden }
                let lastID = UserDefaults.standard.string(forKey: BotChatsOrdering.lastBotKey)
                let bot = visible.first { $0.id == lastID } ?? visible.first(where: \.isDefault) ?? visible.first
                leaveIntegrations { openBotsPage(with: bot) }
            },
            showsFullscreenToggle: true,
            isFullscreen: isFullscreen,
            onFullscreenToggle: toggleFullscreen,
            onSelectProfile: { profile in
                leaveIntegrations {
                    botMode.selectProfile(profile)
                    // Apply the scope now: a sidebar chat from another bot
                    // resumes right after, and a deferred scope change would
                    // start a new chat over it.
                    handleProfileScopeChange(botMode.selectedProfileID)
                }
            },
            onOpenWindow: onOpenWindow,
            isDockedWindow: usesWindowChrome,
            history: (navHistory.canGoBack, navHistory.canGoForward, goBack, goForward),
            isSidebarCollapsed: chatListCollapsed
        )
    }

    var currentNavigationDestination: NavigationDestination {
        NavigationDestination(
            surface: fullscreenSurface,
            tab: fullscreenSurface == .global ? fullscreenGlobalTab : nil,
            sessionID: fullscreenSurface == .conversation ? model.navigationSessionID : nil)
    }

    func goBack() { if let destination = navHistory.back() { navigate(to: destination) } }
    func goForward() { if let destination = navHistory.forward() { navigate(to: destination) } }

    /// Reopens a visited destination through the same owners the sidebar uses.
    func navigate(to destination: NavigationDestination) {
        leaveIntegrations {
            switch destination.surface {
            case .conversation:
                if let id = destination.sessionID, let session = model.sessions.first(where: { $0.id == id }) {
                    sessionNavNavigation.selectSession(id)
                    inspectorScope = .session
                    model.resumeSession(session)
                }
                fullscreenSurface = .conversation
            case .global:
                let tab = destination.tab ?? .kanban
                sessionNavNavigation.selectGlobal(tab)
                fullscreenGlobalTab = tab
                fullscreenSurface = .global
            case .artifacts:
                sessionNavNavigation.selectArtifacts()
                fullscreenSurface = .artifacts
            case .bots: openBotsPage()
            case .pullRequests: selectGitHubSection(.pullRequests)
            case .issues: selectGitHubSection(.issues)
            case .chatGrid:
                sessionNavNavigation.clearSelection()
                fullscreenSurface = .chatGrid
            }
        }
    }

    /// Starts a chat with the selected bot from the sidebar or title picker.
    func startNewConversation() {
        leaveIntegrations {
            sessionNavNavigation.beginNewConversation()
            fullscreenSurface = .conversation
            inspectorScope = .session
            model.newChat()
            model.requestComposerFocus()
        }
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
        sessionNavNavigation.clearSelection()
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
                sessionNavNavigation.openProjectSession(sessionID: sessionID)
                // Global surfaces (such as Projects) own discovery; after a
                // session is chosen, return the user to the shared chat
                // workspace where that session is visible.
                fullscreenSurface = .conversation
            },
            onOpenBotChat: { bot in openBotsPage(with: bot) },
            onOpenRecentBotSession: openRecentBotSession,
            showsHeader: false,
            showsModePicker: false,
            initialMode: fullscreenGlobalTab,
            agentUpdateService: agentUpdateService,
            integrationsWorkspace: sessionNavNavigation.integrations(
                client: model.controlRPCClient, store: workspaceStore)
        )
    }

    var fullscreenGlobalSurface: some View {
        Group {
            if fullscreenSurface == .chatGrid {
                SessionDashboard(
                    model: model, bots: botMode, control: controlCenter, store: workspaceStore,
                    onNewConversation: {
                        sessionNavNavigation.beginNewConversation()
                        inspectorScope = .session
                        model.newChat()
                        model.requestComposerFocus()
                    },
                    onOpenWorkspace: {
                        sessionNavNavigation.synchronizeActiveSession(model.navigationSessionID)
                        fullscreenSurface = .conversation
                        inspectorScope = .session
                    },
                    onShowList: {
                        sessionNavNavigation.synchronizeActiveSession(model.navigationSessionID)
                        fullscreenSurface = .conversation
                    },
                    onSelectProfile: { profile in
                        botMode.selectProfile(profile)
                        // Apply the scope now so the chat resumes in its own bot.
                        handleProfileScopeChange(botMode.selectedProfileID)
                    }
                ) {
                    chatConversationContent(railWidth: 0)
                }
            } else if fullscreenSurface == .pullRequests || fullscreenSurface == .issues {
                GitHubWorkspace(
                    selection: Binding(
                        get: { () -> GitHubWorkspaceSection in
                            return sessionNavNavigation.selectedGitHubSection
                        },
                        set: { selectGitHubSection($0) })
                ) {
                    if fullscreenSurface == .pullRequests {
                        PullRequestWorkspace(
                            center: pullRequestCenter, projects: controlCenter.projects, onOpenChat: openPullRequestChat
                        )
                        .id("fullscreen-pull-requests")
                    } else {
                        IssueWorkspacePage(
                            center: issueCenter, projects: controlCenter.projects, onOpenChat: openIssueChat
                        )
                        .id("fullscreen-issues")
                    }
                }
                .environment(\.openGitHubItem, openGitHubReference)
                .environment(\.openGitHubRepository, openGitHubRepository)
            } else if fullscreenSurface == .artifacts {
                ArtifactsInspectorView(model: model, presentation: .page) { session in
                    sessionNavNavigation.openSession(session.id)
                    fullscreenSurface = .conversation
                    inspectorScope = .session
                    model.resumeSession(session)
                }
                .id("fullscreen-artifacts")
            } else {
                fullscreenGlobalControlSurface
            }
        }
    }

    func openMarkdownURL(_ url: URL) {
        if url.scheme == "herm-bot-preview" {
            if let id = BotMentions.previewBotID(url), let bot = botMode.botsByID[id] {
                SessionMessageTabs.shared.open(.bot(bot), in: WorkspaceIdentity.session(model))
            }
            return
        }
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

    func selectGitHubSection(_ section: GitHubWorkspaceSection) {
        if section == .repositories {
            sessionNavNavigation.selectGitHubRepositories()
            fullscreenSurface = .pullRequests
        } else if section == .pullRequests {
            sessionNavNavigation.selectPullRequests()
            fullscreenSurface = .pullRequests
        } else {
            sessionNavNavigation.selectIssues()
            fullscreenSurface = .issues
        }
    }

    func openGitHubRepository(_ repository: GitHubRepositoryReference, kind: GitHubItemKind) {
        if kind == .issue {
            issueCenter.browse(repository: repository)
            selectGitHubSection(.issues)
        } else {
            pullRequestCenter.browse(repository: repository)
            selectGitHubSection(.pullRequests)
        }
    }

    func openGitHubReference(_ reference: GitHubItemReference) {
        if reference.kind == .pullRequest {
            selectGitHubSection(.pullRequests)
            Task { await pullRequestCenter.open(reference) }
        } else {
            selectGitHubSection(.issues)
            Task { await issueCenter.open(reference) }
        }
    }

    var botsListPanel: some View {
        BotChatsPage(
            bots: botMode,
            groups: botMode.groupChats,
            activeBotID: model.activeBotProfileID,
            style: DockThemePalette(theme: dockThemeStore.selectedThemeID),
            usesWindowChrome: usesWindowChrome,
            openRoomID: $openGroupRoomID,
            isCollapsed: chatListCollapsed,
            onShowSessions: startNewConversation,
            // Stays on Bots: the rail keeps Bots selected while the chat changes.
            onOpen: { bot in model.resumeBotChat(bot) }
        )
    }

    /// Left side of the conversation toolbar: the bot on the Bots page, else the session title.
    @ViewBuilder
    func toolbarIdentity(style: DockThemePalette) -> some View {
        if fullscreenSurface == .bots, let bot = botMode.botsByID[model.activeBotProfileID ?? ""] {
            HStack(spacing: 8) {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 24)
                Text(bot.name)
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
            }
            .dockPadding(.horizontal, 8)
        } else {
            sessionIdentity(style: style)
        }
    }

    /// The Bots page: every bot's main chat beside the open conversation.
    func openBotsPage(with bot: BotSummary? = nil) {
        sessionNavNavigation.selectBots()
        Task { await botMode.refreshNow(force: true) }
        fullscreenSurface = .bots
        inspectorScope = .session
        if let bot {
            UserDefaults.standard.set(bot.id, forKey: BotChatsOrdering.lastBotKey)
            openGroupRoomID = ""
            model.resumeBotChat(bot)
        }
    }

    func openBotChat(_ bot: BotSummary) {
        let chat = bot.chat ?? BotChatReference(sessionID: BotService.canonicalBotChatTitle, profileID: bot.id)
        sessionNavNavigation.openBotChat(sessionID: chat.sessionID)
        fullscreenSurface = .conversation
        inspectorScope = .session
        model.resumeBotChat(bot)
    }

    func openRecentBotSession(_ bot: BotSummary, recent: BotChatReference) {
        sessionNavNavigation.openSession(recent.sessionID)
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
                sessionNavNavigation.openPullRequestChat(sessionID: linkedSession.id)
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
                sessionNavNavigation.openPullRequestChat(sessionID: model.sessionID)
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
            sessionNavNavigation.openIssueChat(sessionID: sessionID)
            model.draft = context.prompt
            fullscreenSurface = .conversation
            inspectorScope = .session
            model.requestComposerFocus()
        }
    }

    var contextPanel: some View {
        VStack(spacing: 0) {
            if sessionWorkspaceMode.usesContextPreview {
                sessionSurfacePreview
                    .transition(.opacity)
                    .animation(.dockEase(duration: 0.2), value: sessionWorkspaceMode)
            } else {
                if !usesSessionNavLayout && !isNarrowLayout {
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
                                .dockPadding(.horizontal, 8)
                                .frame(height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .accessibilityLabel("Back to chat")
                        Spacer(minLength: 0)
                    }
                    .dockPadding(.horizontal, 8)
                    .dockPadding(.top, 8)
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
                            agentUpdateService: agentUpdateService,
                            integrationsWorkspace: sessionNavNavigation.integrations(
                                client: model.controlRPCClient, store: workspaceStore)
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
                                ? DockWindowChrome.titleRowHeight : conversationMetrics.headerHeight,
                            tabRequest: $sessionInspectorTabRequest
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
                    onSave: { draft, expected in
                        guard self.activeSessionRepositoryScope == explorerSelection.scope else { return false }
                        guard
                            await RepositoryService.saveDocument(
                                path: explorerSelection.scope.repositoryPath, filePath: explorerSelection.document.path,
                                contents: draft, expectedContents: expected)
                        else { return false }
                        await refreshSessionWorkflow()
                        guard self.activeSessionRepositoryScope == explorerSelection.scope else { return true }
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
            Text("WORKSPACE")
                .dockFont(.metadata, weight: .bold)
                .tracking(1.05)
                .foregroundStyle(Color.dockMetadataText)

            Spacer(minLength: 8)

            scopePicker
        }
        .dockPadding(.horizontal, 16)
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

    var sessionWorkspaceIdentity: String {
        WorkspaceIdentity.session(
            profileID: model.sessionProfileID ?? model.profileScopeID, sessionID: model.navigationSessionID)
    }

    var cachedSessionRepositoryPath: String? {
        get {
            cachedSessionRepository?.path(for: sessionWorkspaceIdentity)
        }
        nonmutating set {
            cachedSessionRepository = newValue.map { .init(workspace: sessionWorkspaceIdentity, path: $0) }
        }
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

    /// Branches the shown worktree into a fresh one and moves the draft to a
    /// new chat there, so its agent works beside this one without sharing edits.
    func startWorktreeTask(from path: String) async {
        do {
            let worktree = try await RepositoryService.createTaskWorktree(path: path, id: UUID())
            model.newChatMovingDraft(projectPath: worktree)
        } catch {
            model.reportAttachmentError(HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
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
                usesSessionNavLayout || isNarrowLayout
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
                .accessibilityLabel("Show \(scope.rawValue) workspace")
            }
        }
        .dockPadding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace scope")
    }

    func synchronizeWorkspace(status: HermesStatus? = nil) {
        guard let sessionID = model.sessionID else { return }
        let title =
            model.currentSessionTitle
            ?? model.messages.first(where: { $0.role == .user })?.text
            ?? "Current Herm task"
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

    var header: some View { conversationToolbar(identity: nil, groupActions: nil) }

    /// The conversation toolbar; a group room swaps the name and the session controls for its own.
    func conversationToolbar(identity: AnyView?, groupActions: AnyView?) -> some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        return GeometryReader { geometry in
            let showsInspector = geometry.size.width >= 440
            HStack(spacing: 4) {
                // Leading like a native toolbar title; actions sit at the trailing edge.
                if hidesChatList {
                    DockSidebarToggle(isCollapsed: chatListCollapsed)
                }
                if let identity { identity } else { toolbarIdentity(style: style) }
                Spacer(minLength: 12)
                    .frame(maxHeight: .infinity)
                    .background { if usesWindowChrome { TitlebarDoubleClickArea() } }

                if let groupActions {
                    groupActions
                } else {
                    if sessionWorkspaceMode == .chat, !model.messageNavigatorItems.isEmpty {
                        // Pinned messages open from the "…" menu; the popover anchors here.
                        Color.clear.frame(width: 0, height: 0)
                            .dockPopover(isPresented: $isShowingMessagePins, arrowEdge: .bottom) {
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

                    if sessionWorkspaceMode == .chat,
                        ConversationWorkspaceMetrics.sessionRailWidth(availableWidth: geometry.size.width) > 0
                    {
                        Button {
                            isSessionRailVisible.toggle()
                        } label: {
                            DockIcon(
                                .cardsThree, size: DockLayout.toolbarIconSize,
                                weight: isSessionRailVisible ? .fill : .regular,
                                color: isSessionRailVisible ? style.primaryText : style.secondaryText
                            )
                            .frame(width: DockLayout.iconControlSize, height: DockLayout.iconControlSize)
                            .accessibilityAddTraits(isSessionRailVisible ? .isSelected : [])
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .help(isSessionRailVisible ? "Hide session rail" : "Show session rail")
                        .accessibilityLabel(isSessionRailVisible ? "Hide session rail" : "Show session rail")
                        .accessibilityValue(isSessionRailVisible ? "Shown" : "Hidden")
                    }

                    sessionViewMenu(includesInspector: !showsInspector, style: style)
                        .fixedSize()

                }

                if showsInspector && !inspectorHasOwnToggle {
                    DockSidebarToggle(
                        isCollapsed: !inspectorPanelIsVisible, edge: .trailing, action: toggleInspectorPanel)
                }
            }
            .dockPadding(.leading, hidesChatList && usesWindowChrome ? DockWindowChrome.sidebarToggleLeading : 12)
            .dockPadding(.trailing, 12)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: usesWindowChrome ? DockWindowChrome.titleRowHeight : conversationMetrics.headerHeight)
        .background(usesWindowChrome ? Color.dockSidebar : Color.dockCanvas)
        .overlay(alignment: .bottom) { if usesWindowChrome { DockWindowChrome.titleRowSeparator } }
    }
}
