import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// Native panel placement is owned by AppKit, while this state lets the
/// SwiftUI surface match its silhouette without resetting conversation state.
final class DockPanelPresentation: ObservableObject {
    @Published var isEdgeAttached = false
}

/// Presentation state owned by the left navigation rail, rather than a
/// particular split-view host. Global destinations replace their trailing
/// content host, so keeping this state here lets the rail retain its expanded
/// sections and local selection while the user moves between pages.
private final class MissionControlNavigationState: ObservableObject {
    @Published var showsAllConversations = false
    @Published var selectedTaskID: UUID?
    @Published var selectedSessionID: String?
    @Published var areConversationsExpanded = true
    var hasRequestedSessionIndex = false
}

private struct DockPanelSurfaceShape: Shape {
    let isEdgeAttached: Bool
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()

        if isEdgeAttached {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )

        if !isEdgeAttached {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }
        path.closeSubpath()
        return path
    }
}

/// Canonical owner for session workspace presentation state. A document or
/// diff is valid only while both the session and its resolved repository path
/// still match this scope.
struct SessionRepositoryScope: Equatable {
    let sessionID: String
    let repositoryPath: String

    var identity: String { "\(sessionID):\(repositoryPath)" }
}

struct ScopedRepositoryDocument: Equatable {
    let scope: SessionRepositoryScope
    let document: RepositoryFileDocument
}

struct ScopedRepositoryChange: Equatable {
    let scope: SessionRepositoryScope
    let file: RepositoryFileChange
}

struct DockPopover: View {
    @ObservedObject var model: DockModel
    @ObservedObject var panelPresentation: DockPanelPresentation
    /// Read-only screen capacity. Layout decisions must never resize the live
    /// panel while they are merely determining whether desktop content fits.
    var availableWorkspaceWidth: () -> CGFloat = { .greatestFiniteMagnitude }
    var onWorkspaceWidthChange: (CGFloat) -> CGFloat = { $0 }
    var onClose: () -> Void = {}
    var onFullscreenToggle: () -> Void = {}
    @State private var isConversationAtBottom = true
    @State private var unseenMessageCount = 0
    @State private var lastRenderedMessageBubbleCount = 0
    @State private var conversationScrollRequest = 0
    @State private var renderedMessageLimit = ConversationMessageWindow.initialLimit
    @State private var visibleNavigatorTargets: Set<MessageNavigatorTarget> = []
    @State private var isStreamingTailScrollScheduled = false
    @State private var isTransientTailAdjustmentScheduled = false
    @State private var isPastEndRepairScheduled = false
    @State private var isHistoryCompactionScheduled = false
    @State private var conversationPerformance = ConversationPerformanceMonitor()
    @State private var isWorkspaceManuallyExpanded = true
    @State private var isNarrowLayout = false
    @State private var isNarrowControlVisible = true
    @State private var selectedChatImage: ChatImagePreview?
    @StateObject private var speechInput = SpeechInput()
    @StateObject private var voiceOutput = VoiceOutput()
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var controlCenter = ControlCenterModel()
    @StateObject private var agentUpdateService = HermesUpdateService()
    @StateObject private var developerWorkflow = DeveloperWorkflowModel()
    @StateObject private var pullRequestCenter = PullRequestCenterModel()
    @StateObject private var pullRequestChatLinks = PullRequestChatLinkStore()
    @StateObject private var repositoryPreferences = CommandCenterPreferencesStore()
    @StateObject private var botMode = BotModeModel()
    @StateObject private var missionControlNavigation = MissionControlNavigationState()
    @State private var sessionWorkspaceMode: SessionWorkspaceMode = .chat
    @State private var suppressNextVoiceResponse = false
    @State private var sessionPendingDeletion: HermesSession?
    // These selections are owned by the active session/repository scope. The
    // request IDs invalidate completions from an older scope or selection.
    @State private var explorerSelection: ScopedRepositoryDocument?
    @State private var selectedChange: ScopedRepositoryChange?
    @State private var selectedChangeDiff: RepositoryDiff?
    @State private var isLoadingChangeDiff = false
    @State private var sourceControlRequestID = UUID()
    @StateObject private var sessionPullRequestCenter = PullRequestCenterModel()
    // A restored/active conversation is the primary workspace at launch, so
    // the right pane should open on its session context rather than Today.
    @State private var inspectorScope: InspectorScope = .session
    /// Cached project/repo folder name for the active session.
    /// Only updated when a non-nil value is resolved — never cleared on transient
    /// refresh-cycle gaps where projectIDBySessionID is momentarily empty.
    @State private var cachedProjectName: String? = nil
    @State private var cachedSessionRepositoryPath: String? = nil
    @State private var lastSessionTitleAtIdentityChange: String?
    @State private var isFullscreen = false
    @State private var isMissionInspectorVisible = true

    private enum FullscreenSurface {
        case conversation, pullRequests
        case global
        case artifacts
        case bots
    }
    @State private var fullscreenSurface: FullscreenSurface = .conversation
    @State private var fullscreenGlobalTab: ControlTab = .today

    enum SessionWorkspaceMode: CaseIterable, Identifiable {
        case chat
        case voice
        case explorer
        case sourceControl
        case pullRequests

        var id: Self { self }

        var label: String {
            switch self {
            case .chat: "Chat"
            case .voice: "Talk"
            case .explorer: "Explorer"
            case .sourceControl: "Source Control"
            case .pullRequests: "Pull Requests"
            }
        }

        var icon: String {
            switch self {
            case .chat: "text.bubble"
            case .voice: "audio-lines"
            case .explorer: "folder"
            case .sourceControl: "arrow.triangle.branch"
            case .pullRequests: "git.pull.request"
            }
        }

        var help: String {
            switch self {
            case .chat: "Conversation transcript and composer"
            case .voice: "Voice conversation"
            case .explorer: "Browse this session's project files"
            case .sourceControl: "Review this session's repository changes"
            case .pullRequests: "Pull requests for this session's repository"
            }
        }

        /// Whether the inspector renders the selected center content's preview.
        var usesContextPreview: Bool {
            switch self {
            case .explorer, .sourceControl, .pullRequests: true
            case .chat, .voice: false
            }
        }
    }

    private enum InspectorScope: String, CaseIterable, Identifiable {
        case global = "Global"
        case session = "Session"
        case artifacts = "Artifacts"

        var id: Self { self }

        var icon: String {
            switch self {
            case .global: "square.grid.2x2"
            case .session: "bubble.left.and.bubble.right"
            case .artifacts: "doc.text.magnifyingglass"
            }
        }
    }

    private enum QuickPrompt: CaseIterable, Identifiable {
        case reminder, notes, research, summarize, automation, review, email, message, search, kanban

        var id: Self { self }
        var label: String {
            switch self {
            case .reminder: "Reminder"
            case .notes: "Save to Notes"
            case .research: "Research"
            case .summarize: "Summarize work"
            case .automation: "Recurring automation"
            case .review: "Review work"
            case .email: "Email"
            case .message: "Message"
            case .search: "Search sources"
            case .kanban: "Kanban task"
            }
        }
        var prompt: String {
            switch self {
            case .reminder: "Create an Apple Reminder for: "
            case .notes: "Save the following to Apple Notes: "
            case .research: "Start research on: "
            case .summarize: "Summarize my active work and list the next actions."
            case .automation: "Help me create a recurring automation for: "
            case .review: "Review my completed work and identify anything that needs follow-up."
            case .email: "Using the Himalaya skill, help me draft or send this email: "
            case .message: "Using the configured messaging skill, help me draft or send this message: "
            case .search: "Search all connected Hermes sources for: "
            case .kanban: "Create or update a Hermes Kanban task for: "
            }
        }

        var requiredCapability: String? {
            switch self {
            case .reminder: "reminders"
            case .notes: "notes"
            case .automation: "rpc-scheduling"
            case .email: "email"
            case .message: "messaging"
            case .kanban: "kanban.create"
            case .research, .summarize, .review, .search: nil
            }
        }
    }

    var body: some View {
        observerLayerFour(observerLayerThree(observerLayerTwo(observerLayerOne(rootPopoverContent))))
    }

    private func observerLayerOne<V: View>(_ view: V) -> some View {
        view
        .onReceive(model.objectWillChange) { _ in
            conversationPerformance.recordModelPublication()
        }
        .onChange(of: controlCenter.capabilities) { _, capabilities in
            handleCapabilitiesChange(capabilities)
        }
        .onAppear {
            configureWorkspaceOnAppear()
        }
        .onChange(of: isWorkspaceVisible) { _, visible in
            handleWorkspaceVisibilityChange(visible)
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

    private func observerLayerTwo<V: View>(_ view: V) -> some View {
        view
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
    }

    private func observerLayerThree<V: View>(_ view: V) -> some View {
        view
        .onChange(of: model.sessionID) { oldValue, newValue in
            handleSessionIDChange(oldValue: oldValue, newValue: newValue)
        }
        .onChange(of: model.sessionID) { _, _ in
            handleSessionMetadataChange()
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
        }
    }

    private func observerLayerFour<V: View>(_ view: V) -> some View {
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
    }

    private var rootPopoverContent: some View {
        layoutContent
            .frame(width: isFullscreen ? nil : popupWidth, height: isFullscreen ? nil : 720)
            .background(Color.dockCanvas)
            .clipShape(DockPanelSurfaceShape(
                isEdgeAttached: !isFullscreen && panelPresentation.isEdgeAttached,
                cornerRadius: isFullscreen ? 0 : 22
            ))
            .overlay {
                DockPanelSurfaceShape(
                    isEdgeAttached: !isFullscreen && panelPresentation.isEdgeAttached,
                    cornerRadius: isFullscreen ? 0 : 22
                )
                    .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.5)
            }
            .animation(.dockEase(duration: 0.35), value: isWorkspaceVisibleForLayout)
            .sheet(item: $selectedChatImage) { preview in
                ChatImagePreviewModal(image: preview.image)
            }
            .task {
                loadInitialModelConfiguration()
            }
    }

    @ViewBuilder
    private var layoutContent: some View {
        if isFullscreen && !isNarrowLayout {
            desktopWorkspaceShell
        } else {
            compactLayoutContent
        }
    }

    @ViewBuilder
    private var compactLayoutContent: some View {
        if !isNarrowLayout {
            desktopWorkspaceShell
        } else {
            HStack(spacing: 2) {
                if !isNarrowLayout || !isNarrowControlVisible {
                    conversationColumn
                        .frame(
                            width: isFullscreen ? .infinity : (showsDesktopContextPanel ? 480 : 500),
                            height: isFullscreen ? .infinity : 720
                        )
                }

                if isWorkspaceVisibleForLayout {
                    Rectangle().fill(Color.dockBorderLight).frame(width: 0.5)
                    contextPanel
                        .frame(
                            width: isFullscreen ? .infinity : (isNarrowLayout ? 500 : 480),
                            height: isFullscreen ? .infinity : 720
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    /// Keep the navigation rail in one AppKit host for every desktop
    /// destination. Replacing a two-pane global host with a three-pane chat
    /// host remounted the rail after a session selection, producing the
    /// visible whole-app restart. Only the trailing workspace changes here.
    private var desktopWorkspaceShell: some View {
        FullscreenPanelSplitView(
            leading: missionControlQueue,
            trailing: desktopTrailingWorkspace,
            leadingFraction: 0.30
        )
    }

    private var desktopTrailingWorkspace: AnyView {
        if isGlobalSurfaceActive {
            AnyView(fullscreenGlobalSurface)
        } else if isInspectorVisibleForDesktopWorkspace {
            // The nested split keeps the conversation and inspector resizable
            // without disturbing the outer, persistent navigation split.
            AnyView(
                FullscreenPanelSplitView(
                    leading: conversationColumn,
                    trailing: contextPanel,
                    leadingFraction: 0.57
                )
            )
        } else {
            AnyView(conversationColumn)
        }
    }

    private var isGlobalSurfaceActive: Bool {
        switch fullscreenSurface {
        case .global, .artifacts, .bots, .pullRequests: true
        case .conversation: false
        }
    }

    private var isInspectorVisibleForDesktopWorkspace: Bool {
        isFullscreen ? isMissionInspectorVisible : isWorkspaceVisibleForLayout
    }

    private var isWorkspaceVisible: Bool {
        // Inspector visibility is user-owned presentation state. Letting a
        // subagent event force it open replaces the split-view host and
        // reflows every transcript row during an active response, which can
        // invalidate the conversation's scroll extent.
        isWorkspaceManuallyExpanded
    }

    private var isWorkspaceVisibleForLayout: Bool {
        isNarrowLayout ? isNarrowControlVisible : isWorkspaceVisible
    }

    /// Both fullscreen and the desktop dock use the queue → workspace →
    /// inspector shell. Keep the inspector chrome identical in those two
    /// presentations; only the genuinely narrow two-pane dock needs its own
    /// visible inspector scope picker.
    private var usesMissionControlLayout: Bool {
        isFullscreen || (!isNarrowLayout && isWorkspaceVisibleForLayout)
    }

    private var popupWidth: CGFloat {
        if !isNarrowLayout { return showsDesktopContextPanel ? 1_200 : 720 }
        return 500
    }

    private var showsDesktopContextPanel: Bool {
        !isNarrowLayout && isWorkspaceVisibleForLayout
    }

    /// The status-bar item can live on a different display from `NSScreen.main`.
    /// Ask the native panel for the width it can actually occupy before choosing
    /// the desktop layout, then render only a layout that fits that screen.
    private func synchronizePanelLayout() {
        let shouldUseNarrowLayout = availableWorkspaceWidth() < desktopRequiredWidth
        if isNarrowLayout != shouldUseNarrowLayout {
            isNarrowLayout = shouldUseNarrowLayout
            if shouldUseNarrowLayout { isNarrowControlVisible = false }
        }
        // Resize once, after the final presentation decision is known.
        _ = onWorkspaceWidthChange(popupWidth)
    }

    private var desktopRequiredWidth: CGFloat { 1_040 }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            header
            switch sessionWorkspaceMode {
            case .chat:
                conversation
                Divider().overlay(Color.dockBorderLight)
                ChatComposerView(
                    model: model,
                    composer: model.composer,
                    speechInput: speechInput,
                    botMode: botMode,
                    onStop: stopCurrentRequest,
                    isFullscreen: isFullscreen
                )
            case .voice:
                voiceMode
            case .explorer:
                SessionExplorerSurface(
                    scope: activeSessionRepositoryScope,
                    onRefresh: { await refreshSessionWorkflow() },
                    onOpenFile: { scope, document in
                        guard scope == activeSessionRepositoryScope else { return }
                        explorerSelection = ScopedRepositoryDocument(scope: scope, document: document)
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

    private func loadInitialModelConfiguration() {
        model.refreshRuntimeConfiguration()
        model.refreshRuntimeModelOptions()
        model.refreshDefaultReasoningVariant()
    }

    private func handleVoiceStateChange(_ state: HermesVoiceState) {
        if state == .interrupted {
            // The native gateway has accepted a spoken interruption. Stop
            // any fallback playback immediately before it resumes capture.
            voiceOutput.stop()
        }
        if case .localFallback = state {
            resumeVoiceConversationIfReady()
        }
    }

    private func handleVoicePlaybackChange(_ isSpeaking: Bool) {
        guard !isSpeaking, !model.voiceState.isNativeConversationActive else { return }
        resumeVoiceConversationIfReady()
    }

    private func handleSessionModeChange(previousMode: SessionWorkspaceMode, mode: SessionWorkspaceMode) {
        guard previousMode == .voice, mode != .voice else { return }
        // Leaving voice mode must always release both fallback and native
        // voice capture, including a microphone that is still starting.
        speechInput.stop()
        voiceOutput.stop()
        model.stopVoiceConversation()
    }

    private func handleRecordingChange(_ isRecording: Bool) {
        guard !isRecording, speechInput.errorMessage != nil else { return }
        sessionWorkspaceMode = .chat
    }

    private func handleCompletedTranscript(_ transcript: String?) {
        guard let transcript, !transcript.isEmpty, !model.isSending else { return }
        guard !voiceOutput.isSpeaking else {
            speechInput.consumeCompletedTranscript()
            return
        }
        model.draft = transcript
        speechInput.consumeCompletedTranscript()
        model.send()
    }

    private func handleWorkspaceVisibilityChange(_ visible: Bool) {
        if isNarrowLayout { isNarrowControlVisible = visible }
        synchronizePanelLayout()
    }

    private func handleCapabilitiesChange(_ capabilities: [CapabilityState]) {
        let available = capabilities.first { capability in
            capability.id == HermesFeatureIDs.ID.bots.rawValue
        }?.isAvailable == true
        botMode.setCapabilityAvailable(available)
        if available { botMode.refresh() }
    }

    private func handleModelStatusChange(_ status: HermesStatus) {
        synchronizeWorkspace(status: status)
        guard sessionWorkspaceMode == .voice,
              status == .idle,
              !model.voiceState.isNativeConversationActive else { return }
        if suppressNextVoiceResponse {
            suppressNextVoiceResponse = false
            resumeVoiceConversationIfReady()
            return
        }
        let response = model.messages.last { message in
            message.role == .hermes
        }
        let responseText = response?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !responseText.isEmpty, let response else {
            resumeVoiceConversationIfReady()
            return
        }
        speechInput.stopForAssistantSpeech()
        voiceOutput.speak(messageID: response.id, text: response.text)
    }

    private func handleSessionIDChange(oldValue: String?, newValue: String?) {
        DebugLog.writeDiagnostic("session.switch old=\(oldValue ?? "nil") new=\(newValue ?? "nil") title=\(model.currentSessionTitle ?? "nil") cachedProject=\(cachedProjectName ?? "nil") cachedRepo=\(cachedSessionRepositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "nil")")
        synchronizeWorkspace()
        controlCenter.focus(sessionID: newValue)
        synchronizePanelLayout()

        guard oldValue != newValue else { return }
        let title = model.currentSessionTitle
        let previousTitle = lastSessionTitleAtIdentityChange
        let titleChanged = previousTitle != nil && title != previousTitle
        lastSessionTitleAtIdentityChange = title
        guard newValue == nil || titleChanged else { return }
        cachedProjectName = nil
        cachedSessionRepositoryPath = nil
        refreshCachedProjectName()
        cacheSessionRepositoryPath()
    }

    private func handleProjectMembershipChange() {
        DebugLog.writeDiagnostic("session.membership_changed session=\(model.sessionID ?? "nil") project=\(contextProjectName ?? "nil") cachedProject=\(cachedProjectName ?? "nil")")
        refreshCachedProjectName()
        cacheSessionRepositoryPath()
        synchronizeSessionMetadataFromControlCenter()
    }

    private func handleMessageCountChange(oldCount: Int, newCount: Int) {
        guard newCount > oldCount else { return }
        synchronizeWorkspace()
    }

    private func handleSessionMetadataChange() {
        model.refreshSessionModelOptions()
        synchronizeSessionMetadataFromControlCenter()
    }

    private func clearSessionSurfaceSelections() {
        sourceControlRequestID = UUID()
        explorerSelection = nil
        selectedChange = nil
        selectedChangeDiff = nil
        isLoadingChangeDiff = false
    }

    private func handleWorkspaceChange() {
        synchronizeWorkspace()
    }

    private func configureWorkspaceOnAppear() {
        synchronizePanelLayout()
        synchronizeWorkspace()
        controlCenter.bind(to: model)
        // The session Activity child can mount before this root lifecycle hook.
        // Reissue its durable, read-only projection after binding so an early
        // unbound attempt cannot leave the visible session permanently empty.
        controlCenter.refreshSessionKanban(for: model.kanbanSessionID)
        botMode.bind(to: model.controlRPCClient, capabilityAvailable: controlCenter.capabilityAvailable(HermesFeatureIDs.ID.bots.rawValue))
        agentUpdateService.checkForUpdates()
        Task { @MainActor in
            await botMode.refreshNow(force: true)
            handleProfileScopeChange(botMode.selectedProfileID)
            model.restoreLatestSessionIfNeeded()
            controlCenter.refresh()
            controlCenter.startInitialProjectNavigationLoad()
        }
        // Seed the project name cache immediately after bind so the label is
        // visible from the first render if membership data is already loaded.
        refreshCachedProjectName()
    }

    /// Fullscreen has a dedicated navigation rail. Unlike the compact session
    /// picker popover, it keeps the active queue visible while the user works
    /// through a conversation or task.
    private var missionControlQueue: some View {
        MissionControlQueue(
            model: model,
            botMode: botMode,
            workspaceStore: workspaceStore,
            controlCenter: controlCenter,
            agentUpdateService: agentUpdateService,
            navigationState: missionControlNavigation,
            activeSessionID: model.sessionID,
            activeGlobalTab: fullscreenSurface == .global ? fullscreenGlobalTab : nil,
            isArtifactsActive: fullscreenSurface == .artifacts,
            isBotsActive: fullscreenSurface == .bots,
            isPullRequestsActive: fullscreenSurface == .pullRequests,
            onNewConversation: {
                fullscreenSurface = .conversation
                inspectorScope = .session
                model.newChat()
                model.requestComposerFocus()
            },
            onSelectSession: { session in
                fullscreenSurface = .conversation
                inspectorScope = .session
                model.resumeSession(session)
            },
            onSelectTask: { task in
                if let sessionID = task.sessionID,
                   let session = model.sessions.first(where: { $0.id == sessionID }) {
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
                fullscreenGlobalTab = tab
                fullscreenSurface = .global
            },
            onOpenArtifacts: {
                fullscreenSurface = .artifacts
            },
            onOpenBots: {
                Task { await botMode.refreshNow(force: true) }
                fullscreenSurface = .bots
            },
            onOpenPullRequests: {
                fullscreenSurface = .pullRequests
            },
            showsFullscreenToggle: true,
            isFullscreen: isFullscreen,
            onFullscreenToggle: toggleFullscreen,
            onSelectProfile: { botMode.selectProfile($0) }
        )
    }

    private func handleProfileScopeChange(_ profileID: String?) {
        let normalized = profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = normalized?.isEmpty == false ? normalized : nil
        model.setProfileScope(selected)
        controlCenter.setProjectProfile(selected)
        clearSessionSurfaceSelections()
        cachedProjectName = nil
        cachedSessionRepositoryPath = nil
    }

    private var fullscreenGlobalControlSurface: some View {
        WorkspaceActivitySidebar(
            model: model,
            botMode: botMode,
            store: workspaceStore,
            control: controlCenter,
            workflow: developerWorkflow,
            onClose: onClose,
            onRestartDock: {
                // Do not restore the old session's model pin after relaunch.
                // The restart is explicitly a provider/account sync boundary.
                model.newChat()
                agentUpdateService.restartDock()
            },
            onOpenArtifacts: { },
            onSessionOpened: { _ in
                // Global surfaces (such as Projects) own discovery; after a
                // session is chosen, return the user to the shared chat
                // workspace where that session is visible.
                fullscreenSurface = .conversation
                isMissionInspectorVisible = true
            },
            showsHeader: false,
            showsModePicker: false,
            initialMode: fullscreenGlobalTab,
            agentUpdateService: agentUpdateService
        )
        .id("fullscreen-global-\(fullscreenGlobalTab.id)")
    }

    private var fullscreenGlobalSurface: some View {
        Group {
            if fullscreenSurface == .pullRequests {
                PullRequestWorkspace(
                    center: pullRequestCenter,
                    projects: controlCenter.projects,
                    onOpenChat: openPullRequestChat
                )
                .id("fullscreen-pull-requests")
            } else if fullscreenSurface == .artifacts {
                ArtifactsInspectorView(model: model)
                    .id("fullscreen-artifacts")
            } else if fullscreenSurface == .bots {
                BotRosterPage(model: botMode, dockModel: model, onSelectBot: openBotChat)
                    .id("fullscreen-bots")
            } else {
                fullscreenGlobalControlSurface
            }
        }
    }

    private func openBotChat(_ bot: BotSummary) {
        fullscreenSurface = .conversation
        inspectorScope = .session
        model.resumeBotChat(bot)
    }

    private func openPullRequestChat(_ pullRequest: PullRequestRecord) {
        let prompt = """
        Review pull request #\(pullRequest.number), \"\(pullRequest.title)\", in \(pullRequest.repository.id).
        PR: \(pullRequest.webURL?.absoluteString ?? "Unavailable")
        Branch: \(pullRequest.headBranch) → \(pullRequest.baseBranch)

        Review risks, test coverage, and findings. Do not modify files unless I ask.
        """
        Task {
            if let linkedID = pullRequestChatLinks.sessionID(for: pullRequest.id),
               let linkedSession = model.sessions.first(where: { $0.id == linkedID }) {
                model.resumeSession(linkedSession)
            } else {
                pullRequestChatLinks.remove(pullRequestID: pullRequest.id)
                await model.startNewChat(in: pullRequest.localPath)
                if let createdID = model.sessionID { pullRequestChatLinks.save(sessionID: createdID, for: pullRequest.id) }
            }
            model.draft = prompt
            fullscreenSurface = .conversation
            inspectorScope = .session
            model.requestComposerFocus()
        }
    }

    private var contextPanel: some View {
        VStack(spacing: 0) {
            if sessionWorkspaceMode.usesContextPreview {
                sessionSurfacePreview
                    .transition(.opacity)
                    .animation(.dockEase(duration: 0.2), value: sessionWorkspaceMode)
            } else {
                if !usesMissionControlLayout {
                    contextPanelHeader
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
                        .id("context-global-\(fullscreenGlobalTab.id)")
                     case .session:
                         SessionInspector(
                             model: model,
                             botMode: botMode,
                             control: controlCenter,
                             workflow: developerWorkflow,
                             sessionRepositoryPath: activeSessionRepositoryPath,
                             sessionProjectIsBound: activeSessionRepositoryPath != nil,
                             showsHeader: false
                         )
                    case .artifacts:
                        ArtifactsInspectorView(model: model)
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
                path: repositoryPath,
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
    private var sessionSurfacePreview: some View {
        switch sessionWorkspaceMode {
        case .explorer:
            if let explorerSelection,
               let activeScope = activeSessionRepositoryScope,
               explorerSelection.scope == activeScope {
                RepositoryCodeWorkspaceView(
                    repositoryPath: explorerSelection.scope.repositoryPath,
                    document: explorerSelection.document,
                    onClose: { self.explorerSelection = nil },
                    onSave: { draft in
                        guard self.activeSessionRepositoryScope == explorerSelection.scope else { return false }
                        guard await RepositoryService.saveDocument(path: explorerSelection.scope.repositoryPath, filePath: explorerSelection.document.path, contents: draft) else { return false }
                        await refreshSessionWorkflow()
                        self.explorerSelection = ScopedRepositoryDocument(
                            scope: explorerSelection.scope,
                            document: RepositoryFileDocument(path: explorerSelection.document.path, contents: draft, byteCount: draft.lengthOfBytes(using: .utf8))
                        )
                        return true
                    },
                    isStandalonePane: true
                )
            } else {
                SessionSurfacePreviewPlaceholder(
                    icon: "folder",
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
            PullRequestDetailView(center: sessionPullRequestCenter, onOpenChat: openPullRequestChat)
        case .chat, .voice:
            EmptyView()
        }
    }

    private var contextPanelHeader: some View {
        HStack(spacing: 12) {
            Text("INSPECTOR")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.05)
                .foregroundStyle(Color.dockMetadataText)

            Spacer(minLength: 8)

            scopePicker
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Color.dockSurface2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var contextProjectPath: String? {
        guard let sessionID = model.sessionID,
              let project = controlCenter.project(forSessionID: sessionID),
              project.name != "__no_project__",
              !project.name.isEmpty else { return nil }
        return project.name
    }

    private var contextProjectName: String? {
        let path = contextProjectPath
        guard let path, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private var activeSessionRepositoryPath: String? {
        liveSessionRepositoryPath ?? cachedSessionRepositoryPath
    }

    private var liveSessionRepositoryPath: String? {
        workspaceStore.resolvedProjectPath(
            forSessionID: model.sessionID,
            hermesProjectPath: model.sessionID.flatMap { controlCenter.project(forSessionID: $0)?.name }
        )
    }

    private var activeSessionRepositoryIdentity: String? {
        activeSessionRepositoryScope?.identity
    }

    private var activeSessionRepositoryScope: SessionRepositoryScope? {
        guard let sessionID = model.sessionID,
              let path = activeSessionRepositoryPath else { return nil }
        return SessionRepositoryScope(sessionID: sessionID, repositoryPath: path)
    }

    /// Updates the cached project name from the live computed value.
    /// Called whenever the session or project membership changes.
    private func refreshCachedProjectName() {
        if let contextProjectName {
            cachedProjectName = contextProjectName
        }
    }

    private func cacheSessionRepositoryPath() {
        if let liveSessionRepositoryPath {
            cachedSessionRepositoryPath = liveSessionRepositoryPath
        }
    }

    private func synchronizeSessionMetadataFromControlCenter() {
        guard let sessionID = model.sessionID,
              let summary = controlCenter.sessionSummary(for: sessionID) else { return }
        model.updateCurrentSessionTitle(summary.title)
    }

    private var scopePicker: some View {
        HStack(spacing: 0) {
            // The fullscreen right region is an inspector for the active
            // center surface, never a competing global workspace.
            let scopes: [InspectorScope] = usesMissionControlLayout
                ? [.session, .artifacts]
                : InspectorScope.allCases
            ForEach(scopes) { scope in
                Button {
                    withAnimation(.dockEase(duration: 0.18)) {
                        inspectorScope = scope
                    }
                } label: {
                    Text(scope.rawValue)
                        .font(.system(size: 13, weight: inspectorScope == scope ? .semibold : .regular))
                        .foregroundStyle(inspectorScope == scope ? Color.dockPrimaryText : Color.dockSecondaryText)
                        .frame(width: 82, height: 34)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(inspectorScope == scope ? Color.dockAccent.opacity(0.10) : Color.clear)
                        }
                        .overlay(alignment: .bottom) {
                            if inspectorScope == scope {
                                Color.dockAccent.frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show \(scope.rawValue) inspector")
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector scope")
    }

    private func synchronizeWorkspace(status: HermesStatus? = nil) {
        guard let sessionID = model.sessionID else { return }
        let title = model.currentSessionTitle
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

    private var header: some View {
        HStack(spacing: DockLayout.controlGap) {
            // Treat the session identity as one deliberate control instead of
            // a loose status dot, title, and disclosure icon.
            Button(action: { model.toggleSessions() }) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.18))
                            .frame(width: 18, height: 18)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.dockSurface2, lineWidth: 1.5))
                    }
                    Text(model.currentSessionTitle ?? "Untitled chat")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    LucideImage(systemName: model.isShowingSessions ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.dockMetadataText)
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(DockPressButtonStyle())
            .help("Session status: \(model.status.title)")
            .accessibilityLabel("\(model.currentSessionTitle ?? "Untitled chat"), \(model.status.title)")
            .popover(isPresented: $model.isShowingSessions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                sessionPicker
                    .frame(width: 390, height: 310)
                    .padding(.vertical, 4)
                    .background(Color.dockCanvas)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                sessionModePicker

                Divider()
                    .frame(height: 22)
                    .overlay(Color.dockBorderLight)

                // This control belongs to the active conversation: it
                // toggles the inspector (the third workspace panel).
                Button(action: toggleInspectorPanel) {
                    LucideImage(systemName: inspectorPanelIsVisible ? "rectangle.split.2x1" : "rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(inspectorPanelIsVisible ? Color.dockAccent : Color.dockSecondaryText)
                        .frame(width: 32, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(inspectorPanelIsVisible ? Color.dockAccent.opacity(0.13) : Color.clear)
                        )
                }
                .buttonStyle(DockPressButtonStyle())
                .help(inspectorPanelIsVisible ? "Hide inspector" : "Show inspector")
                .accessibilityLabel(inspectorPanelIsVisible ? "Hide inspector" : "Show inspector")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dockSurface4))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
            }
        }
        .padding(.horizontal, DockLayout.contentInset)
        .padding(.vertical, 10)
        .background(Color.dockSurface2)
        .overlay(alignment: .bottom) {
            Color.dockBorderLight.frame(height: DockLayout.hairline)
        }
        .animation(.dockEase(duration: 0.2), value: model.status)
    }

    private var sessionModePicker: some View {
        HStack(spacing: 2) {
            ForEach(SessionWorkspaceMode.allCases) { mode in
                sessionModeButton(mode)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session surface")
    }

    private func sessionModeButton(_ mode: SessionWorkspaceMode) -> some View {
        Button(action: { selectSessionMode(mode) }) {
            Group {
                if mode == .pullRequests {
                    LucideIcon(name: .gitPullRequest, size: 13, color: sessionWorkspaceMode == mode ? Color.dockAccent : Color.dockSecondaryText)
                } else {
                    LucideImage(systemName: mode.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(sessionWorkspaceMode == mode ? Color.dockAccent : Color.dockSecondaryText)
                }
            }
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(sessionWorkspaceMode == mode ? Color.dockAccent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(mode.help)
        .accessibilityLabel(mode.label)
    }

    private func selectSessionMode(_ mode: SessionWorkspaceMode) {
        guard mode != sessionWorkspaceMode else { return }
        withAnimation(.dockEase(duration: 0.2)) {
            sessionWorkspaceMode = mode
        }
        if mode.usesContextPreview {
            ensureInspectorPanelVisible()
        }
    }

    private func ensureInspectorPanelVisible() {
        if isFullscreen {
            isMissionInspectorVisible = true
        } else if isNarrowLayout {
            isNarrowControlVisible = true
        } else {
            isWorkspaceManuallyExpanded = true
        }
    }

    private func refreshSessionWorkflow() async {
        await developerWorkflow.refresh(preferences: repositoryPreferences, control: controlCenter)
    }

    private func selectChangeFile(_ file: RepositoryFileChange) {
        guard let scope = activeSessionRepositoryScope else { return }
        let requestID = UUID()
        sourceControlRequestID = requestID
        selectedChange = ScopedRepositoryChange(scope: scope, file: file)
        selectedChangeDiff = nil
        isLoadingChangeDiff = true
        Task {
            let diff = await RepositoryService.diff(path: scope.repositoryPath, file: file)
            guard sourceControlRequestID == requestID,
                  activeSessionRepositoryScope == scope,
                  selectedChange?.file.id == file.id else { return }
            selectedChangeDiff = diff
            isLoadingChangeDiff = false
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: .dockSuccess
        case .working: .dockAccent
        case .needsApproval: .dockWarning
        case .needsClarification: .dockWarning
        case .offline: .dockDestructive
        }
    }

    private var inspectorPanelIsVisible: Bool {
        isFullscreen ? isMissionInspectorVisible : isWorkspaceVisibleForLayout
    }

    private func toggleInspectorPanel() {
        if isFullscreen {
            isMissionInspectorVisible.toggle()
        } else if isNarrowLayout {
            isNarrowControlVisible.toggle()
        } else {
            isWorkspaceManuallyExpanded.toggle()
        }
    }

    private func toggleFullscreen() {
        // Fullscreen changes only the host window and available layout space.
        // It must not select a different workspace, inspector scope, or
        // session surface: those are user-owned presentation state.
        let preservedInspectorVisibility = inspectorPanelIsVisible
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFullscreen.toggle()
            if isFullscreen {
                isNarrowLayout = false
                isMissionInspectorVisible = preservedInspectorVisibility
            } else {
                synchronizePanelLayout()
                if isNarrowLayout {
                    isNarrowControlVisible = preservedInspectorVisibility
                } else {
                    isWorkspaceManuallyExpanded = preservedInspectorVisibility
                }
            }
        }
        onFullscreenToggle()
    }

    private var sessionModelDisplayName: String {
        if let id = model.sessionModelOptionID,
           let option = model.runtimeModelOptions.first(where: { $0.id == id }) {
            return option.displayName
        }
        if let value = model.sessionModelValue, !value.isEmpty {
            return value
        }
        let runtime = model.runtimeConfiguration
        if let provider = runtime?.provider, let modelName = runtime?.model {
            return "\(provider)  /  \(modelName)"
        }
        return "LOADING…"
    }

    private var sessionReasoningDisplayName: String {
        let reasoning = model.sessionID == nil
            ? model.defaultReasoningVariant
            : model.sessionReasoningVariant
        return reasoning?.displayName ?? "LOADING…"
    }

    private var selectedModelOptionID: String? {
        if model.sessionID != nil { return model.sessionModelOptionID }
        guard let provider = model.runtimeConfiguration?.provider,
              let modelName = model.runtimeConfiguration?.model else { return nil }
        return HermesModelOption(provider: provider, model: modelName).id
    }

    private var selectedReasoningVariant: HermesReasoningVariant? {
        model.sessionID == nil ? model.defaultReasoningVariant : model.sessionReasoningVariant
    }

    private var configurationScopeLabel: String {
        model.sessionID == nil ? "new chats" : "this session"
    }

    /// A single, divider-led rail keeps the two session settings scannable as
    /// one piece of context instead of presenting competing controls.
    @ViewBuilder
    private var sessionConfigurationRow: some View {
        HStack(spacing: 0) {
            Menu {
                if model.runtimeModelOptions.isEmpty {
                    Text("Loading model catalog…")
                } else {
                    ForEach(model.runtimeModelOptions) { option in
                        Button {
                            if model.sessionID == nil {
                                model.updateRuntimeModel(option)
                            } else {
                                model.updateSessionModel(option)
                            }
                        } label: {
                            HStack {
                                Text(option.displayName)
                                if option.id == selectedModelOptionID {
                                    LucideImage(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                sessionConfigurationLabel(
                    icon: "cpu",
                    title: "MODEL",
                    value: sessionModelDisplayName,
                    truncatesValue: true
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.borderless)
            .disabled(model.sessionID == nil ? model.isLoadingRuntimeConfiguration : model.isUpdatingSessionModel)
            .help("Change the model for \(configurationScopeLabel)")
            .accessibilityLabel("Model for \(configurationScopeLabel): \(sessionModelDisplayName)")

            Color.dockBorderLight
                .frame(width: 0.5, height: 24)

            Menu {
                ForEach(HermesReasoningVariant.allCases) { variant in
                    Button {
                        if model.sessionID == nil {
                            model.updateDefaultReasoning(variant)
                        } else {
                            model.updateSessionReasoning(variant)
                        }
                    } label: {
                        HStack {
                            Text(variant.displayName)
                            if variant == selectedReasoningVariant {
                                LucideImage(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                sessionConfigurationLabel(
                    icon: "brain",
                    title: "THINKING",
                    value: sessionReasoningDisplayName
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.borderless)
            .disabled(model.sessionID == nil ? model.isUpdatingDefaultReasoning : model.isUpdatingSessionReasoning)
            .help("Change thinking depth for \(configurationScopeLabel)")
            .accessibilityLabel("Thinking depth for \(configurationScopeLabel): \(sessionReasoningDisplayName)")
        }
        .foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockSurface4)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.dockBorder, lineWidth: 0.5)
        }
    }

    private func sessionConfigurationLabel(
        icon: String,
        title: String,
        value: String,
        truncatesValue: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            LucideImage(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockAccent)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.dockSecondaryText)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(truncatesValue ? .middle : .tail)
                .layoutPriority(1)

            LucideImage(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.dockSecondaryText)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionList
        }
        .background(Color.dockCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete \(session.displayTitle)", role: .destructive) {
                model.deleteSession(session)
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: { session in
            Text("This permanently deletes the saved conversation and its transcript.")
        }
        .alert(
            "Could Not Delete Session",
            isPresented: Binding(
                get: { model.sessionDeletionError != nil },
                set: { if !$0 { model.clearSessionDeletionError() } }
            )
        ) {
            Button("OK", role: .cancel) {
                model.clearSessionDeletionError()
            }
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
            Button("OK", role: .cancel) {
                model.clearSessionVisibilityError()
            }
        } message: {
            Text(model.sessionVisibilityError ?? "The session visibility could not be updated.")
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONVERSATIONS")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.dockAccent.opacity(0.8))
                Spacer()
                if model.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Button(action: { model.loadSessions() }) {
                        LucideImage(systemName: "refresh-cw")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.dockSecondaryText)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.dockSurface2)

            if model.sessions.isEmpty && !model.isLoadingSessions {
                Text("No saved conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                List {
                    ForEach(model.sessions) { session in
                        HStack(spacing: 6) {
                            Button(action: { model.resumeSession(session) }) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.displayTitle)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .foregroundStyle(Color.dockPrimaryText)
                                    if let preview = session.displayPreview {
                                        Text(preview)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.dockSecondaryText)
                                            .lineLimit(1)
                                    }
                                    if let projectName = conversationProjectName(for: session) {
                                        LucideLabel(projectName, icon: "folder")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Color.dockMetadataText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    if let date = session.lastUpdatedAt {
                        Text(date, style: .relative)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.dockMetadataText)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)

                            Button {
                                sessionPendingDeletion = session
                            } label: {
                                LucideImage(systemName: "trash")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.dockWarning)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                            .disabled(session.id == model.sessionID || model.deletingSessionID != nil)
                            .help(session.id == model.sessionID ? "The active session cannot be deleted" : "Delete session")
                            .accessibilityLabel("Delete \(session.displayTitle)")

                            Button {
                                model.setSessionHidden(session, hidden: !session.isHidden)
                            } label: {
                                LucideImage(systemName: session.isHidden ? "eye" : "eye.slash")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.dockSecondaryText)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                            .help(session.isHidden ? "Show session" : "Hide session")
                            .accessibilityLabel(session.isHidden ? "Show \(session.displayTitle)" : "Hide \(session.displayTitle)")
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 250)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func conversationProjectName(for session: HermesSession) -> String? {
        guard let project = controlCenter.project(forSessionID: session.id),
              !project.name.isEmpty,
              project.name != "__no_project__" else {
            return nil
        }

        let name = URL(fileURLWithPath: project.name).lastPathComponent
        return name.isEmpty ? project.name : name
    }

    @ViewBuilder
    private var conversation: some View {
        if speechInput.isRecording {
            voiceMode
        } else {
            chatScroll
        }
    }

    private var voiceMode: some View {
        VStack(spacing: 0) {
            Spacer()
            Button {
                if model.voiceState.isNativeConversationActive || speechInput.isRecording {
                    exitVoiceMode()
                } else if !model.isSending && !voiceOutput.isSpeaking {
                    voiceOutput.stop()
                    beginVoiceConversation()
                }
            } label: {
                VoiceOrbView(
                    isListening: model.voiceState == .listening || speechInput.isRecording,
                    isResponding: model.voiceState == .preparing || model.voiceState == .interrupted || model.voiceState == .thinking || model.voiceState == .speaking || (model.status == .working && !speechInput.isRecording) || voiceOutput.isSpeaking,
                    audioLevel: speechInput.audioLevel
                )
                    .frame(width: 320, height: 320)
            }
            .buttonStyle(.borderless)
            .help(model.voiceState.isNativeConversationActive || speechInput.isRecording ? "End voice conversation" : "Resume listening")
            .overlay(alignment: .bottom) {
                if let detail = model.voiceState.fallbackDetail {
                    Text("LOCAL FALLBACK · \(detail)")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(0.35)
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 270)
                        .offset(y: 42)
                } else if model.voiceState.isNativeConversationActive {
                    VStack(spacing: 5) {
                        Text(model.voiceState.label(agentName: model.agentDisplayName))
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.75)
                            .foregroundStyle(model.voiceState == .listening ? Color.dockSuccess : Color.dockAccent)
                        if let timing = model.voiceTelemetry.summary {
                            Text(timing)
                                .font(.system(size: 12, weight: .medium))
                                .tracking(0.45)
                                .foregroundStyle(Color.dockMetadataText)
                        }
                    }
                    .offset(y: 42)
                } else if model.status == .working && !speechInput.isRecording {
                    voiceActivityIndicator
                        .offset(y: 34)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .animation(.dockEase(duration: 0.25), value: model.status)
        .onAppear { beginVoiceConversation() }
    }

    private func beginVoiceConversation() {
        if case .localFallback = model.voiceState {
            resumeVoiceConversationIfReady()
        } else {
            model.startVoiceConversation()
        }
    }

    private func resumeVoiceConversationIfReady() {
        guard sessionWorkspaceMode == .voice,
              !model.voiceState.isNativeConversationActive,
              model.status == .idle,
              !model.isSending,
              !speechInput.isRecording,
              !speechInput.isStarting,
              !voiceOutput.isSpeaking else { return }
        // A new local turn resets transient capture failures. Leaving the old
        // error as a guard made the voice orb's retry action a permanent no-op.
        speechInput.startListening()
    }

    private func exitVoiceMode() {
        speechInput.stop()
        voiceOutput.stop()
        model.stopVoiceConversation()
        sessionWorkspaceMode = .chat
    }

    private func stopCurrentRequest() {
        if sessionWorkspaceMode == .voice {
            suppressNextVoiceResponse = true
            voiceOutput.stop()
        }
        model.stop()
    }

    private var voiceActivityIndicator: some View {
        HStack(spacing: 8) {
            ThinkingDots()
            Text(voiceActivityText)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(Color.dockAccent)
        .padding(.horizontal, 13)
        .frame(height: 32)
        .background(Capsule().fill(Color.dockSurface6).stroke(Color.dockAccent.opacity(0.25), lineWidth: 0.5))
        .shadow(color: Color.dockAccent.opacity(0.12), radius: 10)
    }

    private var voiceActivityText: String {
        if let reasoning = model.reasoningState, !reasoning.text.isEmpty {
            return "HERMES IS REASONING"
        }
        if let tool = model.activeToolCalls.first(where: { !$0.isComplete }) {
            return "RUNNING \(tool.name.uppercased())"
        }
        return "HERMES IS THINKING"
    }

    private var chatScroll: some View {
        legacyChatScroll
    }

    private var legacyChatScroll: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        VStack(spacing: 0) {
                            // Variable-height Markdown rows need an exact
                            // SwiftUI document extent. LazyVStack estimates
                            // off-screen heights and can expose a blank tail
                            // before it corrects those estimates.
                            VStack(spacing: 0) {
                                if model.messages.isEmpty && model.status != .working {
                                    StartupAssistantView(agentName: model.agentDisplayName)
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: max(300, viewport.size.height - 16))
                                }

                                let messages = ConversationMessageWindow.visibleMessages(
                                    model.messages,
                                    limit: renderedMessageLimit
                                )
                                if model.messages.count > messages.count {
                                    Button(action: revealEarlierMessages) {
                                        HStack(spacing: 7) {
                                            LucideImage(systemName: "arrow.up")
                                                .font(.system(size: 11, weight: .semibold))
                                            Text("Show earlier messages")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .padding(.horizontal, 14)
                                        .frame(height: 32)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.dockSurface4)
                                                .overlay {
                                                    Capsule(style: .continuous)
                                                        .stroke(Color.dockAccent.opacity(0.32), lineWidth: 0.6)
                                                }
                                        )
                                        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
                                    }
                                    .buttonStyle(.borderless)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 3)
                                    .padding(.bottom, 8)
                                }

                                ForEach(messages) { message in
                                    messageRow(message)
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: MessageNavigatorViewportPreferenceKey.self,
                                                    value: [MessageNavigatorViewport(
                                                        target: MessageNavigatorTarget(sessionID: model.sessionID ?? "", messageID: message.id),
                                                        minY: geometry.frame(in: .named("conversation-scroll")).minY,
                                                        maxY: geometry.frame(in: .named("conversation-scroll")).maxY
                                                    )]
                                                )
                                            }
                                        }
                                        .id(message.id)
                                }
                                if let approval = model.approvalText {
                                    approvalRow(
                                        title: model.approvalTitle ?? "Review requested action",
                                        detail: approval,
                                        alwaysAllowCaption: ApprovalPresentation.alwaysAllowCaption(
                                            title: model.approvalTitle ?? "Review requested action",
                                            detail: approval)
                                    )
                                        .id("approval")
                                }
                                if isConversationActivityVisible {
                                    activityView
                                        .id("activity")
                                }
                            }
                            .padding(.vertical, 8)

                            Color.clear
                                .frame(height: 1)
                                .id("conversation-bottom")
                        }
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ConversationContentBoundsPreferenceKey.self,
                                    value: ConversationContentBounds(
                                        topMinY: geometry.frame(in: .named("conversation-scroll")).minY,
                                        bottomMaxY: geometry.frame(in: .named("conversation-scroll")).maxY
                                    )
                                )
                            }
                        )
                    }
                    .id(model.sessionID)
                    .defaultScrollAnchor(.bottom)
                    .coordinateSpace(name: "conversation-scroll")
                    .onAppear {
                        isConversationAtBottom = true
                        unseenMessageCount = 0
                        renderedMessageLimit = ConversationMessageWindow.limitForSessionReplacement()
                        lastRenderedMessageBubbleCount = renderedMessageBubbleCount
                    }
                    .onChange(of: model.sessionID) { _, _ in
                        // The ScrollView identity is session-specific, but its
                        // parent presentation state is not. Reset explicitly
                        // so a session opened after an expanded history page
                        // mounts only its bounded recent window.
                        isConversationAtBottom = true
                        unseenMessageCount = 0
                        renderedMessageLimit = ConversationMessageWindow.limitForSessionReplacement()
                        lastRenderedMessageBubbleCount = renderedMessageBubbleCount
                        isStreamingTailScrollScheduled = false
                        isTransientTailAdjustmentScheduled = false
                        isPastEndRepairScheduled = false
                        isHistoryCompactionScheduled = false
                        scrollConversationToBottom(proxy)
                    }
                    .onPreferenceChange(ConversationContentBoundsPreferenceKey.self) { bounds in
                        conversationPerformance.recordScrollBoundsUpdate()
                        updateConversationPosition(
                            bounds,
                            viewportHeight: viewport.size.height,
                            proxy: proxy
                        )
                    }
                    .onPreferenceChange(MessageNavigatorViewportPreferenceKey.self) { viewports in
                        let viewportHeight = viewport.size.height
                        visibleNavigatorTargets = Set(
                            viewports
                                .filter { $0.maxY >= 0 && $0.minY <= viewportHeight }
                                .map(\.target)
                        )
                    }
                    .onChange(of: model.scrollToLatestMessageRequest) { _, _ in
                        unseenMessageCount = 0
                        isConversationAtBottom = true
                        scrollConversationToBottom(proxy)
                    }
                    .onChange(of: conversationScrollRequest) { _, _ in
                        scrollConversationToBottom(proxy, animated: true)
                    }
                    .onChange(of: model.messages.count) { oldCount, newCount in
                        renderedMessageLimit = ConversationMessageWindow.limitAfterCountChange(
                            currentLimit: renderedMessageLimit,
                            oldCount: oldCount,
                            newCount: newCount,
                            isAtBottom: isConversationAtBottom
                        )
                        let previousBubbleCount = lastRenderedMessageBubbleCount
                        let currentBubbleCount = renderedMessageBubbleCount
                        lastRenderedMessageBubbleCount = currentBubbleCount

                        guard newCount > oldCount else {
                            if newCount < oldCount { unseenMessageCount = 0 }
                            return
                        }
                        // Activity transport can append empty assistant
                        // placeholders to the canonical array. They do not
                        // produce a message bubble, so they must not create
                        // an unread-message badge.
                        let newBubbleCount = max(0, currentBubbleCount - previousBubbleCount)
                        guard newBubbleCount > 0 else { return }
                        if isConversationAtBottom {
                            scrollConversationToBottom(proxy)
                        } else {
                            unseenMessageCount += newBubbleCount
                        }
                    }
                    .onChange(of: model.approvalText) { _, _ in
                        guard isConversationAtBottom else { return }
                        scheduleTransientTailAdjustment(proxy)
                    }
                    .onChange(of: isConversationActivityVisible) { _, _ in
                        guard isConversationAtBottom else { return }
                        scheduleTransientTailAdjustment(proxy)
                    }
                    .onReceive(model.streamingText.$chunks) { _ in
                        conversationPerformance.recordStreamingUpdate()
                        guard isConversationAtBottom else { return }
                        scheduleStreamingTailScroll(proxy)
                    }

                    if unseenMessageCount > 0 {
                        Button {
                            unseenMessageCount = 0
                            isConversationAtBottom = true
                            renderedMessageLimit = ConversationMessageWindow.limitForSessionReplacement()
                            conversationScrollRequest &+= 1
                        } label: {
                            HStack(spacing: 7) {
                                LucideIcon(
                                    name: .arrowDown,
                                    size: 11,
                                    color: Color.dockOnAccentText
                                )
                                Text("\(unseenMessageCount) new \(unseenMessageCount == 1 ? "message" : "messages")")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.dockOnAccentText)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.dockAccent))
                            .shadow(color: Color.dockAccent.opacity(0.3), radius: 10, y: 3)
                        }
                        .buttonStyle(.borderless)
                        .padding(.bottom, 12)
                    }

                    MessageNavigatorView(
                        items: ConversationMessageWindow.navigatorItems(messages: model.messages, sessionID: model.sessionID ?? ""),
                        sessionID: model.sessionID ?? "",
                        visibleTargets: visibleNavigatorTargets,
                        onSelect: { item in jumpToMessage(item, proxy: proxy) }
                    )
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                }
            }
        }
    }

    private func jumpToMessage(_ item: MessageNavigatorItem, proxy: ScrollViewProxy) {
        guard let effect = ConversationMessageWindow.jumpEffect(
            for: item,
            sessionID: model.sessionID ?? "",
            messages: model.messages,
            currentLimit: renderedMessageLimit
        ) else { return }
        renderedMessageLimit = effect.renderedLimit
        isConversationAtBottom = effect.isAtBottom
        unseenMessageCount = effect.unseenMessageCount
        Task { @MainActor in
            await Task.yield()
            guard item.sessionID == (model.sessionID ?? "") else { return }
            proxy.scrollTo(effect.messageID, anchor: .center)
        }
    }

    private func revealEarlierMessages() {
        guard renderedMessageLimit < model.messages.count else { return }
        renderedMessageLimit = ConversationMessageWindow.revealedLimit(
            currentLimit: renderedMessageLimit,
            totalCount: model.messages.count
        )
    }

    private var renderedMessageBubbleCount: Int {
        ConversationUnreadMessagePolicy.renderedMessageCount(
            model.messages,
            streamingID: model.streamingMessageIDForPresentation
        )
    }

    private func updateConversationPosition(
        _ bounds: ConversationContentBounds,
        viewportHeight: CGFloat,
        proxy: ScrollViewProxy
    ) {
        let wasAtBottom = isConversationAtBottom
        let atBottom = ConversationScrollMetrics.isAtBottom(
            topMinY: bounds.topMinY,
            bottomMaxY: bounds.bottomMaxY,
            viewportHeight: viewportHeight
        )
        if atBottom != isConversationAtBottom {
            isConversationAtBottom = atBottom
            if atBottom { unseenMessageCount = 0 }
            if ConversationMessageWindow.shouldCompactAfterRepinning(
                wasAtBottom: wasAtBottom,
                isAtBottom: atBottom,
                currentLimit: renderedMessageLimit,
                totalCount: model.messages.count
            ) {
                scheduleHistoryCompaction(proxy)
            }
        }

        // This is deliberately independent of the pinned/browsing transition
        // above. A simultaneous composer resize and approval/activity change
        // can leave the clip origin past the real content end without changing
        // the derived pinned state. The stable footer is the one canonical
        // clamp target for that invalid geometry.
        if ConversationScrollMetrics.isPastEnd(
            topMinY: bounds.topMinY,
            bottomMaxY: bounds.bottomMaxY,
            viewportHeight: viewportHeight
        ) {
            schedulePastEndRepair(proxy)
        }
    }

    private func scheduleHistoryCompaction(_ proxy: ScrollViewProxy) {
        guard !isHistoryCompactionScheduled else { return }
        isHistoryCompactionScheduled = true
        let owningSessionID = model.sessionID

        Task { @MainActor in
            await Task.yield()
            guard owningSessionID == model.sessionID, isConversationAtBottom else {
                isHistoryCompactionScheduled = false
                return
            }

            renderedMessageLimit = ConversationMessageWindow.compactedLimit(
                totalCount: model.messages.count
            )

            await Task.yield()
            guard owningSessionID == model.sessionID, isConversationAtBottom else {
                isHistoryCompactionScheduled = false
                return
            }

            proxy.scrollTo("conversation-bottom", anchor: .bottom)
            isHistoryCompactionScheduled = false
        }
    }

    private func scrollConversationToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        Task { @MainActor in
            // Let the inserted row participate in layout before targeting the
            // stable footer. This is the only programmatic scroll target in
            // the restored SwiftUI presentation.
            await Task.yield()
            if animated {
                withAnimation(.dockEase(duration: 0.22)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private func scheduleStreamingTailScroll(_ proxy: ScrollViewProxy) {
        guard !isStreamingTailScrollScheduled else { return }
        isStreamingTailScrollScheduled = true
        Task { @MainActor in
            // A streaming text flush already triggers an expensive re-wrap of
            // the growing live row. Coalesce footer movement on a slightly
            // slower cadence so it cannot compete with that work every 80 ms.
            try? await Task.sleep(
                for: .milliseconds(ConversationStreamingPresentationPolicy.tailAdjustmentIntervalMilliseconds)
            )
            isStreamingTailScrollScheduled = false
            guard isConversationAtBottom else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private func scheduleTransientTailAdjustment(_ proxy: ScrollViewProxy) {
        guard !isTransientTailAdjustmentScheduled else { return }
        isTransientTailAdjustmentScheduled = true
        Task { @MainActor in
            // Clarification chips resize the composer while approval/activity
            // rows resize the transcript. Wait through both layout turns and
            // issue one footer request only for a viewport that was pinned.
            await Task.yield()
            await Task.yield()
            isTransientTailAdjustmentScheduled = false
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private func schedulePastEndRepair(_ proxy: ScrollViewProxy) {
        guard !isPastEndRepairScheduled else { return }
        isPastEndRepairScheduled = true
        Task { @MainActor in
            // A negative content top together with a trailing edge above the
            // viewport is an invalid offset, never a legitimate browsing
            // position. Coalesce the repair after the current layout pass.
            await Task.yield()
            await Task.yield()
            isPastEndRepairScheduled = false
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private var activityView: some View {
        ConversationActivityRow(model: model)
    }

    private var isConversationActivityVisible: Bool {
        model.status == .working || AgentActivityPresentation.hasActiveWork(
            toolCalls: model.activeToolCalls,
            subagents: model.activeSubagents
        )
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.id == model.streamingMessageIDForPresentation {
            StreamingAssistantMessageRow(
                streaming: model.streamingText,
                timestamp: message.timestamp,
                modelName: message.modelName,
                responseDuration: message.responseDuration
            )
        } else if message.role == .hermes && !message.hasBodyText && message.images.isEmpty {
            EmptyView()
        } else {
            ConversationMessageRow(
                message: message,
                isStreamingMessage: false,
                streamingText: model.streamingText,
                activeBotProfileID: model.activeBotProfileID,
                botsByID: botMode.botsByID,
                avatarImages: botMode.avatarImages,
                botRosterRevision: botMode.rosterRevision,
                onImagePreview: { image in selectedChatImage = ChatImagePreview(image: image) }
            )
            .equatable()
        }
    }

    private func reasoningBlock(_ reasoning: ReasoningState) -> some View {
        DisclosureGroup(isExpanded: $model.isShowingReasoning) {
            Text(reasoning.text.isEmpty ? "…" : reasoning.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .foregroundStyle(Color.dockSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            HStack(spacing: 5) {
                LucideImage(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                Text("Reasoning")
                    .font(.system(size: 12, weight: .medium))
                if !reasoning.isComplete {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                }
            }
            .foregroundStyle(Color.dockSecondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.dockSurface)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        )
    }

    private func approvalRow(title: String, detail: String, alwaysAllowCaption: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                LucideIcon(
                    name: .triangleAlert,
                    size: 16,
                    color: Color.white
                )
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Color.dockWarning)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approval required")
                        .font(.system(size: 14, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockWarning)
                        .lineLimit(2)
                }
                .foregroundStyle(Color.dockPrimaryText)
                Spacer()
                Text("ACTION NEEDED")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.dockWarning)
            }

            ScrollView(.vertical) {
                Text(detail)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .frame(maxHeight: 160)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.16))
                        .stroke(Color.dockBorderLight, lineWidth: 0.5)
                )

            HStack(spacing: 6) {
                Button { model.respondToApproval("deny") } label: {
                    DockActionLabel(
                        title: "Deny",
                        pendingTitle: "Working…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.dockWarning
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockWarning)
                .frame(minWidth: 88, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.dockWarning.opacity(0.08))
                        .stroke(Color.dockWarning.opacity(0.34), lineWidth: 0.5)
                )
                .disabled(model.isRespondingToApproval)
                Button { model.respondToApproval("once") } label: {
                    DockActionLabel(
                        title: "Allow once",
                        pendingTitle: "Allowing…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.dockOnAccentText
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockOnAccentText)
                .frame(minWidth: 112, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.dockAccent)
                )
                .disabled(model.isRespondingToApproval)
                Button { model.respondToApproval(ApprovalChoice.always) } label: {
                    DockActionLabel(
                        title: "Always allow",
                        pendingTitle: "Allowing…",
                        isPending: model.isRespondingToApproval,
                        tint: Color.dockOnAccentText
                    )
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockOnAccentText)
                .frame(minWidth: 112, minHeight: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.dockAccent.opacity(0.82))
                )
                .disabled(model.isRespondingToApproval)
            }
            Text(alwaysAllowCaption)
                .font(.system(size: 11))
                .foregroundStyle(Color.dockMetadataText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.dockSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.dockWarning.opacity(0.035))
                }
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.dockWarning.opacity(0.22), lineWidth: 0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func quickPromptChip(_ quickPrompt: QuickPrompt) -> some View {
        let requiredCapability = quickPrompt.requiredCapability
        let isAvailable = requiredCapability.map(controlCenter.capabilityAvailable) ?? true
        return Button(quickPrompt.label) {
            selectQuickPrompt(quickPrompt)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isAvailable ? Color.dockSecondaryText : Color.dockMetadataText)
        .padding(.horizontal, 9)
        .frame(minHeight: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(Color.dockSurface4).stroke(Color.dockBorderLight, lineWidth: 0.5))
        .disabled(!isAvailable)
        .help(isAvailable ? quickPrompt.label : unavailableCapabilityDetail(requiredCapability))
    }

    private var quickPromptOverflowMenu: some View {
        Menu {
            ForEach(QuickPrompt.allCases.dropFirst(2)) { quickPrompt in
                Button(quickPrompt.label) {
                    selectQuickPrompt(quickPrompt)
                }
                .disabled(quickPrompt.requiredCapability.map(controlCenter.capabilityAvailable) == false)
            }
        } label: {
            LucideLabel("More", icon: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockSecondaryText)
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(Capsule().fill(Color.dockSurface4).stroke(Color.dockBorderLight, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func selectQuickPrompt(_ quickPrompt: QuickPrompt) {
        model.draft = quickPrompt.prompt
        model.requestComposerFocus()
    }

    private func unavailableCapabilityDetail(_ id: String?) -> String {
        guard let id, let capability = controlCenter.capabilities.first(where: { $0.id == id }) else {
            return "This Hermes capability is unavailable. Open Settings and refresh capabilities."
        }
        return capability.recovery ?? capability.detail
    }
}

/// Fullscreen navigation stays visible as a quiet operational queue. It is
/// intentionally list-led rather than another dashboard: selecting an item
/// always changes the central work surface.
private struct MissionControlConversationGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let sessions: [HermesSession]
    let declaredSessionCount: Int
    let projectID: String?
    /// The gateway project name is the repository path used as `cwd` when
    /// creating a project-scoped chat.
    let projectPath: String?
    let isLinked: Bool
}

private enum SessionAttentionDot: Equatable {
    case warning, failure, success, activity

    var color: Color {
        switch self {
        case .warning: .dockWarning
        case .failure: .dockDestructive
        case .success: .dockSuccess
        case .activity: .dockAccent
        }
    }
}

private struct MissionControlQueue: View {
    private struct QueueTaskGroup: Identifiable {
        let key: String
        let task: WorkspaceTask
        let count: Int
        var id: String { key }
    }

    @ObservedObject var model: DockModel
    @ObservedObject var botMode: BotModeModel
    @ObservedObject var workspaceStore: WorkspaceStore
    @ObservedObject var controlCenter: ControlCenterModel
    @ObservedObject var agentUpdateService: HermesUpdateService
    @ObservedObject var navigationState: MissionControlNavigationState
    let activeSessionID: String?
    let activeGlobalTab: ControlTab?
    let isArtifactsActive: Bool
    let isBotsActive: Bool
    let isPullRequestsActive: Bool
    let onNewConversation: () -> Void
    let onSelectSession: (HermesSession) -> Void
    let onSelectTask: (WorkspaceTask) -> Void
    let onOpenGlobal: (ControlTab) -> Void
    let onOpenArtifacts: () -> Void
    let onOpenBots: () -> Void
    let onOpenPullRequests: () -> Void
    let showsFullscreenToggle: Bool
    let isFullscreen: Bool
    let onFullscreenToggle: () -> Void
    let onSelectProfile: (String) -> Void
    @State private var isProfileSelectorPresented = false

    private var readyTasks: [WorkspaceTask] {
        workspaceStore.tasks.filter { $0.status == .readyForReview || $0.status == .todo }
    }

    private var blockedTasks: [WorkspaceTask] {
        workspaceStore.tasks.filter { $0.status == .awaitingApproval }
    }

    private var recentSessions: [HermesSession] {
        model.sessions.sorted { sessionDate($0) > sessionDate($1) }
    }

    /// The Conversations section is the complete session index, including
    /// sessions that are also represented under a project. Project groups can
    /// contain gateway summaries that are not present in `model.sessions`, so
    /// build this from the already-normalized groups and deduplicate by ID.
    private var allConversationSessions: [HermesSession] {
        Dictionary(
            conversationGroups.flatMap(\.sessions).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .sorted { lhs, rhs in
            let lhsDate = sessionDate(lhs)
            let rhsDate = sessionDate(rhs)
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }
    }

    private var projectLinkedSessionIDs: Set<String> {
        Set(conversationGroups.filter(\.isLinked).flatMap(\.sessions).map(\.id))
    }

    private var projectNameBySessionID: [String: String] {
        var names: [String: String] = [:]
        for group in conversationGroups where group.isLinked {
            for session in group.sessions where names[session.id] == nil {
                names[session.id] = group.title
            }
        }
        return names
    }

    private var sessionAttentionDots: [String: SessionAttentionDot] {
        var dots: [String: SessionAttentionDot] = [:]
        for item in controlCenter.attention {
            guard let sessionID = item.reference.sessionID else { continue }
            dots[sessionID] = item.kind == .approval || item.kind == .clarification
                ? .warning
                : item.kind == .failure ? .failure : .activity
        }
        for activity in controlCenter.latestActivities where dots[activity.sessionID] == nil {
            let state = activity.state.lowercased()
            let name = activity.activityName.lowercased()
            if state.contains("fail") || state.contains("error") {
                dots[activity.sessionID] = .failure
            } else if state.contains("complete") || state.contains("success") || state == "done" {
                dots[activity.sessionID] = .success
            } else if name.contains("permission") || name.contains("approval") || name.contains("clarif") {
                dots[activity.sessionID] = .warning
            }
        }
        return dots
    }

    private var conversationGroups: [MissionControlConversationGroup] {
        var groups: [MissionControlConversationGroup] = []
        var assigned = Set<String>()

        for project in controlCenter.projects where project.isRenderableProject {
            var sessionsByID = Dictionary(recentSessions.compactMap { session -> (String, HermesSession)? in
                let isMember = project.sessionIDs.contains(session.id)
                    || controlCenter.projectIDBySessionID[session.id] == project.id
                guard isMember else { return nil }
                assigned.insert(session.id)
                return (session.id, session)
            }, uniquingKeysWith: { first, _ in first })
            for summary in controlCenter.projectSessionsByProjectID[project.id] ?? [] {
                let savedSession = sessionsByID[summary.id]
                let updatedAt = [summary.updatedAt, savedSession?.updatedAt].compactMap { $0 }.max()
                let savedSessionIsNewer = sessionDate(savedSession) > (summary.updatedAt ?? .distantPast)
                sessionsByID[summary.id] = HermesSession(
                    id: summary.id,
                    profileID: controlCenter.projectProfileID,
                    title: savedSessionIsNewer ? savedSession?.title ?? summary.title : summary.title,
                    preview: savedSessionIsNewer ? savedSession?.preview ?? summary.preview ?? "" : summary.preview ?? savedSession?.preview ?? "",
                    startedAt: savedSession?.startedAt,
                    updatedAt: updatedAt,
                    messageCount: savedSession?.messageCount ?? 0,
                    source: savedSession?.source ?? "project",
                    isHidden: savedSession?.isHidden ?? false
                )
                assigned.insert(summary.id)
            }
            let sessions = sessionsByID.values.sorted { sessionDate($0) > sessionDate($1) }
            groups.append(
                MissionControlConversationGroup(
                    id: "project:\(project.id)",
                    title: projectDisplayName(project.name),
                    sessions: sessions,
                    declaredSessionCount: project.sessionCount,
                    projectID: project.id,
                    projectPath: project.name,
                    isLinked: true
                )
            )
        }

        // session.list may repeat a row; keep the first occurrence.
        var unlinkedByID = Dictionary(recentSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Synthetic gateway buckets are not projects, but their session rows
        // are still valid conversations. Move those rows into the unlinked
        // group instead of dropping them with the bucket.
        for project in controlCenter.projects where !project.isRenderableProject && project.name != "__no_project__" {
            for summary in controlCenter.projectSessionsByProjectID[project.id] ?? [] {
                let savedSession = unlinkedByID[summary.id]
                let updatedAt = [summary.updatedAt, savedSession?.updatedAt].compactMap { $0 }.max()
                let savedSessionIsNewer = sessionDate(savedSession) > (summary.updatedAt ?? .distantPast)
                unlinkedByID[summary.id] = HermesSession(
                    id: summary.id,
                    profileID: controlCenter.projectProfileID,
                    title: savedSessionIsNewer ? savedSession?.title ?? summary.title : summary.title,
                    preview: savedSessionIsNewer ? savedSession?.preview ?? summary.preview ?? "" : summary.preview ?? savedSession?.preview ?? "",
                    startedAt: savedSession?.startedAt,
                    updatedAt: updatedAt,
                    messageCount: savedSession?.messageCount ?? 0,
                    source: savedSession?.source ?? "conversation",
                    isHidden: savedSession?.isHidden ?? false
                )
            }
        }
        let unlinked = unlinkedByID.values
            .filter { !assigned.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsDate = sessionDate(lhs)
                let rhsDate = sessionDate(rhs)
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id < rhs.id
            }
        if !unlinked.isEmpty {
            groups.append(
                MissionControlConversationGroup(
                    id: "unlinked",
                    title: "Unlinked conversations",
                    sessions: Array(unlinked),
                    declaredSessionCount: unlinked.count,
                    projectID: nil,
                    projectPath: nil,
                    isLinked: false
                )
            )
        }
        // Project-tree order is the canonical navigation order. Ordering this
        // list by changing session activity made it visibly jump while a
        // refresh populated project session details.
        return groups
    }

    private func sessionDate(_ session: HermesSession) -> Date {
        session.lastUpdatedAt ?? .distantPast
    }

    private func sessionDate(_ session: HermesSession?) -> Date {
        session.map(sessionDate) ?? .distantPast
    }

    private var readyTaskGroups: [QueueTaskGroup] {
        groupedTasks(readyTasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                profileHeader
                Spacer(minLength: 0)
                Button(action: onNewConversation) {
                    LucideIcon(name: .messageCirclePlus, size: 18, color: Color.dockPrimaryText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.dockSurface4))
                }
                .buttonStyle(.borderless)
                .help("New conversation")
                if showsFullscreenToggle {
                    Button(action: onFullscreenToggle) {
                        LucideImage(systemName: isFullscreen
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.dockSurface4))
                    }
                    .buttonStyle(.borderless)
                    .help(isFullscreen ? "Exit fullscreen" : "Enter fullscreen")
                    .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            ScrollView {
                globalRailBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
            }
        }
        .background(Color.dockSurface2)
        // This queue can move between AppKit split-view hosts as the center
        // destination changes. Loading the index is an initial-popover task,
        // not a navigation side effect; otherwise selecting a project or
        // conversation remounts the rail and reissues a full list refresh.
        .task {
            guard !navigationState.hasRequestedSessionIndex else { return }
            navigationState.hasRequestedSessionIndex = true
            model.loadSessions()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes control queue")
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
           let selected = visible.first(where: { $0.id == id }) {
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

    private var profileHeader: some View {
        let bot = selectedBot
        let label = bot.map { option in
            option.title.map { "\(option.name) — \($0)" } ?? option.name
        } ?? model.agentDisplayName
        let identity = HStack(spacing: 8) {
            if let bot {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 24)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.dockSurface4)
                    LucideImage(systemName: "bot")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                .frame(width: 24, height: 24)
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
        }

        return Group {
            if visibleBots.count > 1 {
                Button {
                    isProfileSelectorPresented.toggle()
                } label: {
                    HStack(spacing: 6) {
                        identity
                        LucideImage(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $isProfileSelectorPresented, arrowEdge: .top) {
                    profileSelectorPopover(selectedBot: bot)
                }
                .accessibilityLabel("Select Bot, currently \(label)")
            } else {
                identity.accessibilityLabel("Current Bot: \(label)")
            }
        }
    }

    private func profileSelectorPopover(selectedBot: BotSummary?) -> some View {
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
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.dockPrimaryText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if option.id == selectedBot?.id {
                                LucideImage(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.dockAccent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
        .background(Color.dockSurface2)
    }

    /// A one-line horizontal rail keeps global navigation compact and makes
    /// selection independent from every neighbouring destination.
    private var globalRailBar: some View {
        let projects = conversationGroups.filter(\.isLinked)
        let allConversations = allConversationSessions

        return VStack(alignment: .leading, spacing: 2) {
            globalRailDestination(.today)
            globalRailDestination(.inbox)
            globalRailDestination(.kanban)
            globalRailDestination(.quota)
            pullRequestsDestinationRow
            globalRailDestination(.automations)
            globalRailDestination(.officePreview)
            queueRailDestination("Artifacts", icon: "doc.text.magnifyingglass", isSelected: isArtifactsActive) {
                onOpenArtifacts()
            }
            botsDestinationRow

            if showsProjectsForSelectedBot {
                MissionControlProjectList(
                    groups: projects,
                    activeSessionID: activeSessionID,
                    selectedSessionID: navigationState.selectedSessionID,
                    attentionDots: sessionAttentionDots,
                    showsAllConversations: navigationState.showsAllConversations,
                    isLoadingProjects: controlCenter.isRefreshing && projects.isEmpty,
                    isRefreshing: controlCenter.isRefreshingProjectNavigation,
                    isCreatingChat: model.isCreatingSession,
                    onSelectSession: { session in
                        navigationState.selectedSessionID = session.id
                        navigationState.selectedTaskID = nil
                        onSelectSession(session)
                    },
                    onRefresh: {
                        controlCenter.refreshProjectNavigation()
                    },
                    onNewChatInProject: { projectPath in
                        Task {
                            await model.startNewChat(in: projectPath)
                            model.loadSessions()
                            controlCenter.refreshProjectNavigation()
                            model.requestComposerFocus()
                        }
                    }
                )
            }

            navigationDisclosureRow(
                title: "Conversations",
                icon: "bubble.left.and.bubble.right",
                count: allConversations.count,
                isExpanded: navigationState.areConversationsExpanded,
                isRefreshing: controlCenter.isRefreshingProjectNavigation,
                refreshAction: {
                    model.loadSessions()
                    controlCenter.refreshProjectNavigation()
                }
            ) {
                withAnimation(.dockEase(duration: 0.18)) { navigationState.areConversationsExpanded.toggle() }
            }
            if navigationState.areConversationsExpanded {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if allConversations.isEmpty {
                        queueEmpty("No saved conversations")
                            .padding(.leading, 14)
                    } else {
                        let visibleSessions = navigationState.showsAllConversations
                            ? allConversations
                            : Array(allConversations.prefix(10))
                        ForEach(visibleSessions) { session in
                            sessionRow(session)
                                .padding(.leading, 24)
                        }
                    }
                    if allConversations.count > 10 {
                        conversationExpansionButton
                            .padding(.leading, 24)
                    }
                }
            }

            globalRailDestination(.core)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hermes renders Bots beside Sessions in the left sidebar and opens the
    /// roster as its own page; the Dock keeps the same sibling placement.
    private var botsDestinationRow: some View {
        queueRailDestination(
            "Bots",
            icon: "bot",
            isSelected: isBotsActive
        ) {
            onOpenBots()
        }
    }

    private var pullRequestsDestinationRow: some View {
        Button {
            onOpenPullRequests()
        } label: {
            HStack(spacing: 8) {
                PullRequestBranchIcon(status: .neutral)
                    .frame(width: 20, height: 22)
                Text("Pull requests")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isPullRequestsActive ? Color.dockPrimaryText : Color.dockSecondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(isPullRequestsActive ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.borderless)
    }

    private func globalRailDestination(_ tab: ControlTab) -> some View {
        queueRailDestination(
            tab.globalRailLabel,
            icon: tab.icon,
            isSelected: activeGlobalTab == tab,
            showsUpdateBadge: tab == .core && agentUpdateService.phase == .updateAvailable
        ) {
            onOpenGlobal(tab)
        }
    }

    private func navigationDisclosureRow(
        title: String,
        icon: String,
        count: Int,
        isExpanded: Bool,
        isRefreshing: Bool = false,
        refreshAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Button(action: action) {
            HStack(spacing: 8) {
                LucideIcon(name: .from(systemName: icon), size: 16, color: Color.dockSecondaryText)
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockSecondaryText)
                Spacer(minLength: 0)
                Text(compactCount(count))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                LucideIcon(name: isExpanded ? .chevronDown : .chevronRight, size: 12, color: Color.dockMetadataText)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            if let refreshAction {
                Button(action: refreshAction) {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            LucideIcon(name: .refreshCw, size: 13, color: Color.dockSecondaryText)
                        }
                    }
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help(isRefreshing ? "Refreshing conversations…" : "Refresh conversations")
            }
        }
    }

    private func queueSection<Content: View>(
        _ title: String,
        count: Int?,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let action {
                    Button(action: action) { queueSectionHeader(title, count: count, isInteractive: true) }
                        .buttonStyle(.borderless)
                        .help("Open \(title.lowercased())")
                } else {
                    queueSectionHeader(title, count: count, isInteractive: false)
                }
            }
            content()
        }
    }

    private func queueSectionHeader(_ title: String, count: Int?, isInteractive: Bool) -> some View {
        HStack(spacing: 6) {
            LucideImage(systemName: title == "CONVERSATIONS" ? "bubble.left.and.bubble.right" : "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isInteractive ? Color.dockAccent : Color.dockSecondaryText)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(isInteractive ? Color.dockSecondaryText : Color.dockMetadataText)
            Spacer(minLength: 0)
            if let count {
                Text(compactCount(count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(count == 0 ? Color.dockMetadataText : Color.dockAccent)
            }
            if isInteractive {
                LucideImage(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(Color.clear)
        .contentShape(Rectangle())
    }

    private func queueEmpty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color.dockMetadataText)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
    }

    private func queueRailDestination(
        _ title: String,
        icon: String,
        isSelected: Bool,
        showsUpdateBadge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LucideIcon(name: .from(systemName: icon), size: 16, color: isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if showsUpdateBadge {
                    Circle()
                        .fill(Color.dockWarning)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Update available")
                }
            }
            .foregroundStyle(isSelected ? Color.dockPrimaryText : Color.dockSecondaryText)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 34)
                .contentShape(Rectangle())
                .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func queueOverflowButton(total: Int, visible: Int, title: String, action: @escaping () -> Void) -> some View {
        if total > visible {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text("Showing \(visible) of \(compactCount(total))")
                    Text(title)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dockAccent)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    private var conversationExpansionButton: some View {
        Button { navigationState.showsAllConversations.toggle() } label: {
            HStack(spacing: 6) {
                Text(navigationState.showsAllConversations ? "Show recent conversations" : "Show more conversations")
                LucideImage(systemName: navigationState.showsAllConversations ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.dockAccent)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func taskRow(_ task: WorkspaceTask, duplicateCount: Int = 1) -> some View {
        Button {
            navigationState.selectedTaskID = task.id
            navigationState.selectedSessionID = nil
            onSelectTask(task)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(taskColor(task.status))
                        .frame(width: 6, height: 6)
                    Text(taskDisplayTitle(task))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if duplicateCount > 1 {
                        Text("×\(duplicateCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.dockMetadataText)
                    }
                }
                if let detail = taskDisplayDetail(task) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isTaskSelected(task) ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help(task.sessionID == nil ? "Open this task in Kanban" : "Open task conversation")
    }

    private func sessionRow(_ session: HermesSession) -> some View {
        MissionControlConversationSessionRow(
            session: session,
            isSelected: isSessionSelected(session),
            isProjectLinked: projectLinkedSessionIDs.contains(session.id),
            projectName: projectNameBySessionID[session.id],
            attentionDot: sessionAttentionDots[session.id],
            onSelect: {
                navigationState.selectedSessionID = session.id
                navigationState.selectedTaskID = nil
                onSelectSession(session)
            }
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
        return navigationState.selectedTaskID == task.id || (task.sessionID != nil && task.sessionID == activeSessionID)
    }

    private func isSessionSelected(_ session: HermesSession) -> Bool {
        guard activeGlobalTab == nil, !isArtifactsActive else { return false }
        return navigationState.selectedSessionID == session.id || session.id == activeSessionID
    }

    private func taskDisplayTitle(_ task: WorkspaceTask) -> String {
        guard task.title == "Untitled chat",
              let sessionID = task.sessionID,
              let session = model.sessions.first(where: { $0.id == sessionID }) else { return task.title }
        return session.displayTitle
    }

    private func taskDisplayDetail(_ task: WorkspaceTask) -> String? {
        if !task.summary.isEmpty { return task.summary }
        guard let sessionID = task.sessionID,
              let session = model.sessions.first(where: { $0.id == sessionID }) else { return nil }
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

private struct MissionControlConversationSessionRow: View, Equatable {
    let session: HermesSession
    let isSelected: Bool
    let isProjectLinked: Bool
    let projectName: String?
    let attentionDot: SessionAttentionDot?
    let onSelect: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.session == rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.isProjectLinked == rhs.isProjectLinked
            && lhs.projectName == rhs.projectName
            && lhs.attentionDot == rhs.attentionDot
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let attentionDot {
                        Circle().fill(attentionDot.color).frame(width: 6, height: 6)
                    }
                }
                if let projectName {
                    LucideLabel(projectName, icon: "folder.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dockAccent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Project or repository: \(projectName)")
                }
                if let preview = session.displayPreview {
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                }
                if let timestamp = session.lastUpdatedAt {
                    HStack(spacing: 4) {
                        Text("Updated")
                        Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.dockAccent.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
    }
}

/// Project navigation is isolated from DockModel so high-frequency activity
/// updates do not rebuild the project hierarchy.
private struct MissionControlProjectList: View, Equatable {
    let groups: [MissionControlConversationGroup]
    let activeSessionID: String?
    let selectedSessionID: String?
    let attentionDots: [String: SessionAttentionDot]
    let showsAllConversations: Bool
    let isLoadingProjects: Bool
    let isRefreshing: Bool
    let isCreatingChat: Bool
    let onSelectSession: (HermesSession) -> Void
    let onRefresh: () -> Void
    let onNewChatInProject: (String) -> Void
    @State private var collapsedProjectIDs: Set<String> = []
    @State private var isExpanded = true

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.groups == rhs.groups
            && lhs.activeSessionID == rhs.activeSessionID
            && lhs.selectedSessionID == rhs.selectedSessionID
            && lhs.attentionDots == rhs.attentionDots
            && lhs.showsAllConversations == rhs.showsAllConversations
            && lhs.isLoadingProjects == rhs.isLoadingProjects
            && lhs.isRefreshing == rhs.isRefreshing
            && lhs.isCreatingChat == rhs.isCreatingChat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.dockEase(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        LucideIcon(name: .folder, size: 15, color: Color.dockSecondaryText)
                            .frame(width: 18, alignment: .center)
                        Text("Projects")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.dockSecondaryText)
                        Spacer(minLength: 0)
                        if isLoadingProjects {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(compactCount(groups.count))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.dockMetadataText)
                        }
                        LucideIcon(name: isExpanded ? .chevronDown : .chevronRight, size: 12, color: Color.dockMetadataText)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isExpanded ? Color.dockSurface4.opacity(0.72) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Button(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            LucideIcon(name: .refreshCw, size: 13, color: Color.dockSecondaryText)
                        }
                    }
                    .foregroundStyle(Color.dockSecondaryText)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help(isRefreshing ? "Refreshing projects…" : "Refresh projects")
            }

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        projectGroup(group)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func projectGroup(_ group: MissionControlConversationGroup) -> some View {
        let sessionCount = max(group.declaredSessionCount, group.sessions.count)
        let isCollapsed = sessionCount == 0 || collapsedProjectIDs.contains(group.id)
        let sessions = (showsAllConversations ? group.sessions : Array(group.sessions.prefix(10)))
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastUpdatedAt ?? .distantPast
                let rhsDate = rhs.lastUpdatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id < rhs.id
            }
        let isActiveProject = group.sessions.contains { $0.id == activeSessionID }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.dockEase(duration: 0.18)) {
                        if collapsedProjectIDs.contains(group.id) { collapsedProjectIDs.remove(group.id) }
                        else { collapsedProjectIDs.insert(group.id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isActiveProject ? Color.dockPrimaryText : Color.dockSecondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(compactCount(sessionCount))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.dockMetadataText)
                        LucideIcon(name: isCollapsed ? .chevronRight : .chevronDown, size: 12, color: Color.dockMetadataText)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 7)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                if let projectPath = group.projectPath, !projectPath.isEmpty {
                    Button {
                        onNewChatInProject(projectPath)
                    } label: {
                        LucideIcon(name: .messageCirclePlus, size: 15, color: Color.dockSecondaryText)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(isCreatingChat)
                    .help("New chat in \(group.title)")
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActiveProject ? Color.dockAccent.opacity(0.10) : Color.dockSurface.opacity(0.22))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isActiveProject ? Color.dockAccent.opacity(0.22) : Color.dockBorderLight.opacity(0.65), lineWidth: DockLayout.hairline)
            }
            if !isCollapsed {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isRefreshing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading linked sessions…")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockMetadataText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    } else if sessions.isEmpty && sessionCount > 0 {
                        Text("Loading linked sessions…")
                            .font(.system(size: 11)).foregroundStyle(Color.dockMetadataText)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                    } else {
                        ForEach(sessions) { session in sessionRow(session) }
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 3)
                .overlay(alignment: .leading) { Color.dockBorderLight.frame(width: DockLayout.hairline) }
            }
        }
    }

    private func sessionRow(_ session: HermesSession) -> some View {
        MissionControlProjectSessionRow(
            session: session,
            activeSessionID: activeSessionID,
            selectedSessionID: selectedSessionID,
            attentionDot: attentionDots[session.id],
            onSelect: onSelectSession
        )
        .equatable()
    }

    private func compactCount(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}

private struct MissionControlProjectSessionRow: View, Equatable {
    let session: HermesSession
    let activeSessionID: String?
    let selectedSessionID: String?
    let attentionDot: SessionAttentionDot?
    let onSelect: (HermesSession) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
            && lhs.activeSessionID == rhs.activeSessionID
            && lhs.selectedSessionID == rhs.selectedSessionID
            && lhs.attentionDot == rhs.attentionDot
    }

    var body: some View {
        Button { onSelect(session) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if let attentionDot {
                        Circle().fill(attentionDot.color).frame(width: 6, height: 6)
                    }
                }
                if let preview = session.displayPreview {
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                }
                if let timestamp = session.lastUpdatedAt {
                    HStack(spacing: 4) {
                        Text("Updated")
                        Text(timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                session.id == activeSessionID || session.id == selectedSessionID
                    ? Color.dockAccent.opacity(0.12)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.borderless)
    }
}

/// A three-region fullscreen shell: queue, focused workspace, and contextual
/// inspector. The queue and inspector keep sensible minimums while the center
/// owns all remaining space.
private struct MissionControlSplitView<Queue: View, Workspace: View, Inspector: View>: NSViewRepresentable {
    let queue: Queue
    let workspace: Workspace
    let inspector: Inspector

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.addArrangedSubview(context.coordinator.queueHost)
        splitView.addArrangedSubview(context.coordinator.workspaceHost)
        splitView.addArrangedSubview(context.coordinator.inspectorHost)
        context.coordinator.splitView = splitView
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.queueHost.rootView = AnyView(queue)
        context.coordinator.workspaceHost.rootView = AnyView(workspace)
        context.coordinator.inspectorHost.rootView = AnyView(inspector)

        guard !context.coordinator.hasSetInitialPositions else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.hasSetInitialPositions,
                  splitView.bounds.width > 0 else { return }
            // Mission Control deliberately gives the queue, work surface, and
            // inspector equal outer weight at launch. Users may still resize
            // either divider for a chat- or operations-heavy session.
            splitView.setPosition(splitView.bounds.width * 0.30, ofDividerAt: 0)
            splitView.setPosition(splitView.bounds.width * 0.70, ofDividerAt: 1)
            context.coordinator.hasSetInitialPositions = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let queueHost = NSHostingView(rootView: AnyView(EmptyView()))
        let workspaceHost = NSHostingView(rootView: AnyView(EmptyView()))
        let inspectorHost = NSHostingView(rootView: AnyView(EmptyView()))
        weak var splitView: NSSplitView?
        var hasSetInitialPositions = false

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            dividerIndex == 0 ? 220 : 540
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            if dividerIndex == 0 {
                return min(360, splitView.bounds.width - 680)
            }
            return splitView.bounds.width - 280
        }
    }
}

/// AppKit owns the fullscreen divider so panel resizing stays responsive even
/// while the conversation and inspector contain complex, frequently-updating
/// SwiftUI content.
private struct FullscreenPanelSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let leading: Leading
    let trailing: Trailing
    let leadingFraction: CGFloat

    init(leading: Leading, trailing: Trailing, leadingFraction: CGFloat = 0.30) {
        self.leading = leading
        self.trailing = trailing
        self.leadingFraction = leadingFraction
    }

    func makeCoordinator() -> Coordinator { Coordinator(leadingFraction: leadingFraction) }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.addArrangedSubview(context.coordinator.leadingHost)
        splitView.addArrangedSubview(context.coordinator.trailingHost)
        context.coordinator.splitView = splitView
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.leadingHost.rootView = AnyView(leading)
        context.coordinator.trailingHost.rootView = AnyView(trailing)

        guard !context.coordinator.hasSetInitialPosition else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.hasSetInitialPosition,
                  splitView.bounds.width > 0 else { return }
            splitView.setPosition(splitView.bounds.width * leadingFraction, ofDividerAt: 0)
            context.coordinator.hasSetInitialPosition = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let leadingFraction: CGFloat
        let leadingHost = NSHostingView(rootView: AnyView(EmptyView()))
        let trailingHost = NSHostingView(rootView: AnyView(EmptyView()))
        weak var splitView: NSSplitView?
        var hasSetInitialPosition = false
        init(leadingFraction: CGFloat) { self.leadingFraction = leadingFraction }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            min(leadingFraction < 0.25 ? 220 : 320, splitView.bounds.width * 0.35)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let minimumLeadingWidth = min(leadingFraction < 0.25 ? 220 : 320, splitView.bounds.width * 0.35)
            let minimumTrailingWidth = min(360, splitView.bounds.width * 0.35)
            return max(minimumLeadingWidth, splitView.bounds.width - splitView.dividerThickness - minimumTrailingWidth)
        }
    }
}

enum ConversationScrollMetrics {
    // Streaming rows grow while the viewport is parked at the bottom; the
    // sticky-bottom check must tolerate that transient growth so auto-scroll
    // is not suppressed before the settle re-assertion runs.
    static let atBottomTolerance: CGFloat = 96
    static let pastEndTolerance: CGFloat = 1

    static func isAtBottom(bottomMaxY: CGFloat, viewportHeight: CGFloat) -> Bool {
        bottomMaxY >= viewportHeight - pastEndTolerance
            && bottomMaxY <= viewportHeight + atBottomTolerance
    }

    static func isAtBottom(
        topMinY: CGFloat,
        bottomMaxY: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        // A transcript that fits without scrolling has one legal origin: zero.
        // It is therefore both at the top and at the bottom; treating it as
        // browsing produces a false unread badge on the next append.
        if topMinY >= -pastEndTolerance,
           bottomMaxY <= viewportHeight + pastEndTolerance {
            return true
        }
        return isAtBottom(bottomMaxY: bottomMaxY, viewportHeight: viewportHeight)
    }

    /// The content is visibly above the viewport bottom despite having already
    /// been scrolled upward. Unlike a short transcript at origin zero, this is
    /// an invalid trailing scroll position and must be clamped to the footer.
    static func isPastEnd(
        topMinY: CGFloat,
        bottomMaxY: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        topMinY < -pastEndTolerance
            && bottomMaxY < viewportHeight - pastEndTolerance
    }
}
