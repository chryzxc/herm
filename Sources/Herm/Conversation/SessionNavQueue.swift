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
    @ObservedObject private var pinnedOrder: PinnedSessionOrder
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
    let onCreateBot: (() -> Void)?
    let onShowBots: (() -> Void)?
    let showsFullscreenToggle: Bool
    let isFullscreen: Bool
    let onFullscreenToggle: () -> Void
    let onSelectProfile: (String) -> Void
    let onOpenWindow: (() -> Void)?
    let isDockedWindow: Bool
    let showsWindowTitleRow: Bool
    @Binding var isSidebarCollapsed: Bool
    @AppStorage("herm.chats.usesBotRail") private var usesBotRail = false
    @AppStorage("herm.sessions.hiddenSidebarOptions") private var hiddenSidebarOptions =
        SessionRailSection.defaultHiddenOptions
    @State private var sidebarArchive: (request: ArchiveRequest, result: SessionSidebarArchive?)?
    @State private var archiveMutationRevision: UInt64 = 0
    @State private var sidebarLiveResult: SidebarLiveResult?
    @State private var sessionSearchQuery = ""
    @State private var sessionSearchResults: SessionSidebarSearch.Results?
    @State private var isProfileSelectorPresented = false
    @State private var isProfileHovering = false
    @State private var creatingProjectPath: String?
    @State private var isShowingProjectSheet = false
    private let sidebarSessionSeenStore = SidebarSessionSeenStore.shared
    @State private var botUnreadCounts: [String: Int] = [:]
    @State private var unreadSidebarSessions: Set<ProfileScopedID> = []
    @State private var botUnreadIncomplete = true

    private struct BotUnreadRequest: Equatable {
        let sessions: Set<SidebarUnreadSession>
        let scopeProfileID: String?
        let baselinedProfiles: Set<String>
        let seen: [String: Date]
        let incomplete: Bool
    }

    private var botUnreadRequest: BotUnreadRequest {
        let incomplete: Bool
        switch sidebarSnapshot.inputs.allBotSessionsState {
        case .ready(let rows): incomplete = rows.count >= DockModel.allBotSessionsLimit
        case .empty: incomplete = false
        case .loading, .stale, .unavailable, .failed: incomplete = true
        }
        return BotUnreadRequest(
            sessions: sidebar.unreadSessions.rows,
            scopeProfileID: sidebarSnapshot.inputs.profileScopeID,
            baselinedProfiles: sidebarSnapshot.inputs.baselinedProfiles,
            seen: sidebarSnapshot.inputs.seenAtByKey,
            incomplete: incomplete)
    }

    private func refreshBotUnreadCounts(_ request: BotUnreadRequest) async {
        let sessions = sidebar.unreadSessions.sessions
        let result = try? await model.sessionUnreadReplies.botCounts(
            sessions: sessions, scopeProfileID: request.scopeProfileID,
            seenStore: sidebarSessionSeenStore, incomplete: request.incomplete)
        guard !Task.isCancelled, request == botUnreadRequest else { return }
        let counts = result?.counts ?? [:]
        let incomplete = result?.incomplete ?? true
        if botUnreadCounts != counts { botUnreadCounts = counts }
        unreadSidebarSessions = result?.unreadSessions ?? []
        if botUnreadIncomplete != incomplete { botUnreadIncomplete = incomplete }
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
        onCreateBot: (() -> Void)? = nil,
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
        self.pinnedOrder = workspaceStore.pinnedSessionOrder
        self.controlCenter = controlCenter
        self.agentUpdateService = agentUpdateService
        self.navigationState = navigationState
        self.dockThemeStore = dockThemeStore
        _sidebar = StateObject(
            wrappedValue: SessionNavSidebarModel.shared(model: model, control: controlCenter, store: workspaceStore))
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
        self.onCreateBot = onCreateBot
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
                && (lhs.onCreateBot == nil) == (rhs.onCreateBot == nil)
                && (lhs.onShowBots == nil) == (rhs.onShowBots == nil)
                && (lhs.onOpenWindow == nil) == (rhs.onOpenWindow == nil)
        }
    }

    private var sidebarSnapshot: SessionNavSidebarSnapshot {
        sidebar.snapshot
    }

    /// "All profiles" needs another bot to list; with one bot it is the same list.
    private var showsAllProfiles: Bool {
        navigationState.showsAllProfiles && visibleBots.count > 1
    }

    private var pinnedSessionPresentation: PinnedSessionPresentation {
        let presentation =
            showsAllProfiles ? sidebarSnapshot.allProfilePinPresentation : sidebarSnapshot.scopedPinPresentation
        return navigationState.hasRequestedSessionIndex ? presentation : presentation.withInitialRequestPending()
    }

    private var pinnedOrderScope: PinnedSessionOrderScope {
        showsAllProfiles ? .all : .profile(sidebarSnapshot.inputs.profileScopeID)
    }

    private func isPinned(_ session: HermesSession) -> Bool {
        guard showsAllProfiles else {
            return sidebarSnapshot.inputs.pinnedSessions.contains { $0.id == session.id }
        }
        let scope = sidebarSnapshot.inputs.profileScopeID
        let key = AllProfilesSessions.pinKey(session, scopeProfileID: scope)
        return sidebarSnapshot.allProfilePinned.contains {
            AllProfilesSessions.pinKey($0, scopeProfileID: scope) == key
        }
    }

    private func togglePin(_ session: HermesSession) {
        let pinned = isPinned(session)
        Task { await model.toggleSessionPinned(session, isPinned: pinned) }
    }

    /// The owning bot's pill, only when the rail mixes profiles.
    private func ownerBot(_ session: HermesSession) -> BotSummary? {
        guard showsAllProfiles else { return nil }
        return AllProfilesSessions.ownerBot(
            session, bots: visibleBots, scopeProfileID: sidebarSnapshot.inputs.profileScopeID)
    }

    /// Opens a chat from any bot. Another bot's chat switches the profile
    /// first, synchronously, so the scope change cannot replace the resume.
    private func openSession(_ session: HermesSession) {
        if !sessionPanes.hasOpenSession(session.id, profileID: session.profileID),
            let profileID = session.profileID, profileID != model.profileScopeID,
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
        let unreadRequest = hostVisible && !isSidebarCollapsed ? botUnreadRequest : nil
        let searchRequest = hostVisible && !isSidebarCollapsed ? sessionSearchRequest : nil
        let archiveRequest = archiveRequest
        let liveRequest = sidebarLiveRequest
        listPanel(style: style)
            .dockShellPane()
            .task(id: searchRequest) {
                guard let searchRequest else {
                    sessionSearchResults = nil
                    return
                }
                let worker = Task.detached(priority: .userInitiated) { searchRequest.resolve() }
                let matches = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                sessionSearchResults = matches
            }
            .task(id: unreadRequest) {
                guard let unreadRequest else { return }
                await refreshBotUnreadCounts(unreadRequest)
            }
            .task(id: archiveRequest) { await loadSidebarArchive(archiveRequest) }
            .onReceive(model.archivedSidebarMutationUpdates) { archiveMutationRevision = $0 }
            .task(id: liveRequest) { await pollSidebarLiveStatus(liveRequest) }
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
            .onReceive(sidebar.$snapshot.receive(on: RunLoop.main)) { _ in
                baselineSidebarSessionsIfAuthoritative()
            }
            .onReceive(
                sidebar.$snapshot.map(\.inputs.allBotSessionsState).removeDuplicates().receive(on: RunLoop.main)
            ) { _ in
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
    private func titleActions(style: DockThemePalette) -> some View {
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

        DockMenu {
            DockMenu {
                DockMenuChoices(selection: $usesBotRail) {
                    DockMenuOption("Bot rail", value: true, leading: AnyView(DockIcon(.sidebarSimple, size: 14)))
                    DockMenuOption("Bot menu", value: false, leading: AnyView(DockIcon(.caretUpDown, size: 14)))
                }
            } label: {
                Text("Bot switcher layout")
            }
            DockMenu {
                ForEach(SessionRailSection.filterOptions, id: \.self) { option in
                    Toggle(
                        option.title,
                        isOn: Binding(
                            get: { option.isVisible(in: hiddenSidebarOptions) },
                            set: { visible in
                                guard visible != option.isVisible(in: hiddenSidebarOptions) else { return }
                                hiddenSidebarOptions = option.toggled(in: hiddenSidebarOptions)
                            })
                    )
                    .dockMenuKeepOpen()
                }
            } label: {
                Text("Show sidebar sections")
            }
        } label: {
            DockIcon(.dotsThreeVertical, size: DockLayout.toolbarIconSize, color: style.secondaryText)
                .frame(width: DockLayout.iconControlSize, height: DockLayout.iconControlSize)
        }
        .help("Sidebar options")
        .accessibilityLabel("Sidebar options")
    }

    /// Secondary panel: identity, new conversation, and the session lists.
    private func listPanel(style: DockThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The session list owns its title strip beside the conversation and inspector.
            if isDockedWindow && showsWindowTitleRow {
                HStack(spacing: 0) {
                    DockTitleLeadingControls { DockSidebarToggle(isCollapsed: $isSidebarCollapsed) }
                    Spacer(minLength: 0)
                        .frame(maxHeight: .infinity)
                        .background { TitlebarDoubleClickArea() }
                    titleActions(style: style)
                }
                .dockPadding(.leading, DockWindowChrome.sidebarToggleLeading)
                .dockPadding(.trailing, 8)
                .frame(height: DockWindowChrome.titleRowHeight)
                .dockShellChrome()
            }
            HStack(alignment: .top, spacing: 0) {
                if usesBotRail && (!visibleBots.isEmpty || canCreateBot) {
                    botRail(style: style)
                }
                sessionList(style: style)
            }
        }
        .dockShellPane()
        .frame(maxWidth: .infinity)
    }

    private func sessionList(style: DockThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            botsSwitchButton(style: style)
                .dockPadding(.horizontal, 12)
                .dockPadding(.top, 8)
                .dockPadding(.bottom, 12)
            if !isDockedWindow || !usesBotRail {
                HStack(spacing: 2) {
                    if !isDockedWindow {
                        DockSidebarToggle(isCollapsed: $isSidebarCollapsed)
                        titleActions(style: style)
                    }
                    if !usesBotRail { profileHeader(style: style) }
                }
                .dockPadding(.leading, isDockedWindow ? 12 : 6)
                .dockPadding(.trailing, 12)
            }

            HStack(spacing: 6) {
                sessionSearchField
                DockIconButton(icon: .notePencil, label: "New chat", style: style, action: onNewConversation)
            }
            .dockPadding(.horizontal, 12)
            .dockPadding(.top, 12)
            .dockPadding(.bottom, 2)
            .overlay(alignment: .bottomLeading) {
                if !botMode.activityBanner.isEmpty {
                    BotActivityBanner(events: botMode.activityBanner)
                        .dockPadding(.horizontal, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: botMode.activityBanner)
            .zIndex(1)

            HoverPausingScrollView {
                globalRailBar(style: style)
                    .dockButtonSize(.standard)
                    .dockPadding(.horizontal, 6)
                    .dockPadding(.bottom, 8)
            }
            .coordinateSpace(name: SessionSidebarStickyBackground.coordinateSpace)
        }
        .frame(maxWidth: .infinity)
    }

    private var canCreateBot: Bool { botMode.canCreateBots && onCreateBot != nil }

    private func botRail(style: DockThemePalette) -> some View {
        VStack(spacing: 0) {
            if visibleBots.count > 1 {
                botRailButton("All", isSelected: showsAllProfiles, style: style, action: selectAllProfiles) {
                    let size = DockWorkspaceScale.points(DockBotRailMetrics.avatarSize, scale: workspaceScale)
                    Text("All")
                        .dockFont(.body, weight: .semibold)
                        .foregroundStyle(style.primaryText)
                        .frame(width: size, height: size)
                        .background(DockThemeShape(cornerRadius: DockControlMetrics.cornerRadius).fill(style.surface4))
                }
                .dockHoverTip("All", edge: .trailing)
                .accessibilityLabel("Show conversations from all profiles")
                .dockPadding(.top, 6)
            }
            DockProfilePickerList(
                bots: visibleBots, order: workspaceStore.profilePickerOrder, style: style, isRail: true
            ) { bot in
                let selected = !showsAllProfiles && bot.id == selectedBot?.id
                let imageData = botMode.avatarImages[bot.id]
                botRailButton(
                    bot.name,
                    isSelected: selected, style: style, action: { selectProfile(bot.id) }
                ) {
                    if botMode.isAvatarPending(bot) {
                        DockLoadingIndicator().controlSize(.small)
                    } else {
                        BotAvatarView(
                            bot: bot, imageData: imageData, size: DockBotRailMetrics.avatarSize, animated: false)
                    }
                }
                .overlay(alignment: .trailing) {
                    botActivityBadge(for: [bot], style: style, inRail: true)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .dockHoverTip(
                    BotRosterPresentation.railTooltip(for: bot), edge: .trailing, gap: 8,
                    preview: DockHoverTipPreview(
                        contentID: AnyHashable(imageData),
                        content: AnyView(BotRailProfileTip(bot: bot, imageData: imageData)))
                )
                .accessibilityLabel(botPickerAccessibilityLabel(bot, selected: selected))
            }
            if canCreateBot, let onCreateBot {
                DockIconButton(icon: .plus, label: "New Bot", style: style, action: onCreateBot)
                    .dockPadding(.bottom, 6)
            }
        }
        .frame(width: DockBotRailMetrics.width)
        .dockShellChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bot rail")
    }

    private func botRailButton<Avatar: View>(
        _ title: String, isSelected: Bool, style: DockThemePalette,
        action: @escaping () -> Void,
        @ViewBuilder avatar: () -> Avatar
    ) -> some View {
        Button(action: action) {
            avatar()
                .frame(width: DockBotRailMetrics.rowSize, height: DockBotRailMetrics.rowSize)
                .dockSelectionBackground(
                    DockThemeShape(cornerRadius: DockControlMetrics.cornerRadius), active: isSelected,
                    fill: style.selectedFill, allowsInvert: false, theme: style.theme
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        let allProfiles = showsAllProfiles
        let bot = allProfiles ? nil : selectedBot
        let name = allProfiles ? "All" : bot?.name ?? "Herm"
        let subtitle = allProfiles ? "\(visibleBots.count) bots" : bot?.title
        let label = subtitle.map { "\(name) — \($0)" } ?? name
        let isSwitchable = visibleBots.count > 1
        let identity = HStack(spacing: 9) {
            if allProfiles {
                allProfilesMark(size: 28, style: style)
            } else if let bot, botMode.isAvatarPending(bot) {
                // Startup: the avatar is still loading, so hold its slot instead of a stand-in face.
                DockLoadingIndicator().controlSize(.small).frame(width: 28, height: 28)
                    .accessibilityLabel("Loading \(bot.name)'s avatar")
            } else if let bot {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 28)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).fill(
                        style.selectedFill)
                    DockIcon(.robot, size: 15, color: style.secondaryText)
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
                botActivityBadge(for: allProfiles ? [] : visibleBots.filter { $0.id != bot?.id }, style: style)
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
    private func botActivityBadge(for bots: [BotSummary], style: DockThemePalette, inRail: Bool = false) -> some View {
        // One board decides status for the picker and the notch alike; it
        // re-resolves on every session event and roster poll.
        let board = botMode.activity
        let blockedBots = bots.filter { board.status(of: $0.id) == .blocked }
        let workingBots = bots.filter { board.status(of: $0.id) == .working }
        let working = workingBots.count
        let unread = bots.reduce(0) { $0 + botUnreadCounts[$1.id, default: 0] }
        let unreadLabel = unread > 99 ? "99+" : "\(unread)\(botUnreadIncomplete ? "+" : "")"
        let unreadDescription =
            botUnreadIncomplete
            ? (unread > 0 ? "At least \(unread) unread sessions" : "Unread session count unavailable")
            : "\(unread) unread \(unread == 1 ? "session" : "sessions")"
        let summary =
            (blockedBots.map { "\($0.name) is waiting on you" }
            + workingBots.map { "\($0.name) is running" } + [unreadDescription]).joined(separator: "\n")
        let layout =
            inRail ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 0)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            if !blockedBots.isEmpty {
                HStack(spacing: 4) {
                    DockActivityIndicator(state: .approval, role: inRail ? .compact : .inline)
                    if bots.count > 1 { Text("\(blockedBots.count)").dockFont(.compactStatus, weight: .bold) }
                }
                .foregroundStyle(DockActivityState.approval.color)
            }
            if working > 0 {
                HStack(spacing: 4) {
                    DockActivityIndicator(state: .running, role: inRail ? .compact : .inline)
                    if bots.count > 1 { Text("\(working)").dockFont(.compactStatus, weight: .bold) }
                }
                .foregroundStyle(DockActivityState.running.color)
            }
            if inRail { Spacer(minLength: 0) }
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
        .help(inRail ? "" : summary)
        .accessibilityLabel(summary.replacingOccurrences(of: "\n", with: ", "))
    }

    /// The selected bot's avatar in front, with the next bots peeking behind it.
    private func allProfilesMark(size: CGFloat, style: DockThemePalette) -> some View {
        let current = selectedBot
        let bots = Array(([current].compactMap { $0 } + visibleBots.filter { $0.id != current?.id }).prefix(3))
        // One row, side by side: no overlap, so no backing disc is needed.
        return HStack(spacing: 2) {
            ForEach(bots) { bot in
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: size * 0.72, animated: false)
            }
        }
        .frame(height: size)
        .accessibilityHidden(true)
    }

    private func selectProfile(_ profileID: String) {
        navigationState.showsAllProfiles = false
        onSelectProfile(profileID)
    }

    private func selectAllProfiles() {
        navigationState.showsAllProfiles = true
        model.loadAllBotSessions(force: true)
        isProfileSelectorPresented = false
    }

    private func profileSelectorPopover(selectedBot: BotSummary?, style: DockThemePalette) -> some View {
        let allProfiles = showsAllProfiles
        return DockProfilePickerList(
            bots: visibleBots, order: workspaceStore.profilePickerOrder, style: style, showsHeader: true,
            header: { allProfilesPickerRow(isSelected: allProfiles, style: style) },
            row: { option in
                Button {
                    selectProfile(option.id)
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
                            .dockTapAction {
                                // The spinner doubles as "view the running session".
                                guard botMode.activity.status(of: option.id) == .working,
                                    let worker = option.liveWorkerChat
                                else {
                                    selectProfile(option.id)
                                    isProfileSelectorPresented = false
                                    return
                                }
                                selectProfile(option.id)
                                onOpenBotChat(option, worker)
                                isProfileSelectorPresented = false
                            }
                        if !allProfiles, option.id == selectedBot?.id {
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
                    botPickerAccessibilityLabel(option, selected: !allProfiles && option.id == selectedBot?.id)
                )
            })
    }

    private func allProfilesPickerRow(isSelected: Bool, style: DockThemePalette) -> some View {
        Button(action: selectAllProfiles) {
            HStack(spacing: 9) {
                allProfilesMark(size: 22, style: style)
                Text("All")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                botActivityBadge(for: visibleBots, style: style)
                if isSelected {
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
        .accessibilityLabel(isSelected ? "All profiles, selected" : "Show conversations from all profiles")
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
        let pinned = pinnedSessionPresentation
        let statuses = sidebarSnapshot.sessionStatuses

        // Native sections keep headers visible without geometry tracking or eager row containers.
        return LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            if isSearchingSessions {
                searchResultRows(pinned: pinned, statuses: statuses, style: style)
                if SessionRailSection.archived.isVisible(in: hiddenSidebarOptions) {
                    filterOutline(.archived, style: style)
                }
            } else {
                let recents = showsAllProfiles ? sidebarSnapshot.allBotRecents : sidebarSnapshot.scopedRecents
                let scope = sessionSearchScope
                let conversations = recents.conversations.filter(scope.includes)
                let automations = recents.automations.filter(scope.includes)
                let sections = navigationState.sectionOrder.filter { $0.isVisible(in: hiddenSidebarOptions) }
                ForEach(sections, id: \.self) { section in
                    switch section {
                    case .pinned:
                        if pinned.status != .empty || !pinned.sessions.isEmpty {
                            pinnedOutline(pinned, statuses: statuses, style: style)
                        }
                    case .recents:
                        conversationOutline(
                            conversations, type: .conversations, statuses: statuses, style: style)
                    case .projects:
                        projectsOutline(projects, statuses: statuses, style: style)
                    case .automations:
                        conversationOutline(
                            automations, type: .automation, statuses: statuses, style: style)
                    case .unread, .needsYou, .running, .archived:
                        filterOutline(section, style: style)
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
                await botMode.refreshNow(minimumInterval: 10)
                if visibleBots.count > 1, !model.isLoadingSessions, !model.isPollingSessions,
                    !model.sessionIndexReadRecently(within: 10)
                {
                    model.loadAllBotSessions()
                }
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
                shownSessionIDs: sessionPanes.shownSessionIDs,
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
                pinningSessionID: sidebarSnapshot.inputs.pinningSessionID,
                projectTargets: { sidebarSnapshot.projectTargets(forSessionID: $0) },
                isMovingSession: model.movingSessionToProjectID != nil,
                onAddToProject: moveToProject,
                loadSessions: { controlCenter.loadProjectNavigationSessions($0) },
                failedProjectSessionIDs: sidebarSnapshot.inputs.failedProjectSessionIDs
            )
        }
    }

    private func filterDisclosure(_ section: SessionRailSection) -> Binding<Bool> {
        Binding(
            get: { navigationState.expandedFilterSections.contains(section) },
            set: { expanded in
                if expanded {
                    navigationState.expandedFilterSections.insert(section)
                } else {
                    navigationState.expandedFilterSections.remove(section)
                }
            })
    }

    private struct ArchiveRequest: Equatable {
        let scope: SessionSidebarArchive.Scope
        let revision: UInt64
    }

    private var archiveRequest: ArchiveRequest? {
        guard hostVisible, !isSidebarCollapsed,
            SessionRailSection.archived.isVisible(in: hiddenSidebarOptions),
            navigationState.expandedFilterSections.contains(.archived)
        else { return nil }
        let scope: SessionSidebarArchive.Scope =
            showsAllProfiles
            ? .allProfiles : .profile(selectedBot?.id ?? sidebarSnapshot.inputs.profileScopeID ?? "default")
        return ArchiveRequest(scope: scope, revision: archiveMutationRevision)
    }

    private func loadSidebarArchive(_ request: ArchiveRequest?) async {
        guard !Task.isCancelled, let request else { return }
        do {
            let result = try await model.interruptRPC.archivedSidebarSessions(scope: request.scope)
            guard !Task.isCancelled, model.archivedSidebarMutationRevision == request.revision else { return }
            sidebarArchive = (request, result)
        } catch {
            guard !Task.isCancelled, model.archivedSidebarMutationRevision == request.revision else { return }
            sidebarArchive = (request, nil)
        }
    }

    private struct SidebarLiveRequest: Equatable {
        let sections: Set<SessionRailSection>
        let profiles: [String]
    }

    private struct SidebarLiveResult: Equatable {
        let request: SidebarLiveRequest
        let statuses: [SessionRailSection: SessionSidebarLiveStatus]
    }

    private var sidebarLiveRequest: SidebarLiveRequest? {
        guard hostVisible, !isSidebarCollapsed, !isSearchingSessions else { return nil }
        let sections = navigationState.expandedFilterSections.intersection([.needsYou, .running])
            .filter { $0.isVisible(in: hiddenSidebarOptions) }
        guard !sections.isEmpty else { return nil }
        let current = selectedBot?.id ?? sidebarSnapshot.inputs.profileScopeID ?? "default"
        let profiles = showsAllProfiles && !visibleBots.isEmpty ? visibleBots.map(\.id).sorted() : [current]
        return SidebarLiveRequest(sections: sections, profiles: profiles)
    }

    private func pollSidebarLiveStatus(_ request: SidebarLiveRequest?) async {
        guard !Task.isCancelled, let request else { return }
        // Share one active-list read per profile across both expanded live sections.
        while !Task.isCancelled {
            let statuses = await model.interruptRPC.sidebarLiveStatus(for: request.sections, profiles: request.profiles)
            guard !Task.isCancelled else { return }
            let result = SidebarLiveResult(request: request, statuses: statuses)
            if sidebarLiveResult != result { sidebarLiveResult = result }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    @ViewBuilder
    private func filterOutline(_ section: SessionRailSection, style: DockThemePalette) -> some View {
        let expanded = filterDisclosure(section)
        let snapshot = sidebarSnapshot
        let live =
            sidebarLiveResult?.request.profiles == sidebarLiveRequest?.profiles
            ? sidebarLiveResult?.statuses[section] : nil
        let inventory =
            expanded.wrappedValue
            ? SessionSidebarFilterInventory(
                inputs: snapshot.inputs, unreadSessions: unreadSidebarSessions,
                confirmedApprovals: section == .needsYou ? live?.ids ?? [] : nil,
                confirmedRunning: section == .running ? live?.ids ?? [] : nil,
                activeProfileID: model.sessionProfileID)
            : nil
        let archive = archiveRequest == sidebarArchive?.request ? sidebarArchive : nil
        let scopedProfile = snapshot.inputs.profileScopeID ?? "default"
        let projectProfile = snapshot.inputs.projectProfileID ?? scopedProfile
        let matches =
            inventory?.results(
                section == .archived
                    ? archive?.result?.sessions ?? []
                    : (showsAllProfiles ? snapshot.allBotConversations : snapshot.conversations)
                        + pinnedSessionPresentation.sessions,
                section: section, query: sessionSearchQuery, scope: sessionSearchScope,
                projectNames: snapshot.projectNameBySessionID) ?? []
        let message = sidebarFilterStatus(section, archive: archive, live: live)
        Section {
            Group {
                if let inventory {
                    ForEach(matches, id: \.[sidebarSection: section.rawValue]) { session in
                        plainConversationSessionRow(
                            session, statuses: [session.id: inventory.status(for: session)], style: style,
                            showProjectMetadata: (session.profileID ?? scopedProfile) == projectProfile)
                    }
                    if let message {
                        queueEmpty(message, style: style).dockPadding(.leading, 12)
                    } else if matches.isEmpty {
                        queueEmpty(emptyFilterMessage(section), style: style)
                            .dockPadding(.leading, 12)
                    }
                }
            }
            .sessionSidebarFadesUnderStickyHeader()
        } header: {
            DockSectionHeader(
                title: section.title,
                count: expanded.wrappedValue && (message == nil || !matches.isEmpty)
                    ? matches.count : nil,
                isExpanded: expanded, style: style
            )
            .sessionRailReorder(section, state: navigationState)
            .frame(maxWidth: .infinity)
            .dockPadding(.top, style.sectionSpacing)
            .dockPadding(.bottom, expanded.wrappedValue ? 2 : 0)
            .sessionSidebarStickyBackground()
            .accessibilityAddTraits(.isHeader)
        }
    }

    private func emptyFilterMessage(_ section: SessionRailSection) -> String {
        switch section {
        case .unread: "No unread sessions in loaded history"
        case .needsYou: "No sessions need approval"
        case .running: "No running sessions in loaded history"
        case .archived: isSearchingSessions ? "No matching archived sessions" : "No archived sessions"
        default: "No sessions"
        }
    }

    private func sidebarFilterStatus(
        _ section: SessionRailSection, archive: (request: ArchiveRequest, result: SessionSidebarArchive?)?,
        live: SessionSidebarLiveStatus?
    ) -> String? {
        if section == .archived {
            if let result = archive?.result {
                return result.isIncomplete ? "Some archived sessions are unavailable" : nil
            }
            return archive == nil ? "Loading archived sessions…" : "Archived sessions are unavailable"
        }
        guard section == .needsYou || section == .running else { return nil }
        guard let live else { return "Loading session status…" }
        return live.isIncomplete ? "Some session statuses are unavailable" : nil
    }

    private var isSearchingSessions: Bool {
        !sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sessionSearchScope: SessionSidebarSearch.Scope {
        SessionSidebarSearch.Scope(
            mainChatIDs: BotMentions.mainChatSessionIDs, showsAllProfiles: showsAllProfiles,
            selectedBotID: selectedBot?.id, visibleBots: visibleBots,
            profileScopeID: sidebarSnapshot.inputs.profileScopeID)
    }

    private var sessionSearchRequest: SessionSidebarSearch.Request? {
        guard isSearchingSessions else { return nil }
        return SessionSidebarSearch.Request(
            query: sessionSearchQuery,
            conversations: showsAllProfiles ? sidebarSnapshot.allBotConversations : sidebarSnapshot.conversations,
            pinned: pinnedSessionPresentation.sessions, projects: sidebarSnapshot.projectNameBySessionID,
            scope: sessionSearchScope)
    }

    private var sessionSearchField: some View {
        DockSearchField(
            placeholder: "Search sessions", text: $sessionSearchQuery,
            accessibilityDescription: "Search sidebar sessions", accessibilityID: "sidebar-session-search")
    }

    @ViewBuilder
    private func searchResultRows(
        pinned: PinnedSessionPresentation, statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        let result = sessionSearchResults?.sessions(for: sessionSearchRequest)
        let matches = result ?? []
        HStack(spacing: 6) {
            Text(result == nil ? "Searching loaded sessions…" : "Loaded sessions · \(matches.count)")
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(style.secondaryText)
            // Fixed-size slot so a routine refresh never shifts the list below
            // or reads as activity inside a conversation row.
            DockLoadingIndicator()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
                .opacity(sidebarSnapshot.inputs.isLoadingSessions ? 1 : 0)
                .accessibilityLabel("Refreshing sessions")
                .accessibilityHidden(!sidebarSnapshot.inputs.isLoadingSessions)
        }
        .dockPadding(8)
        if result != nil, matches.isEmpty {
            queueEmpty("No matching loaded sessions", style: style)
        }
        if case .stale(let message) = pinned.status {
            queueEmpty(message, style: style)
        } else if case .unavailable(let message) = pinned.status {
            queueEmpty(message, style: style)
        } else if case .failed(let message) = pinned.status {
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

    private func conversationExpansionButton(type: SessionRecentsType, style: DockThemePalette) -> some View {
        let showingAll =
            type == .automation ? navigationState.showsAllAutomations : navigationState.showsAllConversations
        return Button {
            if type == .automation {
                navigationState.showsAllAutomations.toggle()
            } else {
                navigationState.showsAllConversations.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text(showingAll ? "Show recent \(type.rowName)" : "Show more \(type.rowName)")
                DockIcon(showingAll ? .caretUp : .caretDown)
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
    private func markAllSessionsRead(_ conversations: [HermesSession], type: SessionRecentsType) {
        let all = SessionDashboardProjection.sessions(in: sidebarSnapshot)
        // Stamp "now": reply timestamps can run ahead of a stale index `updatedAt`.
        model.markSessionsRead(
            type.matching(all + conversations), seenStore: sidebarSessionSeenStore, at: .now)
        if type == .conversations {
            botUnreadCounts = [:]
            unreadSidebarSessions = []
        }
    }

    private func hasUnread(
        _ conversations: [HermesSession], _ statuses: [String: SidebarSessionStatus], type: SessionRecentsType
    ) -> Bool {
        conversations.contains { statuses[$0.id] == .unreadComplete }
            || (type == .conversations && botUnreadCounts.values.contains { $0 > 0 })
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
        _ session: HermesSession, statuses: [String: SidebarSessionStatus], style: DockThemePalette,
        showProjectMetadata: Bool = true
    ) -> some View {
        let owner = ownerBot(session)
        return SessionNavSidebarSessionRow(
            session: session,
            selectedSessionID: isSessionSelected(session) ? session.id : nil,
            sessionStatus: statuses[session.id] ?? .none,
            style: style,
            repositoryName: showProjectMetadata ? sidebarSnapshot.projectNameBySessionID[session.id] : nil,
            repositoryPath: showProjectMetadata ? sidebarSnapshot.projectPathBySessionID[session.id] : nil,
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
            projectTargets: showProjectMetadata ? sidebarSnapshot.projectTargets(forSessionID: session.id) : [],
            isInProject: showProjectMetadata && sidebarSnapshot.projectNameBySessionID[session.id] != nil,
            isMovingSession: model.movingSessionToProjectID != nil,
            onAddToProject: moveToProject,
            ownerBot: owner,
            ownerAvatar: owner.flatMap { botMode.avatarImages[$0.id] },
            isShownInPane: sessionPanes.shownSessionIDs.contains(session.id)
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
            let scope = pinnedOrderScope
            let sessions = pinnedOrder.ordered(pinned.sessions, in: scope)
            ForEach(sessions, id: \.scopedID) { session in
                pinnedSessionRow(
                    session, statuses: statuses, style: style,
                    drag: PinnedSessionDrag(session: SessionPaneDrag(session: session), scope: scope)
                )
                .modifier(
                    PinnedSessionReorderTarget(enabled: sessions.count > 1) { source, after in
                        guard source.scope == scope, scope == pinnedOrderScope else { return }
                        pinnedOrder.move(
                            source.id, relativeTo: session.scopedID, after: after,
                            sessions: pinnedSessionPresentation.sessions, in: scope)
                    })
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
        _ session: HermesSession, statuses: [String: SidebarSessionStatus], style: DockThemePalette,
        drag: PinnedSessionDrag
    ) -> some View {
        let owner = ownerBot(session)
        let shown = isPinnedSessionShown(session)
        return SessionNavSidebarSessionRow(
            session: session,
            selectedSessionID: isPinnedSessionSelected(session, shown: shown) ? session.id : nil,
            sessionStatus: statuses[session.id] ?? .none,
            style: style,
            repositoryName: sidebarSnapshot.projectNameBySessionID[session.id],
            repositoryPath: sidebarSnapshot.projectPathBySessionID[session.id],
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
            isPinning: sidebarSnapshot.inputs.pinningSessionID == session.id,
            projectTargets: sidebarSnapshot.projectTargets(forSessionID: session.id),
            isInProject: sidebarSnapshot.projectNameBySessionID[session.id] != nil,
            onAddToProject: moveToProject,
            ownerBot: owner,
            ownerAvatar: owner.flatMap { botMode.avatarImages[$0.id] },
            isShownInPane: shown,
            pinnedDrag: drag
        )
        .equatable()
    }

    private func isPinnedSessionShown(_ session: HermesSession) -> Bool {
        guard showsAllProfiles else { return sessionPanes.shownSessionIDs.contains(session.id) }
        return sessionPanes.panels.contains { panel in
            guard let tab = panel.selected, let id = tab.sessionID else { return false }
            return ProfileScopedID(profileID: tab.profileID, resourceID: id) == session.scopedID
        }
            || (sessionPanes.detachedSessionIDs.contains(session.id)
                && sidebarSnapshot.allProfilePinned.lazy.filter { $0.id == session.id }.prefix(2).count == 1)
    }

    private func isPinnedSessionSelected(_ session: HermesSession, shown: Bool) -> Bool {
        guard showsAllProfiles else { return isSessionSelected(session) }
        guard activeGlobalTab == nil, !isArtifactsActive else { return false }
        if shown { return true }
        guard navigationState.selection.isSessionSelected(session.id) else { return false }
        let owner = model.sessionProfileID ?? model.profileScopeID
        let key = ProfileScopedID(profileID: owner, resourceID: session.id)
        return sidebarSnapshot.allProfilePinPresentation.selectedRow(key)?.scopedID == session.scopedID
    }

    private func moveToProject(_ session: HermesSession, _ target: SidebarProjectTarget) {
        Task { @MainActor in
            _ = await SessionProjectMove.perform(
                session, to: target, model: model, control: controlCenter, store: workspaceStore)
        }
    }

    /// Section rows remain lazy; only the header is pinned by the rail.
    @ViewBuilder
    private func conversationOutline(
        _ conversations: [HermesSession], type: SessionRecentsType,
        statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        let expanded =
            type == .automation ? $navigationState.areAutomationsExpanded : $navigationState.areConversationsExpanded
        Section {
            conversationRows(conversations, type: type, statuses: statuses, style: style)
                .sessionSidebarFadesUnderStickyHeader()
        } header: {
            DockSectionHeader(
                title: type == .automation ? "Automations" : "Recents",
                count: conversations.count,
                isExpanded: expanded,
                style: style
            ) {
                HStack(spacing: DockSpacing.tight) {
                    if hasUnread(conversations, statuses, type: type) {
                        DockIconButton(icon: .checks, label: "Mark all as read", size: 24, style: style) {
                            markAllSessionsRead(conversations, type: type)
                        }
                    }
                    DockIconButton(
                        icon: .arrowsClockwise,
                        label: sidebarSnapshot.inputs.isLoadingSessions
                            ? "Refreshing \(type.rowName)…" : "Refresh \(type.rowName)",
                        isBusy: sidebarSnapshot.inputs.isLoadingSessions,
                        size: 24,
                        style: style
                    ) {
                        model.loadSessions(reconcileHistory: true)
                        controlCenter.refreshProjectNavigation()
                    }
                }
            }
            .sessionRailReorder(type == .automation ? .automations : .recents, state: navigationState)
            .frame(maxWidth: .infinity)
            .dockPadding(.top, style.sectionSpacing)
            .dockPadding(.bottom, expanded.wrappedValue ? 2 : 0)
            .contextMenu {
                Button("Mark all as read") {
                    markAllSessionsRead(conversations, type: type)
                }
                .disabled(!hasUnread(conversations, statuses, type: type))
            }
            .sessionSidebarStickyBackground()
            .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private func conversationRows(
        _ conversations: [HermesSession], type: SessionRecentsType,
        statuses: [String: SidebarSessionStatus], style: DockThemePalette
    ) -> some View {
        if type == .automation ? navigationState.areAutomationsExpanded : navigationState.areConversationsExpanded {
            if conversations.isEmpty {
                queueEmpty(
                    sidebarSnapshot.inputs.isLoadingSessions
                        ? "Loading \(type.rowName)…"
                        : (type == .automation
                            ? "No automation sessions" : "No saved conversations"),
                    style: style
                )
                .dockPadding(.leading, 20)
            } else {
                let visibleSessions =
                    (type == .automation ? navigationState.showsAllAutomations : navigationState.showsAllConversations)
                    ? conversations
                    : Array(conversations.prefix(10))
                ForEach(visibleSessions, id: \.[sidebarSection: "conversations"]) { session in
                    conversationSessionRow(session, statuses: statuses, style: style)
                }
            }
            if conversations.count > 10 {
                conversationExpansionButton(type: type, style: style)
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

struct BotRailProfileTip: View {
    let bot: BotSummary
    let imageData: Data?

    var body: some View {
        let role = bot.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = bot.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                BotAvatarView(bot: bot, imageData: imageData, size: 36, animated: false, mood: .idle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.name)
                        .dockFont(.navigation, weight: .semibold)
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                    if !role.isEmpty {
                        Text(role)
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockSecondaryText)
                            .lineLimit(2)
                    }
                }
            }
            if !description.isEmpty {
                Color.dockBorderLight.frame(height: DockLayout.hairline)
                Text(description)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineSpacing(2)
                    .lineLimit(12)
            }
        }
    }
}
