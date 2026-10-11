import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

/// Native panel placement is owned by AppKit, while this state lets the
/// SwiftUI surface match its silhouette without resetting conversation state.
final class DockPanelPresentation: ObservableObject {
    @Published var quotaRequest = 0
    @Published var kanbanRequest = 0
    @Published var isEdgeAttached = false
    @Published var edgeSide: EdgeDockSide = .right
    @Published var compactHeight: CGFloat = 720
    @Published var compactWidth: CGFloat = .greatestFiniteMagnitude
    @Published var availableWidth: CGFloat = .greatestFiniteMagnitude
    /// Owned by the panel controller; the view mirrors it so the layout always
    /// matches the window, including when the panel reopens in fullscreen.
    @Published var isFullscreen = false
}

/// UserDefaults keys for optional sidebar destinations; all default to visible.
enum SidebarVisibilityKey {
    static let kanban = "hermes.sidebar.shows-kanban"
    static let pullRequests = "hermes.sidebar.shows-pull-requests"
    static let issues = "hermes.sidebar.shows-issues"
    static let office = "hermes.sidebar.shows-office"
    static let calendar = "hermes.sidebar.shows-calendar"
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
    var edgeSide: EdgeDockSide = .right

    func path(in rect: CGRect) -> Path {
        if isEdgeAttached { return EdgeNotchShape(side: edgeSide).path(in: rect) }
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

private struct ConversationScrollAnchor: Equatable {
    let messageID: UUID
    let offset: CGFloat
}

struct DockPopover: View {
    @ObservedObject var model: DockModel
    @ObservedObject var panelPresentation: DockPanelPresentation
    @ObservedObject var controlCenter: ControlCenterModel
    /// Read-only screen capacity. Layout decisions must never resize the live
    /// panel while they are merely determining whether desktop content fits.
    var availableWorkspaceWidth: () -> CGFloat = { .greatestFiniteMagnitude }
    var onWorkspaceWidthChange: (CGFloat) -> CGFloat = { $0 }
    var onClose: () -> Void = {}
    var onFullscreenToggle: () -> Void = {}
    /// Floating panel: open the docked window. Docked window: return to floating.
    var onOpenWindow: (() -> Void)?
    /// The native window supplies its own frame, so drop the rounded surface.
    var usesWindowChrome = false
    @State private var isConversationAtBottom = true
    @State private var clarificationSelection: [String] = []
    @State private var valuePromptText = ""
    @State private var valuePromptIdentifier = ""
    @State private var unseenMessageCount = 0
    @State private var isShowingMessageSearch = false
    @State private var isSessionIdentityHovering = false
    @State private var isSessionMenuHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var conversationScrollRequest = 0
    @State private var mountedMessageRange: Range<Int> = 0..<0
    @State private var visibleNavigatorTargets: Set<MessageNavigatorTarget> = []
    @State private var scrollController = ConversationScrollController()
    /// Scroll bookkeeping that never drives rendering. Kept out of `@State`
    /// values so settle, preference and layout callbacks do not invalidate
    /// this entire view on every scroll.
    @State private var scrollBookkeeping = ConversationTranscriptBookkeeping()
    @State private var streamingTailScroll = ConversationTailScrollScheduler()
    @State private var conversationPerformance = ConversationPerformanceMonitor()
    @State private var isWorkspaceManuallyExpanded = false
    @State private var isNarrowLayout = false
    @State private var isNarrowControlVisible = true
    @State private var selectedChatImage: ChatImagePreview?
    @ObservedObject private var filePreview = FilePreviewCenter.shared
    @StateObject private var speechInput = SpeechInput()
    @StateObject private var voiceOutput = VoiceOutput()
    @StateObject private var micLevelMeter = MicLevelMeter()
    @StateObject private var messageActionState = ConversationMessageActionState()
    @StateObject private var workspaceStore = WorkspaceStore()
    @StateObject private var agentUpdateService = HermesUpdateService()
    @StateObject private var developerWorkflow = DeveloperWorkflowModel()
    @StateObject private var pullRequestCenter = PullRequestCenterModel()
    @StateObject private var pullRequestChatLinks = PullRequestChatLinkStore()
    @State private var chatContextRouter = ChatContextRouter()
    @StateObject private var repositoryPreferences = CommandCenterPreferencesStore()
    @ObservedObject private var dockThemeStore = DockThemeStore.shared
    @StateObject private var botMode = BotModeModel()
    @StateObject private var missionControlNavigation = MissionControlNavigationState()
    @State private var sessionWorkspaceMode: SessionWorkspaceMode = .chat
    @State private var suppressNextVoiceResponse = false
    /// Full voice mode: the voice stage covers the navigation and inspector.
    @State private var isVoiceImmersive = false
    @State private var voiceSubtitles = VoiceSubtitleTrack()
    @State private var isVoiceTranscriptVisible = false
    @State private var voiceHUD = VoiceHUDState()
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
    @State private var isMissionInspectorVisible = false

    private enum FullscreenSurface {
        case conversation, pullRequests, issues
        case global
        case artifacts
        case bots
    }
    @State private var fullscreenSurface: FullscreenSurface = .conversation
    @State private var fullscreenGlobalTab: ControlTab = .kanban

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

        var icon: Ph {
            switch self {
            case .chat: .chatText
            case .voice: .waveform
            case .explorer: .folder
            case .sourceControl: .gitBranch
            case .pullRequests: .gitPullRequest
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

        var icon: Ph {
            switch self {
            case .global: .squaresFour
            case .session: .chats
            case .artifacts: .fileMagnifyingGlass
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
            .environment(\.chatContextRouter, chatContextRouter)
    }

    private func observerLayerOne<V: View>(_ view: V) -> some View {
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
        .onChange(of: filePreview.url) { _, _ in showFilePreview() }
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
        .onChange(of: botMode.bots.first(where: \.isDefault)?.name, initial: true) { _, name in
            model.defaultBotName = name
        }
    }

    private var rootPopoverContent: some View {
        Group {
            // Replaces the shell instead of overlaying it: the AppKit split
            // panes draw above SwiftUI overlays, so side panels showed through.
            if isVoiceImmersive && sessionWorkspaceMode == .voice {
                immersiveVoiceStage.transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                layoutContent
            }
        }
            .animation(.dockEase(duration: 0.3), value: isVoiceImmersive)
            .frame(width: isFullscreen ? nil : min(popupWidth, panelPresentation.compactWidth), height: isFullscreen ? nil : panelPresentation.compactHeight)
            .padding(.horizontal, !isFullscreen && panelPresentation.isEdgeAttached ? EdgeDockLayout.workspaceHorizontalInset : 0)
            .padding(.vertical, !isFullscreen && panelPresentation.isEdgeAttached ? EdgeDockLayout.workspaceVerticalInset : 0)
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
                isEdgeAttached: !isFullscreen && panelPresentation.isEdgeAttached,
                cornerRadius: usesWindowChrome ? 0 : 22,
                edgeSide: panelPresentation.edgeSide
            ))
            .overlay {
                DockPanelSurfaceShape(
                    isEdgeAttached: !isFullscreen && panelPresentation.isEdgeAttached,
                    cornerRadius: usesWindowChrome ? 0 : 22,
                    edgeSide: panelPresentation.edgeSide
                )
                    .stroke(Color.dockBorderStrong, lineWidth: usesWindowChrome ? 0 : panelPresentation.isEdgeAttached ? 1 : 0.5)
            }
            .dockThemedRoot()
            .preferredColorScheme(dockThemeStore.selectedThemeID.appearance == .light ? .light : dockThemeStore.selectedThemeID.appearance == .dark ? .dark : nil)
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

    /// Fullscreen and the desktop panel must share this single
    /// `desktopWorkspaceShell` branch. Rendering it from separate if/else
    /// branches gave each presentation its own identity, so toggling
    /// fullscreen remounted the whole workspace and reset its state.
    @ViewBuilder
    private var layoutContent: some View {
        if !isNarrowLayout {
            desktopWorkspaceShell
        } else {
            HStack(spacing: 2) {
                if !isNarrowLayout || !isNarrowControlVisible {
                    conversationColumn
                        .frame(
                            width: isFullscreen ? .infinity : min(showsDesktopContextPanel ? 480 : 500, panelPresentation.compactWidth),
                            height: isFullscreen ? .infinity : panelPresentation.compactHeight
                        )
                }

                if isWorkspaceVisibleForLayout {
                    Rectangle().fill(Color.dockBorderLight).frame(width: 0.5)
                    contextPanel
                        .frame(
                            width: isFullscreen ? .infinity : min(isNarrowLayout ? 500 : 480, panelPresentation.compactWidth),
                            height: isFullscreen ? .infinity : panelPresentation.compactHeight
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
    /// Applies to both the fullscreen and the windowed/minimized popover
    /// presentations, since both route through this shell.
    private var desktopWorkspaceShell: some View {
        FullscreenPanelSplitView(
            leading: missionControlQueue,
            trailing: desktopTrailingWorkspace,
            leadingFraction: DesktopWorkspaceFractions.queue,
            minimumTrailingWidth: desktopTrailingMinimumWidth
        )
    }

    /// The outer split must leave room for the conversation's minimum plus
    /// the inspector's, or the inner split squeezes the conversation.
    private var desktopTrailingMinimumWidth: CGFloat {
        guard !isGlobalSurfaceActive, sessionWorkspaceMode != .explorer else { return 360 }
        let conversation = DesktopWorkspaceFractions.minimumConversationWidth
        return isInspectorVisibleForDesktopWorkspace ? conversation + 1 + 360 : conversation
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
                    // Fraction of the *remaining* space after the outer
                    // queue split, chosen so the three visible columns land
                    // at the DesktopWorkspaceFractions targets (queue /
                    // conversation / inspector) rather than an even split.
                    leadingFraction: sessionWorkspaceMode == .explorer ? nil : DesktopWorkspaceFractions.conversationOfRemainder,
                    initialLeadingWidth: sessionWorkspaceMode == .explorer ? explorerNavigatorWidth : nil,
                    minimumLeadingWidth: sessionWorkspaceMode == .explorer ? ExplorerWorkspaceMetrics.minimumNavigatorWidth : DesktopWorkspaceFractions.minimumConversationWidth,
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
        if !isNarrowLayout { return showsDesktopContextPanel || isGlobalSurfaceActive ? 1_200 : 820 }
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

    private var desktopRequiredWidth: CGFloat { 1_110 }
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

    private func loadInitialModelConfiguration() {
        model.refreshRuntimeConfiguration()
        model.refreshRuntimeModelOptions()
        model.refreshDefaultReasoningVariant()
    }

    private func handleVoiceStateChange(_ state: HermesVoiceState) {
        // Hermes' gateway owns the microphone in native mode; a passive meter
        // lets the orb follow the user's voice anyway.
        if state.isNativeConversationActive { micLevelMeter.start() } else { micLevelMeter.stop() }
        micLevelMeter.onUtteranceEnd = { [model, micLevelMeter] transcript in
            model.finishVoiceUtterance(transcript: transcript, overPlayback: micLevelMeter.heardPlayback)
        }
        micLevelMeter.onIdle = { [model] in model.sleepVoiceConversation() }
        micLevelMeter.onBargeSpeech = { [model] heard in model.bargeInVoiceReply(heard: heard) }
        // Asleep, the meter only listens for the wake phrase, and only on-device.
        let listensForWake = state == .paused && !model.isVoiceMicMuted && wakesByVoice
        micLevelMeter.listen(
            // While Hermes thinks, speech steers the running turn instead of being lost.
            endpointing: state == .listening || listensForWake || (state == .thinking && !model.isVoiceMicMuted),
            watchingForBarge: state == .speaking && !model.isVoiceMicMuted && wakesByVoice
        )
        if state == .interrupted {
            // The native gateway has accepted a spoken interruption. Stop
            // any fallback playback immediately before it resumes capture.
            voiceOutput.stop()
        }
        if case .localFallback = state {
            resumeVoiceConversationIfReady()
        }
    }

    /// Approvals and questions are spoken in voice mode and answered aloud.
    private func handleVoicePromptChange(_ speech: String?) {
        guard sessionWorkspaceMode == .voice else { return }
        if model.voiceState.isNativeConversationActive { return model.presentVoicePrompt(speech) }
        if let speech { speakLocalVoicePrompt(speech) }
    }

    private func speakLocalVoicePrompt(_ speech: String) {
        speechInput.stopForAssistantSpeech()
        voiceOutput.speak(messageID: UUID(), text: speech)
    }

    private func handleVoicePlaybackChange(_ isSpeaking: Bool) {
        guard !isSpeaking, !model.voiceState.isNativeConversationActive else { return }
        resumeVoiceConversationIfReady()
    }

    private func handleSessionModeChange(previousMode: SessionWorkspaceMode, mode: SessionWorkspaceMode) {
        guard previousMode == .voice, mode != .voice else { return }
        isVoiceImmersive = false
        // Leaving voice mode must always release both fallback and native
        // voice capture, including a microphone that is still starting.
        releaseVoiceCapture()
    }

    private func releaseVoiceCapture() {
        micLevelMeter.stop()
        speechInput.stop()
        voiceOutput.stop()
        model.stopVoiceConversation()
    }

    private func handleRecordingChange(_ isRecording: Bool) {
        guard !isRecording, speechInput.errorMessage != nil else { return }
        sessionWorkspaceMode = .chat
    }

    private func handleCompletedTranscript(_ transcript: String?) {
        if sessionWorkspaceMode == .voice, model.voicePromptSpeech != nil, let transcript, !transcript.isEmpty {
            speechInput.consumeCompletedTranscript()
            if let retry = model.answerVoicePrompt(transcript) { speakLocalVoicePrompt(retry) }
            return
        }
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
        missionControlNavigation.synchronizeActiveSession(model.navigationSessionID)
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
        missionControlNavigation.synchronizeActiveSession(model.navigationSessionID)
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
            onSelectProfile: { botMode.selectProfile($0) },
            onOpenWindow: onOpenWindow,
            isDockedWindow: usesWindowChrome
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
            if let url = filePreview.url {
                FilePreviewPane(url: url, model: model) { filePreview.url = nil }
            } else if sessionWorkspaceMode.usesContextPreview {
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
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        return GeometryReader { geometry in
            let showsInspector = geometry.size.width >= 440
            HStack(spacing: 4) {
                sessionIdentity(style: style)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)

                if sessionWorkspaceMode == .chat, !model.messageNavigatorItems.isEmpty {
                    DockIconButton(
                        icon: .magnifyingGlass,
                        label: isShowingMessageSearch ? "Close message search" : "Find a message (⌘F)",
                        isProminent: isShowingMessageSearch,
                        style: style
                    ) { isShowingMessageSearch.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                }

                DockIconButton(
                    icon: sessionWorkspaceMode == .voice ? .chatCircleText : .waveform,
                    label: sessionWorkspaceMode == .voice ? "Return to chat" : "Voice conversation",
                    isProminent: sessionWorkspaceMode == .voice,
                    style: style
                ) { selectSessionMode(sessionWorkspaceMode == .voice ? .chat : .voice) }
                .accessibilityAddTraits(sessionWorkspaceMode == .voice ? .isSelected : [])

                sessionViewMenu(includesInspector: !showsInspector, style: style)
                    .fixedSize()

                if showsInspector {
                    DockIconButton(
                        icon: .sidebarSimple,
                        label: inspectorPanelIsVisible ? "Hide inspector" : "Show inspector",
                        isProminent: inspectorPanelIsVisible,
                        style: style,
                        action: toggleInspectorPanel
                    )
                }
            }
            .padding(.horizontal, 8)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: conversationMetrics.headerHeight)
        .background(Color.dockCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }

    private func sessionIdentity(style: DockThemePalette) -> some View {
        Button(action: { model.toggleSessions() }) {
            HStack(spacing: 8) {
                Text(model.currentSessionTitle ?? "Untitled chat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                DockIcon(.caretUpDown, size: 12, color: style.metadataText)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                    .fill(model.isShowingSessions ? style.selectedFill : isSessionIdentityHovering ? style.surface4.opacity(0.6) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
        .onHover { isSessionIdentityHovering = $0 }
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: isSessionIdentityHovering)
        .help("\(model.currentSessionTitle ?? "Untitled chat") — \(model.status.title)")
        .accessibilityLabel("Choose session: \(model.currentSessionTitle ?? "Untitled chat"), \(model.status.title)")
        .popover(isPresented: $model.isShowingSessions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            sessionPicker
                .frame(width: 390, height: 310)
                .padding(.vertical, 4)
                .background(Color.dockCanvas)
        }
    }

    private func sessionViewMenu(includesInspector: Bool, style: DockThemePalette) -> some View {
        Menu {
            ForEach(SessionWorkspaceMode.allCases) { mode in
                Button { selectSessionMode(mode) } label: {
                    if mode == sessionWorkspaceMode {
                        Label(mode.label, icon: .check)
                    } else {
                        Text(mode.label)
                    }
                }
            }
            if includesInspector {
                Divider()
                Button(inspectorPanelIsVisible ? "Hide inspector" : "Show inspector", action: toggleInspectorPanel)
            }
        } label: {
            DockIcon(.dotsThree, size: 14, color: isSessionMenuHovering ? style.primaryText : style.secondaryText)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
                        .fill(isSessionMenuHovering ? style.surface4.opacity(0.7) : .clear)
                )
                .contentShape(Rectangle())
        }
        .onHover { isSessionMenuHovering = $0 }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Session views: \(sessionWorkspaceMode.label)")
        .accessibilityLabel("Session views, current view: \(sessionWorkspaceMode.label)")
    }

    private func showFilePreview() {
        guard filePreview.url != nil else { return }
        filePreview.sessionID = model.sessionID
        if isNarrowLayout, sessionWorkspaceMode == .explorer { sessionWorkspaceMode = .chat }
        ensureInspectorPanelVisible()
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
        onFullscreenToggle()
    }

    private func applyFullscreen(_ fullscreen: Bool) {
        guard fullscreen != isFullscreen else { return }
        // Fullscreen changes only the host window and available layout space.
        // It must not select a different workspace, inspector scope, or
        // session surface: those are user-owned presentation state.
        let preservedInspectorVisibility = inspectorPanelIsVisible
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFullscreen = fullscreen
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
        if let id = model.sessionModelOptionID { return id }
        guard model.sessionID == nil, let provider = model.runtimeConfiguration?.provider,
              let modelName = model.runtimeConfiguration?.model else { return nil }
        return HermesModelOption(provider: provider, model: modelName).id
    }

    private var selectedReasoningVariant: HermesReasoningVariant? {
        model.sessionID == nil ? model.defaultReasoningVariant : model.sessionReasoningVariant
    }

    private var reasoningVariantSelection: Binding<HermesReasoningVariant?> {
        Binding(
            get: { selectedReasoningVariant },
            set: { variant in
                guard let variant else { return }
                if model.sessionID == nil {
                    model.updateDefaultReasoning(variant)
                } else {
                    model.updateSessionReasoning(variant)
                }
            }
        )
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
                            model.updateSessionModel(option)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                if option.id == selectedModelOptionID {
                                    Ph.check.image()
                                }
                            }
                        }
                    }
                }
            } label: {
                sessionConfigurationLabel(
                    icon: .cpu,
                    title: "MODEL",
                    value: sessionModelDisplayName,
                    truncatesValue: true
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.dockHover)
            .disabled(model.isUpdatingSessionModel)
            .help("Change the model for \(configurationScopeLabel)")
            .accessibilityLabel("Model for \(configurationScopeLabel): \(sessionModelDisplayName)")

            Color.dockBorderLight
                .frame(width: 0.5, height: 24)

            Menu {
                Picker("", selection: reasoningVariantSelection) {
                    ForEach(HermesReasoningVariant.allCases) { variant in
                        Text(variant.displayName).tag(Optional(variant))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                sessionConfigurationLabel(
                    icon: .brain,
                    title: "THINKING",
                    value: sessionReasoningDisplayName
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.dockHover)
            .disabled(model.sessionID != nil && model.isUpdatingSessionReasoning)
            .help("Change thinking depth for \(configurationScopeLabel)")
            .accessibilityLabel("Thinking depth for \(configurationScopeLabel): \(sessionReasoningDisplayName)")
        }
        .foregroundStyle(Color.dockPrimaryText)
        .background(Color.dockSurface4)
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .stroke(Color.dockBorder, lineWidth: 0.5)
        }
    }

    private func sessionConfigurationLabel(
        icon: Ph,
        title: String,
        value: String,
        truncatesValue: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            DockIcon(icon)
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

            DockIcon(.caretDown)
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
        .clipShape(RoundedRectangle(cornerRadius: DockLayout.paneRadius + 2, style: .continuous))
    }

    private var sessionList: some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        return VStack(alignment: .leading, spacing: 4) {
            DockSectionHeader(
                title: "Conversations",
                count: model.sessions.isEmpty ? nil : model.sessions.count,
                style: style
            ) {
                DockIconButton(
                    icon: .arrowsClockwise,
                    label: "Refresh conversations",
                    isBusy: model.isLoadingSessions,
                    size: 24,
                    style: style
                ) { model.loadSessions() }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)

            if model.sessions.isEmpty && model.isLoadingSessions {
                DockLoadingState(title: "Loading conversations…", minHeight: 80)
            } else if model.sessions.isEmpty {
                Text("No saved conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(style.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                List {
                    ForEach(model.sessions) { session in
                        SessionPickerRow(
                            session: session,
                            projectName: conversationProjectName(for: session),
                            isCurrent: session.id == model.navigationSessionID,
                            canDelete: session.id != model.sessionID && model.deletingSessionID == nil,
                            isUpdatingVisibility: model.updatingSessionVisibilityID == session.id,
                            style: style,
                            onOpen: { model.resumeSession(session) },
                            onToggleHidden: {
                                Task { @MainActor in
                                    if await model.setSessionHidden(session, hidden: !session.isHidden) {
                                        controlCenter.refreshProjectNavigation()
                                    }
                                }
                            },
                            onDelete: { sessionPendingDeletion = session }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 280)
                .scrollContentBackground(.hidden)
                .padding(.bottom, 6)
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

    private var voiceMode: some View { voiceStage(immersive: false) }

    /// Full voice mode: the stage covers the navigation and inspector panels,
    /// with activity cards popping in around the orb.
    private var immersiveVoiceStage: some View {
        ZStack {
            Color.dockCanvas
            RadialGradient(colors: [Color.dockAccent.opacity(0.10), .clear], center: .center, startRadius: 40, endRadius: 700)
            voiceStage(immersive: true)
        }
        .ignoresSafeArea()
    }

    private func voiceStage(immersive: Bool) -> some View {
        let style = DockThemePalette(theme: dockThemeStore.selectedThemeID)
        let captions = voiceCaptions
        let orbScale: CGFloat = immersive ? 1.45 : 1
        return VStack(spacing: 0) {
            VoiceStatusStrip(model: model, repositoryPath: activeSessionRepositoryPath)
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .opacity(isVoiceTranscriptVisible ? 0 : 1)
            Spacer(minLength: 12)
            Button(action: handleVoiceOrbTap) {
                VoiceOrbView(mode: voiceOrbMode, audioLevel: max(speechInput.audioLevel, micLevelMeter.level))
                    .frame(width: 320, height: 320)
                    .overlay {
                        if voiceOrbMode == .listening, !speechInput.isRecording {
                            VoiceListeningRing(progress: micLevelMeter.turnProgress).padding(36)
                        }
                    }
                    .scaleEffect(orbScale)
                    .frame(width: 320 * orbScale, height: 320 * orbScale)
                    .contentShape(Circle())
            }
            .buttonStyle(.dockHover)
            .help(voiceOrbHelp)
            .accessibilityLabel(voiceOrbHelp)

            voiceStatusLabel
                .frame(height: 40)

            if !model.activeSubagents.isEmpty {
                VoiceSubagentOrbs(agents: model.activeSubagents)
                    .padding(.bottom, 8)
            }

            if hasPendingVoicePrompt {
                // Approvals and questions block the turn, so they take the
                // captions' place until answered.
                voicePromptCard
                    .frame(maxWidth: immersive ? 520 : 420)
                    .shadow(color: (model.approvalText != nil ? Color.dockWarning : Color.dockAccent).opacity(0.35), radius: 28)
                    .padding(.horizontal, 16)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
            VStack(spacing: 8) {
                if let user = captions.user {
                    Text(user)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                        .lineLimit(2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let reply = captions.reply {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let cue = voiceSubtitles.cue(
                            messageID: reply.id,
                            text: reply.text,
                            now: context.date.timeIntervalSinceReferenceDate
                        )
                        Text(cue ?? "")
                            .font(.system(size: immersive ? 17 : 14, weight: .medium))
                            .foregroundStyle(Color.dockPrimaryText)
                            .lineLimit(3)
                            .id(cue)
                            .transition(.opacity)
                            .animation(.dockEase(duration: 0.2), value: cue)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: immersive ? 560 : 360, minHeight: 96, alignment: .top)
            .padding(.horizontal, 16)
            }

            voiceControls(style: style)
                .padding(.top, 10)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // A pending approval or question dims everything else.
            VoiceActivityPillsLayer(model: model, cardWidth: immersive ? 280 : 200, cronJobs: controlCenter.cronJobs,
                                    leavesLeftFree: !voiceHUD.cards.isEmpty)
                .padding(immersive ? 24 : 12)
                .opacity(hasPendingVoicePrompt ? 0.2 : 1)
        }
        .overlay(alignment: .leading) {
            GeometryReader { geometry in
                let inset: CGFloat = immersive ? 24 : 12
                let width = min(immersive ? 300.0 : 210.0, max(0, (geometry.size.width - inset * 2 - 12) / 2))
                ViewThatFits(in: .vertical) {
                    VoiceHUDDeck(state: voiceHUD, width: width)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView(.vertical) {
                        VoiceHUDDeck(state: voiceHUD, width: width)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(width: width, height: geometry.size.height)
                .padding(.leading, inset)
                .opacity(hasPendingVoicePrompt ? 0.2 : 1)
                .allowsHitTesting(!hasPendingVoicePrompt)
            }
        }
        .overlay { VoiceWakeFlash(count: model.wakeCount) }
        .onChange(of: model.activeToolCalls) { _, calls in voiceHUD = VoiceHUDState(calls: calls) }
        .overlay(alignment: .top) {
            if isVoiceTranscriptVisible {
                VoiceRecentTranscript(messages: model.messages)
                    .frame(maxWidth: immersive ? 520 : 400)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.dockEase(duration: 0.25), value: isVoiceTranscriptVisible)
        .animation(.dockEase(duration: 0.3), value: model.voiceState)
        .animation(.dockEase(duration: 0.25), value: captions.user)
        .animation(.dockEase(duration: 0.25), value: captions.reply == nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: hasPendingVoicePrompt)
        .onAppear {
            voiceHUD = VoiceHUDState(calls: model.activeToolCalls)
            beginVoiceConversation()
        }
    }

    private var voiceOrbMode: VoiceOrbMode {
        if speechInput.isRecording { return .listening }
        if voiceOutput.isSpeaking { return .speaking }
        switch model.voiceState {
        case .listening: return .listening
        case .transcribing, .interrupted: return .transcribing
        case .preparing, .thinking: return .thinking
        case .speaking: return .speaking
        case .paused, .inactive, .localFallback: return model.status == .working ? .thinking : .idle
        }
    }

    private var voiceOrbHelp: String {
        switch voiceOrbMode {
        case .listening: "Tap to send now"
        case .thinking, .speaking: "Tap to interrupt"
        case .transcribing: "Transcribing"
        case .idle: "Tap to resume listening"
        }
    }

    @ViewBuilder
    private var voiceStatusLabel: some View {
        if let detail = model.voiceState.fallbackDetail, !speechInput.isRecording, !voiceOutput.isSpeaking {
            Text("LOCAL FALLBACK · \(detail)")
                .font(.system(size: 12, weight: .medium))
                .tracking(0.35)
                .foregroundStyle(Color.dockWarning)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        } else if model.voiceState.isNativeConversationActive {
            VStack(spacing: 4) {
                Text(voiceStatusText)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(model.voiceState == .listening ? Color.dockSuccess : (model.voiceState == .paused ? Color.dockMetadataText : Color.dockAccent))
                    .contentTransition(.opacity)
            }
        } else if model.status == .working && !speechInput.isRecording {
            voiceActivityIndicator
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if speechInput.isRecording || voiceOutput.isSpeaking {
            Text(speechInput.isRecording ? "\(model.agentDisplayName.uppercased()) IS LISTENING" : "\(model.agentDisplayName.uppercased()) IS SPEAKING")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.75)
                .foregroundStyle(speechInput.isRecording ? Color.dockSuccess : Color.dockAccent)
        }
    }

    /// Approvals keep their card so the command stays readable; questions
    /// are asked aloud instead when spoken answers work.
    private var hasPendingVoicePrompt: Bool {
        model.approvalText != nil
            || (showsVoiceClarificationCard && model.status == .needsClarification && model.clarificationQuestion != nil)
            || model.valuePrompt != nil
    }

    private var showsVoiceClarificationCard: Bool {
        model.voiceState.isNativeConversationActive ? !model.answersVoicePromptsAloud : speechInput.isUnavailable
    }

    /// The same prompt rows the chat shows, floated on the voice stage.
    @ViewBuilder
    private var voicePromptCard: some View {
        if let approval = model.approvalText {
            approvalRow(model.approvalDetails ?? ApprovalPresentation(
                title: model.approvalTitle ?? "Review requested action",
                detail: approval,
                detailIsCommand: model.approvalTitle == "Run command"
            ))
        } else if showsVoiceClarificationCard, model.status == .needsClarification, model.clarificationQuestion != nil {
            clarificationRow
        } else if let prompt = model.valuePrompt {
            valuePromptRow(prompt)
        }
    }

    /// What you said and what the agent is saying, so the conversation reads
    /// like live captions rather than a hidden transcript.
    private var voiceCaptions: (user: String?, reply: (id: UUID, text: String)?) {
        if speechInput.isRecording || (model.voiceState.isNativeConversationActive && voiceOrbMode == .listening) {
            let live = speechInput.isRecording ? speechInput.transcript : micLevelMeter.transcript
            let partial = live.trimmingCharacters(in: .whitespacesAndNewlines)
            return (partial.isEmpty ? nil : partial, nil)
        }
        // Talking over a running turn steers it; show what is being heard.
        let steering = micLevelMeter.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.voiceState == .thinking, !steering.isEmpty { return ("→ " + steering, nil) }
        // While Hermes transcribes, the last user line is the previous turn.
        guard voiceOrbMode != .listening, voiceOrbMode != .idle, voiceOrbMode != .transcribing,
              let userIndex = model.messages.lastIndex(where: { $0.role == .user }) else { return (nil, nil) }
        let reply = model.messages[(userIndex + 1)...].last { $0.role == .hermes }
        let text = reply?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (
            "“" + model.messages[userIndex].text + "”",
            reply.flatMap { text.isEmpty ? nil : ($0.id, text) }
        )
    }

    private func voiceControls(style: DockThemePalette) -> some View {
        HStack(spacing: 14) {
            if model.voiceState.isNativeConversationActive {
                DockIconButton(
                    icon: .waveform,
                    label: model.voiceRepliesEnabled ? "Mute spoken replies" : "Speak replies aloud",
                    isProminent: model.voiceRepliesEnabled,
                    size: 34,
                    style: style
                ) { model.toggleVoiceReplies() }
                DockIconButton(
                    icon: model.isVoiceMicMuted ? .microphoneSlash : .microphone,
                    label: model.isVoiceMicMuted ? "Unmute microphone" : "Mute microphone",
                    isProminent: model.isVoiceMicMuted,
                    size: 34,
                    style: style
                ) { model.toggleVoiceMicMuted() }
            }
            DockIconButton(
                icon: .chatCircleText,
                label: isVoiceTranscriptVisible ? "Hide recent conversation" : "Show recent conversation",
                isProminent: isVoiceTranscriptVisible,
                size: 34,
                style: style
            ) { isVoiceTranscriptVisible.toggle() }
            switch voiceOrbMode {
            case .listening:
                DockIconButton(icon: .arrowUp, label: "Send now", size: 34, style: style, action: handleVoiceOrbTap)
            case .thinking, .speaking:
                DockIconButton(icon: .stop, label: "Interrupt", size: 34, style: style, action: handleVoiceOrbTap)
            case .idle:
                // While muted, the mute toggle is the resume control.
                if !model.isVoiceMicMuted {
                    DockIconButton(icon: .play, label: "Resume listening", size: 34, style: style, action: handleVoiceOrbTap)
                }
            case .transcribing:
                DockIconButton(icon: .microphone, label: "Transcribing", isBusy: true, size: 34, style: style) {}
            }
            DockIconButton(
                icon: isVoiceImmersive ? .cornersIn : .cornersOut,
                label: isVoiceImmersive ? "Exit full voice mode" : "Full voice mode",
                size: 34,
                style: style
            ) { isVoiceImmersive.toggle() }
            .keyboardShortcut(isVoiceImmersive ? .cancelAction : nil)
            DockIconButton(icon: .x, label: "End voice conversation", size: 34, style: style, action: exitVoiceMode)
        }
    }

    private var wakesByVoice: Bool {
        model.answersVoicePromptsAloud && MicLevelMeter.canDetectWakePhrase
    }

    private var voiceStatusText: String {
        if model.isVoiceMicMuted { return "MIC MUTED — TAP TO RESUME" }
        if model.voiceState == .paused, wakesByVoice {
            return "SAY “HEY \(model.agentDisplayName.uppercased())” OR TAP"
        }
        return model.voiceState.label(agentName: model.agentDisplayName)
    }

    private func handleVoiceOrbTap() {
        switch model.voiceState {
        case .listening:
            model.finishVoiceUtterance(transcript: micLevelMeter.utteranceTranscript)
            return
        case .thinking, .speaking:
            model.interruptVoiceTurn()
            return
        case .paused:
            model.resumeVoiceListening()
            return
        case .preparing, .transcribing, .interrupted:
            return
        case .inactive, .localFallback:
            break
        }
        if speechInput.isRecording {
            speechInput.finishUtterance()
        } else if voiceOutput.isSpeaking {
            voiceOutput.stop()
        } else if model.status == .working {
            stopCurrentRequest()
        } else {
            beginVoiceConversation()
        }
    }

    private func beginVoiceConversation() {
        if case .localFallback = model.voiceState {
            resumeVoiceConversationIfReady()
        } else {
            model.startVoiceConversation()
        }
    }

    private func resumeVoiceConversationIfReady() {
        // A pending approval or question waits for a spoken answer.
        let awaitsAnswer = model.voicePromptSpeech != nil
        guard sessionWorkspaceMode == .voice,
              !model.voiceState.isNativeConversationActive,
              model.status == .idle || awaitsAnswer,
              !model.isSending || awaitsAnswer,
              !speechInput.isRecording,
              !speechInput.isStarting,
              !voiceOutput.isSpeaking else { return }
        // A new local turn resets transient capture failures. Leaving the old
        // error as a guard made the voice orb's retry action a permanent no-op.
        speechInput.startListening()
    }

    private func exitVoiceMode() {
        releaseVoiceCapture()
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
                                } else if model.messages.isEmpty {
                                    // A resume clears the old transcript before Hermes answers.
                                    DockLoadingState(title: "Loading conversation…", minHeight: max(300, viewport.size.height - 16))
                                }

                                let mountedRange = effectiveMountedRange
                                let messages = model.messages[mountedRange]
                                ForEach(Array(messages.enumerated()), id: \.element.id) { rowOffset, message in
                                    messageRow(message)
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: MessageNavigatorViewportPreferenceKey.self,
                                                    value: [MessageNavigatorViewport(
                                                        target: MessageNavigatorTarget(sessionID: model.sessionID ?? "", messageID: message.id),
                                                        index: mountedRange.lowerBound + rowOffset,
                                                        minY: geometry.frame(in: .named("conversation-document")).minY,
                                                        maxY: geometry.frame(in: .named("conversation-document")).maxY
                                                    )]
                                                )
                                            }
                                        }
                                        .id(message.id)
                                }
                                if let approval = model.approvalText {
                                    approvalRow(model.approvalDetails ?? ApprovalPresentation(
                                        title: model.approvalTitle ?? "Review requested action",
                                        detail: approval,
                                        detailIsCommand: model.approvalTitle == "Run command"
                                    ))
                                        .id("approval")
                                }
                                if model.status == .needsClarification, model.clarificationQuestion != nil {
                                    clarificationRow
                                        .id("clarification")
                                }
                                if let prompt = model.valuePrompt {
                                    valuePromptRow(prompt)
                                        .id("value-prompt")
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
                                        topMinY: geometry.frame(in: .named("conversation-document")).minY,
                                        bottomMaxY: geometry.frame(in: .named("conversation-document")).maxY
                                    )
                                )
                            }
                        )
                        // Inside the scrolled content so the observer's
                        // superview chain reaches the NSScrollView; a
                        // background on the ScrollView itself is a sibling
                        // and never attaches.
                        .background {
                            ConversationScrollEventObserver(
                                controller: scrollController,
                                onScroll: { geometry, deltaTop in
                                    // Runs for every bounds change: keep it to a
                                    // few comparisons unless an edge is reached.
                                    if deltaTop < 0 {
                                        loadEarlierMessagesIfNeeded(geometry)
                                    } else if deltaTop > 0 {
                                        loadLaterMessagesIfNeeded(geometry)
                                    }
                                },
                                onScrollSettled: { geometry in
                                    conversationPerformance.recordScrollSettled()
                                    let top = geometry.visibleTop
                                    scrollBookkeeping.isPaging = false
                                    // Content bounds are expressed relative to the
                                    // viewport: the document top sits at -top.
                                    updateConversationPosition(
                                        ConversationContentBounds(
                                            topMinY: -top,
                                            bottomMaxY: geometry.documentHeight - top
                                        ),
                                        viewportHeight: viewport.size.height,
                                        proxy: proxy
                                    )
                                    updateNavigatorVisibility(
                                        top: top,
                                        bottom: top + geometry.visibleHeight
                                    )
                                    // A short transcript cannot be scrolled toward
                                    // its edge, so settle also fills the buffer.
                                    loadEarlierMessagesIfNeeded(geometry)
                                }
                            )
                        }
                        .coordinateSpace(name: "conversation-document")
                    }
                    .id(model.sessionID)
                    .defaultScrollAnchor(.bottom)
                    .onAppear {
                        isConversationAtBottom = true
                        unseenMessageCount = 0
                        mountedMessageRange = ConversationMessageWindow.rangeForSessionReplacement(
                            totalCount: model.messages.count
                        )
                        scrollBookkeeping.lastRenderedMessageBubbleCount = renderedMessageBubbleCount
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
                        scrollBookkeeping.pendingAnchor = nil
                        scrollBookkeeping.isPaging = false
                        scrollBookkeeping.lastRenderedMessageBubbleCount = renderedMessageBubbleCount
                        streamingTailScroll.cancel()
                        scrollBookkeeping.isPastEndRepairScheduled = false
                        scrollBookkeeping.isHistoryCompactionScheduled = false
                        scrollConversationToBottom(proxy)
                    }
                    .onPreferenceChange(ConversationContentBoundsPreferenceKey.self) { bounds in
                        scrollBookkeeping.documentHeight = max(0, bounds.bottomMaxY - bounds.topMinY)
                    }
                    .onPreferenceChange(MessageNavigatorViewportPreferenceKey.self) { viewports in
                        // Document-space frames are stable during live scroll;
                        // retain them until the native clip view reports that
                        // scrolling has settled.
                        scrollBookkeeping.rowViewports = viewports
                        guard let anchor = scrollBookkeeping.pendingAnchor else { return }
                        scrollBookkeeping.pendingAnchor = nil
                        // The new page is laid out; a continuing fling may
                        // request the next one without waiting to settle.
                        defer { scrollBookkeeping.isPaging = false }
                        guard let restoredRow = viewports.first(where: { $0.target.messageID == anchor.messageID }),
                              let geometry = scrollController.geometry else { return }
                        // Rows mounted or evicted around the reader moved the
                        // anchor row; move the viewport with it in this same
                        // pass so the page never visibly jumps.
                        let currentOffset = restoredRow.minY - geometry.visibleTop
                        scrollController.shiftVisibleTop(by: currentOffset - anchor.offset)
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
                        if let prepend = model.lastTranscriptPrepend,
                           prepend.resultingCount == newCount,
                           newCount - oldCount == prepend.count {
                            // A navigator jump already placed the window.
                            guard prepend.generation != scrollBookkeeping.consumedTranscriptPrependGeneration else { return }
                            // Older history was inserted at index 0: keep the
                            // same rows mounted by shifting the window with them.
                            scrollBookkeeping.consumedTranscriptPrependGeneration = prepend.generation
                            scrollBookkeeping.lastRenderedMessageBubbleCount = renderedMessageBubbleCount
                            let bounds = ConversationMessageWindow.visibleRange(mountedMessageRange, totalCount: oldCount)
                            if !bounds.isEmpty {
                                mountedMessageRange = (bounds.lowerBound + prepend.count)..<(bounds.upperBound + prepend.count)
                            }
                            DispatchQueue.main.async {
                                if let geometry = scrollController.geometry { loadEarlierMessagesIfNeeded(geometry) }
                            }
                            return
                        }
                        mountedMessageRange = ConversationMessageWindow.rangeAfterCountChange(
                            mountedMessageRange,
                            oldCount: oldCount,
                            newCount: newCount,
                            isAtBottom: isConversationAtBottom
                        )
                        let previousBubbleCount = scrollBookkeeping.lastRenderedMessageBubbleCount
                        let currentBubbleCount = renderedMessageBubbleCount
                        scrollBookkeeping.lastRenderedMessageBubbleCount = currentBubbleCount

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
                    // Hermes parks the turn on these prompts with a deadline
                    // (approvals: 60s). A card mounted below the viewport
                    // times out unseen, so a new prompt always scrolls in.
                    .onChange(of: model.approvalText) { _, text in
                        if text != nil { revealBlockingPrompt() }
                    }
                    .onChange(of: model.valuePrompt?.requestID) { _, requestID in
                        valuePromptText = ""
                        valuePromptIdentifier = ""
                        if requestID != nil { revealBlockingPrompt() }
                    }
                    .onChange(of: model.clarificationQuestion) { _, question in
                        clarificationSelection = []
                        if question != nil { revealBlockingPrompt() }
                    }
                    .onDisappear { streamingTailScroll.cancel() }
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
                                DockIcon(.arrowDown, size: 11, color: Color.dockOnAccentText)
                                Text("\(unseenMessageCount) new \(unseenMessageCount == 1 ? "message" : "messages")")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.dockOnAccentText)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.dockAccent))
                            .shadow(color: Color.dockAccent.opacity(0.3), radius: 10, y: 3)
                        }
                        .buttonStyle(.dockHover)
                        .padding(.bottom, 12)
                    }

                    let showsNavigatorMap = model.messageNavigatorItems.count >= MessageNavigator.minimumMessagesToShowNavigator
                        && viewport.size.width >= navigatorMinimumConversationWidth
                    if showsNavigatorMap || isShowingMessageSearch {
                        MessageNavigatorView(
                            items: model.messageNavigatorItems,
                            sessionID: model.sessionID ?? "",
                            visibleTargets: visibleNavigatorTargets,
                            isSearchPresented: $isShowingMessageSearch,
                            showsMap: showsNavigatorMap,
                            isLoadingHistory: model.isLoadingTranscriptHistory,
                            onSearch: {
                                guard model.hasUnloadedTranscript, !model.isLoadingTranscriptHistory else { return }
                                Task { await model.loadTranscriptHistory(through: nil) }
                            },
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
        if let rowID = item.storedRowID {
            // The prompt is older than the loaded transcript: load through it,
            // then jump to the message it became.
            Task { @MainActor in
                guard let messageID = await model.loadTranscriptHistory(through: rowID),
                      model.sessionID == sessionID else { return }
                // The jump sets the window itself; the count change must not
                // shift it again as an ordinary prepend.
                if let prepend = model.lastTranscriptPrepend {
                    scrollBookkeeping.consumedTranscriptPrependGeneration = prepend.generation
                }
                scrollBookkeeping.lastRenderedMessageBubbleCount = renderedMessageBubbleCount
                let loadedItem = model.messageNavigatorItems.first { $0.messageID == messageID }
                if let loadedItem { jumpToMessage(loadedItem, proxy: proxy) }
            }
            return
        }
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

    /// History pages mount automatically once the reader is within this
    /// distance of a mounted edge, so the next page is laid out before it is
    /// needed.
    private func pagingEdgeDistance(_ geometry: ConversationScrollGeometry) -> CGFloat {
        max(480, geometry.visibleHeight)
    }

    private func loadEarlierMessagesIfNeeded(_ geometry: ConversationScrollGeometry) {
        guard !scrollBookkeeping.isPaging,
              geometry.visibleTop < pagingEdgeDistance(geometry) else { return }
        let current = effectiveMountedRange
        guard current.lowerBound > 0 else {
            // Every loaded message is mounted; fetch the next stored page.
            model.loadEarlierTranscriptIfAvailable()
            return
        }
        let next = ConversationMessageWindow.revealEarlier(
            current,
            totalCount: model.messages.count,
            visibleSpan: visibleIndexSpan(in: geometry)
        )
        applyPagedRange(next, from: current, geometry: geometry)
    }

    private func loadLaterMessagesIfNeeded(_ geometry: ConversationScrollGeometry) {
        guard !scrollBookkeeping.isPaging,
              geometry.distanceToBottom < pagingEdgeDistance(geometry) else { return }
        let current = effectiveMountedRange
        guard current.upperBound < model.messages.count else { return }
        let next = ConversationMessageWindow.revealLater(
            current,
            totalCount: model.messages.count,
            visibleSpan: visibleIndexSpan(in: geometry)
        )
        applyPagedRange(next, from: current, geometry: geometry)
    }

    private func applyPagedRange(
        _ next: Range<Int>,
        from current: Range<Int>,
        geometry: ConversationScrollGeometry
    ) {
        guard next != current else { return }
        let top = geometry.visibleTop
        let bottom = top + geometry.visibleHeight
        let anchorRow = scrollBookkeeping.rowViewports
            .filter { $0.maxY > top && $0.minY < bottom }
            .min(by: { $0.index < $1.index })
        if let anchorRow {
            scrollBookkeeping.pendingAnchor = ConversationScrollAnchor(
                messageID: anchorRow.target.messageID,
                offset: anchorRow.minY - top
            )
        }
        // Cleared once the anchored page is laid out, or by the next settle.
        scrollBookkeeping.isPaging = true
        mountedMessageRange = next
    }

    private func visibleIndexSpan(in geometry: ConversationScrollGeometry) -> ClosedRange<Int>? {
        let top = geometry.visibleTop
        let bottom = top + geometry.visibleHeight
        var lower: Int?
        var upper: Int?
        for row in scrollBookkeeping.rowViewports where row.maxY > top && row.minY < bottom {
            lower = min(lower ?? row.index, row.index)
            upper = max(upper ?? row.index, row.index)
        }
        guard let lower, let upper else { return nil }
        return lower...upper
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

    private func updateNavigatorVisibility(top: CGFloat, bottom: CGFloat) {
        var next = Set<MessageNavigatorTarget>()
        for row in scrollBookkeeping.rowViewports where row.maxY >= top && row.minY <= bottom {
            next.insert(row.target)
        }
        if next != visibleNavigatorTargets {
            visibleNavigatorTargets = next
        }
    }

    private func scheduleHistoryCompaction(_ proxy: ScrollViewProxy) {
        guard !scrollBookkeeping.isHistoryCompactionScheduled else { return }
        scrollBookkeeping.isHistoryCompactionScheduled = true
        let owningSessionID = model.sessionID

        Task { @MainActor in
            await Task.yield()
            guard owningSessionID == model.sessionID, isConversationAtBottom else {
                scrollBookkeeping.isHistoryCompactionScheduled = false
                return
            }

            mountedMessageRange = ConversationMessageWindow.compactedRange(
                totalCount: model.messages.count
            )
            await Task.yield()
            guard owningSessionID == model.sessionID, isConversationAtBottom else {
                scrollBookkeeping.isHistoryCompactionScheduled = false
                return
            }

            proxy.scrollTo("conversation-bottom", anchor: .bottom)
            scrollBookkeeping.isHistoryCompactionScheduled = false
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
            // Lazily measured rows (feed/kanban lines, tall cards) settle one
            // layout pass later; re-target so the tail is not left mid-way.
            await Task.yield()
            guard isConversationAtBottom else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private func scheduleStreamingTailScroll(_ proxy: ScrollViewProxy) {
        let owningSessionID = model.sessionID
        streamingTailScroll.schedule {
            guard owningSessionID == model.sessionID, isConversationAtBottom else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private func revealBlockingPrompt() {
        isConversationAtBottom = true
        conversationScrollRequest &+= 1
    }

    private func schedulePastEndRepair(_ proxy: ScrollViewProxy) {
        guard !scrollBookkeeping.isPastEndRepairScheduled else { return }
        scrollBookkeeping.isPastEndRepairScheduled = true
        Task { @MainActor in
            // A negative content top together with a trailing edge above the
            // viewport is an invalid offset, never a legitimate browsing
            // position. Coalesce the repair after the current layout pass.
            await Task.yield()
            await Task.yield()
            scrollBookkeeping.isPastEndRepairScheduled = false
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        let isStreaming = message.id == model.streamingMessageIDForPresentation
        let activity = isStreaming ? model.streamingTurnActivity : message.activity
        if message.role == .hermes, isStreaming || !activity.isEmpty {
            TurnActivityView(
                activity: activity,
                runningSince: isStreaming ? (model.streamingResponseStartedAt ?? message.timestamp) : nil,
                duration: message.responseDuration
            )
            .padding(.horizontal, conversationMetrics.contentInset + 4)
            .padding(.top, 8)
        }
        if message.role == .hermes && !message.hasBodyText && message.images.isEmpty && !isStreaming {
            EmptyView()
        } else {
            ConversationMessageRow(
                message: message,
                isStreamingMessage: message.id == model.streamingMessageIDForPresentation,
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
                },
                loadKanbanDetail: { notice in await controlCenter.sessionKanbanTaskDetail(notice.taskSummary) }
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
                DockIcon(.brain)
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
            RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                .fill(Color.dockSurface)
                .stroke(Color.dockBorderLight, lineWidth: 0.5)
        )
    }

    private func approvalRow(_ approval: ApprovalPresentation) -> some View {
        let isPending = model.isRespondingToApproval
        let choices = approval.choices
        let alwaysAllowCaption = ApprovalPresentation.alwaysAllowCaption(for: approval)
        return DockCallout(tone: .warning, icon: .shieldWarning, title: "Approval required", message: approval.title, badge: isPending ? "Sending…" : "Needs approval") {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.vertical) {
                    Text(approval.detail)
                        .font(approval.detailIsCommand ? .system(size: 12, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(Color.dockPrimaryText)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    DockThemeShape(cornerRadius: DockLayout.controlRadius)
                        .fill(Color.dockSurface2)
                        .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
                )

                if let reason = approval.reason {
                    Label { Text(reason) } icon: { DockIcon(.info, size: 12) }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DockCalloutActions {
                    if choices.contains(ApprovalChoice.once) {
                        Button { model.respondToApproval(ApprovalChoice.once) } label: {
                            DockActionLabel(title: "Allow once", pendingTitle: "Allowing…", isPending: isPending, tint: .dockOnAccentText)
                                .frame(minHeight: DockControlMetrics.hitTarget)
                        }
                        .buttonStyle(DockPrimaryButtonStyle())
                    }
                    if choices.contains(ApprovalChoice.session) {
                        Button { model.respondToApproval(ApprovalChoice.session) } label: {
                            Text("Allow this session").frame(minHeight: DockControlMetrics.hitTarget)
                        }
                        .buttonStyle(DockSecondaryButtonStyle())
                        .help("Don't ask again for this command until the session ends.")
                    }
                    if choices.contains(ApprovalChoice.always) {
                        Button { model.respondToApproval(ApprovalChoice.always) } label: {
                            Text("Always allow").frame(minHeight: DockControlMetrics.hitTarget)
                        }
                        .buttonStyle(DockSecondaryButtonStyle())
                        .help(alwaysAllowCaption)
                    }
                    Button(role: .destructive) { model.respondToApproval(ApprovalChoice.deny) } label: {
                        Text("Deny").frame(minHeight: DockControlMetrics.hitTarget)
                    }
                    .buttonStyle(DockSecondaryButtonStyle())
                }
                .disabled(isPending)

                Text(approval.smartDenied
                     ? "Hermes' safety check blocked this. You can override it once."
                     : choices.contains(ApprovalChoice.always) ? alwaysAllowCaption : "Hermes asks again next time.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, conversationMetrics.contentInset + 4)
        .padding(.vertical, 8)
    }

    /// The question itself stays in the transcript as Hermes' message; this
    /// card sits under it with the ways to answer.
    private var clarificationRow: some View {
        let choices = model.clarificationChoices
        let isMultiSelect = model.clarificationMultiSelect
        let isPending = model.isRespondingToClarification
        let isDisabled = isPending || model.isRestoringSession
        return DockCallout(tone: .info, icon: .question, title: "Clarification needed",
                           message: model.clarificationProgress, badge: isPending ? "Sending…" : "Needs answer") {
            VStack(alignment: .leading, spacing: 8) {
                if !choices.isEmpty {
                    Text(isMultiSelect ? "Choose one or more responses" : "Choose a response")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                    VStack(spacing: 6) {
                        ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                            let isSelected = clarificationSelection.contains(choice)
                            Button {
                                if !isMultiSelect {
                                    model.respondToClarification(choice)
                                } else if isSelected {
                                    clarificationSelection.removeAll { $0 == choice }
                                } else {
                                    clarificationSelection.append(choice)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isMultiSelect {
                                        DockIcon(isSelected ? .checkSquare : .square, size: 14,
                                                 weight: isSelected ? .fill : .regular,
                                                 color: isSelected ? .dockAccent : .dockMetadataText)
                                    }
                                    Text(choice)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    if !isMultiSelect {
                                        DockIcon(.arrowRight, size: 12, color: .dockAccent)
                                    }
                                }
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, minHeight: DockControlMetrics.hitTarget, alignment: .leading)
                            }
                            .buttonStyle(DockSecondaryButtonStyle())
                            .overlay {
                                DockThemeShape(cornerRadius: DockLayout.controlRadius)
                                    .fill(isSelected ? Color.dockAccent.opacity(0.08) : Color.clear)
                                    .stroke(isSelected ? Color.dockAccent : Color.clear, lineWidth: DockLayout.hairline)
                                    .allowsHitTesting(false)
                            }
                            .accessibilityLabel(isMultiSelect ? choice : "Send suggested response: \(choice)")
                            .accessibilityAddTraits(isMultiSelect && isSelected ? .isSelected : [])
                        }
                    }
                    .controlSize(.small)
                    .disabled(isDisabled)
                }
                if isMultiSelect {
                    Button {
                        let selection = clarificationSelection
                        model.respondToClarification(ClarifyQuestion.multiSelectAnswer(selection),
                                                     displayText: selection.joined(separator: ", "))
                    } label: {
                        DockActionLabel(title: clarificationSelection.isEmpty ? "Send selection" : "Send \(clarificationSelection.count) selected",
                                        pendingTitle: "Sending…", isPending: isPending, tint: .dockOnAccentText)
                            .frame(minHeight: DockControlMetrics.hitTarget)
                    }
                    .buttonStyle(DockPrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(isDisabled || clarificationSelection.isEmpty)
                }
                Text(choices.isEmpty ? "Type your answer in the message box below." : "Or type a different answer below.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dockMetadataText)
            }
        }
        .padding(.horizontal, conversationMetrics.contentInset + 4)
        .padding(.vertical, 8)
    }

    private func valuePromptRow(_ prompt: ValuePrompt) -> some View {
        let isPending = model.isRespondingToValuePrompt
        let canSubmit = !valuePromptText.isEmpty && (!prompt.asksForLogin || !valuePromptIdentifier.isEmpty)
        let submit = {
            guard canSubmit, !isPending else { return }
            model.respondToValuePrompt(prompt.answer(value: valuePromptText, identifier: valuePromptIdentifier))
        }
        return DockCallout(tone: .warning, icon: prompt.isSecret ? .lockKey : .key, title: prompt.title,
                           message: prompt.message, badge: isPending ? "Sending…" : "Input needed") {
            VStack(alignment: .leading, spacing: 8) {
                if prompt.asksForLogin {
                    Text("Username or email")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dockSecondaryText)
                    TextField("Username or email", text: $valuePromptIdentifier)
                        .font(.system(size: 12))
                        .textFieldStyle(.dockGlass)
                        .textContentType(.username)
                        .disabled(isPending)
                }
                Text(prompt.fieldLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
                Group {
                    if prompt.isSecret {
                        SecureField(prompt.fieldLabel, text: $valuePromptText)
                    } else {
                        TextField(prompt.fieldLabel, text: $valuePromptText)
                            .textContentType(.oneTimeCode)
                    }
                }
                .font(.system(size: 12))
                .textFieldStyle(.dockGlass)
                .disabled(isPending)
                .onSubmit(submit)

                DockCalloutActions {
                    Button(action: submit) {
                        DockActionLabel(title: prompt.asksForLogin ? "Send login" : "Send", pendingTitle: "Sending…", isPending: isPending, tint: .dockOnAccentText)
                            .frame(minHeight: DockControlMetrics.hitTarget)
                    }
                    .buttonStyle(DockPrimaryButtonStyle())
                    .disabled(!canSubmit)
                    Button { model.respondToValuePrompt("") } label: {
                        Text("Skip").frame(minHeight: DockControlMetrics.hitTarget)
                    }
                    .buttonStyle(DockSecondaryButtonStyle())
                }
                .disabled(isPending)

                Text(model.valuePromptError ?? "Sent only to your local Hermes. Herm does not store it.")
                    .font(.system(size: 12))
                    .foregroundStyle(model.valuePromptError == nil ? Color.dockMetadataText : Color.dockDestructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, conversationMetrics.contentInset + 4)
        .padding(.vertical, 8)
    }

    private func quickPromptChip(_ quickPrompt: QuickPrompt) -> some View {
        let requiredCapability = quickPrompt.requiredCapability
        let isAvailable = requiredCapability.map(controlCenter.capabilityAvailable) ?? true
        return Button(quickPrompt.label) {
            selectQuickPrompt(quickPrompt)
        }
        .buttonStyle(.dockHover)
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
            DockIconLabel("More", icon: .dotsThree)
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

/// A session's live working/unread state, shown alongside `SessionAttentionDot`
/// wherever a session row is rendered. Working takes priority over unread; both
/// stay silent when the session is idle and read.
struct SessionActivityGlyph: View {
    let isWorking: Bool
    let hasUnreadUpdate: Bool

    var body: some View {
        if isWorking {
            ProgressView().controlSize(.mini).frame(width: 8, height: 8)
        } else if hasUnreadUpdate {
            Circle().fill(Color.dockSuccess).frame(width: 6, height: 6)
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
    let onOpenPullRequests: () -> Void
    let onOpenIssues: () -> Void
    let showsFullscreenToggle: Bool
    let isFullscreen: Bool
    let onFullscreenToggle: () -> Void
    let onSelectProfile: (String) -> Void
    let onOpenWindow: (() -> Void)?
    let isDockedWindow: Bool
    @State private var isProfileSelectorPresented = false
    @State private var isProfileHovering = false
    @State private var creatingProjectPath: String?
    @State private var isShowingProjectSheet = false
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
        onSelectProfile: @escaping (String) -> Void,
        onOpenWindow: (() -> Void)? = nil,
        isDockedWindow: Bool = false
    ) {
        self.model = model
        self.botMode = botMode
        self.workspaceStore = workspaceStore
        self.controlCenter = controlCenter
        self.agentUpdateService = agentUpdateService
        self.navigationState = navigationState
        self.dockThemeStore = dockThemeStore
        _sidebar = StateObject(wrappedValue: MissionControlSidebarModel(model: model, control: controlCenter, store: workspaceStore))
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
        self.onOpenWindow = onOpenWindow
        self.isDockedWindow = isDockedWindow
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
            // One row: identity takes the free width, window chrome stays quiet,
            // and the primary action is the only prominent control.
            HStack(spacing: 2) {
                profileHeader(style: style)
                if let onOpenWindow {
                    DockIconButton(
                        icon: isDockedWindow ? .pictureInPicture : .appWindow,
                        label: isDockedWindow ? "Back to floating panel" : "Open as window",
                        style: style,
                        action: onOpenWindow
                    )
                }
                if showsFullscreenToggle {
                    DockIconButton(
                        icon: isFullscreen ? .cornersIn : .cornersOut,
                        label: isFullscreen ? "Exit fullscreen" : "Enter fullscreen",
                        style: style,
                        action: onFullscreenToggle
                    )
                }
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
            .overlay(alignment: .bottom) { style.divider.frame(height: 0.5) }

            ScrollView {
                globalRailBar(style: style)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }

            VStack(spacing: 2) {
                globalRailDestination(.quota, style: style)
                globalRailDestination(.core, style: style)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { style.divider.frame(height: 0.5) }
        }
        .background(style.background)
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
                model.messages = (scenario == .shortControl || scenario == .streamingLongMarkdown)
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
        let name = bot?.name ?? sidebarSnapshot.inputs.agentDisplayName
        let subtitle = bot?.title
        let label = subtitle.map { "\(name) — \($0)" } ?? name
        let isSwitchable = visibleBots.count > 1
        let identity = HStack(spacing: 9) {
            if let bot {
                BotAvatarView(bot: bot, imageData: botMode.avatarImages[bot.id], size: 28)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).fill(style.selectedFill)
                    DockIcon(.robot, size: 15, color: style.secondaryText)
                }
                .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.theme == .hermesClassic ? style.accent : style.primaryText)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(style.metadataText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isSwitchable {
                DockIcon(.caretUpDown, size: 12, color: style.metadataText)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                .fill(isSwitchable && (isProfileHovering || isProfileSelectorPresented) ? style.surface4.opacity(0.6) : .clear)
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
                                DockIcon(.check)
                                    .font(.system(size: 11, weight: .semibold))
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
        let allConversations = sidebarSnapshot.conversations
        // Built once per pass; rows previously rebuilt it per row (O(n²)).
        let statuses = sidebarSessionStatuses

        // One flat LazyVStack: sections below emit their rows as direct
        // children. Nested lazy stacks inside eager VStacks are not lazy, so
        // every conversation and project row was built on each layout pass.
        return LazyVStack(alignment: .leading, spacing: 0) {
            // Grouped by purpose: work items, time, library, then setup.
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if showsKanban {
                        globalRailDestination(.kanban, style: style)
                    }
                    if showsPullRequests { pullRequestsDestinationRow(style: style) }
                    if showsIssues { issuesDestinationRow(style: style) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if showsCalendar { globalRailDestination(.calendar, style: style) }
                    globalRailDestination(.automations, style: style)
                }
                VStack(alignment: .leading, spacing: 2) {
                    queueRailDestination("Artifacts", icon: .fileMagnifyingGlass, isSelected: navigationState.selection.selection == .artifacts, style: style) {
                        onOpenArtifacts()
                    }
                    if showsOffice { globalRailDestination(.officePreview, style: style) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    botsDestinationRow(style: style)
                    globalRailDestination(.usage, style: style)
                }
            }

            let pinned = pinnedSessionPresentation
            if pinned.status != .empty || !pinned.sessions.isEmpty {
                pinnedOutline(pinned, statuses: statuses, style: style)
            }

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
                    onNewChatInProject: startNewChat(inProject:)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingProjectSheet) {
            ProjectFolderSheet(
                projects: controlCenter.projects.filter(\.isRenderableProject),
                // The rail hides sessionless projects, so a new project opens
                // straight into its first chat instead of vanishing.
                onCreate: { name, folder in
                    let created = await controlCenter.createProject(name: name, folder: folder)
                    if created { startNewChat(inProject: folder) }
                    return created
                },
                onAddFolder: { await controlCenter.addProjectFolder($0, folder: $1) }
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

    private func botsDestinationRow(style: DockThemePalette) -> some View {
        queueRailDestination(
            "Bots",
            icon: .robot,
            isSelected: navigationState.selection.selection == .bots,
            style: style
        ) {
            onOpenBots()
        }
    }

    private func pullRequestsDestinationRow(style: DockThemePalette) -> some View {
        queueRailDestination("Pull requests", icon: .gitPullRequest, isSelected: navigationState.selection.selection == .pullRequests, style: style, action: onOpenPullRequests)
    }

    private func issuesDestinationRow(style: DockThemePalette) -> some View {
        queueRailDestination("Issues", icon: .record, isSelected: isIssuesActive, style: style, action: onOpenIssues)
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
        icon: Ph,
        isSelected: Bool,
        showsUpdateBadge: Bool = false,
        style: DockThemePalette,
        action: @escaping () -> Void
    ) -> some View {
        DockNavRow(title: title, icon: icon, isSelected: isSelected, showsUpdateBadge: showsUpdateBadge, style: style, action: action)
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
            .buttonStyle(.dockHover)
        }
    }

    private func conversationExpansionButton(style: DockThemePalette) -> some View {
        Button { navigationState.showsAllConversations.toggle() } label: {
            HStack(spacing: 6) {
                Text(navigationState.showsAllConversations ? "Show recent conversations" : "Show more conversations")
                DockIcon(navigationState.showsAllConversations ? .caretUp : .caretDown)
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(style.accent)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dockHover)
    }

    private func conversationSessionRow(_ session: HermesSession, statuses: [String: SidebarSessionStatus], style: DockThemePalette) -> some View {
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
            projectTargets: sidebarSnapshot.projectNameBySessionID[session.id] == nil ? sidebarSnapshot.projectTargets : [],
            onAddToProject: { selected, target in
                workspaceStore.ensureTask(title: selected.displayTitle, sessionID: selected.id)
                workspaceStore.attachProject(at: target.path, toSessionID: selected.id)
            }
        )
        .equatable()
    }

    /// Emits header and rows as siblings so the rail's LazyVStack owns them.
    @ViewBuilder
    private func pinnedOutline(_ pinned: PinnedSessionPresentation, statuses: [String: SidebarSessionStatus], style: DockThemePalette) -> some View {
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

    private func pinnedSessionRow(_ session: HermesSession, statuses: [String: SidebarSessionStatus], style: DockThemePalette) -> some View {
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
            onRequestDelete: { sessionPendingDeletion = $0 }
        )
        .equatable()
    }

    /// Emits header and rows as siblings so the rail's LazyVStack owns them.
    @ViewBuilder
    private func conversationOutline(_ conversations: [HermesSession], statuses: [String: SidebarSessionStatus], style: DockThemePalette) -> some View {
        DockSectionHeader(
            title: "Conversations",
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

        if navigationState.areConversationsExpanded {
            if conversations.isEmpty {
                queueEmpty(sidebarSnapshot.inputs.isLoadingSessions ? "Loading conversations…" : "No saved conversations", style: style)
                    .padding(.leading, 20)
            } else {
                let visibleSessions = navigationState.showsAllConversations
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
        togglePin: @escaping () -> Void,
        onSelect: @escaping () -> Void
    ) -> PinnedSessionRowControls {
        PinnedSessionRowControls(select: onSelect, togglePin: togglePin)
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
            .buttonStyle(.dockHover)

            Button(action: onTogglePin) {
                DockIcon(.pushPin, size: 13, color: isPinned ? style.accent : style.metadataText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
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
                SessionActivityGlyph(isWorking: session.isWorking, hasUnreadUpdate: session.hasUnreadUpdate)
                if let attentionDot {
                    Circle().fill(attentionDot.color).frame(width: 6, height: 6)
                }
            }
            if let badge = ConversationRepositoryBadgePresentation.make(
                projectName: projectName,
                isProjectLinked: isProjectLinked
            ) {
                DockIconLabel(badge.label, icon: .gitBranch)
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
    /// Projects the user flipped away from their default (expanded, or collapsed when empty).
    private var toggledProjectIDs: Set<String> = []
    private var expandedSessionProjectIDs: Set<String> = []

    mutating func toggle(projectID: String) {
        if toggledProjectIDs.contains(projectID) {
            toggledProjectIDs.remove(projectID)
        } else {
            toggledProjectIDs.insert(projectID)
        }
    }

    func isCollapsed(projectID: String, isEmpty: Bool = false) -> Bool {
        isEmpty != toggledProjectIDs.contains(projectID)
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
    let creatingProjectPath: String?
    let onSelectSession: (HermesSession) -> Void
    let onRefresh: () -> Void
    let onAddProject: () -> Void
    let onArchiveProject: (String) -> Void
    let onAddSourceFolder: (String, String) -> Void
    let onNewChatInProject: (String) -> Void
    @State private var disclosureState = ProjectDisclosureState()
    @State private var isExpanded = true
    @State private var hoveredNewChatProjectID: String?
    @State private var hoveredProjectRowID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sessionLimit = 10

    /// No container: header, project headers and session rows flatten into
    /// the rail's LazyVStack so only on-screen rows are built.
    @ViewBuilder
    var body: some View {
        DockSectionHeader(title: "Projects", count: groups.count, isExpanded: $isExpanded, style: style) {
            DockIconButton(icon: .plus, label: "New project or add folder", size: 24, style: style, action: onAddProject)
            DockIconButton(
                icon: .arrowsClockwise,
                label: isRefreshing ? "Refreshing projects…" : "Refresh projects",
                isBusy: isRefreshing,
                size: 24,
                style: style,
                action: onRefresh
            )
        }
        .padding(.top, style.sectionSpacing)
        .padding(.bottom, isExpanded ? 2 : 0)

        if isExpanded {
            if groups.isEmpty {
                projectStatusRow(isLoadingProjects ? "Loading projects…" : "No projects")
            } else {
                ForEach(groups) { group in projectGroup(group) }
            }
        }
    }

    @ViewBuilder
    private func projectGroup(_ group: MissionControlConversationGroup) -> some View {
        let sessionCount = max(group.declaredSessionCount, group.sessions.count)
        let isCollapsed = disclosureState.isCollapsed(projectID: group.id, isEmpty: sessionCount == 0 && group.sessions.isEmpty)
        let sessions = disclosureState.visibleSessions(group.sessions, projectID: group.id, limit: sessionLimit)
        let isActiveProject = group.sessions.contains { $0.id == selectedSessionID }
        let isCreatingHere = creatingProjectPath != nil && creatingProjectPath == group.projectPath
        HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .dockEase(duration: 0.18)) {
                    disclosureState.toggle(projectID: group.id)
                }
            } label: {
                HStack(spacing: 7) {
                    DockIcon(isCollapsed ? .caretRight : .caretDown, size: 11, color: style.metadataText)
                        .frame(width: 12)
                    DockIcon(.folder, size: 15, color: isActiveProject ? style.accent : style.secondaryText)
                        .frame(width: 16)
                    Text(group.title)
                        .font(style.labelFont)
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if group.hasGit {
                        DockIcon(.gitBranch, size: 11, color: style.metadataText)
                            .help("Git repository")
                            .accessibilityLabel("Git repository")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityLabel(isCollapsed ? "Expand project \(group.title)" : "Collapse project \(group.title)")

            // Count at rest; actions replace it while the row is hovered.
            let showsActions = hoveredProjectRowID == group.id || isCreatingHere
            ZStack(alignment: .trailing) {
                if sessionCount > 0 {
                    Text(compactCount(sessionCount))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(style.metadataText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(style.metadataText.opacity(0.14)))
                        .padding(.trailing, 10)
                        .opacity(showsActions ? 0 : 1)
                }
                if let projectPath = group.projectPath, !projectPath.isEmpty {
                    HStack(spacing: 0) {
                        Button {
                            onNewChatInProject(projectPath)
                        } label: {
                            Group {
                                if isCreatingHere {
                                    ProgressView().controlSize(.small)
                                } else {
                                    DockIcon(.chatTeardropText, size: 15, color: hoveredNewChatProjectID == group.id ? style.accent : style.secondaryText)
                                }
                            }
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .disabled(isCreatingChat || creatingProjectPath != nil)
                        .help("New chat in \(group.title)")
                        .accessibilityLabel("New chat in \(group.title)")
                        .onHover { isHovered in
                            hoveredNewChatProjectID = isHovered
                                ? group.id
                                : (hoveredNewChatProjectID == group.id ? nil : hoveredNewChatProjectID)
                        }

                        Button {
                            let menu = NSMenu()
                            menu.addClosureItem("Reveal in Finder") {
                                ExternalOpen.reveal([URL(fileURLWithPath: projectPath)])
                            }
                            if let projectID = group.projectID {
                                menu.addClosureItem("Add Source Folder…") { chooseSourceFolder(projectID: projectID) }
                                menu.addItem(.separator())
                                menu.addClosureItem("Archive Project") { onArchiveProject(projectID) }
                            }
                            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                        } label: {
                            DockIcon(.dotsThree, size: 15, weight: .fill, color: style.secondaryText)
                                .frame(width: 32, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.dockHover)
                        .help("More options for \(group.title)")
                        .accessibilityLabel("More options for \(group.title)")
                    }
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
                }
            }
            .frame(width: 64)
        }
        .onHover { isHovered in
            hoveredProjectRowID = isHovered
                ? group.id
                : (hoveredProjectRowID == group.id ? nil : hoveredProjectRowID)
        }
        .background(Color.clear)
        if !isCollapsed {
            if group.sessions.isEmpty {
                projectStatusRow(sessionCount == 0 ? "No conversations yet" : "Loading linked sessions…", leading: 0)
                    .padding(.leading, 12)
            } else {
                ForEach(sessions, id: \.[sidebarSection: group.id]) { session in sessionRow(session).padding(.leading, 12) }
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
                            DockIcon(disclosureState.showsAllSessions(projectID: group.id) ? .caretUp : .caretDown, size: 10, color: style.accent)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.accent)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover)
                    .accessibilityLabel(disclosureState.showsAllSessions(projectID: group.id)
                                        ? "Show recent sessions for \(group.title)"
                                        : "Show \(group.sessions.count - sessionLimit) more sessions for \(group.title)")
                    .padding(.leading, 12)
                }
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

    private func chooseSourceFolder(projectID: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runAboveHerm() == .OK, let url = panel.url else { return }
        onAddSourceFolder(projectID, url.path)
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

enum SidebarSessionTime {
    /// Compact rail timestamp: "now", "9m", "3h", "5d", then "Sep 2".
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// The rail is one flat LazyVStack, and a session can appear in Pinned,
/// Conversations and a project at once. Lazy stacks conflate rows that share
/// an id across sibling ForEach blocks and leave one blank until re-render.
private extension HermesSession {
    subscript(sidebarSection section: String) -> String { "\(section):\(id)" }
}

struct SidebarProjectTarget: Identifiable, Equatable {
    let title: String
    let path: String
    var id: String { path }
}

private struct MissionControlSidebarSessionRow: View, Equatable {
    let session: HermesSession
    let selectedSessionID: String?
    let sessionStatus: SidebarSessionStatus
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
    var projectTargets: [SidebarProjectTarget] = []
    var onAddToProject: (HermesSession, SidebarProjectTarget) -> Void = { _, _ in }
    @State private var isHovered = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var renameError: String?
    @State private var titleFieldDidFocus = false
    @FocusState private var titleFieldFocused: Bool
    @FocusState private var rowFocused: Bool

    private static let rowHeight: CGFloat = 30

    private var isSelected: Bool { session.id == selectedSessionID }

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

    private var showsActions: Bool {
        isHovered || rowFocused || pendingAction != nil
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session == rhs.session
            && lhs.selectedSessionID == rhs.selectedSessionID
            && lhs.sessionStatus == rhs.sessionStatus
            && lhs.style.theme == rhs.style.theme
            && lhs.repositoryName == rhs.repositoryName
            && lhs.isPinned == rhs.isPinned
            && lhs.isActive == rhs.isActive
            && lhs.isDeleting == rhs.isDeleting
            && lhs.isUpdatingVisibility == rhs.isUpdatingVisibility
            && lhs.isRenaming == rhs.isRenaming
            && lhs.projectTargets == rhs.projectTargets
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            statusIndicator
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                if !isEditingTitle, session.sourceBadgeTitle != nil || repository != nil || preview != nil {
                    HStack(spacing: 6) {
                        if let source = session.sourceBadgeTitle {
                            HStack(spacing: 4) {
                                DockIcon(.discordLogo, size: 12)
                                Text(source)
                                    .font(.system(size: 11, weight: .medium))
                            }
                                .foregroundStyle(Color.dockDiscord)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.dockDiscord.opacity(0.16)))
                                .fixedSize()
                                .accessibilityLabel("Source: \(source)")
                                .help("Session from \(source)")
                        }
                        if let repository { repositoryPill(repository) }
                        if let preview {
                            Text(preview)
                                .font(.subheadline)
                                .foregroundStyle(style.metadataText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .frame(minHeight: Self.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous).fill(rowFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        .dockHoverable().onTapGesture { if !isEditingTitle { onSelect(session) } }
        .focusable(!isEditingTitle)
        .focusEffectDisabled()
        .focused($rowFocused)
        .onKeyPress(.return) {
            guard !isEditingTitle else { return .ignored }
            onSelect(session)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(accessibilityLabel)
        .help(tooltip)
        .disabled(isDeleting)
        .opacity(isDeleting ? 0.5 : 1)
        .onHover { isHovered = $0 }
        .contextMenu { contextActions }
        .onChange(of: isEditingTitle) { _, editing in
            if editing {
                titleDraft = session.displayTitle
                renameError = nil
                titleFieldDidFocus = false
                // The context menu is still dismissing and reclaims focus; wait for it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { titleFieldFocused = true }
            }
        }
        .onChange(of: titleFieldFocused) { _, focused in
            if focused { titleFieldDidFocus = true }
            // Only treat blur as cancel once the field actually had focus.
            else if titleFieldDidFocus, isEditingTitle, pendingAction == nil { cancelRename() }
        }
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(spacing: 6) {
            if isEditingTitle {
                TextField("Session title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(Font.body.weight(.medium))
                    .foregroundStyle(style.primaryText)
                    .focused($titleFieldFocused)
                    .onSubmit { submitRename() }
                    .onExitCommand { cancelRename() }
                    .help(renameError ?? "Press Return to save, Esc to cancel")
                if renameError != nil {
                    DockIcon(.warningCircle, size: 11, color: .dockWarning)
                        .help(renameError ?? "")
                }
            } else {
                Text(session.displayTitle)
                    .font(Font.body.weight(isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? style.primaryText : style.primaryText.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .modifier(WorkingTitleShimmer(isActive: sessionStatus == .working, color: style.accent))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsActions {
                    actionSurface
                } else {
                    trailingDetail
                }
            }
        }
        .frame(height: 24)
    }

    private var repository: String? { Self.nonEmpty(repositoryName) }
    private var preview: String? { Self.nonEmpty(session.displayPreview) }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Wired repo shown as a pill ahead of the last-message preview.
    private func repositoryPill(_ name: String) -> some View {
        HStack(spacing: 3) {
            DockIcon(.gitBranch, size: 10, color: style.accent)
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(style.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(style.surface4.opacity(0.8)))
        .fixedSize()
        .help(name)
    }

    private var rowFill: Color {
        if isSelected { return style.selectedFill }
        return isHovered ? style.selectedFill.opacity(0.4) : .clear
    }

    private var tooltip: String {
        [session.displayTitle, session.sourceBadgeTitle, repositoryName, session.displayPreview]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        var parts = [session.displayTitle]
        if let source = session.sourceBadgeTitle { parts.append("Source: \(source)") }
        if sessionStatus != .none { parts.append(sessionStatus.label) }
        if let repositoryName, !repositoryName.isEmpty { parts.append(repositoryName) }
        if let date = session.lastUpdatedAt { parts.append(SidebarSessionTime.short(date)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var trailingDetail: some View {
        if let date = session.lastUpdatedAt {
            Text(SidebarSessionTime.short(date))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(style.metadataText)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Leading status slot. Fixed width keeps titles aligned whether or not a
    /// row has status. Only working rows spin, so scrolling stays cheap.
    private var statusIndicator: some View {
        Group {
            switch sessionStatus {
            case .working:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .tint(statusColor)
            case .needsAttention:
                DockIcon(.warningCircle, size: 10, color: statusColor)
            case .failed:
                DockIcon(.xCircle, size: 10, color: statusColor)
            case .unreadComplete:
                Circle().frame(width: 6, height: 6)
            case .none:
                Color.clear
            }
        }
        .foregroundStyle(statusColor)
        .frame(width: 14, height: 14)
        .help(sessionStatus.help)
        .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch sessionStatus {
        case .working, .unreadComplete: style.accent
        case .needsAttention: .dockWarning
        case .failed: .dockDestructive
        case .none: .clear
        }
    }

    private var actionSurface: some View {
        HStack(spacing: 0) {
            Button { onTogglePin(session) } label: {
                DockIcon(.pushPin, size: 12, color: isPinned ? style.accent : style.metadataText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help(isPinned ? "Unpin session" : "Pin session")
            .accessibilityLabel(isPinned ? "Unpin \(session.displayTitle)" : "Pin \(session.displayTitle)")

            if pendingAction != nil {
                ProgressView().controlSize(.mini).frame(width: 24, height: 24)
            } else {
                // Menu labels on macOS only reliably render Text/Image.
                Menu { contextActions } label: {
                    Ph.dotsThree.image(size: 13, color: NSColor(Color.dockSecondaryText))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More session actions")
                .accessibilityLabel("More actions for \(session.displayTitle)")
            }
        }
    }

    @ViewBuilder
    private var contextActions: some View {
        Button(isPinned ? "Unpin" : "Pin", icon: isPinned ? .pushPinSlash : .pushPin) {
            onTogglePin(session)
        }
        Button("Rename…", icon: .pencilSimple) {
            isEditingTitle = true
        }
        Button(presentation.visibilityTitle, icon: session.isHidden ? .eye : .eyeSlash) {
            Task { @MainActor in
                _ = await onToggleHidden(session, !session.isHidden)
            }
        }
        .disabled(isUpdatingVisibility || isDeleting)
        if !projectTargets.isEmpty {
            Menu("Add to project") {
                ForEach(projectTargets) { target in
                    Button(target.title) { onAddToProject(session, target) }
                }
            }
        }
        Divider()
        Button("Delete", icon: .trash, role: .destructive) {
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        splitPaneSize(proposal)
    }

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
        context.coordinator.queueHost.rootView = AnyView(queue.dockThemedRoot())
        context.coordinator.workspaceHost.rootView = AnyView(workspace.dockThemedRoot())
        context.coordinator.inspectorHost.rootView = AnyView(inspector.dockThemedRoot())

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
        let queueHost = splitPaneHost()
        let workspaceHost = splitPaneHost()
        let inspectorHost = splitPaneHost()
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

/// The split views fill whatever SwiftUI offers. Without these, SwiftUI
/// sizes the representable through Auto Layout `fittingSize`, which walks
/// every constraint of the nested transcript on each layout pass — the main
/// cost of scrolling a long conversation.
private func splitPaneSize(_ proposal: ProposedViewSize) -> CGSize {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
}

@MainActor
private func splitPaneHost() -> NSHostingView<AnyView> {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    // The split view places panes by frame; don't publish SwiftUI's
    // intrinsic/min/max size as constraints for the outer layout to solve.
    host.sizingOptions = []
    return host
}

/// Named target proportions for the desktop three-column shell (queue rail /
/// conversation / inspector), applied identically whether the Dock is
/// fullscreen or in its windowed/minimized popover presentation. The center
/// conversation column is intentionally the largest share.
private enum DesktopWorkspaceFractions {
    static let queue: CGFloat = 0.22
    static let conversation: CGFloat = 0.51
    static let inspector: CGFloat = 0.27
    static let minimumConversationWidth: CGFloat = 520
    /// The inner split only sees the space left after the outer queue split,
    /// so its leading fraction must be re-derived against that remainder.
    static let conversationOfRemainder: CGFloat = conversation / (conversation + inspector)
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        splitPaneSize(proposal)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = FractionPreservingSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.fraction = leadingFraction
        splitView.minimumLeadingWidth = minimumLeadingWidth
        splitView.maximumLeadingWidth = maximumLeadingWidth
        splitView.minimumTrailingWidth = minimumTrailingWidth
        splitView.addArrangedSubview(context.coordinator.leadingHost)
        splitView.addArrangedSubview(context.coordinator.trailingHost)
        context.coordinator.splitView = splitView
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.leadingHost.rootView = AnyView(
            leading.dockThemedRoot()
                .overlay(alignment: .trailing) {
                    Color.dockBorderLight.frame(width: DockLayout.hairline)
                }
        )
        context.coordinator.trailingHost.rootView = AnyView(trailing.dockThemedRoot())
        context.coordinator.leadingWidth = leadingWidth
        if let splitView = splitView as? FractionPreservingSplitView {
            splitView.fraction = leadingFraction
            splitView.minimumLeadingWidth = minimumLeadingWidth
            splitView.maximumLeadingWidth = maximumLeadingWidth
            splitView.minimumTrailingWidth = minimumTrailingWidth
        }

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
        let leadingHost = splitPaneHost()
        let trailingHost = splitPaneHost()
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
            (splitView as? FractionPreservingSplitView)?.minimumLeadingPosition
                ?? min(minimumLeadingWidth, max(0, splitView.bounds.width - splitView.dividerThickness - minimumTrailingWidth))
        }

        func maximumLeadingPosition(in splitView: NSSplitView) -> CGFloat {
            if let splitView = splitView as? FractionPreservingSplitView {
                return splitView.maximumLeadingPosition
            }
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

/// Window resizes (e.g. entering fullscreen, moving to a larger display, or
/// dragging the window edge) otherwise dump 100% of the size delta into
/// NSSplitView's trailing subview, silently collapsing a fraction-based
/// layout like 30/40/30 back to whatever raw pixel widths were set at
/// launch. Re-derive the leading position from the stored fraction on every
/// resize so proportional splits stay proportional, unless the person has
/// dragged a divider (tracked via delegate resize-subviews callbacks driven
/// by the divider itself rather than the window).
private final class FractionPreservingSplitView: NSSplitView {
    // AppKit can paint the divider at the old coordinate after a host/window
    // width change. The hosting view paints the hairline at its real edge;
    // this transparent divider still provides the native drag target.
    override var dividerColor: NSColor { .clear }
    var fraction: CGFloat?
    var minimumLeadingWidth: CGFloat = 220
    var maximumLeadingWidth: CGFloat?
    var minimumTrailingWidth: CGFloat = 360
    private var userAdjusted = false
    private var lastAppliedWidth: CGFloat = 0

    var minimumLeadingPosition: CGFloat {
        min(minimumLeadingWidth, max(0, bounds.width - dividerThickness - minimumTrailingWidth))
    }

    var maximumLeadingPosition: CGFloat {
        let availableMaximum = max(minimumLeadingPosition, bounds.width - dividerThickness - minimumTrailingWidth)
        return min(maximumLeadingWidth ?? availableMaximum, availableMaximum)
    }

    override func mouseDown(with event: NSEvent) {
        userAdjusted = true
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        // Cache the width we last applied the fraction to so we only call
        // setPosition() when width actually changes, not on every layout pass.
        // This prevents cascading layout invalidations that cause stuttering.
        guard let fraction, !userAdjusted, bounds.width > 0, bounds.width != lastAppliedWidth,
              arrangedSubviews.count >= 2 else { return }
        lastAppliedWidth = bounds.width
        // Passing an out-of-range fraction lets AppKit clamp the subview but
        // leaves its drawn divider at the requested coordinate. This happens
        // when the inspector closes and the window narrows to 720pt.
        let position = min(max(bounds.width * fraction, minimumLeadingPosition), maximumLeadingPosition)
        setPosition(position, ofDividerAt: 0)
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

/// Reference-type scroll bookkeeping for the transcript. Mutating it does not
/// publish, so high-frequency geometry callbacks stay out of SwiftUI's
/// invalidation graph.
@MainActor
fileprivate final class ConversationTranscriptBookkeeping {
    var lastRenderedMessageBubbleCount = 0
    var rowViewports: [MessageNavigatorViewport] = []
    var documentHeight: CGFloat = 0
    var pendingAnchor: ConversationScrollAnchor?
    /// A history page is mounting; edge checks wait for the next settle.
    var isPaging = false
    var isPastEndRepairScheduled = false
    var isHistoryCompactionScheduled = false
    var consumedTranscriptPrependGeneration = 0
}


/// One conversation in the session picker popover: title, preview, and a
/// single metadata line, with hide and delete kept visible in a quiet color.
private struct SessionPickerRow: View {
    let session: HermesSession
    let projectName: String?
    let isCurrent: Bool
    let canDelete: Bool
    let isUpdatingVisibility: Bool
    let style: DockThemePalette
    let onOpen: () -> Void
    let onToggleHidden: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(session.isHidden ? style.secondaryText : style.primaryText)
                        .lineLimit(1)
                    if let preview = session.displayPreview {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundStyle(style.secondaryText)
                            .lineLimit(1)
                    }
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.leading, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            DockIconButton(
                icon: session.isHidden ? .eye : .eyeSlash,
                label: session.isHidden ? "Show \(session.displayTitle)" : "Hide \(session.displayTitle)",
                isBusy: isUpdatingVisibility,
                size: 24,
                style: style,
                action: onToggleHidden
            )
            DockIconButton(
                icon: .trash,
                label: isCurrent ? "The active conversation cannot be deleted" : "Delete \(session.displayTitle)",
                size: 24,
                style: style,
                action: onDelete
            )
            .disabled(!canDelete)
            .opacity(canDelete ? 1 : 0.4)
            .padding(.trailing, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: DockControlMetrics.cornerRadius, style: .continuous)
                .fill(isCurrent ? style.selectedFill : isHovering ? style.surface4.opacity(0.6) : .clear)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule().fill(style.accent).frame(width: 3, height: 14)
            }
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .dockEase(duration: 0.16), value: isHovering)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            if isCurrent {
                Text("Current")
                    .foregroundStyle(style.accent)
            }
            if session.isHidden {
                DockIconLabel("Hidden", icon: .eyeSlash)
            }
            if let projectName {
                DockIconLabel(projectName, icon: .folder)
                    .truncationMode(.middle)
            }
            if let date = session.lastUpdatedAt {
                Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(style.metadataText)
        .lineLimit(1)
        .padding(.top, 2)
    }
}


/// Sweeps an accent highlight across a working session's title. Static under
/// Reduce Motion; only working rows pay for the timeline.
private struct WorkingTitleShimmer: ViewModifier {
    let isActive: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content.overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    GeometryReader { geo in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                        let band = max(geo.size.width * 0.4, 40)
                        LinearGradient(colors: [.clear, color, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (geo.size.width + band) * phase)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else if isActive {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}
