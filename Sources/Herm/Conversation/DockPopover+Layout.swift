import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension DockPopover {
    func observerLayerOne<V: View>(_ view: V) -> some View {
        view
            .onReceive(model.objectWillChange) { _ in
                conversationPerformance.recordModelPublication()
            }
            .onChange(of: controlCenter.capabilities) { _, capabilities in
                handleCapabilitiesChange(capabilities)
            }
            .task(id: "\(model.kanbanSessionID ?? ""):\(hostPresentation.isVisible)") {
                guard hostPresentation.isVisible else { return }
                // Keeps chat kanban handoff notices current while the Activity
                // panel (which polls on its own) is closed.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, let sessionID = model.kanbanSessionID,
                        controlCenter.capabilityAvailable("kanban")
                    else { continue }
                    controlCenter.refreshSessionKanban(for: sessionID, quiet: true)
                }
            }
            .onAppear {
                configureWorkspaceOnAppear()
                model.richGenerationContextProvider = richHostRouter.contextProvider()
                chatContextRouter.model = model
                chatContextRouter.bots = botMode
                chatContextRouter.onOpened = { sessionID in
                    sessionNavNavigation.openPullRequestChat(sessionID: sessionID)
                    fullscreenSurface = .conversation
                    inspectorScope = .session
                }
            }
            .onChange(of: isWorkspaceVisible) { _, visible in
                handleWorkspaceVisibilityChange(visible)
            }
            // Keep each session's tabs and connect Hermes to its profile's browser.
            .onChange(of: model.isHermesConnected, initial: true) { _, connected in
                guard connected else { return }
                SessionBrowserStore.shared.activate(model: model, reconnect: true)
                Task { await botMode.refreshNow(force: true) }
            }
            .onChange(of: WorkspaceIdentity.session(model)) { _, _ in
                model.richGenerationContextProvider = richHostRouter.contextProvider()
            }
            .onChange(of: model.browserSessionKey) { _, _ in
                guard model.isHermesConnected else { return }
                SessionBrowserStore.shared.activate(model: model)
            }
            .onChange(of: model.profileScopeID) { _, _ in
                guard model.isHermesConnected, model.browserSessionKey == nil else { return }
                SessionBrowserStore.shared.activate(model: model)
            }
            .onChange(of: model.activeBrowserCall != nil) { _, browsing in
                if browsing, AgentBrowser.opensInHerm() {
                    NotificationCenter.default.post(name: .hermOpenInBrowser, object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hermOpenInBrowser)) { notification in
                let browserTabID: UUID?
                if let url = notification.object as? URL {
                    guard !InAppBrowser.handled else { return }
                    InAppBrowser.handled = true
                    browserTabID = SessionBrowserStore.shared.present(url, model: model)
                } else {
                    SessionBrowserStore.shared.present(nil, model: model)
                    browserTabID = nil
                }
                showSessionRailInspector(.browser, browserTabID: browserTabID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .hermRevealInspector)) { notification in
                guard let section = notification.object as? SessionInspector.Section else { return }
                if section == .browser {
                    SessionBrowserStore.shared.present(nil, model: model)
                }
                showSessionRailInspector(section)
            }
            .onReceive(SessionMessageTabs.shared.$openRequest) { workspace in
                guard workspace == WorkspaceIdentity.session(model) else { return }
                inspectorScope = .session
                ensureInspectorPanelVisible()
            }
            .onReceive(SessionSimulatorLaunchStore.shared.$latest) { request in
                guard let request, request.session == WorkspaceIdentity.session(model) else { return }
                showSessionRailInspector(request.receipt.target == .ios ? .iosSimulator : .androidEmulator)
            }
            .onChange(of: botMode.selectedProfileID) { _, profileID in
                handleProfileScopeChange(profileID)
            }
            .onChange(of: speechInput.completedTranscript) { _, transcript in
                handleCompletedTranscript(transcript)
            }
            .onChange(of: speechInput.isRecording) { _, isRecording in
                handleRecordingChange(isRecording)
            }
    }

    func observerLayerTwo<V: View>(_ view: V) -> some View {
        view
            .onReceive(filePreview.$attachmentDiff) { changes in
                guard changes != nil else { return }
                inspectorScope = .session
                sessionWorkspaceMode = .chat
                ensureInspectorPanelVisible()
            }
            .onChange(of: sessionWorkspaceMode) { previousMode, mode in
                handleSessionModeChange(previousMode: previousMode, mode: mode)
            }
            .onChange(of: model.status) { _, status in
                handleModelStatusChange(status)
            }
            .onChange(of: voiceOutput.isSpeaking) { _, isSpeaking in
                handleVoicePlaybackChange(isSpeaking)
            }
            .onChange(of: model.voiceState) { _, state in
                handleVoiceStateChange(state)
            }
            .onChange(of: model.isVoiceMicMuted) { _, _ in
                handleVoiceStateChange(model.voiceState)
            }
            .onChange(of: model.voicePromptSpeech) { _, speech in
                handleVoicePromptChange(speech)
            }
            .onDisappear {
                // Leaving the session view while voice is live must still release the mic.
                if sessionWorkspaceMode == .voice { releaseVoiceCapture() }
            }
    }

    func observerLayerThree<V: View>(_ view: V) -> some View {
        view
            // Settled destinations only: opening a session changes the surface before the session id.
            .background { historyShortcuts }
            .task(id: currentNavigationDestination) {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                navHistory.record(currentNavigationDestination)
            }
            .onChange(of: model.sessionID) { oldValue, newValue in
                filePreview.attachmentDiff = nil
                handleSessionIDChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: model.sessionID) { _, _ in
                isShowingMessagePins = false
                pinnedMessageJumpID = nil
                handleSessionMetadataChange()
            }
            .modifier(MessagePinFeedbackPresentation(model: model, isPresented: $isShowingMessagePins))
            .onChange(of: model.currentSessionTitle) { _, _ in handleWorkspaceChange() }
            .onChange(of: controlCenter.projectSessions) { _, _ in
                handleSessionMetadataChange()
            }
            .onChange(of: controlCenter.activeSessions) { _, _ in
                handleSessionMetadataChange()
            }
            .onChange(of: activeSessionRepositoryIdentity) { _, _ in
                clearSessionSurfaceSelections()
                if activeSessionRepositoryScope == nil,
                    sessionWorkspaceMode == .pullRequests || sessionWorkspaceMode == .issues
                {
                    selectSessionMode(.chat)
                }
            }
    }

    func observerLayerFour<V: View>(_ view: V) -> some View {
        view
            // Refresh the cached project name whenever the membership map updates.
            // This fires after the async resolveProjectMembership completes and
            // ensures the label reappears even after a refresh cycle wiped it.
            .onChange(of: controlCenter.projectIDBySessionID) { _, _ in
                handleProjectMembershipChange()
            }
            .onChange(of: model.messages.count) { oldCount, newCount in
                handleMessageCountChange(oldCount: oldCount, newCount: newCount)
            }
            .onChange(of: botMode.bots.first(where: \.isDefault)?.name, initial: true) { _, name in
                model.defaultBotName = name
            }
    }

    var rootPopoverContent: some View {
        Group {
            // Replaces the shell instead of overlaying it: the AppKit split
            // panes draw above SwiftUI overlays, so side panels showed through.
            if isVoiceImmersive && sessionWorkspaceMode == .voice {
                immersiveVoiceStage.dockPadding(.top, titlebarInset).transition(
                    .opacity.combined(with: .scale(scale: 1.02)))
            } else {
                layoutContent
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                    let oldHidesList = hidesChatList
                    let oldMinimum = desktopConversationMinimumWidth
                    workspaceGeometry.width = width
                    if oldHidesList != hidesChatList || oldMinimum != desktopConversationMinimumWidth {
                        workspaceLayoutRevision &+= 1
                    }
                }
            }
        }
        .animation(.dockEase(duration: 0.3), value: isVoiceImmersive)
        .frame(
            width: isFullscreen ? nil : min(popupWidth, panelPresentation.compactWidth),
            height: isFullscreen ? nil : panelPresentation.compactHeight
        )
        .dockPadding(
            panelPresentation.isEdgeAttached && !usesWindowChrome && !isFullscreen
                ? panelPresentation.edgeInsets
                : EdgeInsets()
        )
        .background {
            // Continue the sidebar surface through the corner clearance instead of exposing a decorative frame.
            if panelPresentation.isEdgeAttached, !usesWindowChrome, !isFullscreen {
                Color.dockSidebar
            }
            // The camera-housing band is always black, whatever skin the window wears.
            if panelPresentation.isEdgeAttached, panelPresentation.edgeSide == .top,
                !usesWindowChrome, !isFullscreen
            {
                Color.black.frame(height: panelPresentation.edgeInsets.top).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .overlay(alignment: .top) {
            if let status = panelPresentation.islandStatus, panelPresentation.edgeSide == .top,
                panelPresentation.isEdgeAttached, !usesWindowChrome, !isFullscreen
            {
                EdgeIslandStatusStrip(
                    state: status, control: controlCenter,
                    height: panelPresentation.edgeInsets.top - 8,
                    openTask: panelPresentation.openIslandTask,
                    openQuota: { panelPresentation.quotaRequest &+= 1 }
                )
                .dockPadding(.horizontal, EdgeDockLayout.islandSideInset + 12)
                .environment(\.colorScheme, .dark)
            }
        }
        .onChange(of: panelPresentation.availableWidth) { _, _ in synchronizePanelLayout() }
        .onChange(of: isGlobalSurfaceActive) { _, _ in synchronizePanelLayout() }
        .onChange(of: panelPresentation.isFullscreen, initial: true) { _, fullscreen in
            applyFullscreen(fullscreen)
        }
        .onChange(of: panelPresentation.kanbanRequest, initial: true) { _, request in
            guard request > 0 else { return }
            panelPresentation.kanbanRequest = 0
            sessionNavNavigation.selectGlobal(.kanban)
            fullscreenGlobalTab = .kanban
            fullscreenSurface = .global
        }
        .onChange(of: panelPresentation.quotaRequest, initial: true) { _, request in
            guard request > 0 else { return }
            panelPresentation.quotaRequest = 0
            sessionNavNavigation.selectGlobal(.quota)
            fullscreenGlobalTab = .quota
            fullscreenSurface = .global
        }
        .onChange(of: panelPresentation.settingsRequest, initial: true) { _, request in
            guard request > 0 else { return }
            panelPresentation.settingsRequest = 0
            sessionNavNavigation.selectGlobal(.core)
            fullscreenGlobalTab = .core
            fullscreenSurface = .global
        }
        .background {
            DockWindowBackground(
                shape: AnyShape(
                    DockPanelSurfaceShape(
                        isEdgeAttached: !usesWindowChrome && panelPresentation.isEdgeAttached,
                        cornerRadius: usesWindowChrome ? 0 : DockLayout.windowRadius,
                        edgeSide: panelPresentation.edgeSide
                    )))
        }
        .clipShape(
            DockPanelSurfaceShape(
                isEdgeAttached: !usesWindowChrome && panelPresentation.isEdgeAttached,
                cornerRadius: usesWindowChrome ? 0 : DockLayout.windowRadius,
                edgeSide: panelPresentation.edgeSide
            )
        )
        .overlay {
            DockPanelSurfaceShape(
                isEdgeAttached: !usesWindowChrome && panelPresentation.isEdgeAttached,
                cornerRadius: usesWindowChrome ? 0 : DockLayout.windowRadius,
                edgeSide: panelPresentation.edgeSide
            )
            .stroke(
                Color.dockBorderStrong,
                lineWidth: panelPresentation.isEdgeAttached && !usesWindowChrome
                    ? 1 : (DockThemeStyle.current.material == .glass ? 0 : DockLayout.hairline))
        }
        .modifier(
            EdgeSurfaceReveal(
                isActive: panelPresentation.isEdgeAttached && !usesWindowChrome && !isFullscreen,
                side: panelPresentation.edgeSide, revealed: panelPresentation.isRevealed,
                collapsed: panelPresentation.collapsedSize)
        )
        .ignoresSafeArea(edges: usesWindowChrome ? .top : [])
        .dockThemedRoot()
        .environment(\.dockNavigationHistory, navigationHistoryControls)
        .modifier(
            ExpandedReviewHost(
                model: model, router: expandedReviewRouter,
                titleRow: usesWindowChrome
                    ? DockTitleRow(
                        height: DockWindowChrome.titleRowHeight,
                        leadingClearance: DockWindowChrome.fullWidthTrafficLightClearance) : nil)
        )
        .dockSheet(item: $selectedChatImage) { preview in
            ChatImagePreviewModal(image: preview.image)
        }
        .dockSheet(
            item: Binding(
                get: { controlCenter.integrationDestination },
                set: { controlCenter.integrationDestination = $0 })
        ) { destination in
            WorkflowIntegrationView(destination: destination, client: model.controlRPCClient)
        }
        .modifier(
            WorkflowWorkspaceNavigation(
                model: model, control: controlCenter,
                openRepository: openRequestedRepositoryReview, openAutomation: openRequestedAutomation)
        )
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete \(session.displayTitle)", role: .destructive) {
                sessionPendingDeletion = nil
                Task { @MainActor in
                    if await model.deleteSession(session) {
                        controlCenter.refreshProjectNavigation()
                    }
                }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: { _ in
            Text("This permanently deletes the saved conversation and its transcript.")
        }
        .task {
            loadInitialModelConfiguration()
        }
    }

    /// Keep the same hosts across narrow, desktop, and fullscreen layouts.
    var layoutContent: some View {
        desktopWorkspaceShell
    }

    /// Pages put their DockPageHeader in the title row; group chats keep the plain inset.
    @ViewBuilder
    var globalSurfaceInTitleRow: some View {
        if usesWindowChrome, !showsChatsPanel {
            fullscreenGlobalSurface.environment(
                \.dockTitleRow,
                DockTitleRow(
                    height: DockWindowChrome.titleRowHeight,
                    leadingClearance: DockWindowChrome.trafficLightClearance
                ))
        } else {
            fullscreenGlobalSurface.underTitlebar(titlebarInset)
        }
    }

    /// Keep the navigation rail in one AppKit host for every desktop
    /// destination. Replacing a two-pane global host with a three-pane chat
    /// host remounted the rail after a session selection, producing the
    /// visible whole-app restart. Only the trailing workspace changes here.
    /// Applies to both the fullscreen and the windowed/minimized popover
    /// presentations, since both route through this shell.
    var desktopWorkspaceShell: some View {
        DockWorkspaceShell(
            toolbarHeight: titlebarInset, rail: { sessionNavRail },
            content: {
                FullscreenPanelSplitView(
                    leading: desktopLeadingPanel,
                    trailing: desktopTrailingWorkspace,
                    leadingFraction: DesktopWorkspaceFractions.queue,
                    minimumLeadingWidth: 300,
                    minimumTrailingWidth: desktopTrailingMinimumWidth,
                    isLeadingCollapsed: isNarrowLayout || !showsChatsPanel || hidesChatList
                )
            })
    }

    /// Sessions in Chats; every bot and group room on the Bots page.
    var desktopLeadingPanel: AnyView {
        AnyView(
            (fullscreenSurface == .bots ? AnyView(botsListPanel) : AnyView(sessionNavQueue))
                .environment(\.dockNavigationHistory, navigationHistoryControls)
                .environment(
                    \.dockHostVisible,
                    hostPresentation.isVisible && showsChatsPanel && !isNarrowLayout && !hidesChatList))
    }

    var openGroupRoom: GroupRoom? { botMode.groupChats.rooms.first { $0.id == openGroupRoomID } }

    var hidesChatList: Bool {
        guard fullscreenSurface == .conversation || fullscreenSurface == .bots, !isNarrowLayout else { return false }
        return isChatListCollapsed
            || DesktopWorkspaceFractions.listCannotFit(width: workspaceLayoutWidth, isFullscreen: isFullscreen)
            || (isInspectorVisibleForDesktopWorkspace
                && DesktopWorkspaceFractions.shouldCollapseQueue(
                    width: workspaceLayoutWidth, isFullscreen: isFullscreen))
    }

    var chatListCollapsed: Binding<Bool> {
        Binding(
            get: { hidesChatList },
            set: { collapsed in
                isChatListCollapsed = collapsed
                if !collapsed, isInspectorVisibleForDesktopWorkspace,
                    DesktopWorkspaceFractions.shouldCollapseQueue(
                        width: workspaceLayoutWidth, isFullscreen: isFullscreen)
                {
                    toggleInspectorPanel()
                }
            })
    }

    /// The session lists belong to Chats: a conversation is open.
    var showsChatsPanel: Bool {
        switch fullscreenSurface {
        case .conversation, .bots: true
        default: false
        }
    }

    var sessionNavRail: some View {
        SessionNavRail(
            model: model,
            controlCenter: controlCenter,
            workspaceStore: workspaceStore,
            isWorkspaceVisible: isWorkspaceVisible,
            agentUpdateService: agentUpdateService,
            navigationState: sessionNavNavigation,
            dockThemeStore: dockThemeStore,
            isChatsActive: showsChatsPanel || fullscreenSurface == .chatGrid,
            isGitHubActive: fullscreenSurface == .pullRequests || fullscreenSurface == .issues,
            onOpenChats: {
                leaveIntegrations {
                    sessionNavNavigation.clearSelection()
                    if sessionWorkspaceMode == .voice { selectSessionMode(.chat) }
                    fullscreenSurface = prefersChatGrid ? .chatGrid : .conversation
                    inspectorScope = .session
                    // Narrow layout shows the inspector instead of the chat; Chats brings the chat back.
                    if isNarrowLayout { isNarrowControlVisible = false }
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
            onOpenGitHub: { section in leaveIntegrations { selectGitHubSection(section) } },
            isFullscreen: isFullscreen,
            isHermesConnected: model.isHermesConnected,
            hermesConnectionIssue: model.hermesConnectionIssue,
            // A failure lands in `hermesConnectionIssue` through the gateway.
            onReconnect: { try? await model.gateway.connect() },
            isDockedWindow: usesWindowChrome,
            onFullscreenToggle: toggleFullscreen,
            onOpenWindow: onOpenWindow
        )
        .underTitlebar(titlebarInset, separator: false)
        .task(id: isWorkspaceVisible && hostPresentation.isVisible) {
            guard isWorkspaceVisible, hostPresentation.isVisible else { return }
            // Keep Chats status current even when its session list is unmounted.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                guard model.isHermesConnected else { continue }
                await model.loadSessions(quiet: true)?.value
            }
        }
        // The title strip above the rail is part of the sidebar, not the window canvas.
        .background(DockThemePalette(theme: dockThemeStore.selectedThemeID).sidebarBackground)
    }

    /// The outer split must leave room for the conversation's minimum plus
    /// the inspector's, or the inner split squeezes the conversation.
    var desktopTrailingMinimumWidth: CGFloat {
        guard !isGlobalSurfaceActive, sessionWorkspaceMode != .explorer else { return 360 }
        let conversation = desktopConversationMinimumWidth
        return isInspectorVisibleForDesktopWorkspace ? conversation + 1 + 360 : conversation
    }

    // The floating shell must fit the list, conversation, and inspector together.
    var desktopConversationMinimumWidth: CGFloat {
        let preferred = DesktopWorkspaceFractions.minimumConversationWidth(isFullscreen: isFullscreen)
        guard hidesChatList, isInspectorVisibleForDesktopWorkspace else { return preferred }
        return min(preferred, max(360, workspaceLayoutWidth - 52 - 2 - 360))
    }

    var desktopTrailingWorkspace: AnyView {
        if isGlobalSurfaceActive {
            return AnyView(globalSurfaceInTitleRow)
        } else {
            // The split stays mounted while the inspector is collapsed (the
            // trailing pane is only hidden) so tabs, open files and terminals
            // keep their state across collapse/expand.
            let isVisible = isInspectorVisibleForDesktopWorkspace
            return AnyView(
                FullscreenPanelSplitView(
                    leading: conversationColumn,
                    trailing:
                        contextPanel
                        .environment(\.dockHostVisible, hostPresentation.isVisible && isVisible)
                        .environment(\.localPreviewDiscoveryVisible, isVisible && expandedReviewRouter.layers.isEmpty),
                    // Fraction of the *remaining* space after the outer
                    // queue split, chosen so the three visible columns land
                    // at the DesktopWorkspaceFractions targets (queue /
                    // conversation / inspector) rather than an even split.
                    leadingFraction: sessionWorkspaceMode == .explorer
                        ? nil : DesktopWorkspaceFractions.conversationOfRemainder,
                    initialLeadingWidth: sessionWorkspaceMode == .explorer ? explorerNavigatorWidth : nil,
                    minimumLeadingWidth: sessionWorkspaceMode == .explorer
                        ? ExplorerWorkspaceMetrics.minimumNavigatorWidth : desktopConversationMinimumWidth,
                    maximumLeadingWidth: sessionWorkspaceMode == .explorer
                        ? ExplorerWorkspaceMetrics.maximumNavigatorWidth : nil,
                    minimumTrailingWidth: sessionWorkspaceMode == .explorer
                        ? ExplorerWorkspaceMetrics.minimumEditorWidth : 360,
                    leadingWidth: sessionWorkspaceMode == .explorer ? $explorerNavigatorWidth : nil,
                    isTrailingCollapsed: !isVisible,
                    isLeadingCollapsed: isNarrowLayout && isVisible
                )
            )
        }
    }

    var isGlobalSurfaceActive: Bool {
        switch fullscreenSurface {
        case .global, .artifacts, .pullRequests, .issues, .chatGrid: true
        case .conversation, .bots: false
        }
    }

    var isInspectorVisibleForDesktopWorkspace: Bool {
        isFullscreen ? isMissionInspectorVisible : isWorkspaceVisibleForLayout
    }

    var isWorkspaceVisible: Bool {
        // Inspector visibility is user-owned presentation state. Letting a
        // subagent event force it open replaces the split-view host and
        // reflows every transcript row during an active response, which can
        // invalidate the conversation's scroll extent.
        isWorkspaceManuallyExpanded
    }

    var isWorkspaceVisibleForLayout: Bool {
        if sessionWorkspaceMode == .explorer, isNarrowLayout {
            return isNarrowControlVisible && explorerSelection != nil
        }
        return isNarrowLayout ? isNarrowControlVisible : isWorkspaceVisible
    }

    /// Both fullscreen and the desktop dock use the queue → workspace →
    /// inspector shell. Keep the inspector chrome identical in those two
    /// presentations; only the genuinely narrow two-pane dock needs its own
    /// visible inspector scope picker.
    var usesSessionNavLayout: Bool {
        isFullscreen || (!isNarrowLayout && isWorkspaceVisibleForLayout)
    }

    var popupWidth: CGFloat {
        // Collapsing the inspector widens the conversation instead of shrinking the window.
        if !isNarrowLayout { return 1_200 }
        return 500
    }

    /// The status-bar item can live on a different display from `NSScreen.main`.
    /// Ask the native panel for the width it can actually occupy before choosing
    /// the desktop layout, then render only a layout that fits that screen.
    func synchronizePanelLayout() {
        let shouldUseNarrowLayout = availableWorkspaceWidth() < desktopRequiredWidth
        if isNarrowLayout != shouldUseNarrowLayout {
            isNarrowLayout = shouldUseNarrowLayout
            if shouldUseNarrowLayout { isNarrowControlVisible = false }
        }
        // Resize once, after the final presentation decision is known.
        _ = onWorkspaceWidthChange(popupWidth)
    }

    var conversationMetrics: ConversationWorkspaceMetrics {
        .resolve(isFullscreen: isFullscreen)
    }

    var conversationColumn: some View {
        VStack(spacing: 0) {
            if fullscreenSurface == .bots, let room = openGroupRoom {
                GroupChatView(
                    store: botMode.groupChats, botMode: botMode, roomID: room.id, metrics: conversationMetrics,
                    toolbar: { identity, actions in
                        AnyView(conversationToolbar(identity: identity, groupActions: actions))
                    }
                ) {
                    openGroupRoomID = ""
                }
                .id(room.id)
            } else {
                header
                switch sessionWorkspaceMode {
                case .chat:
                    GeometryReader { geometry in
                        let railWidth =
                            isSessionRailVisible
                            ? ConversationWorkspaceMetrics.sessionRailWidth(availableWidth: geometry.size.width) : 0
                        chatConversationContent(railWidth: railWidth)
                            .overlay(alignment: .trailing) {
                                if railWidth > 0 {
                                    SessionPullRequestRail(
                                        model: model, workflow: developerWorkflow, control: controlCenter,
                                        repositoryPath: activeSessionRepositoryScope?.repositoryPath,
                                        onViewAllChanges: { showSessionRailInspector(.changes) },
                                        onViewPullRequest: viewSessionRailPullRequest,
                                        onRefreshChanges: refreshSessionRailChanges,
                                        onViewAllOutputs: { showSessionRailInspector(.artifacts) },
                                        onViewTimeline: { showSessionRailInspector(.timeline) },
                                        onRespondInChat: {
                                            sessionRailReplyRequest &+= 1
                                            model.requestComposerFocus()
                                        },
                                        onViewPin: { pin in
                                            let identity = WorkspaceIdentity.session(model)
                                            guard let id = await model.messageID(forPin: pin),
                                                identity == WorkspaceIdentity.session(model)
                                            else { return false }
                                            pinnedMessageJumpID = id
                                            return true
                                        }
                                    )
                                    .id(sessionWorkspaceIdentity)
                                    .frame(width: railWidth - DockSpacing.section)
                                    .dockPadding(.trailing, DockSpacing.section)
                                }
                            }
                    }
                case .voice:
                    if isVoiceImmersive {
                        // Full voice mode renders the stage over the whole shell.
                        Color.clear
                    } else {
                        voiceMode
                    }
                case .explorer:
                    SessionExplorerSurface(
                        scope: activeSessionRepositoryScope,
                        isCompact: isNarrowLayout,
                        onRefresh: { await refreshSessionWorkflow() },
                        onOpenFile: { scope, document in
                            guard scope == activeSessionRepositoryScope else { return }
                            explorerSelection = ScopedRepositoryDocument(scope: scope, document: document)
                            if isNarrowLayout { isNarrowControlVisible = true }
                        }
                    )
                case .sourceControl:
                    SessionSourceControlSurface(
                        model: model,
                        workflow: developerWorkflow,
                        scope: activeSessionRepositoryScope,
                        onRefresh: { await refreshSessionWorkflow() },
                        onSelectFile: selectChangeFile,
                        selectedFilePath: selectedChange?.scope == activeSessionRepositoryScope
                            ? selectedChange?.file.path : nil
                    )
                case .pullRequests:
                    SessionPullRequestsSurface(
                        center: sessionPullRequestCenter,
                        repositoryPath: activeSessionRepositoryPath,
                        onOpenChat: openPullRequestChat
                    )
                case .issues:
                    SessionIssuesSurface(center: sessionIssueCenter, repositoryPath: activeSessionRepositoryPath)
                }
            }
        }
    }

    func chatConversationContent(railWidth: CGFloat) -> some View {
        ConversationComposerLayout(
            showsWelcome: model.messages.isEmpty && model.status != .working && !speechInput.isRecording,
            hermFaceID: conversationHermFaceID,
            trailingContentInset: railWidth
        ) {
            conversation(trailingContentInset: railWidth)
        } composer: {
            ChatComposerView(
                model: model,
                composer: model.composer,
                speechInput: speechInput,
                botMode: botMode,
                onStop: stopCurrentRequest,
                isFullscreen: isFullscreen,
                metrics: conversationMetrics,
                controlCenter: controlCenter,
                openQuota: { panelPresentation.quotaRequest += 1 },
                worktreeBar: activeSessionRepositoryScope.map { scope in
                    WorktreePicker(
                        worktrees: developerWorkflow.repository.path == scope.repositoryPath
                            ? developerWorkflow.worktrees : [],
                        selection: scope.repositoryPath,
                        worktreesUnavailable: developerWorkflow.repository.isGitRepository
                            && developerWorkflow.worktreesUnavailable,
                        onOpenWorktree: { await selectWorktree($0) },
                        newTask: { await startWorktreeTask(from: scope.repositoryPath) }
                    )
                }
            )
            .dockPadding(.trailing, railWidth)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 4) {
                SessionSimulatorBanner(
                    sessionKey: WorkspaceIdentity.session(model), metrics: conversationMetrics
                ) { platform in
                    showSessionRailInspector(platform == .ios ? .iosSimulator : .androidEmulator)
                }
                ChatQuotaBanner(control: controlCenter, metrics: conversationMetrics)
            }
            .dockPadding(.trailing, railWidth)
        }
    }
}
