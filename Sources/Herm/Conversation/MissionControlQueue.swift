import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MissionControlQueue: View {
    private struct QueueTaskGroup: Identifiable {
        let key: String
        let task: WorkspaceTask
        let count: Int
        var id: String { key }
    }

    /// Command-only references. Render state for the rail comes from the
    /// deduplicated sidebar snapshot so streaming publications cannot rebuild
    /// the navigation hierarchy.
    let model: DockModel
    @ObservedObject var botMode: BotModeModel
    let workspaceStore: WorkspaceStore
    let controlCenter: ControlCenterModel
    @ObservedObject var agentUpdateService: HermesUpdateService
    @ObservedObject var navigationState: MissionControlNavigationState
    @ObservedObject var dockThemeStore: DockThemeStore
    @StateObject private var sidebar: MissionControlSidebarModel
    @AppStorage(SidebarVisibilityKey.kanban) private var showsKanban = true
    @AppStorage(SidebarVisibilityKey.pullRequests) private var showsPullRequests = true
    @AppStorage(SidebarVisibilityKey.issues) private var showsIssues = true
    @AppStorage(SidebarVisibilityKey.office) private var showsOffice = true
    @AppStorage(SidebarVisibilityKey.calendar) private var showsCalendar = true
    @Binding var sessionPendingDeletion: HermesSession?
    let activeSessionID: String?
    let activeGlobalTab: ControlTab?
    let isArtifactsActive: Bool
    let isBotsActive: Bool
    let isPullRequestsActive: Bool
    let isIssuesActive: Bool
    let onNewConversation: () -> Void
    let onSelectSession: (HermesSession) -> Void
    let onSelectTask: (WorkspaceTask) -> Void
    let onOpenGlobal: (ControlTab) -> Void
    let onOpenArtifacts: () -> Void
    let onOpenBots: () -> Void
    let onOpenBotChat: (BotSummary, BotChatReference?) -> Void
    let onOpenGroupChat: (String) -> Void
    let onOpenPullRequests: () -> Void
    let onOpenIssues: () -> Void
    let showsFullscreenToggle: Bool
    let isFullscreen: Bool
    let onFullscreenToggle: () -> Void
    let onSelectProfile: (String) -> Void
    let onOpenWindow: (() -> Void)?
    let isDockedWindow: Bool
    let showsWindowTitleRow: Bool
    @Binding var isSidebarCollapsed: Bool
    @State private var isProfileSelectorPresented = false
    @State private var isProfileHovering = false
    @State private var creatingProjectPath: String?
    @State private var isShowingProjectSheet = false
    @State private var isShowingNewGroupChat = false
    @ObservedObject private var sidebarSessionSeenStore = SidebarSessionSeenStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        model: DockModel,
        botMode: BotModeModel,
        workspaceStore: WorkspaceStore,
        controlCenter: ControlCenterModel,
        agentUpdateService: HermesUpdateService,
        navigationState: MissionControlNavigationState,
        dockThemeStore: DockThemeStore,
        sessionPendingDeletion: Binding<HermesSession?>,
        activeSessionID: String?,
        activeGlobalTab: ControlTab?,
        isArtifactsActive: Bool,
        isBotsActive: Bool,
        isPullRequestsActive: Bool,
        isIssuesActive: Bool,
        onNewConversation: @escaping () -> Void,
        onSelectSession: @escaping (HermesSession) -> Void,
        onSelectTask: @escaping (WorkspaceTask) -> Void,
        onOpenGlobal: @escaping (ControlTab) -> Void,
        onOpenArtifacts: @escaping () -> Void,
        onOpenBots: @escaping () -> Void,
        onOpenBotChat: @escaping (BotSummary, BotChatReference?) -> Void,
        onOpenGroupChat: @escaping (String) -> Void,
        onOpenPullRequests: @escaping () -> Void,
        onOpenIssues: @escaping () -> Void,
        showsFullscreenToggle: Bool,
        isFullscreen: Bool,
        onFullscreenToggle: @escaping () -> Void,
        onSelectProfile: @escaping (String) -> Void,
        onOpenWindow: (() -> Void)? = nil,
        isDockedWindow: Bool = false,
        showsWindowTitleRow: Bool = true,
        isSidebarCollapsed: Binding<Bool> = .constant(false)
    ) {
        self.model = model
        self.botMode = botMode
        self.workspaceStore = workspaceStore
        self.controlCenter = controlCenter
        self.agentUpdateService = agentUpdateService
        self.navigationState = navigationState
        self.dockThemeStore = dockThemeStore
        _sidebar = StateObject(
            wrappedValue: MissionControlSidebarModel(model: model, control: controlCenter, store: workspaceStore))
        self._sessionPendingDeletion = sessionPendingDeletion
        self.activeSessionID = activeSessionID
        self.activeGlobalTab = activeGlobalTab
        self.isArtifactsActive = isArtifactsActive
        self.isBotsActive = isBotsActive
        self.isPullRequestsActive = isPullRequestsActive
        self.isIssuesActive = isIssuesActive
        self.onNewConversation = onNewConversation
        self.onSelectSession = onSelectSession
        self.onSelectTask = onSelectTask
        self.onOpenGlobal = onOpenGlobal
        self.onOpenArtifacts = onOpenArtifacts
        self.onOpenBots = onOpenBots
        self.onOpenBotChat = onOpenBotChat
        self.onOpenGroupChat = onOpenGroupChat
        self.onOpenPullRequests = onOpenPullRequests
        self.onOpenIssues = onOpenIssues
        self.showsFullscreenToggle = showsFullscreenToggle
        self.isFullscreen = isFullscreen
        self.onFullscreenToggle = onFullscreenToggle
        self.onSelectProfile = onSelectProfile
        self.onOpenWindow = onOpenWindow
        self.isDockedWindow = isDockedWindow
        self.showsWindowTitleRow = showsWindowTitleRow
        self._isSidebarCollapsed = isSidebarCollapsed
    }

    private var readyTasks: [WorkspaceTask] {
        workspaceStore.tasks.filter { $0.status == .readyForReview || $0.status == .todo }
    }

    private var blockedTasks: [WorkspaceTask] {
        workspaceStore.tasks.filter { $0.status == .awaitingApproval }
    }

    private var sidebarSnapshot: MissionControlSidebarSnapshot {
        sidebar.snapshot
    }

    private var pinnedSessionPresentation: PinnedSessionPresentation {
        PinnedSessionPresentation(
            pinned: sidebarSnapshot.inputs.pinnedSessions,
            live: sidebarSnapshot.conversations,
            projection: sidebarSnapshot.inputs.sessionProjectionState,
            hasRequestedSessionIndex: navigationState.hasRequestedSessionIndex
        )
    }

    private func isPinned(_ session: HermesSession) -> Bool {
        sidebarSnapshot.inputs.pinnedSessions.contains { $0.id == session.id }
    }

    private func togglePin(_ session: HermesSession) {
        Task { await model.toggleSessionPinned(session) }
    }

    private var sidebarSessionStatuses: [String: SidebarSessionStatus] {
        // Pins can sit past the recents page, so they need their own status.
        SidebarSessionStatusResolver.statuses(
            for: sidebarSnapshot.conversations + pinnedSessionPresentation.sessions,
            snapshot: sidebarSnapshot,
            seenStore: sidebarSessionSeenStore,
            fallbackProfileID: model.profileScopeID
        )
    }

    private func markSessionSeen(_ session: HermesSession) {
        sidebarSessionSeenStore.markSeen(
            profileID: session.profileID ?? model.profileScopeID,
            sessionID: session.id,
            at: session.lastUpdatedAt
        )
    }

    private func baselineSidebarSessionsIfAuthoritative() {
        switch sidebarSnapshot.inputs.sessionProjectionState {
        case .ready, .empty:
            sidebarSessionSeenStore.baseline(
                profileID: sidebarSnapshot.inputs.profileScopeID ?? model.profileScopeID,
                sessions: sidebarSnapshot.conversations
            )
        case .loading, .stale, .unavailable, .failed:
            break
        }
    }

    private var readyTaskGroups: [QueueTaskGroup] {
        groupedTasks(readyTasks)
    }

    var body: some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        listPanel(style: style)
            .background(style.sidebarBackground)
            // This queue can move between AppKit split-view hosts as the center
            // destination changes. Loading the index is an initial-popover task,
            // not a navigation side effect; otherwise selecting a project or
            // conversation remounts the rail and reissues a full list refresh.
            .task {
                if ScrollPerformanceFixture.isRequested {
                    let fixture = ScrollPerformanceFixture.standard
                    if let fixtureSession = fixture.sessions.first {
                        model.prepareScrollPerformanceFixtureSession(fixtureSession)
                    }
                    model.sessions = fixture.sessions
                    let scenario = ScrollPerformanceFixture.requestedScenario ?? .idleLongMarkdown
                    model.messages =
                        (scenario == .shortControl || scenario == .streamingLongMarkdown)
                        ? Array(fixture.messages.prefix(6))
                        : fixture.messages
                    controlCenter.installScrollPerformanceFixture(fixture)
                    navigationState.hasRequestedSessionIndex = true
                    DebugLog.writePerformance(
                        "scroll_fixture scenario=\(scenario.rawValue) streaming_bytes=\(fixture.streamingBytes) streaming_cadence_ms=\(fixture.streamingCadenceMilliseconds) activity_visible=0"
                    )
                    if scenario == .streamingLongMarkdown {
                        await fixture.runStreaming(on: model)
                    }
                    return
                }
                guard !navigationState.hasRequestedSessionIndex else { return }
                navigationState.hasRequestedSessionIndex = true
                model.loadSessions()
            }
            .onChange(of: sidebar.snapshot.inputs.sessionProjectionState) { _, _ in
                baselineSidebarSessionsIfAuthoritative()
            }
            .onChange(of: sidebar.snapshot.inputs.activeSessionID) { _, _ in
                if let id = sidebar.snapshot.inputs.activeSessionID,
                    let session = sidebar.snapshot.conversations.first(where: { $0.id == id })
                {
                    markSessionSeen(session)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hermes control queue")
    }

    /// Secondary panel: identity, new conversation, and the session lists.
    private func listPanel(style: DockThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The session list owns its title strip beside the conversation and inspector.
            if isDockedWindow && showsWindowTitleRow {
                HStack(spacing: 0) {
                    DockSidebarToggle(isCollapsed: $isSidebarCollapsed)
                    Spacer(minLength: 0)
                }
                .padding(.leading, DockWindowChrome.sidebarToggleLeading)
                .frame(height: DockWindowChrome.titleRowHeight)
                .background { TitlebarDoubleClickArea() }
                .background(style.sidebarBackground)
            }
            // Header: identity plus the primary action. Window chrome lives in the footer.
            HStack(spacing: 2) {
                profileHeader(style: style)
                DockIconButton(
                    icon: .notePencil,
                    label: "New conversation",
                    isProminent: true,
                    style: style,
                    action: onNewConversation
                )
                .padding(.leading, 2)
            }
            .padding(.horizontal, 6)
            .frame(height: 56)
            .overlay(alignment: .bottomLeading) {
                if !botMode.activityBanner.isEmpty {
                    BotActivityBanner(events: botMode.activityBanner)
                        .padding(.horizontal, 8)
                        .offset(y: 38)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: botMode.activityBanner)
            .zIndex(1)

            HoverPausingScrollView {
                globalRailBar(style: style)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }
        }
        .background(style.sidebarBackground)
        .frame(maxWidth: .infinity)
    }

    private func projectDisplayName(_ rawName: String) -> String {
        let name = URL(fileURLWithPath: rawName).lastPathComponent
        return name.isEmpty ? rawName : name
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .dockSuccess
        case .working: .dockAccent
        case .needsApproval, .needsClarification: .dockWarning
        case .offline: .dockDestructive
        }
    }

    private var selectedBot: BotSummary? {
        let visible = botMode.bots.filter { !$0.isHidden }
        if let id = botMode.selectedProfileID,
            let selected = visible.first(where: { $0.id == id })
        {
            return selected
        }
        return visible.first(where: \.isDefault) ?? visible.first
    }

    private var visibleBots: [BotSummary] { botMode.bots.filter { !$0.isHidden } }

    /// Projects belong to the primary Hermes profile. Keep the legacy
    /// single-profile/unsupported behavior intact, but do not expose project
    /// navigation while another visible Bot is selected.
    private var showsProjectsForSelectedBot: Bool {
        visibleBots.count <= 1 || selectedBot?.isDefault == true
    }

    private func profileHeader(style: DockThemePalette) -> some View {
        let bot = selectedBot
        let name = bot?.name ?? sidebarSnapshot.inputs.agentDisplayName
        let subtitle = bot?.title
        let label = subtitle.map { "\(name) — \($0)" } ?? name
        let isSwitchable = visibleBots.count > 1
        let identity = HStack(spacing: 9) {
            if let bot {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 28)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).fill(
                        style.selectedFill)
                    DockIcon(.ghost, size: 15, color: style.secondaryText)
                }
                .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .dockFont(.navigation, weight: .semibold)
                    .foregroundStyle(style.theme == .hermesClassic ? style.accent : style.primaryText)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .dockFont(.metadata)
                        .foregroundStyle(style.metadataText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isSwitchable {
                // Other Bots' activity, so it is visible without opening the switcher.
                botActivityBadge(for: visibleBots.filter { $0.id != bot?.id }, style: style)
                DockIcon(.caretUpDown, size: 12, color: style.metadataText)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                .fill(
                    isSwitchable && (isProfileHovering || isProfileSelectorPresented)
                        ? style.surface4.opacity(0.6) : .clear)
        )
        .contentShape(Rectangle())

        return Group {
            if isSwitchable {
                Button {
                    isProfileSelectorPresented.toggle()
                } label: {
                    identity
                }
                .buttonStyle(.dockHover)
                .onHover { isProfileHovering = $0 }
                .popover(isPresented: $isProfileSelectorPresented, arrowEdge: .top) {
                    profileSelectorPopover(selectedBot: bot, style: style)
                }
                .help("Switch Bot")
                .accessibilityLabel("Select Bot, currently \(label)")
            } else {
                identity.accessibilityLabel("Current Bot: \(label)")
            }
        }
    }

    /// Spinner + count while Bots are working, green check + count once a Bot
    /// has finished with activity you have not looked at yet.
    @ViewBuilder
    private func botActivityBadge(for bots: [BotSummary], style: DockThemePalette) -> some View {
        // Working is time-based (heartbeat age), so re-evaluate on a slow
        // local tick; the roster itself republishes only when it changes.
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            let workingBots = bots.filter { $0.isWorkingNow || $0.isRecentlyActive }
            let doneBots = bots.filter { !($0.isWorkingNow || $0.isRecentlyActive) && botMode.hasUnread($0) }
            let working = workingBots.count
            let done = doneBots.count
            let summary = (workingBots.map { "\($0.name) is running" } + doneBots.map { "\($0.name) is done" }).joined(
                separator: "\n")
            HStack(spacing: 6) {
                if working > 0 {
                    HStack(spacing: 4) {
                        DockActivityIndicator(state: .running, size: 12)
                        if bots.count > 1 { Text("\(working)").dockFont(.compactStatus, weight: .bold) }
                    }
                    .foregroundStyle(DockActivityState.running.color)
                }
                if done > 0 {
                    HStack(spacing: 3) {
                        DockActivityIndicator(state: .done, size: 12, unreadDot: true)
                        if bots.count > 1 { Text("\(done)").dockFont(.compactStatus, weight: .bold) }
                    }
                    .foregroundStyle(DockActivityState.done.color)
                }
            }
            .help(summary)
            .accessibilityLabel(summary.replacingOccurrences(of: "\n", with: ", "))
        }
    }

    private func profileSelectorPopover(selectedBot: BotSummary?, style: DockThemePalette) -> some View {
        let popoverHeight = min(CGFloat(visibleBots.count) * 40 + 12, 360)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(visibleBots) { option in
                    Button {
                        onSelectProfile(option.id)
                        isProfileSelectorPresented = false
                    } label: {
                        HStack(spacing: 9) {
                            BotAvatarView(
                                bot: option,
                                imageData: botMode.avatarImages[option.id],
                                size: 22
                            )
                            Text(option.title.map { "\(option.name) — \($0)" } ?? option.name)
                                .dockFont(.body, weight: .semibold)
                                .foregroundStyle(style.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            botActivityBadge(for: [option], style: style)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // The spinner doubles as "view the running session".
                                    guard let worker = option.liveWorkerChat else {
                                        onSelectProfile(option.id)
                                        isProfileSelectorPresented = false
                                        return
                                    }
                                    onSelectProfile(option.id)
                                    onOpenBotChat(option, worker)
                                    isProfileSelectorPresented = false
                                }
                            if option.id == selectedBot?.id {
                                DockIcon(.check)
                                    .dockFont(.metadata, weight: .semibold)
                                    .foregroundStyle(style.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .accessibilityLabel(
                        option.id == selectedBot?.id
                            ? "\(option.name), selected"
                            : "Select \(option.name)"
                    )
                }
            }
            .padding(6)
        }
        .frame(width: 300, height: popoverHeight)
        .background(style.background)
    }

    /// A one-line horizontal rail keeps global navigation compact and makes
    /// selection independent from every neighbouring destination.
    private func globalRailBar(style: DockThemePalette) -> some View {
        let projects = sidebarSnapshot.linkedProjectGroups
        let allConversations = botScopedConversations(sidebarSnapshot.conversations)
        // Built once per pass; rows previously rebuilt it per row (O(n²)).
        let statuses = sidebarSessionStatuses

        // One flat LazyVStack: sections below emit their rows as direct
        // children. Nested lazy stacks inside eager VStacks are not lazy, so
        // every conversation and project row was built on each layout pass.
        return LazyVStack(alignment: .leading, spacing: 0) {
            let pinned = pinnedSessionPresentation
            if pinned.status != .empty || !pinned.sessions.isEmpty {
                pinnedOutline(pinned, statuses: statuses, style: style)
            }

            GroupChatSidebarSection(
                store: botMode.groupChats,
                botMode: botMode,
                selectedRoomID: {
                    if case .groupChat(let id) = navigationState.selection.selection { return id }
                    return nil
                }(),
                style: style,
                onOpen: onOpenGroupChat,
                onCreate: { isShowingNewGroupChat = true }
            )

            conversationOutline(allConversations, statuses: statuses, style: style)

            if showsProjectsForSelectedBot {
                MissionControlProjectList(
                    groups: projects,
                    selectedSessionID: navigationState.selectedProjectSessionID,
                    activeSessionID: sidebarSnapshot.inputs.activeSessionID,
                    attentionDots: sidebarSnapshot.attentionDots,
                    sessionStatuses: statuses,
                    isLoadingProjects: sidebarSnapshot.inputs.isLoadingProjects,
                    isRefreshing: sidebarSnapshot.inputs.isRefreshingProjectNavigation,
                    isCreatingChat: sidebarSnapshot.inputs.isCreatingSession,
                    style: style,
                    isPinned: isPinned,
                    onTogglePin: togglePin,
                    onRename: { session, title in
                        let succeeded = await model.renameSession(session, title: title)
                        if succeeded { controlCenter.refreshProjectNavigation() }
                        return succeeded
                    },
                    onToggleHidden: { session, hidden in
                        let succeeded = await model.setSessionHidden(session, hidden: hidden)
                        if succeeded {
                            controlCenter.refreshProjectNavigation()
                        }
                        return succeeded
                    },
                    onRequestDelete: { session in sessionPendingDeletion = session },
                    deletingSessionID: sidebarSnapshot.inputs.deletingSessionID,
                    updatingSessionVisibilityID: sidebarSnapshot.inputs.updatingSessionVisibilityID,
                    renamingSessionID: sidebarSnapshot.inputs.renamingSessionID,
                    creatingProjectPath: creatingProjectPath,
                    onSelectSession: { session in
                        markSessionSeen(session)
                        navigationState.selectSession(session.id)
                        onSelectSession(session)
                    },
                    onRefresh: {
                        controlCenter.refreshProjectNavigation()
                    },
                    onAddProject: { isShowingProjectSheet = true },
                    onArchiveProject: { id in
                        guard let project = controlCenter.projects.first(where: { $0.id == id }) else { return }
                        Task { _ = await controlCenter.archiveProject(project) }
                    },
                    onAddSourceFolder: { id, folder in
                        guard let project = controlCenter.projects.first(where: { $0.id == id }) else { return }
                        Task { _ = await controlCenter.addProjectFolder(project, folder: folder) }
                    },
                    onNewChatInProject: startNewChat(inProject:),
                    pinningSessionID: sidebarSnapshot.inputs.pinningSessionID
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // ponytail: 10s roster poll while the rail is on screen (cancelled
            // on disappear); Hermes has no roster push event.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await botMode.refreshNow()
            }
        }
        .sheet(isPresented: $isShowingNewGroupChat) {
            NewGroupChatSheet(
                store: botMode.groupChats, bots: botMode.bots.filter { !$0.isHidden }, onCreated: onOpenGroupChat)
        }
        .sheet(isPresented: $isShowingProjectSheet) {
            ProjectFolderSheet(
                // The rail hides sessionless projects, so a new project opens
                // straight into its first chat instead of vanishing.
                onCreate: { name, folder in
                    // Hermes rejects a second project for the same folder; open a chat in the existing one instead.
                    var created = controlCenter.projects.contains { $0.name == folder }
                    if !created {
                        created = await controlCenter.createProject(name: name, folder: folder)
                        if !created, controlCenter.lastError?.contains("already belongs to project") == true {
                            created = true
                        }
                    }
                    if created { startNewChat(inProject: folder) }
                    return created
                },
                failureReason: { controlCenter.lastError }
            )
        }
    }

    /// Hermes renders Bots beside Sessions in the left sidebar and opens the
    /// roster as its own page; the Dock keeps the same sibling placement.
    private func startNewChat(inProject projectPath: String) {
        creatingProjectPath = projectPath
        navigationState.beginProjectChat()
        Task {
            await model.startNewChat(in: projectPath)
            creatingProjectPath = nil
            if let createdID = model.sessionID {
                navigationState.beginProjectChat(sessionID: createdID)
            }
            model.loadSessions()
            controlCenter.refreshProjectNavigation()
            model.requestComposerFocus()
        }
    }

    private func queueEmpty(_ text: String, style: DockThemePalette) -> some View {
        Text(text)
            .dockFont(.body)
            .foregroundStyle(style.metadataText)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
    }

    @ViewBuilder
    private func queueOverflowButton(total: Int, visible: Int, title: String, action: @escaping () -> Void) -> some View
    {
        if total > visible {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text("Showing \(visible) of \(compactCount(total))")
                    Text(title)
                }
                .dockFont(.control)
                .foregroundStyle(Color.dockAccent)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockLink)
        }
    }

    private func conversationExpansionButton(style: DockThemePalette) -> some View {
        Button {
            navigationState.showsAllConversations.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(navigationState.showsAllConversations ? "Show recent conversations" : "Show more conversations")
                DockIcon(navigationState.showsAllConversations ? .caretUp : .caretDown)
                    .dockFont(size: 9, weight: .bold)
            }
            .dockFont(.control)
            .foregroundStyle(style.secondaryText)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockLink)
    }

    /// Recents follow the selected Bot: another Bot's chat (kept in the model
    /// while it is open) must not leak into this Bot's list.
    private func botScopedConversations(_ base: [HermesSession]) -> [HermesSession] {
        guard base.contains(where: { $0.source == "hermes-bot" }) else { return base }
        let selectedID = selectedBot?.id
        return base.filter { session in
            guard session.source == "hermes-bot" else { return true }
            return botForSession(session)?.id == selectedID
        }
    }

    private func botForSession(_ session: HermesSession) -> BotSummary? {
        guard session.source == "hermes-bot" else { return nil }
        return visibleBots.first { $0.id == session.profileID } ?? visibleBots.first { $0.name == session.title }
    }

    @ViewBuilder
    private func conversationSessionRow(
        _ session: HermesSession, statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        if let bot = botForSession(session) {
            MissionControlBotSessionRow(
                session: session,
                bot: bot,
                imageData: botMode.avatarImages[bot.id],
                isSelected: isSessionSelected(session),
                mood: BotMood(ask: statuses[session.id]?.activityState),
                style: style
            ) {
                markSessionSeen(session)
                onOpenBotChat(bot, bot.chat?.sessionID == session.id ? nil : bot.recentSession)
            }
            .equatable()
        } else {
            plainConversationSessionRow(session, statuses: statuses, style: style)
        }
    }

    private func plainConversationSessionRow(
        _ session: HermesSession, statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        MissionControlSidebarSessionRow(
            session: session,
            selectedSessionID: isSessionSelected(session) ? session.id : nil,
            sessionStatus: statuses[session.id] ?? .none,
            style: style,
            repositoryName: sidebarSnapshot.projectNameBySessionID[session.id],
            isPinned: isPinned(session),
            isActive: session.id == activeSessionID,
            isDeleting: sidebarSnapshot.inputs.deletingSessionID == session.id,
            isUpdatingVisibility: sidebarSnapshot.inputs.updatingSessionVisibilityID == session.id,
            isRenaming: sidebarSnapshot.inputs.renamingSessionID == session.id,
            onSelect: { selected in
                markSessionSeen(selected)
                navigationState.selectSession(selected.id)
                onSelectSession(selected)
            },
            onTogglePin: togglePin,
            onRename: { selected, title in
                let succeeded = await model.renameSession(selected, title: title)
                if succeeded { controlCenter.refreshProjectNavigation() }
                return succeeded
            },
            onToggleHidden: { selected, hidden in
                let succeeded = await model.setSessionHidden(selected, hidden: hidden)
                if succeeded { controlCenter.refreshProjectNavigation() }
                return succeeded
            },
            onRequestDelete: { selected in
                sessionPendingDeletion = selected
            },
            isPinning: sidebarSnapshot.inputs.pinningSessionID == session.id,
            projectTargets: sidebarSnapshot.projectNameBySessionID[session.id] == nil
                ? sidebarSnapshot.projectTargets : [],
            onAddToProject: { selected, target in
                workspaceStore.ensureTask(title: selected.displayTitle, sessionID: selected.id)
                workspaceStore.attachProject(at: target.path, toSessionID: selected.id)
            }
        )
        .equatable()
    }

    /// Emits header and rows as siblings so the rail's LazyVStack owns them.
    @ViewBuilder
    private func pinnedOutline(
        _ pinned: PinnedSessionPresentation, statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        DockSectionHeader(
            title: "Pinned",
            count: pinned.count,
            isExpanded: $navigationState.arePinnedExpanded,
            style: style
        )
        .padding(.top, style.sectionSpacing)
        .padding(.bottom, navigationState.arePinnedExpanded ? 2 : 0)

        if navigationState.arePinnedExpanded {
            if pinned.sessions.isEmpty {
                queueEmpty(pinnedStatusText(pinned.status), style: style)
                    .padding(.leading, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(pinned.sessions, id: \.[sidebarSection: "pinned"]) { session in
                    pinnedSessionRow(session, statuses: statuses, style: style)
                }
            }
        }
    }

    private func pinnedStatusText(_ status: PinnedSessionPresentationStatus) -> String {
        switch status {
        case .loading: "Loading pinned conversations…"
        case .stale(let message), .unavailable(let message), .failed(let message): message
        case .ready, .empty: "No pinned conversations"
        }
    }

    private func pinnedSessionRow(
        _ session: HermesSession, statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        MissionControlSidebarSessionRow(
            session: session,
            selectedSessionID: isSessionSelected(session) ? session.id : nil,
            sessionStatus: statuses[session.id] ?? .none,
            style: style,
            repositoryName: sidebarSnapshot.projectNameBySessionID[session.id],
            isPinned: true,
            isActive: session.id == activeSessionID,
            isDeleting: sidebarSnapshot.inputs.deletingSessionID == session.id,
            isUpdatingVisibility: sidebarSnapshot.inputs.updatingSessionVisibilityID == session.id,
            isRenaming: sidebarSnapshot.inputs.renamingSessionID == session.id,
            onSelect: { selected in
                markSessionSeen(selected)
                navigationState.selectSession(selected.id)
                onSelectSession(selected)
            },
            onTogglePin: togglePin,
            onRename: { selected, title in
                let succeeded = await model.renameSession(selected, title: title)
                if succeeded { controlCenter.refreshProjectNavigation() }
                return succeeded
            },
            onToggleHidden: { selected, hidden in
                let succeeded = await model.setSessionHidden(selected, hidden: hidden)
                if succeeded { controlCenter.refreshProjectNavigation() }
                return succeeded
            },
            onRequestDelete: { sessionPendingDeletion = $0 },
            isPinning: sidebarSnapshot.inputs.pinningSessionID == session.id
        )
        .equatable()
    }

    /// Emits header and rows as siblings so the rail's LazyVStack owns them.
    @ViewBuilder
    private func conversationOutline(
        _ conversations: [HermesSession], statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        DockSectionHeader(
            title: "Recents",
            count: conversations.count,
            isExpanded: $navigationState.areConversationsExpanded,
            style: style
        ) {
            DockIconButton(
                icon: .arrowsClockwise,
                label: sidebarSnapshot.inputs.isLoadingSessions ? "Refreshing conversations…" : "Refresh conversations",
                isBusy: sidebarSnapshot.inputs.isLoadingSessions,
                size: 24,
                style: style
            ) {
                model.loadSessions()
                controlCenter.refreshProjectNavigation()
            }
        }
        .padding(.top, style.sectionSpacing)
        .padding(.bottom, navigationState.areConversationsExpanded ? 2 : 0)
        .contextMenu {
            Button("Mark all as read") {
                model.markSessionsRead(conversations, seenStore: sidebarSessionSeenStore)
            }
            .disabled(!conversations.contains { statuses[$0.id] == .unreadComplete })
        }

        if navigationState.areConversationsExpanded {
            if conversations.isEmpty {
                queueEmpty(
                    sidebarSnapshot.inputs.isLoadingSessions ? "Loading conversations…" : "No saved conversations",
                    style: style
                )
                .padding(.leading, 20)
            } else {
                let visibleSessions =
                    navigationState.showsAllConversations
                    ? conversations
                    : Array(conversations.prefix(10))
                ForEach(visibleSessions, id: \.[sidebarSection: "conversations"]) { session in
                    conversationSessionRow(session, statuses: statuses, style: style)
                }
            }
            if conversations.count > 10 {
                conversationExpansionButton(style: style)
                    .padding(.leading, 12)
            }
        }
    }

    private func taskRow(_ task: WorkspaceTask, duplicateCount: Int = 1) -> some View {
        Button {
            navigationState.selectTask(task.id)
            onSelectTask(task)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(taskColor(task.status))
                        .frame(width: 6, height: 6)
                    Text(taskDisplayTitle(task))
                        .dockFont(.body, weight: .medium)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if duplicateCount > 1 {
                        Text("×\(duplicateCount)")
                            .dockFont(.metadata, weight: .semibold)
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                if let detail = taskDisplayDetail(task) {
                    Text(detail)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isTaskSelected(task) ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        }
        .buttonStyle(.dockHover)
        .help(task.sessionID == nil ? "Open this task in Kanban" : "Open task conversation")
    }

    private func sessionRow(_ session: HermesSession, style: DockThemePalette) -> some View {
        let controls = MissionControlConversationSessionRow.controls(
            togglePin: { togglePin(session) },
            onSelect: {
                PinnedSessionRowInteraction.select(
                    session.id,
                    selectedSessionID: &navigationState.selectedSessionID
                )
                navigationState.selectSession(session.id)
                onSelectSession(session)
            }
        )

        return MissionControlConversationSessionRow(
            session: session,
            isSelected: isSessionSelected(session),
            isProjectLinked: sidebarSnapshot.linkedSessionIDs.contains(session.id),
            projectName: sidebarSnapshot.projectNameBySessionID[session.id],
            attentionDot: sidebarSnapshot.attentionDots[session.id],
            isPinned: isPinned(session),
            style: style,
            onSelect: controls.select,
            onTogglePin: controls.togglePin
        )
        .equatable()
    }

    private func taskColor(_ status: WorkspaceTaskStatus) -> Color {
        switch status {
        case .todo: .dockSecondaryText
        case .inProgress: .dockAccent
        case .awaitingApproval: .dockWarning
        case .readyForReview: .dockSuccess
        case .done: .dockMetadataText
        }
    }

    private func isTaskSelected(_ task: WorkspaceTask) -> Bool {
        guard activeGlobalTab == nil, !isArtifactsActive else { return false }
        return navigationState.selection.isTaskSelected(task.id)
    }

    private func isSessionSelected(_ session: HermesSession) -> Bool {
        guard activeGlobalTab == nil, !isArtifactsActive else { return false }
        return navigationState.selection.isSessionSelected(session.id)
    }

    private func taskDisplayTitle(_ task: WorkspaceTask) -> String {
        guard task.title == "Untitled chat",
            let sessionID = task.sessionID,
            let session = model.sessions.first(where: { $0.id == sessionID })
        else { return task.title }
        return session.displayTitle
    }

    private func taskDisplayDetail(_ task: WorkspaceTask) -> String? {
        if !task.summary.isEmpty { return task.summary }
        guard let sessionID = task.sessionID,
            let session = model.sessions.first(where: { $0.id == sessionID })
        else { return nil }
        return session.displayPreview
    }

    private func compactCount(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private func groupedTasks(_ tasks: [WorkspaceTask]) -> [QueueTaskGroup] {
        var groups: [QueueTaskGroup] = []
        var indexes: [String: Int] = [:]
        for task in tasks {
            let normalizedTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Session-linked tasks represent distinct conversations. Unlinked
            // tasks with the same title are grouped to prevent a stale or
            // repeated projection from filling the entire navigation rail.
            let key = task.sessionID.map { "session:\($0)" } ?? "title:\(normalizedTitle)"
            if let index = indexes[key] {
                let existing = groups[index]
                groups[index] = QueueTaskGroup(key: existing.key, task: existing.task, count: existing.count + 1)
            } else {
                indexes[key] = groups.count
                groups.append(QueueTaskGroup(key: key, task: task, count: 1))
            }
        }
        return groups
    }
}
