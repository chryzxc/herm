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

enum MissionControlNavigationSelection: Equatable {
    case session(String)
    case task(UUID)
    case global(ControlTab)
    case artifacts
    case bots
    case pullRequests
    case issues
}

@MainActor
final class MissionControlNavigationSelectionState: ObservableObject {
    @Published private(set) var selection: MissionControlNavigationSelection?

    func clear() { selection = nil }
    func selectSession(_ id: String) { selection = .session(id) }
    func selectTask(_ id: UUID) { selection = .task(id) }
    func selectGlobal(_ tab: ControlTab) { selection = .global(tab) }
    func selectArtifacts() { selection = .artifacts }
    func selectBots() { selection = .bots }
    func selectPullRequests() { selection = .pullRequests }
    func selectIssues() { selection = .issues }

    func isTaskSelected(_ id: UUID, sessionID: String? = nil) -> Bool {
        if case .task(id) = selection { return true }
        return false
    }

    func isSessionSelected(_ id: String) -> Bool {
        if case .session(id) = selection { return true }
        return false
    }

    func isGlobalSelected(_ tab: ControlTab) -> Bool {
        if case .global(tab) = selection { return true }
        return false
    }
}

/// Presentation state owned by the left navigation rail, rather than a
/// particular split-view host. Global destinations replace their trailing
/// content host, so keeping this state here lets the rail retain its expanded
/// sections and local selection while the user moves between pages.
@MainActor
final class MissionControlNavigationState: ObservableObject {
    let selection = MissionControlNavigationSelectionState()
    @Published var showsAllConversations = false
    @Published var selectedTaskID: UUID?
    @Published var selectedSessionID: String?
    @Published var areConversationsExpanded = true
    @Published var arePinnedExpanded = true
    var hasRequestedSessionIndex = false

    var selectedProjectSessionID: String? {
        guard case .session = selection.selection else { return nil }
        return selectedSessionID
    }

    func selectSession(_ id: String) {
        selection.selectSession(id)
        selectedTaskID = nil
        selectedSessionID = id
    }

    /// Route every callback that opens an existing or newly resolved session
    /// through the same owner so the prior task/global destination cannot
    /// remain selected alongside the conversation.
    func openSession(_ id: String) {
        selectSession(id)
    }

    func openBotChat(sessionID: String) {
        openSession(sessionID)
    }

    func openProjectSession(sessionID: String) {
        openSession(sessionID)
    }

    func openPullRequestChat(sessionID: String?) {
        if let sessionID {
            openSession(sessionID)
        } else {
            clearSelection()
        }
    }

    func synchronizeActiveSession(_ sessionID: String?) {
        if let sessionID, !sessionID.isEmpty {
            openSession(sessionID)
        }
    }

    func openIssueChat(sessionID: String?) {
        openPullRequestChat(sessionID: sessionID)
    }

    func beginProjectChat(sessionID: String? = nil) {
        if let sessionID {
            openSession(sessionID)
        } else {
            beginNewConversation()
        }
    }

    func beginNewConversation() {
        clearSelection()
    }

    func clearSelection() {
        selection.clear()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectTask(_ id: UUID) {
        selection.selectTask(id)
        selectedSessionID = nil
        selectedTaskID = id
    }

    func selectGlobal(_ tab: ControlTab) {
        selection.selectGlobal(tab)
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectArtifacts() {
        selection.selectArtifacts()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectBots() {
        selection.selectBots()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectPullRequests() {
        selection.selectPullRequests()
        selectedTaskID = nil
        selectedSessionID = nil
    }

    func selectIssues() {
        selection.selectIssues()
        selectedTaskID = nil
        selectedSessionID = nil
    }
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
    @State private var mountedMessageRange: Range<Int> = 0..<0
    @State private var visibleNavigatorIndexSpan: ClosedRange<Int>?
    @State private var transcriptAnchorMessageID: UUID?
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
    @StateObject private var messageActionState = ConversationMessageActionState()
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var controlCenter = ControlCenterModel()
    @StateObject private var agentUpdateService = HermesUpdateService()
    @StateObject private var developerWorkflow = DeveloperWorkflowModel()
    @StateObject private var pullRequestCenter = PullRequestCenterModel()
    @StateObject private var pullRequestChatLinks = PullRequestChatLinkStore()
    @StateObject private var repositoryPreferences = CommandCenterPreferencesStore()
    @StateObject private var dockThemeStore = DockThemeStore()
    @StateObject private var botMode = BotModeModel()
    @StateObject private var missionControlNavigation = MissionControlNavigationState()
    @State private var sessionWorkspaceMode: SessionWorkspaceMode = .chat
    @State private var suppressNextVoiceResponse = false
    @State private var sessionPendingDeletion: HermesSession?
    // These selections are owned by the active session/repository scope. The
    // request IDs invalidate completions from an older scope or selection.
    @State private var explorerSelection: ScopedRepositoryDocument?
    @State private var explorerNavigatorWidth: CGFloat = ExplorerWorkspaceMetrics.initialNavigatorWidth
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
        case conversation, pullRequests, issues
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
            .preferredColorScheme(dockThemeStore.selectedThemeID.appearance == .light ? .light : dockThemeStore.selectedThemeID.appearance == .dark ? .dark : nil)
            .animation(.dockEase(duration: 0.35), value: isWorkspaceVisibleForLayout)
            .sheet(item: $selectedChatImage) { preview in
                ChatImagePreviewModal(image: preview.image)
            }
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
                    leadingFraction: sessionWorkspaceMode == .explorer ? nil : 0.57,
                    initialLeadingWidth: sessionWorkspaceMode == .explorer ? explorerNavigatorWidth : nil,
                    minimumLeadingWidth: sessionWorkspaceMode == .explorer ? ExplorerWorkspaceMetrics.minimumNavigatorWidth : 320,
                    maximumLeadingWidth: sessionWorkspaceMode == .explorer ? ExplorerWorkspaceMetrics.maximumNavigatorWidth : nil,
                    minimumTrailingWidth: sessionWorkspaceMode == .explorer ? ExplorerWorkspaceMetrics.minimumEditorWidth : 360,
                    leadingWidth: sessionWorkspaceMode == .explorer ? $explorerNavigatorWidth : nil
                )
            )
        } else {
            AnyView(conversationColumn)
        }
    }

    private var isGlobalSurfaceActive: Bool {
        switch fullscreenSurface {
        case .global, .artifacts, .bots, .pullRequests, .issues: true
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
        if sessionWorkspaceMode == .explorer, isNarrowLayout {
            return isNarrowControlVisible && explorerSelection != nil
        }
        return isNarrowLayout ? isNarrowControlVisible : isWorkspaceVisible
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
    private var conversationMetrics: ConversationWorkspaceMetrics {
        .resolve(isFullscreen: isFullscreen)
    }
    private var conversationMessageMaxWidth: CGFloat { conversationMetrics.readingWidth }
    private var navigatorMinimumConversationWidth: CGFloat { 820 }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            header
            switch sessionWorkspaceMode {
            case .chat:
                conversation
                ChatComposerView(
                    model: model,
                    composer: model.composer,
                    speechInput: speechInput,
                    botMode: botMode,
                    onStop: stopCurrentRequest,
                    isFullscreen: isFullscreen,
                    metrics: conversationMetrics
                )
            case .voice:
                voiceMode
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
        missionControlNavigation.synchronizeActiveSession(newValue)
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
        missionControlNavigation.synchronizeActiveSession(model.sessionID)
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
            dockThemeStore: dockThemeStore,
            sessionPendingDeletion: $sessionPendingDeletion,
            activeSessionID: model.sessionID,
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
        missionControlNavigation.clearSelection()
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
            dockThemeStore: dockThemeStore,
            onClose: onClose,
            onRestartDock: {
                // Do not restore the old session's model pin after relaunch.
                // The restart is explicitly a provider/account sync boundary.
                model.newChat()
                agentUpdateService.restartDock()
            },
            onOpenArtifacts: { },
            onSessionOpened: { sessionID in
                missionControlNavigation.openProjectSession(sessionID: sessionID)
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
            if fullscreenSurface == .pullRequests || fullscreenSurface == .issues {
                PullRequestWorkspace(
                    center: pullRequestCenter,
                    projects: controlCenter.projects,
                    onOpenChat: openPullRequestChat,
                    onOpenIssueChat: openIssueChat,
                    mode: fullscreenSurface == .issues ? .issues : .pullRequests
                )
                .id(fullscreenSurface == .issues ? "fullscreen-issues" : "fullscreen-pull-requests")
            } else if fullscreenSurface == .artifacts {
                ArtifactsInspectorView(model: model, presentation: .page)
                    .id("fullscreen-artifacts")
            } else if fullscreenSurface == .bots {
                BotRosterPage(
                    model: botMode,
                    dockModel: model,
                    onSelectBot: openBotChat,
                    onOpenRecentSession: openRecentBotSession
                )
                    .id("fullscreen-bots")
            } else {
                fullscreenGlobalControlSurface
            }
        }
    }

    private func openBotChat(_ bot: BotSummary) {
        let chat = bot.chat ?? BotChatReference(sessionID: BotService.canonicalBotChatTitle, profileID: bot.id)
        missionControlNavigation.openBotChat(sessionID: chat.sessionID)
        fullscreenSurface = .conversation
        inspectorScope = .session
        model.resumeBotChat(bot)
    }

    private func openRecentBotSession(_ bot: BotSummary, recent: BotChatReference) {
        missionControlNavigation.openSession(recent.sessionID)
        fullscreenSurface = .conversation
        inspectorScope = .session
        model.resumeSession(HermesSession(
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
                missionControlNavigation.openPullRequestChat(sessionID: linkedSession.id)
                model.resumeSession(linkedSession)
            } else {
                pullRequestChatLinks.remove(pullRequestID: pullRequest.id)
                await model.startNewChat(in: pullRequest.localPath)
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

    private func openIssueChat(_ issue: GitHubIssueRecord) {
        let context = IssueContext(issue: issue)
        Task {
            var sessionID: String?
            if let linkedID = pullRequestChatLinks.sessionID(for: context.id),
               let linkedSession = model.sessions.first(where: { $0.id == linkedID }) {
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
                    isStandalonePane: !isNarrowLayout
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
                .frame(minHeight: conversationMetrics.headerHeight - 12)
                .contentShape(Rectangle())
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

            HStack(spacing: 2) {
                sessionModePicker

                Divider()
                    .frame(height: 24)
                    .overlay(Color.dockBorderLight)

                // This control belongs to the active conversation: it
                // toggles the inspector (the third workspace panel).
                Button(action: toggleInspectorPanel) {
                    LucideImage(systemName: inspectorPanelIsVisible ? "rectangle.split.2x1" : "rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(inspectorPanelIsVisible ? Color.dockAccent : Color.dockSecondaryText)
                        .frame(width: 44, height: 44)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(inspectorPanelIsVisible ? Color.dockAccent.opacity(0.12) : Color.clear)
                                .padding(5)
                        }
                }
                .buttonStyle(DockPressButtonStyle())
                .help(inspectorPanelIsVisible ? "Hide inspector" : "Show inspector")
                .accessibilityLabel(inspectorPanelIsVisible ? "Hide inspector" : "Show inspector")
            }
        }
        .padding(.horizontal, DockLayout.contentInset)
        .frame(height: conversationMetrics.headerHeight)
        .background(Color.dockCanvas)
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
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(sessionWorkspaceMode == mode ? Color.dockAccent.opacity(0.12) : Color.clear)
                    .padding(5)
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
            if sessionWorkspaceMode == .explorer { return }
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
                                Task { @MainActor in
                                    if await model.setSessionHidden(session, hidden: !session.isHidden) {
                                        controlCenter.refreshProjectNavigation()
                                    }
                                }
                            } label: {
                                LucideImage(systemName: session.isHidden ? "eye" : "eye.slash")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.dockSecondaryText)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                            .help(session.isHidden ? "Show session" : "Hide session")
                            .accessibilityLabel(session.isHidden ? "Show \(session.displayTitle)" : "Hide \(session.displayTitle)")
                            .disabled(model.updatingSessionVisibilityID == session.id)
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

                                let mountedRange = effectiveMountedRange
                                let messages = model.messages[mountedRange]
                                if mountedRange.lowerBound > 0 {
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

                                ForEach(Array(messages.enumerated()), id: \.element.id) { rowOffset, message in
                                    messageRow(message)
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: MessageNavigatorViewportPreferenceKey.self,
                                                    value: [MessageNavigatorViewport(
                                                        target: MessageNavigatorTarget(sessionID: model.sessionID ?? "", messageID: message.id),
                                                        index: mountedRange.lowerBound + rowOffset,
                                                        minY: geometry.frame(in: .named("conversation-scroll")).minY,
                                                        maxY: geometry.frame(in: .named("conversation-scroll")).maxY
                                                    )]
                                                )
                                            }
                                        }
                                        .id(message.id)
                                }
                                if mountedRange.upperBound < model.messages.count {
                                    Button(action: revealLaterMessages) {
                                        HStack(spacing: 7) {
                                            LucideImage(systemName: "arrow.down")
                                                .font(.system(size: 11, weight: .semibold))
                                            Text("Show later messages")
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
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
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
                            .padding(.vertical, 12)
                            .padding(.horizontal, 0)
                            .frame(maxWidth: conversationMessageMaxWidth)
                            .frame(maxWidth: .infinity)

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
                    .scrollPosition(id: $transcriptAnchorMessageID, anchor: .top)
                    .coordinateSpace(name: "conversation-scroll")
                    .onAppear {
                        isConversationAtBottom = true
                        unseenMessageCount = 0
                        mountedMessageRange = ConversationMessageWindow.rangeForSessionReplacement(
                            totalCount: model.messages.count
                        )
                        lastRenderedMessageBubbleCount = renderedMessageBubbleCount
                    }
                    .onChange(of: model.sessionID) { _, _ in
                        // The ScrollView identity is session-specific, but its
                        // parent presentation state is not. Reset explicitly
                        // so a session opened after an expanded history page
                        // mounts only its bounded recent window.
                        isConversationAtBottom = true
                        unseenMessageCount = 0
                        mountedMessageRange = ConversationMessageWindow.rangeForSessionReplacement(
                            totalCount: model.messages.count
                        )
                        visibleNavigatorIndexSpan = nil
                        transcriptAnchorMessageID = nil
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
                        let visible = viewports.filter { $0.maxY >= 0 && $0.minY <= viewportHeight }
                        let next = Set(visible.map(\.target))
                        // Row frames move in the scroll coordinate space, so
                        // this preference fires on every scroll frame. A state
                        // write with an unchanged value would still invalidate
                        // the whole popover body between row-edge crossings.
                        if next != visibleNavigatorTargets {
                            visibleNavigatorTargets = next
                        }
                        if let first = visible.min(by: { $0.index < $1.index }),
                           let last = visible.max(by: { $0.index < $1.index }) {
                            let span = first.index...last.index
                            if span != visibleNavigatorIndexSpan {
                                visibleNavigatorIndexSpan = span
                            }
                        } else if visibleNavigatorIndexSpan != nil {
                            visibleNavigatorIndexSpan = nil
                        }
                    }
                    .onChange(of: model.scrollToLatestMessageRequest) { _, _ in
                        unseenMessageCount = 0
                        isConversationAtBottom = true
                        mountedMessageRange = ConversationMessageWindow.rangeForSessionReplacement(
                            totalCount: model.messages.count
                        )
                        scrollConversationToBottom(proxy)
                    }
                    .onChange(of: conversationScrollRequest) { _, _ in
                        mountedMessageRange = ConversationMessageWindow.rangeForSessionReplacement(
                            totalCount: model.messages.count
                        )
                        scrollConversationToBottom(proxy, animated: true)
                    }
                    .onChange(of: model.messages.count) { oldCount, newCount in
                        mountedMessageRange = ConversationMessageWindow.rangeAfterCountChange(
                            mountedMessageRange,
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
                            mountedMessageRange = ConversationMessageWindow.rangeForSessionReplacement(
                                totalCount: model.messages.count
                            )
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

                    if model.messages.count >= MessageNavigator.minimumMessagesToShowNavigator,
                       viewport.size.width >= navigatorMinimumConversationWidth {
                        MessageNavigatorView(
                            items: ConversationMessageWindow.navigatorItems(messages: model.messages, sessionID: model.sessionID ?? ""),
                            sessionID: model.sessionID ?? "",
                            visibleTargets: visibleNavigatorTargets,
                            onSelect: { item in jumpToMessage(item, proxy: proxy) }
                        )
                        .frame(width: 286, height: viewport.size.height)
                        .padding(.trailing, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func jumpToMessage(_ item: MessageNavigatorItem, proxy: ScrollViewProxy) {
        let sessionID = model.sessionID ?? ""
        let handler = Self.transcriptSelectionHandler(
            sessionID: sessionID,
            messages: model.messages,
            currentSessionID: { model.sessionID },
            onEffect: { effect in
                mountedMessageRange = effect.windowRange
                isConversationAtBottom = effect.isAtBottom
                unseenMessageCount = effect.unseenMessageCount
            },
            onScroll: { messageID, anchor in
                proxy.scrollTo(messageID, anchor: anchor)
            }
        )
        handler(item)
    }

    static func transcriptSelectionHandler(
        sessionID: String,
        messages: [ChatMessage],
        currentSessionID: @escaping () -> String?,
        onEffect: @escaping (ConversationMessageJumpEffect) -> Void,
        onScroll: @escaping (UUID, UnitPoint) -> Void
    ) -> (MessageNavigatorItem) -> Void {
        ConversationMessageWindow.transcriptSelectionHandler(
            sessionID: sessionID,
            messages: messages,
            onEffect: { effect in
                guard currentSessionID() == sessionID else { return }
                onEffect(effect)
            },
            onScroll: { messageID, anchor in
                Task { @MainActor in
                    await Task.yield()
                    guard currentSessionID() == sessionID else { return }
                    switch anchor {
                    case .center:
                        onScroll(messageID, .center)
                    }
                }
            }
        )
    }

    private var effectiveMountedRange: Range<Int> {
        let total = model.messages.count
        let clamped = ConversationMessageWindow.visibleRange(mountedMessageRange, totalCount: total)
        guard clamped.isEmpty, total > 0 else { return clamped }
        return ConversationMessageWindow.tailRange(totalCount: total)
    }

    private func revealEarlierMessages() {
        mountedMessageRange = ConversationMessageWindow.revealEarlier(
            effectiveMountedRange,
            totalCount: model.messages.count,
            visibleSpan: visibleNavigatorIndexSpan
        )
    }

    private func revealLaterMessages() {
        mountedMessageRange = ConversationMessageWindow.revealLater(
            effectiveMountedRange,
            totalCount: model.messages.count,
            visibleSpan: visibleNavigatorIndexSpan
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
        let atBottom = ConversationMessageWindow.isLiveTail(
            mountedMessageRange,
            totalCount: model.messages.count
        )
            && ConversationScrollMetrics.isAtBottom(
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
                range: mountedMessageRange,
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

            mountedMessageRange = ConversationMessageWindow.compactedRange(
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
                responseDuration: message.responseDuration,
                metrics: conversationMetrics
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
                onImagePreview: { image in selectedChatImage = ChatImagePreview(image: image) },
                pendingAction: messageActionState.pendingAction(for: message.id),
                areSessionActionsAvailable: !(model.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                isSpeaking: voiceOutput.speakingMessageID == message.id,
                metrics: conversationMetrics,
                onCopy: { messageActionState.copy(message) },
                onBranch: {
                    messageActionState.run(message.id, action: .branch) {
                        await model.branchConversation(from: message)
                    }
                },
                onReadAloud: { voiceOutput.toggle(messageID: message.id, text: message.text) },
                onRefresh: {
                    messageActionState.run(message.id, action: .refresh) {
                        await model.refreshCurrentSession()
                    }
                }
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
enum SessionAttentionDot: Equatable {
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

struct ConversationRepositoryBadgePresentation: Equatable {
    static let maximumLabelLength = 24

    let label: String
    let accessibilityLabel: String

    static func make(projectName: String?, isProjectLinked: Bool) -> Self? {
        guard isProjectLinked,
              let projectName,
              !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastPathComponent = URL(fileURLWithPath: trimmedName).lastPathComponent
        let normalizedName = lastPathComponent.isEmpty ? trimmedName : lastPathComponent
        guard !normalizedName.isEmpty else { return nil }

        let label: String
        if normalizedName.count > maximumLabelLength {
            label = String(normalizedName.prefix(maximumLabelLength - 1)) + "…"
        } else {
            label = normalizedName
        }
        return Self(
            label: label,
            accessibilityLabel: "Repository \(label)"
        )
    }
}

struct ConversationRepositoryBadgeAssociationProjection {
    struct Group {
        let sessionIDs: Set<String>
        let title: String
        let isLinked: Bool

        init(sessionIDs: [String], title: String, isLinked: Bool) {
            self.sessionIDs = Set(sessionIDs)
            self.title = title
            self.isLinked = isLinked
        }
    }

    let linkedSessionIDs: Set<String>
    let projectNameBySessionID: [String: String]

    init(groups: [Group]) {
        var linkedSessionIDs = Set<String>()
        var projectNameBySessionID: [String: String] = [:]
        for group in groups where group.isLinked {
            linkedSessionIDs.formUnion(group.sessionIDs)
            for sessionID in group.sessionIDs where projectNameBySessionID[sessionID] == nil {
                projectNameBySessionID[sessionID] = group.title
            }
        }
        self.linkedSessionIDs = linkedSessionIDs
        self.projectNameBySessionID = projectNameBySessionID
    }

    func badge(for sessionID: String) -> ConversationRepositoryBadgePresentation? {
        ConversationRepositoryBadgePresentation.make(
            projectName: projectNameBySessionID[sessionID],
            isProjectLinked: linkedSessionIDs.contains(sessionID)
        )
    }

    func isLinked(sessionID: String) -> Bool {
        linkedSessionIDs.contains(sessionID)
    }

    func projectName(for sessionID: String) -> String? {
        projectNameBySessionID[sessionID]
    }
}

private struct MissionControlQueue: View {
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
    let onOpenPullRequests: () -> Void
    let onOpenIssues: () -> Void
    let showsFullscreenToggle: Bool
    let isFullscreen: Bool
    let onFullscreenToggle: () -> Void
    let onSelectProfile: (String) -> Void
    @State private var isProfileSelectorPresented = false
    @StateObject private var pinnedSessionStore = PinnedSessionStore()
    @StateObject private var sidebarSessionSeenStore = SidebarSessionSeenStore()
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
        onOpenPullRequests: @escaping () -> Void,
        onOpenIssues: @escaping () -> Void,
        showsFullscreenToggle: Bool,
        isFullscreen: Bool,
        onFullscreenToggle: @escaping () -> Void,
        onSelectProfile: @escaping (String) -> Void
    ) {
        self.model = model
        self.botMode = botMode
        self.workspaceStore = workspaceStore
        self.controlCenter = controlCenter
        self.agentUpdateService = agentUpdateService
        self.navigationState = navigationState
        self.dockThemeStore = dockThemeStore
        _sidebar = StateObject(wrappedValue: MissionControlSidebarModel(model: model, control: controlCenter))
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
        self.onOpenPullRequests = onOpenPullRequests
        self.onOpenIssues = onOpenIssues
        self.showsFullscreenToggle = showsFullscreenToggle
        self.isFullscreen = isFullscreen
        self.onFullscreenToggle = onFullscreenToggle
        self.onSelectProfile = onSelectProfile
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
            sessions: sidebarSnapshot.conversations,
            state: pinnedSessionStore.state,
            profileID: sidebarSnapshot.inputs.profileScopeID ?? "",
            projection: sidebarSnapshot.inputs.sessionProjectionState,
            hasRequestedSessionIndex: navigationState.hasRequestedSessionIndex
        )
    }

    private var sidebarSessionStatuses: [String: SidebarSessionStatus] {
        let summaries = Dictionary(uniqueKeysWithValues: sidebarSnapshot.inputs.activeSessions.map { ($0.id, $0) })
        let profileID = sidebarSnapshot.inputs.profileScopeID ?? model.profileScopeID
        return Dictionary(uniqueKeysWithValues: sidebarSnapshot.conversations.map { session in
            let status = SidebarSessionStatusResolver.resolve(
                session: session,
                summary: summaries[session.id],
                activeSessionID: sidebarSnapshot.inputs.activeSessionID,
                activeStatus: session.id == sidebarSnapshot.inputs.activeSessionID ? sidebarSnapshot.inputs.activeStatus : nil,
                attention: sidebarSnapshot.attentionDots[session.id],
                seenAt: sidebarSessionSeenStore.seenAt(profileID: session.profileID ?? profileID, sessionID: session.id),
                isProfileBaselined: sidebarSessionSeenStore.isBaselined(profileID: session.profileID ?? profileID)
            )
            return (session.id, status)
        })
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                profileHeader(style: style)
                Spacer(minLength: 0)
                Button(action: onNewConversation) {
                    LucideIcon(name: .messageCirclePlus, size: 18, color: style.accent)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(style.primaryText)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(style.selectedFill))
                }
                .buttonStyle(.borderless)
                .help("New conversation")
                if showsFullscreenToggle {
                    Button(action: onFullscreenToggle) {
                        LucideImage(systemName: isFullscreen
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(style.secondaryText)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(style.selectedFill))
                    }
                    .buttonStyle(.borderless)
                    .help(isFullscreen ? "Exit fullscreen" : "Enter fullscreen")
                    .padding(.leading, 6)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .overlay(alignment: .bottom) { style.divider.frame(height: 0.5) }

            ScrollView {
                globalRailBar(style: style)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }

            VStack(spacing: 2) {
                globalRailDestination(.quota, style: style)
                globalRailDestination(.core, style: style)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { style.divider.frame(height: 0.5) }
        }
        .background(style.background)
        // This queue can move between AppKit split-view hosts as the center
        // destination changes. Loading the index is an initial-popover task,
        // not a navigation side effect; otherwise selecting a project or
        // conversation remounts the rail and reissues a full list refresh.
        .task {
            guard !navigationState.hasRequestedSessionIndex else { return }
            navigationState.hasRequestedSessionIndex = true
            model.loadSessions()
        }
        .onChange(of: sidebar.snapshot.inputs.sessionProjectionState) { _, _ in
            baselineSidebarSessionsIfAuthoritative()
        }
        .onChange(of: sidebar.snapshot.inputs.activeSessionID) { _, _ in
            if let id = sidebar.snapshot.inputs.activeSessionID,
               let session = sidebar.snapshot.conversations.first(where: { $0.id == id }) {
                markSessionSeen(session)
            }
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

    private func profileHeader(style: DockThemePalette) -> some View {
        let bot = selectedBot
        let label = bot.map { option in
            option.title.map { "\(option.name) — \($0)" } ?? option.name
        } ?? sidebarSnapshot.inputs.agentDisplayName
        let identity = HStack(spacing: 8) {
            if let bot {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 24)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.selectedFill)
                    LucideImage(systemName: "bot")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(style.secondaryText)
                }
                .frame(width: 24, height: 24)
            }
            Text(label)
                .font(style.profileFont)
                .foregroundStyle(style.theme == .hermesClassic ? style.accent : style.primaryText)
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
                            .foregroundStyle(style.metadataText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $isProfileSelectorPresented, arrowEdge: .top) {
                    profileSelectorPopover(selectedBot: bot, style: style)
                }
                .accessibilityLabel("Select Bot, currently \(label)")
            } else {
                identity.accessibilityLabel("Current Bot: \(label)")
            }
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
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(style.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if option.id == selectedBot?.id {
                                LucideImage(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(style.accent)
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
        .background(style.background)
    }

    /// A one-line horizontal rail keeps global navigation compact and makes
    /// selection independent from every neighbouring destination.
    private func globalRailBar(style: DockThemePalette) -> some View {
        let projects = sidebarSnapshot.linkedProjectGroups
        let allConversations = sidebarSnapshot.conversations

        return VStack(alignment: .leading, spacing: style.sectionSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                globalRailDestination(.today, style: style)
                globalRailDestination(.inbox, style: style)
                globalRailDestination(.kanban, style: style)
            }

            sidebarSection("Tools", style: style) {
                pullRequestsDestinationRow(style: style)
                issuesDestinationRow(style: style)
                globalRailDestination(.automations, style: style)
                globalRailDestination(.officePreview, style: style)
                queueRailDestination("Artifacts", icon: "doc.text.magnifyingglass", isSelected: navigationState.selection.selection == .artifacts, style: style) {
                    onOpenArtifacts()
                }
                botsDestinationRow(style: style)
            }

            let pinned = pinnedSessionPresentation
            if pinned.status != .empty || !pinned.sessions.isEmpty {
                pinnedOutline(pinned, style: style)
            }

            if showsProjectsForSelectedBot {
                MissionControlProjectList(
                    groups: projects,
                    selectedSessionID: navigationState.selectedProjectSessionID,
                    activeSessionID: sidebarSnapshot.inputs.activeSessionID,
                    attentionDots: sidebarSnapshot.attentionDots,
                    sessionStatuses: sidebarSessionStatuses,
                    isLoadingProjects: sidebarSnapshot.inputs.isRefreshing && projects.isEmpty,
                    isRefreshing: sidebarSnapshot.inputs.isRefreshingProjectNavigation,
                    isCreatingChat: sidebarSnapshot.inputs.isCreatingSession,
                    style: style,
                    isPinned: { session in
                        pinnedSessionStore.state.contains(
                            profileID: session.profileID ?? model.profileScopeID ?? "",
                            sessionID: session.id
                        )
                    },
                    onTogglePin: { session in
                        pinnedSessionStore.toggle(
                            profileID: session.profileID ?? model.profileScopeID ?? "",
                            sessionID: session.id
                        )
                    },
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
                    onSelectSession: { session in
                        markSessionSeen(session)
                        navigationState.selectSession(session.id)
                        onSelectSession(session)
                    },
                    onRefresh: {
                        controlCenter.refreshProjectNavigation()
                    },
                    onNewChatInProject: { projectPath in
                        navigationState.beginProjectChat()
                        Task {
                            await model.startNewChat(in: projectPath)
                            if let createdID = model.sessionID {
                                navigationState.beginProjectChat(sessionID: createdID)
                            }
                            model.loadSessions()
                            controlCenter.refreshProjectNavigation()
                            model.requestComposerFocus()
                        }
                    }
                )
            }

            conversationOutline(allConversations, style: style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sidebarSection<Content: View>(_ title: String, count: Int? = nil, style: DockThemePalette, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(style.sectionFont).foregroundStyle(style.secondaryText)
                Spacer(minLength: 0)
                if let count { Text(compactCount(count)).font(.system(size: 10)).foregroundStyle(style.metadataText) }
            }
            .padding(.horizontal, 9)
            .frame(height: 24, alignment: .leading)
            content()
        }
        .padding(.top, style.usesStructuredDividers ? 7 : 0)
        .overlay(alignment: .top) {
            if style.usesStructuredDividers { style.divider.frame(height: 0.5) }
        }
    }

    /// Hermes renders Bots beside Sessions in the left sidebar and opens the
    /// roster as its own page; the Dock keeps the same sibling placement.
    private func botsDestinationRow(style: DockThemePalette) -> some View {
        queueRailDestination(
            "Bots",
            icon: "bot",
            isSelected: navigationState.selection.selection == .bots,
            style: style
        ) {
            onOpenBots()
        }
    }

    private func pullRequestsDestinationRow(style: DockThemePalette) -> some View {
        Button {
            onOpenPullRequests()
        } label: {
            HStack(spacing: 8) {
                if style.showsDestinationIcons {
                    PullRequestBranchIcon(status: .neutral)
                        .frame(width: 20, height: 22)
                }
                Text("Pull requests")
                    .font(style.labelFont)
                    .lineLimit(1)
            }
            .foregroundStyle(navigationState.selection.selection == .pullRequests ? style.primaryText : style.secondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: style.rowHeight)
            .contentShape(Rectangle())
            .background(navigationState.selection.selection == .pullRequests ? style.selectedFill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        }
        .buttonStyle(.borderless)
    }

    private func issuesDestinationRow(style: DockThemePalette) -> some View {
        Button(action: onOpenIssues) {
            HStack(spacing: 8) {
                if style.showsDestinationIcons {
                    LucideIcon(name: .fileText, size: 15, color: style.secondaryText)
                        .frame(width: 20, height: 22)
                }
                Text("Issues")
                    .font(style.labelFont)
                    .lineLimit(1)
            }
            .foregroundStyle(isIssuesActive ? style.primaryText : style.secondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: style.rowHeight)
            .contentShape(Rectangle())
            .background(isIssuesActive ? style.selectedFill : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        }
        .buttonStyle(.borderless)
        .help("GitHub issues across your repositories")
    }

    private func globalRailDestination(_ tab: ControlTab, style: DockThemePalette) -> some View {
        queueRailDestination(
            tab.globalRailLabel,
            icon: tab.icon,
            isSelected: navigationState.selection.isGlobalSelected(tab),
            showsUpdateBadge: tab == .core && agentUpdateService.phase == .updateAvailable,
            style: style
        ) {
            navigationState.selectGlobal(tab)
            onOpenGlobal(tab)
        }
    }

    private func queueEmpty(_ text: String, style: DockThemePalette) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(style.metadataText)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
    }

    private func queueRailDestination(
        _ title: String,
        icon: String,
        isSelected: Bool,
        showsUpdateBadge: Bool = false,
        style: DockThemePalette,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if style.showsDestinationIcons {
                    LucideIcon(name: .from(systemName: icon), size: 16, color: isSelected ? style.accent : style.secondaryText)
                        .frame(width: 22, alignment: .center)
                }
                Text(title)
                    .font(style.labelFont)
                    .lineLimit(1)
                if showsUpdateBadge {
                    Circle()
                        .fill(Color.dockWarning)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Update available")
                }
            }
            .foregroundStyle(isSelected ? style.primaryText : style.secondaryText)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: style.rowHeight)
                .contentShape(Rectangle())
                .background(isSelected ? style.selectedFill : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
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
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    private func conversationExpansionButton(style: DockThemePalette) -> some View {
        Button { navigationState.showsAllConversations.toggle() } label: {
            HStack(spacing: 6) {
                Text(navigationState.showsAllConversations ? "Show recent conversations" : "Show more conversations")
                LucideImage(systemName: navigationState.showsAllConversations ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(style.accent)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func conversationSessionRow(_ session: HermesSession, style: DockThemePalette) -> some View {
        MissionControlSidebarSessionRow(
            session: session,
            selectedSessionID: isSessionSelected(session) ? session.id : nil,
            sessionStatus: sidebarSessionStatuses[session.id] ?? .none,
            layout: .compact,
            style: style,
            repositoryName: sidebarSnapshot.projectNameBySessionID[session.id],
            isPinned: pinnedSessionStore.state.contains(
                profileID: session.profileID ?? sidebarSnapshot.inputs.profileScopeID ?? "",
                sessionID: session.id
            ),
            isActive: session.id == activeSessionID,
            isDeleting: sidebarSnapshot.inputs.deletingSessionID == session.id,
            isUpdatingVisibility: sidebarSnapshot.inputs.updatingSessionVisibilityID == session.id,
            isRenaming: sidebarSnapshot.inputs.renamingSessionID == session.id,
            onSelect: { selected in
                markSessionSeen(selected)
                navigationState.selectSession(selected.id)
                onSelectSession(selected)
            },
            onTogglePin: { selected in
                pinnedSessionStore.toggle(
                    profileID: selected.profileID ?? model.profileScopeID ?? "",
                    sessionID: selected.id
                )
            },
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
            }
        )
        .equatable()
    }

    private func pinnedOutline(_ pinned: PinnedSessionPresentation, style: DockThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                    navigationState.arePinnedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    LucideIcon(name: navigationState.arePinnedExpanded ? .chevronDown : .chevronRight, size: 12, color: style.metadataText)
                        .frame(width: 14)
                    Text("Pinned")
                        .font(style.sectionFont)
                        .foregroundStyle(style.secondaryText)
                    Text(compactCount(pinned.count))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(style.metadataText)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(navigationState.arePinnedExpanded ? "Collapse Pinned" : "Expand Pinned")

            if navigationState.arePinnedExpanded {
                if pinned.sessions.isEmpty {
                    queueEmpty(pinnedStatusText(pinned.status), style: style)
                        .padding(.leading, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(pinned.sessions) { session in
                            pinnedSessionRow(session, style: style)
                        }
                    }
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

    private func pinnedSessionRow(_ session: HermesSession, style: DockThemePalette) -> some View {
        MissionControlSidebarSessionRow(
            session: session,
            selectedSessionID: isSessionSelected(session) ? session.id : nil,
            sessionStatus: sidebarSessionStatuses[session.id] ?? .none,
            layout: .pinned,
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
            onTogglePin: { selected in
                pinnedSessionStore.toggle(profileID: selected.profileID ?? model.profileScopeID ?? "", sessionID: selected.id)
            },
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
            onRequestDelete: { sessionPendingDeletion = $0 }
        )
        .equatable()
    }

    private func conversationOutline(_ conversations: [HermesSession], style: DockThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                        navigationState.areConversationsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        LucideIcon(
                            name: navigationState.areConversationsExpanded ? .chevronDown : .chevronRight,
                            size: 12,
                            color: style.metadataText
                        )
                        .frame(width: 14)
                        Text("Conversations")
                            .font(style.sectionFont)
                            .foregroundStyle(style.secondaryText)
                        Text(compactCount(conversations.count))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(style.metadataText)
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(navigationState.areConversationsExpanded ? "Collapse Conversations" : "Expand Conversations")

                Button {
                    model.loadSessions()
                    controlCenter.refreshProjectNavigation()
                } label: {
                    Group {
                        if sidebarSnapshot.inputs.isLoadingSessions {
                            ProgressView().controlSize(.small)
                        } else {
                            LucideIcon(name: .refreshCw, size: 14, color: style.secondaryText)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(sidebarSnapshot.inputs.isLoadingSessions)
                .help(sidebarSnapshot.inputs.isLoadingSessions ? "Refreshing conversations…" : "Refresh conversations")
                .accessibilityLabel(sidebarSnapshot.inputs.isLoadingSessions ? "Refreshing conversations" : "Refresh conversations")
            }

            if navigationState.areConversationsExpanded {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if conversations.isEmpty {
                        queueEmpty(sidebarSnapshot.inputs.isLoadingSessions ? "Loading conversations…" : "No saved conversations", style: style)
                            .padding(.leading, 20)
                    } else {
                        let visibleSessions = navigationState.showsAllConversations
                            ? conversations
                            : Array(conversations.prefix(10))
                        ForEach(visibleSessions) { session in
                            conversationSessionRow(session, style: style)
                                .padding(.leading, 12)
                        }
                    }
                    if conversations.count > 10 {
                        conversationExpansionButton(style: style)
                            .padding(.leading, 12)
                    }
                }
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

    private func sessionRow(_ session: HermesSession, style: DockThemePalette) -> some View {
        let controls = MissionControlConversationSessionRow.controls(
            store: pinnedSessionStore,
            profileID: session.profileID ?? model.profileScopeID ?? "",
            sessionID: session.id,
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
            isPinned: pinnedSessionStore.state.contains(
                profileID: session.profileID ?? sidebarSnapshot.inputs.profileScopeID ?? "",
                sessionID: session.id
            ),
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

struct MissionControlConversationSessionRow: View, Equatable {
    let session: HermesSession
    let isSelected: Bool
    let isProjectLinked: Bool
    let projectName: String?
    let attentionDot: SessionAttentionDot?
    let isPinned: Bool
    var style = DockThemePalette(theme: .nativeMacOS)
    let onSelect: () -> Void
    let onTogglePin: () -> Void

    nonisolated static func controls(
        store: PinnedSessionStore,
        profileID: String,
        sessionID: String,
        onSelect: @escaping () -> Void
    ) -> PinnedSessionRowControls {
        PinnedSessionRowControls(
            select: onSelect,
            togglePin: {
                store.toggle(profileID: profileID, sessionID: sessionID)
            }
        )
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.session == rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.isProjectLinked == rhs.isProjectLinked
            && lhs.projectName == rhs.projectName
            && lhs.attentionDot == rhs.attentionDot
            && lhs.isPinned == rhs.isPinned
            && lhs.style.theme == rhs.style.theme
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                sessionDetails
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Button(action: onTogglePin) {
                LucideIcon(
                    name: .pin,
                    size: 13,
                    color: isPinned ? style.accent : style.metadataText
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPinned ? "Unpin \(session.displayTitle)" : "Pin \(session.displayTitle)")
            .help(isPinned ? "Unpin conversation" : "Pin conversation")
        }
        .background(isSelected ? style.selectedFill : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
    }

    private var sessionDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.displayTitle)
                    .font(style.labelFont)
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let attentionDot {
                    Circle().fill(attentionDot.color).frame(width: 6, height: 6)
                }
            }
            if let badge = ConversationRepositoryBadgePresentation.make(
                projectName: projectName,
                isProjectLinked: isProjectLinked
            ) {
                LucideLabel(badge.label, icon: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(style.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(style.selectedFill))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .help(badge.accessibilityLabel)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(badge.accessibilityLabel)
            }
            if let preview = session.displayPreview {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
            }
            if let timestamp = session.lastUpdatedAt {
                Text(timestamp, style: .relative)
                .font(.system(size: 11))
                .foregroundStyle(style.metadataText)
                .lineLimit(1)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 7)
    }
}

/// Project navigation is isolated from DockModel so high-frequency activity
/// updates do not rebuild the project hierarchy.
struct ProjectDisclosureState: Equatable {
    private var collapsedProjectIDs: Set<String> = []
    private var expandedSessionProjectIDs: Set<String> = []

    mutating func toggle(projectID: String) {
        if collapsedProjectIDs.contains(projectID) {
            collapsedProjectIDs.remove(projectID)
        } else {
            collapsedProjectIDs.insert(projectID)
        }
    }

    func isCollapsed(projectID: String) -> Bool {
        collapsedProjectIDs.contains(projectID)
    }

    mutating func toggleAllSessions(projectID: String) {
        if expandedSessionProjectIDs.contains(projectID) {
            expandedSessionProjectIDs.remove(projectID)
        } else {
            expandedSessionProjectIDs.insert(projectID)
        }
    }

    func showsAllSessions(projectID: String) -> Bool {
        expandedSessionProjectIDs.contains(projectID)
    }

    func visibleSessions(_ sessions: [HermesSession], projectID: String, limit: Int = 10) -> [HermesSession] {
        let newestFirst = sessions.sorted { lhs, rhs in
            let lhsDate = lhs.lastUpdatedAt ?? .distantPast
            let rhsDate = rhs.lastUpdatedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }
        return showsAllSessions(projectID: projectID)
            ? newestFirst
            : Array(newestFirst.prefix(max(0, limit)))
    }
}

private struct MissionControlProjectList: View {
    let groups: [MissionControlConversationGroup]
    let selectedSessionID: String?
    let activeSessionID: String?
    let attentionDots: [String: SessionAttentionDot]
    let sessionStatuses: [String: SidebarSessionStatus]
    let isLoadingProjects: Bool
    let isRefreshing: Bool
    let isCreatingChat: Bool
    let style: DockThemePalette
    let isPinned: (HermesSession) -> Bool
    let onTogglePin: (HermesSession) -> Void
    let onRename: (HermesSession, String) async -> Bool
    let onToggleHidden: (HermesSession, Bool) async -> Bool
    let onRequestDelete: (HermesSession) -> Void
    let deletingSessionID: String?
    let updatingSessionVisibilityID: String?
    let renamingSessionID: String?
    let onSelectSession: (HermesSession) -> Void
    let onRefresh: () -> Void
    let onNewChatInProject: (String) -> Void
    @State private var disclosureState = ProjectDisclosureState()
    @State private var isExpanded = true
    @State private var hoveredNewChatProjectID: String?
    @State private var creatingProjectID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sessionLimit = 10


    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        LucideIcon(name: isExpanded ? .chevronDown : .chevronRight, size: 12, color: style.metadataText)
                            .frame(width: 14)
                        Text("Projects")
                            .font(style.sectionFont)
                            .foregroundStyle(style.secondaryText)
                        Text(compactCount(groups.count))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(style.metadataText)
                        Spacer(minLength: 4)
                    }
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "Collapse Projects" : "Expand Projects")

                Button(action: onRefresh) {
                    Group {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            LucideIcon(name: .refreshCw, size: 14, color: style.secondaryText)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help(isRefreshing ? "Refreshing projects…" : "Refresh projects")
                .accessibilityLabel(isRefreshing ? "Refreshing projects" : "Refresh projects")
            }

            if isExpanded {
                if groups.isEmpty {
                    projectStatusRow(isLoadingProjects ? "Loading projects…" : "No projects")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in projectGroup(group) }
                    }
                }
            }
        }
        .onChange(of: isCreatingChat) { _, isCreating in
            if !isCreating { creatingProjectID = nil }
        }
    }

    private func projectGroup(_ group: MissionControlConversationGroup) -> some View {
        let sessionCount = max(group.declaredSessionCount, group.sessions.count)
        let isCollapsed = disclosureState.isCollapsed(projectID: group.id)
        let sessions = disclosureState.visibleSessions(group.sessions, projectID: group.id, limit: sessionLimit)
        let isActiveProject = group.sessions.contains { $0.id == selectedSessionID }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                        disclosureState.toggle(projectID: group.id)
                    }
                } label: {
                    HStack(spacing: 7) {
                        LucideIcon(name: isCollapsed ? .chevronRight : .chevronDown, size: 11, color: style.metadataText)
                            .frame(width: 12)
                        LucideIcon(name: .folder, size: 15, color: isActiveProject ? style.accent : style.secondaryText)
                            .frame(width: 16)
                        Text(group.title)
                            .font(style.labelFont)
                            .foregroundStyle(style.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        Text(compactCount(sessionCount))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(style.metadataText)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isCollapsed ? "Expand project \(group.title)" : "Collapse project \(group.title)")

                if let projectPath = group.projectPath, !projectPath.isEmpty {
                    Button {
                        creatingProjectID = group.id
                        onNewChatInProject(projectPath)
                    } label: {
                        Group {
                            if creatingProjectID == group.id {
                                ProgressView().controlSize(.small)
                            } else {
                                LucideIcon(
                                    name: .messageCirclePlus,
                                    size: 15,
                                    color: hoveredNewChatProjectID == group.id ? style.accent : style.secondaryText
                                )
                            }
                        }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(isCreatingChat || creatingProjectID != nil)
                    .help("New chat in \(group.title)")
                    .accessibilityLabel("New chat in \(group.title)")
                    .onHover { isHovered in
                        hoveredNewChatProjectID = isHovered
                            ? group.id
                            : (hoveredNewChatProjectID == group.id ? nil : hoveredNewChatProjectID)
                    }
                }
            }
            .background(Color.clear)
            if !isCollapsed {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if group.sessions.isEmpty && sessionCount > 0 {
                        projectStatusRow("Loading linked sessions…", leading: 0)
                    } else if group.sessions.isEmpty && sessionCount == 0 {
                        projectStatusRow("No sessions", leading: 0)
                    } else {
                        ForEach(sessions) { session in sessionRow(session) }
                        if group.sessions.count > sessionLimit {
                            Button {
                                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                                    disclosureState.toggleAllSessions(projectID: group.id)
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(disclosureState.showsAllSessions(projectID: group.id)
                                         ? "Show recent"
                                         : "Show \(group.sessions.count - sessionLimit) more")
                                    LucideIcon(
                                        name: disclosureState.showsAllSessions(projectID: group.id) ? .chevronUp : .chevronDown,
                                        size: 10,
                                        color: style.accent
                                    )
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(style.accent)
                                .frame(minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(disclosureState.showsAllSessions(projectID: group.id)
                                                ? "Show recent sessions for \(group.title)"
                                                : "Show \(group.sessions.count - sessionLimit) more sessions for \(group.title)")
                        }
                    }
                }
                .padding(.leading, 50)
            }
        }
    }

    private func projectStatusRow(_ text: String, leading: CGFloat = 34) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(style.metadataText)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.leading, leading)
    }

    private func sessionRow(_ session: HermesSession) -> some View {
        MissionControlSidebarSessionRow(
            session: session,
            selectedSessionID: selectedSessionID,
            sessionStatus: sessionStatuses[session.id] ?? .none,
            layout: .compact,
            style: style,
            repositoryName: nil,
            isPinned: isPinned(session),
            isActive: session.id == activeSessionID,
            isDeleting: deletingSessionID == session.id,
            isUpdatingVisibility: updatingSessionVisibilityID == session.id,
            isRenaming: renamingSessionID == session.id,
            onSelect: onSelectSession,
            onTogglePin: onTogglePin,
            onRename: onRename,
            onToggleHidden: onToggleHidden,
            onRequestDelete: onRequestDelete
        )
        .equatable()
    }

    private func compactCount(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}

enum ProjectSessionPendingAction: Equatable {
    case rename, visibility, deletion
}

struct ProjectSessionActionPresentation: Equatable {
    let isPinned: Bool
    let isActive: Bool
    let isHidden: Bool
    let pendingAction: ProjectSessionPendingAction?

    var canDelete: Bool { !isActive && pendingAction != .deletion }
    var visibilityTitle: String { isHidden ? "Show" : "Hide" }
}

struct SidebarSessionMetadata: Equatable {
    let relativeTime: String?
    let repository: String?
    let preview: String?

    var values: [String] {
        [relativeTime, repository, preview]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func make(relativeTime: String?, repository: String?, preview: String?) -> Self {
        Self(relativeTime: relativeTime, repository: repository, preview: preview)
    }
}

private enum SidebarSessionRowLayout: Equatable {
    case compact
    case pinned

    var height: CGFloat { self == .pinned ? 72 : 50 }
    var horizontalInset: CGFloat { self == .pinned ? 10 : 4 }
}

private struct MissionControlSidebarSessionRow: View, Equatable {
    let session: HermesSession
    let selectedSessionID: String?
    let sessionStatus: SidebarSessionStatus
    let layout: SidebarSessionRowLayout
    let style: DockThemePalette
    let repositoryName: String?
    let isPinned: Bool
    let isActive: Bool
    let isDeleting: Bool
    let isUpdatingVisibility: Bool
    let isRenaming: Bool
    let onSelect: (HermesSession) -> Void
    let onTogglePin: (HermesSession) -> Void
    let onRename: (HermesSession, String) async -> Bool
    let onToggleHidden: (HermesSession, Bool) async -> Bool
    let onRequestDelete: (HermesSession) -> Void
    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var renameError: String?
    @FocusState private var titleFieldFocused: Bool
    @FocusState private var rowFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Shared: formatter construction loads locale data. Safe because row rendering is main-actor bound.
    private static let relativeTimeFormatter = RelativeDateTimeFormatter()

    private var pendingAction: ProjectSessionPendingAction? {
        if isDeleting { return .deletion }
        if isUpdatingVisibility { return .visibility }
        if isRenaming { return .rename }
        return nil
    }

    private var presentation: ProjectSessionActionPresentation {
        ProjectSessionActionPresentation(
            isPinned: isPinned,
            isActive: isActive,
            isHidden: session.isHidden,
            pendingAction: pendingAction
        )
    }

    private var showsActionSurface: Bool {
        isHovered || rowFocused || session.id == selectedSessionID || isPinned
    }

    private var showsMoreActions: Bool {
        isHovered || rowFocused || session.id == selectedSessionID
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
            && lhs.selectedSessionID == rhs.selectedSessionID
            && lhs.sessionStatus == rhs.sessionStatus
            && lhs.layout == rhs.layout
            && lhs.style.theme == rhs.style.theme
            && lhs.repositoryName == rhs.repositoryName
            && lhs.isPinned == rhs.isPinned
            && lhs.isActive == rhs.isActive
            && lhs.isDeleting == rhs.isDeleting
            && lhs.isUpdatingVisibility == rhs.isUpdatingVisibility
            && lhs.isRenaming == rhs.isRenaming
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if isEditingTitle {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Session title", text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(style.labelFont.weight(.medium))
                            .foregroundStyle(style.primaryText)
                            .focused($titleFieldFocused)
                            .onSubmit { submitRename() }
                            .onExitCommand { cancelRename() }
                        if let renameError {
                            Text(renameError)
                                .font(.system(size: 10))
                                .foregroundStyle(style.metadataText)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Button { onSelect(session) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(session.displayTitle)
                                    .font(titleFont)
                                    .foregroundStyle(style.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                statusIndicator
                            }
                            if let metadata = metadata {
                                metadataView(metadata)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: layout.height, alignment: .center)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .focused($rowFocused)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsActionSurface || isEditingTitle || pendingAction != nil {
                actionSurface
                    .background(rowFill)
                    .transition(.opacity)
            }
        }
        .frame(height: layout.height)
        .padding(.horizontal, layout.horizontalInset)
        .background(rowFill)
        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .disabled(isDeleting)
        .onHover { isHovered = $0 }
        .contextMenu { contextActions }
        .onChange(of: isEditingTitle) { _, editing in
            if editing {
                titleDraft = session.displayTitle
                renameError = nil
                DispatchQueue.main.async { titleFieldFocused = true }
            }
        }
        .onChange(of: titleFieldFocused) { _, focused in
            if !focused, isEditingTitle, pendingAction == nil { cancelRename() }
        }
    }

    private var rowFill: Color {
        session.id == selectedSessionID ? style.selectedFill : (isHovered ? style.selectedFill.opacity(0.38) : .clear)
    }

    private var titleFont: Font {
        let base = layout == .pinned ? Font.system(size: 12) : style.labelFont
        return base.weight(session.id == selectedSessionID ? .medium : .regular)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            switch sessionStatus {
            case .working:
                if reduceMotion {
                    LucideImage(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    ProgressView().controlSize(.small)
                }
            case .needsAttention:
                LucideImage(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            case .failed:
                LucideImage(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            case .unreadComplete:
                Circle().frame(width: 7, height: 7)
            case .none:
                Color.clear.frame(width: 12, height: 12)
            }
        }
        .foregroundStyle(statusColor)
        .frame(width: 16, height: 16)
        .help(sessionStatus.help)
        .accessibilityLabel(sessionStatus.label)
    }

    private var statusColor: Color {
        switch sessionStatus {
        case .working, .unreadComplete: style.accent
        case .needsAttention: .dockWarning
        case .failed: .dockDestructive
        case .none: .clear
        }
    }

    private var metadata: SidebarSessionMetadata? {
        let repository = ConversationRepositoryBadgePresentation.make(
            projectName: repositoryName,
            isProjectLinked: repositoryName != nil
        )?.label
        let result = SidebarSessionMetadata.make(
            relativeTime: session.lastUpdatedAt.map { Self.relativeTimeFormatter.localizedString(for: $0, relativeTo: .now) },
            repository: repository,
            preview: session.displayPreview
        )
        return result.values.isEmpty ? nil : result
    }

    @ViewBuilder
    private func metadataView(_ metadata: SidebarSessionMetadata) -> some View {
        if layout == .pinned {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let repository = metadata.repository, !repository.isEmpty {
                        LucideImage(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                        Text(repository)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if let relativeTime = metadata.relativeTime, !relativeTime.isEmpty {
                        Text(relativeTime)
                            .lineLimit(1)
                    }
                }
                if let preview = metadata.preview, !preview.isEmpty {
                    Text(preview)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(style.metadataText)
        } else {
        let hasRelativeTime = !(metadata.relativeTime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasRepository = !(metadata.repository?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasPreview = !(metadata.preview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        HStack(spacing: 5) {
            if let relativeTime = metadata.relativeTime, hasRelativeTime {
                Text(relativeTime)
            }
            if let repository = metadata.repository, hasRepository {
                if hasRelativeTime { Text("·") }
                LucideImage(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                Text(repository)
            }
            if let preview = metadata.preview, hasPreview {
                if hasRelativeTime || hasRepository { Text("·") }
                Text(preview)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(style.metadataText)
        .lineLimit(1)
        }
    }

    private var actionSurface: some View {
        HStack(spacing: 0) {
            Button { onTogglePin(session) } label: {
                LucideImage(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isPinned ? style.accent : style.metadataText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isPinned ? "Unpin session" : "Pin session")
            .accessibilityLabel(isPinned ? "Unpin \(session.displayTitle)" : "Pin \(session.displayTitle)")

            if isRenaming {
                ProgressView().controlSize(.small).frame(width: 44, height: 44)
            } else if showsMoreActions {
                Menu { contextActions } label: {
                    LucideImage(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(style.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("More session actions")
                .accessibilityLabel("More actions for \(session.displayTitle)")
            }
        }
    }

    @ViewBuilder
    private var contextActions: some View {
        Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin") {
            onTogglePin(session)
        }
        Button("Rename…", systemImage: "pencil") {
            isEditingTitle = true
        }
        Button(presentation.visibilityTitle, systemImage: session.isHidden ? "eye" : "eye.slash") {
            Task { @MainActor in
                _ = await onToggleHidden(session, !session.isHidden)
            }
        }
        .disabled(isUpdatingVisibility || isDeleting)
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            onRequestDelete(session)
        }
        .disabled(!presentation.canDelete || isDeleting)
        .help(isActive ? "The active session cannot be deleted" : "Permanently delete this session")
    }

    private func submitRename() {
        let clean = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            renameError = "Title can’t be empty."
            return
        }
        guard clean != session.title else {
            isEditingTitle = false
            return
        }
        renameError = nil
        Task { @MainActor in
            let succeeded = await onRename(session, clean)
            if succeeded {
                isEditingTitle = false
            } else {
                renameError = "Could not rename. Try again."
                titleFieldFocused = true
            }
        }
    }

    private func cancelRename() {
        isEditingTitle = false
        renameError = nil
        titleDraft = session.displayTitle
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
    let leadingFraction: CGFloat?
    let initialLeadingWidth: CGFloat?
    let minimumLeadingWidth: CGFloat
    let maximumLeadingWidth: CGFloat?
    let minimumTrailingWidth: CGFloat
    let leadingWidth: Binding<CGFloat>?

    init(
        leading: Leading,
        trailing: Trailing,
        leadingFraction: CGFloat? = 0.30,
        initialLeadingWidth: CGFloat? = nil,
        minimumLeadingWidth: CGFloat = 220,
        maximumLeadingWidth: CGFloat? = nil,
        minimumTrailingWidth: CGFloat = 360,
        leadingWidth: Binding<CGFloat>? = nil
    ) {
        self.leading = leading
        self.trailing = trailing
        self.leadingFraction = leadingFraction
        self.initialLeadingWidth = initialLeadingWidth
        self.minimumLeadingWidth = minimumLeadingWidth
        self.maximumLeadingWidth = maximumLeadingWidth
        self.minimumTrailingWidth = minimumTrailingWidth
        self.leadingWidth = leadingWidth
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            leadingFraction: leadingFraction,
            initialLeadingWidth: initialLeadingWidth,
            minimumLeadingWidth: minimumLeadingWidth,
            maximumLeadingWidth: maximumLeadingWidth,
            minimumTrailingWidth: minimumTrailingWidth,
            leadingWidth: leadingWidth
        )
    }

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
        context.coordinator.leadingWidth = leadingWidth

        guard !context.coordinator.hasSetInitialPosition else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.hasSetInitialPosition,
                  splitView.bounds.width > 0 else { return }
            let proposed = initialLeadingWidth ?? (splitView.bounds.width * (leadingFraction ?? 0.30))
            let minimum = context.coordinator.minimumLeadingPosition(in: splitView)
            let maximum = context.coordinator.maximumLeadingPosition(in: splitView)
            splitView.setPosition(min(max(proposed, minimum), maximum), ofDividerAt: 0)
            context.coordinator.hasSetInitialPosition = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let leadingFraction: CGFloat
        let initialLeadingWidth: CGFloat?
        let minimumLeadingWidth: CGFloat
        let maximumLeadingWidth: CGFloat?
        let minimumTrailingWidth: CGFloat
        let leadingHost = NSHostingView(rootView: AnyView(EmptyView()))
        let trailingHost = NSHostingView(rootView: AnyView(EmptyView()))
        weak var splitView: NSSplitView?
        var hasSetInitialPosition = false
        var leadingWidth: Binding<CGFloat>?

        init(
            leadingFraction: CGFloat?,
            initialLeadingWidth: CGFloat?,
            minimumLeadingWidth: CGFloat,
            maximumLeadingWidth: CGFloat?,
            minimumTrailingWidth: CGFloat,
            leadingWidth: Binding<CGFloat>?
        ) {
            self.leadingFraction = leadingFraction ?? 0.30
            self.initialLeadingWidth = initialLeadingWidth
            self.minimumLeadingWidth = minimumLeadingWidth
            self.maximumLeadingWidth = maximumLeadingWidth
            self.minimumTrailingWidth = minimumTrailingWidth
            self.leadingWidth = leadingWidth
        }

        func minimumLeadingPosition(in splitView: NSSplitView) -> CGFloat {
            min(minimumLeadingWidth, max(0, splitView.bounds.width - splitView.dividerThickness - minimumTrailingWidth))
        }

        func maximumLeadingPosition(in splitView: NSSplitView) -> CGFloat {
            let availableMaximum = max(minimumLeadingPosition(in: splitView), splitView.bounds.width - splitView.dividerThickness - minimumTrailingWidth)
            return min(maximumLeadingWidth ?? availableMaximum, availableMaximum)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            minimumLeadingPosition(in: splitView)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            maximumLeadingPosition(in: splitView)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let leadingWidth else { return }
            guard let splitView = notification.object as? NSSplitView else { return }
            leadingWidth.wrappedValue = splitView.subviews.first?.frame.width ?? leadingWidth.wrappedValue
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
