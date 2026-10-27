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

struct ConversationScrollAnchor: Equatable {
    let messageID: UUID
    var offset: CGFloat

    mutating func recordUserScroll(delta: CGFloat) { offset -= delta }

    func correction(rowMinY: CGFloat, visibleTop: CGFloat) -> CGFloat {
        rowMinY - visibleTop - offset
    }
}

struct DockPopover: View {
    @StateObject var expandedReviewRouter = ExpandedReviewRouter()
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
    @State var isShowingMessageSearch = false
    @State var isShowingMessagePins = false
    @State var pinnedMessageJumpID: UUID?
    @State var sessionRailReplyRequest = 0
    @State var isSessionIdentityHovering = false
    @State var sessionPickerQuery = ""
    @ObservedObject var sidebarSessionSeenStore = SidebarSessionSeenStore.shared
    @State var isSessionMenuHovering = false
    @State var isSessionRailVisible = false
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
    @StateObject var gitHubInspector = GitHubInspectorStore()
    @StateObject var pullRequestChatLinks = PullRequestChatLinkStore()
    @State var chatContextRouter = ChatContextRouter()
    @StateObject var repositoryPreferences = CommandCenterPreferencesStore.shared
    @ObservedObject var dockThemeStore = DockThemeStore.shared
    @StateObject var botMode = BotModeModel()
    @StateObject var missionControlNavigation = MissionControlNavigationState()
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
    @State var cachedSessionRepositoryPath: String? = nil
    @State var lastSessionTitleAtIdentityChange: String?
    @State var isFullscreen = false
    @State var isMissionInspectorVisible = false

    enum FullscreenSurface: Equatable {
        case conversation, pullRequests, issues, chatGrid
        case global
        case artifacts
        case bots
        case groupChat(String)
    }
    @AppStorage(ChatViewSettings.gridViewKey) var prefersChatGrid = false
    @State var fullscreenSurface: FullscreenSurface =
        UserDefaults.standard.bool(forKey: ChatViewSettings.gridViewKey) ? .chatGrid : .conversation
    @State var fullscreenGlobalTab: ControlTab = .kanban

    enum SessionWorkspaceMode: CaseIterable, Identifiable {
        case chat
        case voice
        case explorer
        case sourceControl
        case pullRequests
        case issues

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
        // Bound the root's generic layout before observer modifiers copy its sheet state.
        observerLayerFour(observerLayerThree(observerLayerTwo(observerLayerOne(AnyView(rootPopoverContent)))))
            .environment(\.chatContextRouter, chatContextRouter)
            .environment(\.richHostActionRouter, richHostRouter)
            .generativeUISession(model: model)
            .overlay(alignment: .bottomTrailing) {
                if let reference = gitHubInspector.opening[WorkspaceIdentity.session(model)] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Opening \(reference.kind == .pullRequest ? "pull request" : "issue") \(reference.title)…")
                            .dockFont(.body)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .dockFloatingSurface(
                        RoundedRectangle(cornerRadius: DockLayout.controlRadius), tint: .dockSurface2,
                        stroke: .dockBorderLight
                    )
                    .padding(12)
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
    @State var workspaceLayoutWidth: CGFloat = 1200
    var desktopRequiredWidth: CGFloat { 1_110 }
    var conversationMessageMaxWidth: CGFloat { conversationMetrics.readingWidth }
    var navigatorMinimumConversationWidth: CGFloat { 820 }

    var voiceMode: some View { voiceStage(immersive: false) }

}
