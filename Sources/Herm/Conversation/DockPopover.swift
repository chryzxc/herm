import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DockPanelSurfaceShape: Shape {
    let isEdgeAttached: Bool
    let cornerRadius: CGFloat
    var edgeSide: EdgeDockSide = .right

    func path(in rect: CGRect) -> Path {
        if isEdgeAttached { return EdgeNotchShape(side: edgeSide).path(in: rect) }
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
    }
}

/// Canonical owner for session workspace presentation state. A document or
/// diff is valid only while both the session and its resolved repository path
/// still match this scope.
struct SessionRepositoryScope: Equatable {
    let sessionID: String
    let repositoryPath: String

    var identity: String { "\(sessionID):\(repositoryPath)" }

    func containsGitRepository(_ snapshot: RepositorySnapshot) -> Bool {
        snapshot.isGitRepository && snapshot.path == RepositorySnapshot.stableID(path: repositoryPath)
    }
}

struct SessionRepositoryPathCache: Equatable {
    let workspace: String
    let path: String

    func path(for workspace: String) -> String? { self.workspace == workspace ? path : nil }
}

struct ScopedRepositoryDocument: Equatable {
    let scope: SessionRepositoryScope
    let document: RepositoryFileDocument
}

struct ScopedRepositoryChange: Equatable {
    let scope: SessionRepositoryScope
    let file: RepositoryFileChange
}

struct ConversationScrollAnchor: Equatable {
    let messageID: UUID
    var offset: CGFloat

    mutating func recordUserScroll(delta: CGFloat) { offset -= delta }

    func correction(rowMinY: CGFloat, visibleTop: CGFloat) -> CGFloat {
        rowMinY - visibleTop - offset
    }
}

@MainActor
final class WorkspaceGeometry {
    var width: CGFloat = 1200
}

struct DockPopover: View {
    @AppStorage(DockWorkspaceScale.preferenceKey) private var textSize = DockWorkspaceScale.defaultTextSize
    @StateObject var expandedReviewRouter = ExpandedReviewRouter()
    @StateObject var hostPresentation = DockHostPresentation()
    @State private var presentationHostID = UUID()
    let model: DockModel
    @State var modelPresentationRevision = 0
    @ObservedObject var panelPresentation: DockPanelPresentation
    let controlCenter: ControlCenterModel
    @State var controlPresentationRevision = 0
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
    @State var isShowingMessageSearch = false
    @State var isShowingMessagePins = false
    @State var pinnedMessageJumpID: UUID?
    @State var sessionRailReplyRequest = 0
    @State var isSessionIdentityHovering = false
    @State var sessionPickerQuery = ""
    @ObservedObject var sidebarSessionSeenStore = SidebarSessionSeenStore.shared
    /// Read-only handle; `SessionPaneRow` observes the panes so this view does not re-render for them.
    var sessionPanes: SessionPaneStore { .shared }
    @State var isSessionMenuHovering = false
    @State var showsSessionRailInChats = true
    @State var showsSessionRailInBots = false
    /// Chats shows the session rail by default; Bots keeps it hidden until toggled.
    var isSessionRailVisible: Bool {
        get { fullscreenSurface == .bots ? showsSessionRailInBots : showsSessionRailInChats }
        nonmutating set {
            if fullscreenSurface == .bots {
                showsSessionRailInBots = newValue
            } else {
                showsSessionRailInChats = newValue
            }
        }
    }
    @State var isRenamingSession = false
    @State var renameDraft = ""
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var conversationPerformance = ConversationPerformanceMonitor()
    @State var isWorkspaceManuallyExpanded = false
    @State var isNarrowLayout = false
    @State var isNarrowControlVisible = true
    @State var selectedChatImage: ChatImagePreview?
    @ObservedObject var filePreview = FilePreviewCenter.shared
    @StateObject var speechInput = SpeechInput()
    @StateObject var voiceOutput = VoiceOutput()
    @StateObject var micLevelMeter = MicLevelMeter()
    @StateObject var messageActionState = ConversationMessageActionState()
    @StateObject var workspaceStore = WorkspaceStore()
    @StateObject var agentUpdateService = HermesUpdateService.shared
    @StateObject var developerWorkflow = DeveloperWorkflowModel.shared
    @StateObject var pullRequestCenter = PullRequestCenterModel(details: .shared)
    @StateObject var issueCenter = IssueCenterModel()
    @StateObject var githubRepositories = GitHubRepositoriesModel()
    @StateObject var gitHubInspector = GitHubInspectorStore()
    @StateObject var pullRequestChatLinks = PullRequestChatLinkStore()
    @State var chatContextRouter = ChatContextRouter()
    @StateObject var repositoryPreferences = CommandCenterPreferencesStore.shared
    @ObservedObject var dockThemeStore = DockThemeStore.shared
    @StateObject var botMode = BotModeModel()
    @StateObject var sessionNavNavigation = SessionNavigationState()
    @State var sessionWorkspaceMode: SessionWorkspaceMode = .chat
    @State var suppressNextVoiceResponse = false
    /// Full voice mode: the voice stage covers the navigation and inspector.
    @State var isVoiceImmersive = false
    @State var sessionPendingDeletion: HermesSession?
    // These selections are owned by the active session/repository scope. The
    // request IDs invalidate completions from an older scope or selection.
    @State var explorerSelection: ScopedRepositoryDocument?
    @State var explorerNavigatorWidth: CGFloat = ExplorerWorkspaceMetrics.initialNavigatorWidth
    @State var selectedChange: ScopedRepositoryChange?
    @State var selectedChangeDiff: RepositoryDiff?
    @State var isLoadingChangeDiff = false
    @State var sourceControlRequestID = UUID()
    @StateObject var sessionPullRequestCenter = PullRequestCenterModel(details: .shared)
    @StateObject var sessionIssueCenter = IssueCenterModel()
    // A restored/active conversation is the primary workspace at launch, so
    // the right pane should open on its session context rather than Today.
    @State var inspectorScope: InspectorScope = .session
    @State var sessionInspectorTabRequest: SessionInspector.TabRequest?
    /// Cached project/repo folder name for the active session.
    /// Only updated when a non-nil value is resolved — never cleared on transient
    /// refresh-cycle gaps where projectIDBySessionID is momentarily empty.
    @State var cachedProjectName: String? = nil
    @State var cachedSessionRepository: SessionRepositoryPathCache? = nil
    @State var lastSessionTitleAtIdentityChange: String?
    @State var isFullscreen = false
    @State var isMissionInspectorVisible = false

    enum FullscreenSurface: Equatable {
        case conversation, pullRequests, issues, chatGrid
        case global
        case artifacts
        case bots
    }
    @AppStorage(ChatViewSettings.gridViewKey) var prefersChatGrid = false
    @State var fullscreenSurface: FullscreenSurface =
        UserDefaults.standard.bool(forKey: ChatViewSettings.gridViewKey) ? .chatGrid : .conversation
    @State var fullscreenGlobalTab: ControlTab = .kanban
    @State var navHistory = NavigationHistory()

    enum SessionWorkspaceMode: CaseIterable, Identifiable {
        case chat
        case voice
        case explorer
        case sourceControl
        case pullRequests
        case issues

        /// Modes that render inside a split column; the rest take the whole workspace.
        var isColumnMode: Bool { self == .chat || self == .voice || self == .pullRequests || self == .issues }

        var id: Self { self }

        var label: String {
            switch self {
            case .chat: "Chat"
            case .voice: "Talk"
            case .explorer: "Explorer"
            case .sourceControl: "Source Control"
            case .pullRequests: "Pull Requests"
            case .issues: "Issues"
            }
        }

        var icon: Ph {
            switch self {
            case .chat: .chatText
            case .voice: .waveform
            case .explorer: .folder
            case .sourceControl: .gitBranch
            case .pullRequests: .gitPullRequest
            case .issues: .circleDashed
            }
        }

        var help: String {
            switch self {
            case .chat: "Text conversation"
            case .voice: "Voice conversation"
            case .explorer: "Browse this session's project files"
            case .sourceControl: "Review this session's repository changes"
            case .pullRequests: "Pull requests for this session's repository"
            case .issues: "Issues for this session's repository"
            }
        }

        /// Whether the inspector renders the selected center content's preview.
        var usesContextPreview: Bool {
            switch self {
            case .explorer, .sourceControl, .pullRequests, .issues: true
            case .chat, .voice: false
            }
        }
    }

    enum InspectorScope: String, CaseIterable, Identifiable {
        case global = "Global"
        case session = "Session"
        case artifacts = "Artifacts"

        var id: Self { self }

        var icon: Ph {
            switch self {
            case .global: .squaresFour
            case .session: .chats
            case .artifacts: .files
            }
        }
    }

    enum QuickPrompt: CaseIterable, Identifiable {
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
        let _ = HermPerformanceRecorder.countBody("DockPopover")
        let _ = modelPresentationRevision
        let _ = controlPresentationRevision
        let _ = workspaceLayoutRevision
        // Bound the root's generic layout before observer modifiers copy its sheet state.
        return observerLayerFour(observerLayerThree(observerLayerTwo(observerLayerOne(AnyView(rootPopoverContent)))))
            .onReceive(model.workspacePresentationChanges) { _ in modelPresentationRevision &+= 1 }
            .onReceive(model.$activityPresentationRevision.dropFirst().receive(on: RunLoop.main)) { _ in
                if sessionWorkspaceMode == .voice { modelPresentationRevision &+= 1 }
            }
            .onReceive(controlCenter.workspacePresentationChanges) { _ in controlPresentationRevision &+= 1 }
            .environment(\.dockWorkspaceScale, CGFloat(DockWorkspaceScale.supportedTextSize(textSize)))
            .environment(\.dockHostVisible, hostPresentation.isVisible)
            .environment(\.dockHostResizing, hostPresentation.isResizing)
            .background { DockHostPresentationObserver(presentation: hostPresentation).frame(width: 0, height: 0) }
            .onChange(of: hostPresentation.isVisible, initial: true) { _, visible in
                model.presentationDemand.update(presentationHostID, visible: visible)
                if visible, model.sessionID != nil {
                    model.refreshDelegationStatus()
                    model.startDelegationMonitoring()
                }
            }
            .onDisappear { model.presentationDemand.update(presentationHostID, visible: false) }
            .onAppear {
                registerPerformanceSources()
                sessionPanes.runtime = model
                sessionPanes.tabStatus.bind(
                    model: model, control: controlCenter, store: workspaceStore, panes: sessionPanes)
            }
            .environment(\.chatContextRouter, chatContextRouter)
            .environment(\.richHostActionRouter, richHostRouter)
            .environment(
                \.sessionUnreadReplies,
                SessionUnreadReplyContext(replies: model.sessionUnreadReplies, profileID: model.profileScopeID)
            )
            .generativeUISession(model: model)
            .overlay(alignment: .bottomTrailing) {
                if let reference = gitHubInspector.opening[WorkspaceIdentity.session(model)] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Opening \(reference.kind == .pullRequest ? "pull request" : "issue") \(reference.title)…")
                            .dockFont(.body)
                            .lineLimit(2)
                    }
                    .dockPadding(10)
                    .dockFloatingSurface(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius), tint: .dockSurface2,
                        stroke: .dockBorderLight
                    )
                    .dockPadding(12)
                    .accessibilityElement(children: .combine)
                    .allowsHitTesting(false)
                }
            }
            // SwiftUI Text links would otherwise open in the default browser.
            .environment(
                \.openURL,
                OpenURLAction {
                    InAppBrowser.open($0)
                    return .handled
                }
            )
            .environment(
                \.markdownOpenURL,
                OpenURLAction { url in
                    openMarkdownURL(url)
                    return .handled
                })
    }

    /// The window's content runs under its transparent titlebar. Columns
    /// below the traffic lights inset by this; the chat and inspector fill it.
    var titlebarInset: CGFloat { usesWindowChrome ? DockWindowChrome.titleRowHeight : 0 }

    /// Narrow panes give up the rail's 52pt so the whole panel keeps its 500pt width.
    var narrowPaneWidth: CGFloat { min(500, panelPresentation.compactWidth) - 52 }

    @AppStorage("herm.chatListCollapsed") var isChatListCollapsed = false
    /// The group room open on the Bots page; empty means the selected bot's chat.
    @AppStorage(BotChatsOrdering.lastRoomKey) var openGroupRoomID = ""
    @State var workspaceGeometry = WorkspaceGeometry()
    @State var workspaceLayoutRevision = 0
    var workspaceLayoutWidth: CGFloat { workspaceGeometry.width }
    var desktopRequiredWidth: CGFloat { 1_110 }
    var conversationMessageMaxWidth: CGFloat { conversationMetrics.readingWidth }
    var navigatorMinimumConversationWidth: CGFloat { 820 }

    var voiceMode: some View { voiceStage(immersive: false) }

}
