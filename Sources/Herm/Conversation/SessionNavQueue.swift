import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SessionNavQueue: View, Equatable {
    /// Command-only references. Render state for the rail comes from the
    /// deduplicated sidebar snapshot so streaming publications cannot rebuild
    /// the navigation hierarchy.
    let model: DockModel
    @ObservedObject var botMode: BotModeModel
    let workspaceStore: WorkspaceStore
    let controlCenter: ControlCenterModel
    @ObservedObject var agentUpdateService: HermesUpdateService
    @ObservedObject var navigationState: SessionNavigationState
    @ObservedObject var dockThemeStore: DockThemeStore
    @ObservedObject private var sessionPanes = SessionPaneStore.shared
    @StateObject private var sidebar: SessionNavSidebarModel
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
    let onOpenPullRequests: () -> Void
    let onOpenIssues: () -> Void
    let onOpenTiles: (() -> Void)?
    let onShowBots: (() -> Void)?
    let showsFullscreenToggle: Bool
    let isFullscreen: Bool
    let onFullscreenToggle: () -> Void
    let onSelectProfile: (String) -> Void
    let onOpenWindow: (() -> Void)?
    let isDockedWindow: Bool
    let showsWindowTitleRow: Bool
    @Binding var isSidebarCollapsed: Bool
    @State private var sessionSearchQuery = ""
    @State private var isProfileSelectorPresented = false
    @State private var isProfileHovering = false
    @State private var creatingProjectPath: String?
    @State private var isShowingProjectSheet = false
    @ObservedObject private var sidebarSessionSeenStore = SidebarSessionSeenStore.shared
    @State private var botUnreadCounts: [String: Int] = [:]
    @State private var botUnreadIncomplete = true

    private struct BotUnreadRequest: Hashable {
        let sessions: [String]
        let seen: [String]
        let incomplete: Bool
    }

    private var botUnreadRequest: BotUnreadRequest {
        let sessions = SessionDashboardProjection.sessions(in: sidebarSnapshot)
        let incomplete: Bool
        switch sidebarSnapshot.inputs.allBotSessionsState {
        case .ready(let rows): incomplete = rows.count >= DockModel.allBotSessionsLimit
        case .empty: incomplete = false
        case .loading, .stale, .unavailable, .failed: incomplete = true
        }
        return BotUnreadRequest(
            sessions: sessions.map {
                "\($0.profileID ?? model.profileScopeID ?? "")|\($0.id)|\($0.lastUpdatedAt?.timeIntervalSince1970 ?? 0)|\($0.isHidden)"
            }.sorted(),
            seen: sidebarSessionSeenStore.seenAtByKey.map { "\($0.key)|\($0.value.timeIntervalSince1970)" }.sorted(),
            incomplete: incomplete)
    }

    private func refreshBotUnreadCounts(_ request: BotUnreadRequest) async {
        botUnreadCounts = [:]
        botUnreadIncomplete = true
        let sessions = SessionDashboardProjection.sessions(in: sidebarSnapshot)
        guard
            let result = try? await model.sessionUnreadReplies.botCounts(
                sessions: sessions, scopeProfileID: model.profileScopeID,
                seenStore: sidebarSessionSeenStore, incomplete: request.incomplete)
        else { return }
        guard !Task.isCancelled, request == botUnreadRequest else { return }
        botUnreadCounts = result.counts
        botUnreadIncomplete = result.incomplete
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @Environment(\.dockHostVisible) private var hostVisible

    init(
        model: DockModel,
        botMode: BotModeModel,
        workspaceStore: WorkspaceStore,
        controlCenter: ControlCenterModel,
        agentUpdateService: HermesUpdateService,
        navigationState: SessionNavigationState,
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
        onOpenPullRequests: @escaping () -> Void,
        onOpenIssues: @escaping () -> Void,
        onOpenTiles: (() -> Void)? = nil,
        onShowBots: (() -> Void)? = nil,
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
            wrappedValue: SessionNavSidebarModel(model: model, control: controlCenter, store: workspaceStore))
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
        self.onOpenPullRequests = onOpenPullRequests
        self.onOpenIssues = onOpenIssues
        self.onOpenTiles = onOpenTiles
        self.onShowBots = onShowBots
        self.showsFullscreenToggle = showsFullscreenToggle
        self.isFullscreen = isFullscreen
        self.onFullscreenToggle = onFullscreenToggle
        self.onSelectProfile = onSelectProfile
        self.onOpenWindow = onOpenWindow
        self.isDockedWindow = isDockedWindow
        self.showsWindowTitleRow = showsWindowTitleRow
        self._isSidebarCollapsed = isSidebarCollapsed
    }

    /// The host re-renders on every DockModel publication, and closures are
    /// never equal, so compare only rendered values. The rail's own observed
    /// objects and sidebar snapshot still drive its updates.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.activeSessionID == rhs.activeSessionID
                && lhs.activeGlobalTab == rhs.activeGlobalTab
                && lhs.isArtifactsActive == rhs.isArtifactsActive
                && lhs.isBotsActive == rhs.isBotsActive
                && lhs.isPullRequestsActive == rhs.isPullRequestsActive
                && lhs.isIssuesActive == rhs.isIssuesActive
                && lhs.showsFullscreenToggle == rhs.showsFullscreenToggle
                && lhs.isFullscreen == rhs.isFullscreen
                && lhs.isDockedWindow == rhs.isDockedWindow
                && lhs.showsWindowTitleRow == rhs.showsWindowTitleRow
                && lhs.isSidebarCollapsed == rhs.isSidebarCollapsed
                && (lhs.onOpenTiles == nil) == (rhs.onOpenTiles == nil)
                && (lhs.onShowBots == nil) == (rhs.onShowBots == nil)
                && (lhs.onOpenWindow == nil) == (rhs.onOpenWindow == nil)
        }
    }

    private var sidebarSnapshot: SessionNavSidebarSnapshot {
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
            for: sidebarSnapshot.allBotConversations + pinnedSessionPresentation.sessions,
            snapshot: sidebarSnapshot,
            seenStore: sidebarSessionSeenStore,
            fallbackProfileID: model.profileScopeID
        )
    }

    /// Opens a chat from any bot. Another bot's chat switches the profile
    /// first, synchronously, so the scope change cannot replace the resume.
    private func openSession(_ session: HermesSession) {
        if let profileID = session.profileID, profileID != model.profileScopeID,
            visibleBots.contains(where: { $0.id == profileID })
        {
            onSelectProfile(profileID)
        }
        navigationState.selectSession(session.id)
        onSelectSession(session)
    }

    /// Other bots' history is baselined from the all-bot scan, once per
    /// profile, so first use does not mark every old chat unread. The
    /// selected profile keeps its own baseline from its complete list.
    private func baselineOtherBotSessions() {
        guard case .ready = sidebarSnapshot.inputs.allBotSessionsState else { return }
        let scope = sidebarSnapshot.inputs.profileScopeID
        let byProfile = Dictionary(grouping: sidebarSnapshot.allBotConversations) { $0.profileID }
        for (profileID, sessions) in byProfile where profileID != nil && profileID != scope {
            sidebarSessionSeenStore.baseline(profileID: profileID, sessions: sessions)
        }
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

    var body: some View {
        let _ = HermPerformanceRecorder.countBody("SessionNavQueue")
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        listPanel(style: style)
            .dockShellPane()
            .task(id: botUnreadRequest) {
                await refreshBotUnreadCounts(botUnreadRequest)
            }
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
            .onChange(of: sidebar.snapshot.inputs.allBotSessionsState) { _, _ in
                baselineOtherBotSessions()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Herm control queue")
    }

    @ViewBuilder
    private func botsSwitchButton(style: DockThemePalette) -> some View {
        if let onShowBots {
            DockChatsScopeSwitch(showsBots: false, onShowSessions: {}, onShowBots: onShowBots)
        }
    }

    @ViewBuilder
    private func tilesButton(style: DockThemePalette) -> some View {
        if let onOpenTiles {
            Button(action: onOpenTiles) {
                DockIcon(.squaresFour, size: DockLayout.toolbarIconSize, color: style.secondaryText)
                    .frame(width: DockLayout.iconControlSize, height: DockLayout.iconControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help("Show all chats as tiles")
            .accessibilityLabel("Chat tiles")
        }
    }

    /// Secondary panel: identity, new conversation, and the session lists.
    private func listPanel(style: DockThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The session list owns its title strip beside the conversation and inspector.
            if isDockedWindow && showsWindowTitleRow {
                HStack(spacing: 0) {
                    DockBuildBadgeSlot()
                        .dockPadding(.trailing, HermBuildInfo.current.badge() == nil ? 0 : 8)
                    DockSidebarToggle(isCollapsed: $isSidebarCollapsed)
                    DockHistoryButtons()
                    Spacer(minLength: 0)
                        .frame(maxHeight: .infinity)
                        .background { TitlebarDoubleClickArea() }
                    tilesButton(style: style)
                }
                .dockPadding(.leading, DockWindowChrome.sidebarToggleLeading)
                .dockPadding(.trailing, 8)
                .frame(height: DockWindowChrome.titleRowHeight)
                .dockShellChrome()
            }
            botsSwitchButton(style: style)
                .dockPadding(.horizontal, 12)
                .dockPadding(.top, 8)
            // Header: identity. Window chrome lives in the footer.
            HStack(spacing: 2) {
                if !isDockedWindow {
                    DockSidebarToggle(isCollapsed: $isSidebarCollapsed)
                    tilesButton(style: style)
                }
                profileHeader(style: style)
            }
            .dockPadding(.horizontal, 6)
            .frame(height: DockWorkspaceScale.spacing(56, scale: workspaceScale))
            .overlay(alignment: .bottomLeading) {
                if !botMode.activityBanner.isEmpty {
                    BotActivityBanner(events: botMode.activityBanner)
                        .dockPadding(.horizontal, 8)
                        .offset(y: 38)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: botMode.activityBanner)
            .zIndex(1)

            HStack(spacing: 6) {
                sessionSearchField
                DockIconButton(icon: .notePencil, label: "New chat", style: style, action: onNewConversation)
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.bottom, 2)

            HoverPausingScrollView {
                globalRailBar(style: style)
                    .dockButtonSize(.standard)
                    .dockPadding(.horizontal, 6)
                    .dockPadding(.bottom, 8)
            }
            .coordinateSpace(name: SessionSidebarStickyBackground.coordinateSpace)
        }
        .dockShellPane()
        .frame(maxWidth: .infinity)
    }

    private func projectDisplayName(_ rawName: String) -> String {
        let name = URL(fileURLWithPath: rawName).lastPathComponent
        return name.isEmpty ? rawName : name
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
            if let bot, botMode.isAvatarPending(bot) {
                // Startup: the avatar is still loading, so hold its slot instead of a stand-in face.
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    .accessibilityLabel("Loading \(bot.name)'s avatar")
            } else if let bot {
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
        .dockPadding(.horizontal, 6)
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
                .dockPopover(isPresented: $isProfileSelectorPresented, arrowEdge: .top) {
                    profileSelectorPopover(selectedBot: bot, style: style)
                }
                .help("Switch Bot")
                .accessibilityLabel("Select Bot, currently \(label)")
            } else {
                identity.accessibilityLabel("Current Bot: \(label)")
            }
        }
    }

    /// Running activity and unread sessions are independent signals.
    @ViewBuilder
    private func botActivityBadge(for bots: [BotSummary], style: DockThemePalette) -> some View {
        // Working is time-based (heartbeat age), so re-evaluate on a slow
        // local tick; the roster itself republishes only when it changes.
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            // Sessions only: main-chat work shows on the Bots page instead.
            let workingBots = bots.filter(\.isSessionWorking)
            let working = workingBots.count
            let unread = bots.reduce(0) { $0 + botUnreadCounts[$1.id, default: 0] }
            let unreadLabel = unread > 99 ? "99+" : "\(unread)\(botUnreadIncomplete ? "+" : "")"
            let unreadDescription =
                botUnreadIncomplete
                ? (unread > 0 ? "At least \(unread) unread sessions" : "Unread session count unavailable")
                : "\(unread) unread \(unread == 1 ? "session" : "sessions")"
            let summary = (workingBots.map { "\($0.name) is running" } + [unreadDescription]).joined(separator: "\n")
            HStack(spacing: 6) {
                if working > 0 {
                    HStack(spacing: 4) {
                        DockActivityIndicator(state: .running, size: 12)
                        if bots.count > 1 { Text("\(working)").dockFont(.compactStatus, weight: .bold) }
                    }
                    .foregroundStyle(DockActivityState.running.color)
                }
                if unread > 0 {
                    Text(unreadLabel)
                        .dockFont(.compactStatus, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(DockAccentColor.unreadBadgeText)
                        .dockPill(tint: DockAccentColor.unreadBadgeFill, solid: true, compact: true)
                        .lineLimit(1)
                        .fixedSize()
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
                                    guard option.isSessionWorking, let worker = option.liveWorkerChat else {
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
                        .dockPadding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .accessibilityLabel(
                        botPickerAccessibilityLabel(option, selected: option.id == selectedBot?.id)
                    )
                }
            }
            .dockPadding(6)
        }
        .frame(width: 300, height: popoverHeight)
        .background(style.background)
    }

    private func botPickerAccessibilityLabel(_ bot: BotSummary, selected: Bool) -> String {
        let count = botUnreadCounts[bot.id, default: 0]
        let prefix = selected ? "\(bot.name), selected" : "Select \(bot.name)"
        if botUnreadIncomplete {
            return count > 0
                ? "\(prefix), at least \(count) unread sessions" : "\(prefix), unread session count unavailable"
        }
        return "\(prefix), \(count) unread \(count == 1 ? "session" : "sessions")"
    }

    /// A one-line horizontal rail keeps global navigation compact and makes
    /// selection independent from every neighbouring destination.
    private func globalRailBar(style: DockThemePalette) -> some View {
        let projects = sidebarSnapshot.linkedProjectGroups
        let allConversations = botScopedConversations(sidebarSnapshot.conversations)
        // Built once per pass; rows previously rebuilt it per row (O(n²)).
        let statuses = sidebarSessionStatuses

        // Native sections keep headers visible without geometry tracking or eager row containers.
        return LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            if isSearchingSessions {
                sessionSearchResults(statuses: statuses, style: style)
            } else {
                ForEach(navigationState.sectionOrder, id: \.self) { section in
                    switch section {
                    case .pinned:
                        let pinned = pinnedSessionPresentation
                        if pinned.status != .empty || !pinned.sessions.isEmpty {
                            pinnedOutline(pinned, statuses: statuses, style: style)
                        }
                    case .recents:
                        conversationOutline(allConversations, statuses: statuses, style: style)
                    case .projects:
                        projectsOutline(projects, statuses: statuses, style: style)
                    }
                }
                SessionRailEndDropZone(state: navigationState)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: hostVisible && !isSidebarCollapsed) {
            guard hostVisible, !isSidebarCollapsed else { return }
            // ponytail: 10s roster poll while the rail is on screen (cancelled
            // on disappear); Hermes has no roster push event.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await botMode.refreshNow()
                if visibleBots.count > 1 { model.loadAllBotSessions() }
            }
        }
        .dockSheet(isPresented: $isShowingProjectSheet) {
            ProjectFolderSheet(
                // Folder-backed projects open directly into their first chat.
                onCreate: { name, folder in
                    // Hermes rejects a second project for the same folder; open a chat in the existing one instead.
                    var created = folder.map { path in controlCenter.projects.contains { $0.name == path } } ?? false
                    if !created {
                        created = await controlCenter.createProject(name: name, folder: folder)
                        if !created, controlCenter.lastError?.contains("already belongs to project") == true {
                            created = true
                        }
                    }
                    if created, let folder { startNewChat(inProject: folder) }
                    return created
                },
                failureReason: { controlCenter.lastError }
            )
        }
    }

    @ViewBuilder
    private func projectsOutline(
        _ projects: [SessionNavConversationGroup], statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        if showsProjectsForSelectedBot {
            SessionNavProjectList(
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
                    navigationState.selectSession(session.id)
                    onSelectSession(session)
                },
                onRefresh: {
                    controlCenter.refreshProjectNavigation()
                },
                navigationState: navigationState,
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

    private var isSearchingSessions: Bool {
        !sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sessionSearchField: some View {
        DockSearchField(
            placeholder: "Search sessions", text: $sessionSearchQuery,
            accessibilityDescription: "Search sidebar sessions", accessibilityID: "sidebar-session-search")
    }

    @ViewBuilder
    private func sessionSearchResults(statuses: [String: SidebarSessionStatus], style: DockThemePalette) -> some View {
        let matches = SessionSidebarSearch.sessions(
            matching: sessionSearchQuery,
            in: botScopedConversations(sidebarSnapshot.conversations + pinnedSessionPresentation.sessions),
            projects: sidebarSnapshot.projectNameBySessionID)
        Text("Loaded sessions · \(matches.count)")
            .dockFont(.body, weight: .semibold)
            .foregroundStyle(style.secondaryText)
            .dockPadding(8)
        if matches.isEmpty {
            queueEmpty(
                sidebarSnapshot.inputs.isLoadingSessions ? "Loading conversations…" : "No matching loaded sessions",
                style: style)
        }
        if case .stale(let message) = pinnedSessionPresentation.status {
            queueEmpty(message, style: style)
        } else if case .unavailable(let message) = pinnedSessionPresentation.status {
            queueEmpty(message, style: style)
        } else if case .failed(let message) = pinnedSessionPresentation.status {
            queueEmpty(message, style: style)
        }
        ForEach(matches, id: \.[sidebarSection: "search"]) { session in
            conversationSessionRow(session, statuses: statuses, style: style)
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
                // Group the chat under its project now; the session index and
                // project tree only report it after a round-trip.
                if let stableID = model.navigationSessionID {
                    workspaceStore.attachProject(at: projectPath, toSessionID: stableID)
                    model.touchSession(sessionID: stableID, at: Date())
                }
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
            .dockPadding(.horizontal, 8)
            .dockPadding(.vertical, 7)
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
                    .dockFont(.metadata, weight: .bold)
            }
            .dockFont(.control)
            .foregroundStyle(style.secondaryText)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockLink)
    }

    /// Recents follow the selected Bot: another Bot's chat (kept in the model
    /// while it is open) must not leak into this Bot's list. Main chats live
    /// on the Bots page, never here.
    /// The header badge counts every bot's sessions, so "mark all" must too.
    private func markAllSessionsRead(_ conversations: [HermesSession]) {
        let all = SessionDashboardProjection.sessions(in: sidebarSnapshot)
        // Stamp "now": reply timestamps can run ahead of a stale index `updatedAt`.
        model.markSessionsRead(all + conversations, seenStore: sidebarSessionSeenStore, at: .now)
        botUnreadCounts = [:]
    }

    private func hasUnread(_ conversations: [HermesSession], _ statuses: [String: SidebarSessionStatus]) -> Bool {
        conversations.contains { statuses[$0.id] == .unreadComplete } || botUnreadCounts.values.contains { $0 > 0 }
    }

    private func botScopedConversations(_ base: [HermesSession]) -> [HermesSession] {
        let mainChats = BotMentions.mainChatSessionIDs
        let base = base.filter { !mainChats.contains($0.id) }
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
            SessionNavBotSessionRow(
                session: session,
                bot: bot,
                imageData: botMode.avatarImages[bot.id],
                isSelected: isSessionSelected(session),
                sessionStatus: statuses[session.id] ?? .none,
                mood: BotMood(ask: statuses[session.id]?.activityState),
                style: style
            ) {
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
        SessionNavSidebarSessionRow(
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
            onSelect: openSession,
            onTogglePin: togglePin,
            onRename: { selected, title in
                let succeeded = await model.renameSession(selected, title: title)
                if succeeded {
                    controlCenter.refreshProjectNavigation()
                    model.loadAllBotSessions(force: true)
                }
                return succeeded
            },
            onToggleHidden: { selected, hidden in
                let succeeded = await model.setSessionHidden(selected, hidden: hidden)
                if succeeded {
                    controlCenter.refreshProjectNavigation()
                    model.loadAllBotSessions(force: true)
                }
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

    /// Section rows remain lazy; only the header is pinned by the rail.
    @ViewBuilder
    private func pinnedOutline(
        _ pinned: PinnedSessionPresentation, statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        Section {
            Group {
                if navigationState.arePinnedExpanded {
                    pinnedRows(pinned, statuses: statuses, style: style)
                }
            }
            .sessionSidebarFadesUnderStickyHeader()
        } header: {
            DockSectionHeader(
                title: "Pinned",
                count: pinned.count,
                isExpanded: $navigationState.arePinnedExpanded,
                style: style
            )
            .sessionRailReorder(.pinned, state: navigationState)
            .frame(maxWidth: .infinity)
            .dockPadding(.top, style.sectionSpacing)
            .dockPadding(.bottom, navigationState.arePinnedExpanded ? 2 : 0)
            .sessionSidebarStickyBackground()
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func pinnedRows(
        _ pinned: PinnedSessionPresentation, statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        if pinned.sessions.isEmpty {
            queueEmpty(pinnedStatusText(pinned.status), style: style)
                .dockPadding(.leading, 12)
                .dockPadding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(pinned.sessions, id: \.[sidebarSection: "pinned"]) { session in
                pinnedSessionRow(session, statuses: statuses, style: style)
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
        SessionNavSidebarSessionRow(
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
            onSelect: openSession,
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

    /// Section rows remain lazy; only the header is pinned by the rail.
    @ViewBuilder
    private func conversationOutline(
        _ conversations: [HermesSession], statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        Section {
            conversationRows(conversations, statuses: statuses, style: style)
                .sessionSidebarFadesUnderStickyHeader()
        } header: {
            DockSectionHeader(
                title: "Recents",
                count: conversations.count,
                isExpanded: $navigationState.areConversationsExpanded,
                style: style
            ) {
                if hasUnread(conversations, statuses) {
                    DockIconButton(icon: .checks, label: "Mark all as read", size: 24, style: style) {
                        markAllSessionsRead(conversations)
                    }
                }
                DockIconButton(
                    icon: .arrowsClockwise,
                    label: sidebarSnapshot.inputs.isLoadingSessions
                        ? "Refreshing conversations…" : "Refresh conversations",
                    isBusy: sidebarSnapshot.inputs.isLoadingSessions,
                    size: 24,
                    style: style
                ) {
                    model.loadSessions()
                    controlCenter.refreshProjectNavigation()
                }
            }
            .sessionRailReorder(.recents, state: navigationState)
            .frame(maxWidth: .infinity)
            .dockPadding(.top, style.sectionSpacing)
            .dockPadding(.bottom, navigationState.areConversationsExpanded ? 2 : 0)
            .contextMenu {
                Button("Mark all as read") {
                    markAllSessionsRead(conversations)
                }
                .disabled(!hasUnread(conversations, statuses))
            }
            .sessionSidebarStickyBackground()
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func conversationRows(
        _ conversations: [HermesSession], statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        if navigationState.areConversationsExpanded {
            if conversations.isEmpty {
                queueEmpty(
                    sidebarSnapshot.inputs.isLoadingSessions ? "Loading conversations…" : "No saved conversations",
                    style: style
                )
                .dockPadding(.leading, 20)
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
                    .dockPadding(.leading, 12)
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
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 7)
            .background(isTaskSelected(task) ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous))
        }
        .buttonStyle(.dockHover)
        .help(task.sessionID == nil ? "Open this task in Kanban" : "Open task conversation")
    }

    private func sessionRow(_ session: HermesSession, style: DockThemePalette) -> some View {
        let controls = SessionNavConversationSessionRow.controls(
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

        return SessionNavConversationSessionRow(
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
            || sessionPanes.shownSessionIDs.contains(session.id)
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
}
