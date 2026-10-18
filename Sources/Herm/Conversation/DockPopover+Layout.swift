import AppKit
import Combine
import SwiftUI
import Foundation
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
        .task(id: model.kanbanSessionID) {
            // Keeps chat kanban handoff notices current while the Activity
            // panel (which polls on its own) is closed.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let sessionID = model.kanbanSessionID,
                      controlCenter.capabilityAvailable("kanban") else { continue }
                controlCenter.refreshSessionKanban(for: sessionID, quiet: true)
            }
        }
        .onAppear {
            configureWorkspaceOnAppear()
            chatContextRouter.model = model
            chatContextRouter.onOpened = { sessionID in
                missionControlNavigation.openPullRequestChat(sessionID: sessionID)
                fullscreenSurface = .conversation
                inspectorScope = .session
            }
        }
        .onChange(of: isWorkspaceVisible) { _, visible in
            handleWorkspaceVisibilityChange(visible)
        }
        // Retain each session's browser and connect Hermes to the selected one.
        .onChange(of: model.isHermesConnected, initial: true) { _, connected in
            guard connected else { return }
            SessionBrowserStore.shared.activate(model: model, reconnect: true)
        }
        .onChange(of: model.browserSessionKey) { _, _ in
            guard model.isHermesConnected else { return }
            SessionBrowserStore.shared.activate(model: model)
        }
        .onChange(of: model.activeBrowserCall != nil) { _, browsing in
            if browsing { NotificationCenter.default.post(name: .hermOpenInBrowser, object: nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermOpenInBrowser)) { notification in
            if let url = notification.object as? URL {
                guard !InAppBrowser.handled else { return }
                InAppBrowser.handled = true
                SessionBrowserStore.shared.present(url, model: model)
            } else {
                SessionBrowserStore.shared.present(nil, model: model)
            }
            inspectorScope = .session
            if isFullscreen { isMissionInspectorVisible = true }
            else if isNarrowLayout { isNarrowControlVisible = true }
            else { isWorkspaceManuallyExpanded = true }
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
        .onChange(of: filePreview.url) { _, _ in showFilePreview() }
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
        .onChange(of: model.sessionID) { oldValue, newValue in
            filePreview.attachmentDiff = nil
            handleSessionIDChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: model.sessionID) { _, _ in
            isShowingMessagePins = false
            pinnedMessageJumpID = nil
            handleSessionMetadataChange()
        }
        .onChange(of: model.messagePinError) { _, error in
            if error != nil && model.messagePinsSupported { isShowingMessagePins = true }
        }
        .onChange(of: model.currentSessionTitle) { _, _ in handleWorkspaceChange() }
        .onChange(of: controlCenter.projectSessions) { _, _ in
            handleSessionMetadataChange()
        }
        .onChange(of: controlCenter.activeSessions) { _, _ in
            handleSessionMetadataChange()
        }
        .onChange(of: activeSessionRepositoryIdentity) { _, _ in
            clearSessionSurfaceSelections()
            if activeSessionRepositoryScope == nil, sessionWorkspaceMode == .pullRequests {
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
                immersiveVoiceStage.padding(.top, titlebarInset).transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                layoutContent
            }
        }
            .animation(.dockEase(duration: 0.3), value: isVoiceImmersive)
            .frame(width: isFullscreen ? nil : min(popupWidth, panelPresentation.compactWidth), height: isFullscreen ? nil : panelPresentation.compactHeight)
            .padding(panelPresentation.isEdgeAttached && !usesWindowChrome
                     ? (isFullscreen ? EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 0) : panelPresentation.edgeInsets)
                     : EdgeInsets())
            .overlay(alignment: .top) {
                if let status = panelPresentation.islandStatus, panelPresentation.edgeSide == .top,
                   panelPresentation.isEdgeAttached, !usesWindowChrome, !isFullscreen {
                    EdgeIslandStatusStrip(state: status, control: controlCenter,
                        height: panelPresentation.edgeInsets.top - 8,
                        openTask: panelPresentation.openIslandTask,
                        openQuota: { panelPresentation.quotaRequest &+= 1 })
                        .padding(.horizontal, EdgeDockLayout.islandSideInset + 12)
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
                missionControlNavigation.selectGlobal(.kanban)
                fullscreenGlobalTab = .kanban
                fullscreenSurface = .global
            }
            .onChange(of: panelPresentation.quotaRequest, initial: true) { _, request in
                guard request > 0 else { return }
                panelPresentation.quotaRequest = 0
                missionControlNavigation.selectGlobal(.quota)
                fullscreenGlobalTab = .quota
                fullscreenSurface = .global
            }
            .background { DockWindowBackground() }
            .clipShape(DockPanelSurfaceShape(
                isEdgeAttached: !usesWindowChrome && panelPresentation.isEdgeAttached,
                cornerRadius: usesWindowChrome ? 0 : 22,
                edgeSide: panelPresentation.edgeSide
            ))
            .overlay {
                DockPanelSurfaceShape(
                    isEdgeAttached: !usesWindowChrome && panelPresentation.isEdgeAttached,
                    cornerRadius: usesWindowChrome ? 0 : 22,
                    edgeSide: panelPresentation.edgeSide
                )
                    .stroke(Color.dockBorderStrong, lineWidth: panelPresentation.isEdgeAttached && !usesWindowChrome ? 1 : DockLayout.hairline)
            }
            .modifier(EdgeSurfaceReveal(isActive: panelPresentation.isEdgeAttached && !usesWindowChrome && !isFullscreen,
                                        side: panelPresentation.edgeSide, revealed: panelPresentation.isRevealed,
                                        collapsed: panelPresentation.collapsedSize))
            .ignoresSafeArea(edges: usesWindowChrome ? .top : [])
            .dockThemedRoot()
            .preferredColorScheme(dockThemeStore.selectedThemeID.appearance == .light ? .light : dockThemeStore.selectedThemeID.appearance == .dark ? .dark : (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
            .sheet(item: $selectedChatImage) { preview in
                ChatImagePreviewModal(image: preview.image)
            }
            .sheet(item: $controlCenter.integrationDestination) { destination in
                WorkflowIntegrationView(destination: destination, client: model.controlRPCClient)
            }
            .modifier(WorkflowWorkspaceNavigation(model: model, control: controlCenter,
                openRepository: openRequestedRepositoryReview, openAutomation: openRequestedAutomation))
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
            .alert(
                "Could Not Delete Session",
                isPresented: Binding(
                    get: { model.sessionDeletionError != nil },
                    set: { if !$0 { model.clearSessionDeletionError() } }
                )
            ) {
                Button("OK", role: .cancel) { model.clearSessionDeletionError() }
            } message: {
                Text(model.sessionDeletionError ?? "The session could not be deleted.")
            }
            .alert(
                "Could Not Update Session Visibility",
                isPresented: Binding(
                    get: { model.sessionVisibilityError != nil },
                    set: { if !$0 { model.clearSessionVisibilityError() } }
                )
            ) {
                Button("OK", role: .cancel) { model.clearSessionVisibilityError() }
            } message: {
                Text(model.sessionVisibilityError ?? "The session visibility could not be updated.")
            }
            .task {
                loadInitialModelConfiguration()
            }
    }

    /// Fullscreen and the desktop panel must share this single
    /// `desktopWorkspaceShell` branch. Rendering it from separate if/else
    /// branches gave each presentation its own identity, so toggling
    /// fullscreen remounted the whole workspace and reset its state.
    @ViewBuilder
    var layoutContent: some View {
        if !isNarrowLayout {
            desktopWorkspaceShell
        } else {
            // Same shell as fullscreen, compacted: the rail stays and only the
            // content pane narrows. Global destinations replace the chat/inspector pair.
            HStack(spacing: 0) {
                missionControlRail
                if isGlobalSurfaceActive {
                    globalSurfaceInTitleRow
                } else {
                    HStack(spacing: 2) {
                        if !isNarrowControlVisible {
                            conversationColumn
                                .frame(width: narrowPaneWidth, height: panelPresentation.compactHeight)
                        }

                        if isWorkspaceVisibleForLayout {
                            Rectangle().fill(Color.dockBorder).frame(width: DockLayout.hairline)
                            contextPanel
                                .frame(width: narrowPaneWidth, height: panelPresentation.compactHeight)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .underTitlebar(titlebarInset)
                }
            }
        }
    }

    /// Pages put their DockPageHeader in the title row; group chats keep the plain inset.
    @ViewBuilder
    var globalSurfaceInTitleRow: some View {
        if usesWindowChrome, !showsChatsPanel {
            fullscreenGlobalSurface.environment(\.dockTitleRow, DockTitleRow(
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
        HStack(spacing: 0) {
            missionControlRail
            // Starts below the title row so it doesn't cut through the traffic lights;
            // the gap above it is title row, not see-through window.
            Color.dockBorder.frame(width: DockLayout.hairline).padding(.top, titlebarInset)
                .background(Color.dockSidebar)
            if showsChatsPanel, !hidesChatList {
                FullscreenPanelSplitView(
                    leading: missionControlQueue,
                    trailing: desktopTrailingWorkspace,
                    leadingFraction: usesWindowChrome ? DesktopWorkspaceFractions.windowQueue : DesktopWorkspaceFractions.queue,
                    minimumLeadingWidth: 300,
                    minimumTrailingWidth: desktopTrailingMinimumWidth
                )
            } else {
                desktopTrailingWorkspace
            }
        }
    }

    /// Only the windowed chat has a toggle to bring the list back, so only it collapses.
    var hidesChatList: Bool {
        isChatListCollapsed && usesWindowChrome && fullscreenSurface == .conversation && !isNarrowLayout
    }

    /// The session lists belong to Chats: a conversation or group chat is open.
    var showsChatsPanel: Bool {
        switch fullscreenSurface {
        case .conversation, .groupChat: true
        default: false
        }
    }

    var missionControlRail: some View {
        MissionControlRail(
            agentUpdateService: agentUpdateService,
            navigationState: missionControlNavigation,
            dockThemeStore: dockThemeStore,
            isChatsActive: showsChatsPanel,
            isIssuesActive: fullscreenSurface == .issues,
            onOpenChats: {
                missionControlNavigation.clearSelection()
                if sessionWorkspaceMode == .voice { selectSessionMode(.chat) }
                fullscreenSurface = .conversation
                inspectorScope = .session
                // Narrow layout shows the inspector instead of the chat; Chats brings the chat back.
                if isNarrowLayout { isNarrowControlVisible = false }
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
            onOpenPullRequests: {
                missionControlNavigation.selectPullRequests()
                fullscreenSurface = .pullRequests
            },
            onOpenIssues: {
                missionControlNavigation.selectIssues()
                fullscreenSurface = .issues
            },
            isFullscreen: isFullscreen,
            isDockedWindow: usesWindowChrome,
            onFullscreenToggle: toggleFullscreen,
            onOpenWindow: onOpenWindow
        )
        .underTitlebar(titlebarInset, separator: false)
        // The title strip above the rail is part of the sidebar, not the window canvas.
        .background(DockThemePalette(theme: dockThemeStore.selectedThemeID).sidebarBackground)
    }

    /// The outer split must leave room for the conversation's minimum plus
    /// the inspector's, or the inner split squeezes the conversation.
    var desktopTrailingMinimumWidth: CGFloat {
        guard !isGlobalSurfaceActive, sessionWorkspaceMode != .explorer else { return 360 }
        let conversation = DesktopWorkspaceFractions.minimumConversationWidth
        return isInspectorVisibleForDesktopWorkspace ? conversation + 1 + 360 : conversation
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
                GeometryReader { geometry in
                    let minimumWidth = sessionWorkspaceMode == .explorer
                        ? ExplorerWorkspaceMetrics.minimumNavigatorWidth + 1 + ExplorerWorkspaceMetrics.minimumEditorWidth
                        : DesktopWorkspaceFractions.minimumConversationWidth + 1 + 360
                    if isVisible, geometry.size.width < minimumWidth {
                        VStack(spacing: 0) {
                            // The session tab strip already carries the toggle.
                            if !inspectorHasOwnToggle {
                                HStack {
                                    Spacer()
                                    DockSidebarToggle(isCollapsed: false, edge: .trailing, action: toggleInspectorPanel)
                                }
                                .padding(.horizontal, 8)
                            }
                            contextPanel
                        }
                    } else {
                        FullscreenPanelSplitView(
                            leading: conversationColumn,
                            trailing: contextPanel,
                            // Fraction of the *remaining* space after the outer
                            // queue split, chosen so the three visible columns land
                            // at the DesktopWorkspaceFractions targets (queue /
                            // conversation / inspector) rather than an even split.
                            leadingFraction: sessionWorkspaceMode == .explorer ? nil : DesktopWorkspaceFractions.conversationOfRemainder,
                            initialLeadingWidth: sessionWorkspaceMode == .explorer ? explorerNavigatorWidth : nil,
                            minimumLeadingWidth: sessionWorkspaceMode == .explorer ? ExplorerWorkspaceMetrics.minimumNavigatorWidth : DesktopWorkspaceFractions.minimumConversationWidth,
                            maximumLeadingWidth: sessionWorkspaceMode == .explorer ? ExplorerWorkspaceMetrics.maximumNavigatorWidth : nil,
                            minimumTrailingWidth: sessionWorkspaceMode == .explorer ? ExplorerWorkspaceMetrics.minimumEditorWidth : 360,
                            leadingWidth: sessionWorkspaceMode == .explorer ? $explorerNavigatorWidth : nil,
                            isTrailingCollapsed: !isVisible
                        )
                    }
                }
            )
        }
    }

    var isGlobalSurfaceActive: Bool {
        switch fullscreenSurface {
        case .global, .artifacts, .bots, .groupChat, .pullRequests, .issues: true
        case .conversation: false
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
    var usesMissionControlLayout: Bool {
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
            header
            switch sessionWorkspaceMode {
            case .chat:
                conversation
                    .overlay(alignment: .top) { ChatQuotaBanner(control: controlCenter, metrics: conversationMetrics) }
                ChatComposerView(
                    model: model,
                    composer: model.composer,
                    speechInput: speechInput,
                    botMode: botMode,
                    onStop: stopCurrentRequest,
                    isFullscreen: isFullscreen,
                    metrics: conversationMetrics,
                    controlCenter: controlCenter,
                    openQuota: { panelPresentation.quotaRequest += 1 }
                )
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
                    selectedFilePath: selectedChange?.file.path
                )
            case .pullRequests:
                SessionPullRequestsSurface(
                    center: sessionPullRequestCenter,
                    repositoryPath: activeSessionRepositoryPath,
                    onOpenChat: openPullRequestChat
                )
            }
        }
    }
}
