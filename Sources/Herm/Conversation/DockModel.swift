import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// A parsed session-resume transcript. Image attachment is deferred: only
/// file references are parsed synchronously so session selection never
/// performs disk reads or image decoding on the main actor.
struct RestoredTranscript {
    let messages: [ChatMessage]
    /// Stored Hermes row id of each message that carried one.
    var rowIDs: [Int: UUID] = [:]
    /// Tool calls after the last reply: a turn still running, possibly in
    /// another process (a Bot's `hermes chat -Q`), or one that died.
    var trailingActivity: [ActiveToolCall] = []
}

@MainActor
@Observable
final class DockWorkspaceStartup {
    enum Phase {
        case resolvingProfile, loadingSessions, finished
    }

    var phase: Phase = .resolvingProfile
}

@MainActor
final class DockModel: ObservableObject {
    let presentationDemand = DockPresentationDemand()
    let workspaceStartup = DockWorkspaceStartup()
    lazy var botMode = makeBotMode()
    lazy var workspacePresentationChanges = makeWorkspacePresentationChanges()
    lazy var composerPresentationChanges = makeComposerPresentationChanges()
    lazy var inspectorPresentationChanges = makeInspectorPresentationChanges()
    var interruptionCoordinator: HermInterruptionCoordinator?
    var completionNoticeIDs: [String: String] = [:]
    var quickSessionOwners: [String: QuickDestination] = [:] {
        didSet { sessionEventOwnersChanged?() }
    }
    /// Set on the main model only: returns true when a detached window took the session,
    /// so no opener (Spotlight, notch, history, task rows) shows it in two places.
    var focusDetachedSession: ((String) -> Bool)?
    /// Hermes keeps a runtime alive after Herm switches away; its approval and
    /// clarify requests carry only the runtime sid, so rows need the durable id.
    var storageIDsByRuntimeID: [String: String] = [:]
    @Published var status: HermesStatus = .idle
    @Published var isHermesConnected = false
    /// Why Hermes is offline, from the gateway's last failure.
    @Published private(set) var hermesConnectionIssue: String?
    @Published var messages: [ChatMessage] = [] {
        didSet {
            messagesRevision &+= 1
            messageNavigatorRevision &+= 1
            navigatorChangedRows = nil
        }
    }
    private(set) var messagesRevision: UInt64 = 0
    var cachedMessageNavigatorItems: MessageNavigatorProjection.Result?
    var messageNavigatorRevision: UInt64 = 0
    var messageNavigatorTimelineRevision: UInt64 = 0
    /// Nil is a structural change. Known appends and edits restore the exact indices.
    var navigatorChangedRows: Set<Int>?

    let composer = ComposerText()
    var composerDrafts: [SessionComposerDraft.Key: SessionComposerDraft] = [:]
    private var forwardDrafts: [ForwardToBotDraft.Key: ForwardToBotDraft] = [:]

    func forwardDraft(for key: ForwardToBotDraft.Key) -> ForwardToBotDraft {
        if let draft = forwardDrafts[key] { return draft }
        let draft = ForwardToBotDraft()
        forwardDrafts[key] = draft
        return draft
    }

    @Published var pendingSessionSends: [SessionPendingSend] = []
    var deliveryRowClaims: [SessionComposerDraft.Key: [Int: UUID]] = [:]
    @Published var deliveryChecksInFlight: Set<SessionComposerDraft.Key> = []
    @Published var deliveryCheckNotes: [SessionComposerDraft.Key: String] = [:]
    var sessionStopAttempts: [SessionComposerDraft.Key: SessionStopAttempt] = [:]
    let streamingText = StreamingText()
    /// Unflushed-to-step reasoning, observed only by an open live thought row.
    let liveReasoning = LiveReasoningText()

    /// Message the next prompt replies to; sent as a leading quote line (see ReplyQuote).
    @Published var replyQuote: ReplyQuote?
    @Published var pinnedMessages: [PinnedMessage] = [] {
        didSet {
            pinnedMessageUIDs = Set(pinnedMessages.map(\.uid))
            pinnedMessageRowIDs = Set(pinnedMessages.map(\.rowID))
        }
    }
    var pinnedMessageUIDs: Set<String> = []
    var pinnedMessageRowIDs: Set<Int> = []
    @Published var messagePinsSupported = false
    let messagePinStore: MessagePinStore
    @Published var isLoadingMessagePins = false
    @Published var updatingMessagePinRowID: Int?
    var isUpdatingMessagePin: Bool { updatingMessagePinRowID != nil }
    @Published var messagePinError: String?
    @Published var messagePinMutationFeedback: MessagePinMutationFeedback?
    @Published var storedMessageReferences: [UUID: StoredMessageReference] = [:]

    @Published var pendingImages: [ImageAttachment] = []
    /// Context chips prepended to the next prompt (Kanban cards, PRs, issues).
    @Published var attachedContexts: [ChatContext] = []
    @Published var pendingPDFURLs: [URL] = []
    @Published var pendingPDFError: String?
    @Published var extractingImageTextIDs: Set<UUID> = []
    @Published var pendingAttachmentError: String?
    @Published var isSending = false
    @Published var steeringError: String?
    /// Prompts typed during a turn that could not reach it (attachments, a
    /// blocked approval, or a turn that ended first). Not yet submitted, so
    /// removable; sent one per turn once Hermes settles (desktop parity).
    @Published var queuedPrompts: [QueuedPrompt] = []
    var queuedSubmissions: [String: UUID] = [:] {
        didSet { if oldValue != queuedSubmissions { queuedSubmissionChanges.send() } }
    }
    let queuedSubmissionChanges = PassthroughSubject<Void, Never>()
    // Hold newer input until a redirect resolves or its Hermes-queued follow-up finishes.
    @Published var redirectingPrompts: [String: RedirectingPrompt] = [:]
    /// Resume may replace the runtime handle; unsent prompts belong to the
    /// durable conversation, not to that temporary handle.
    var queuedPromptSessionID: String? { sessionStorageID ?? sessionID }
    /// A queued prompt open for editing is never auto-sent; when its turn
    /// comes it moves into the composer instead.
    @Published var approvalTitle: String?
    @Published var approvalText: String?
    /// Full request (reason, offered choices, request id) behind `approvalTitle`/`approvalText`.
    @Published var approvalDetails: ApprovalPresentation?
    @Published var conversationApprovals: [ConversationApproval] = []
    var pendingApprovalsBySessionID: [String: PendingApproval] = [:] {
        didSet { refreshSessionAttention() }
    }
    var pendingApprovalAliasesBySessionID: [String: Set<String>] = [:]
    var activeClarification: PendingClarification?
    var pendingClarificationsBySessionID: [String: PendingClarification] = [:] {
        didSet { refreshSessionAttention() }
    }

    @Published var sessionAttention: [String: SessionAttention] = [:] {
        didSet { syncBotActivitySignals() }
    }
    @Published var attentionAnswers: [AttentionRequest: AttentionAnswerState] = [:]

    var pendingClarificationAliasesBySessionID: [String: Set<String>] = [:]
    var resolvedClarificationRequestIDs = Set<String>()
    var resolvedClarificationRequestIDOrder: [String] = []
    @Published var clarificationQuestion: String?
    @Published var clarificationChoices: [String] = []
    @Published var clarificationMultiSelect = false
    /// "Question 2 of 3" while answering a batch.
    @Published var clarificationProgress: String?
    /// A sudo / secret / vault prompt Hermes is blocked on.
    @Published var valuePrompt: ValuePrompt?
    @Published var valuePromptError: String?
    @Published var isRespondingToValuePrompt = false
    /// Hermes assigns this identifier to the blocking clarify request. A reply
    /// must echo it so the backend can release the exact waiting turn.
    @Published var clarificationRequestID: String?
    /// A clarification request is an event with a stable Hermes ID. Gate a
    /// replay at the event boundary so it cannot become a second transcript
    /// bubble after the user has already answered it.
    var presentedClarificationRequestIDs = Set<String>()
    @Published var clarificationResponseError: String?
    @Published var isRespondingToClarification = false
    @Published var isRespondingToApproval = false
    private var updatingSessionMetadata = false

    /// A replacement produced by this call keeps every row's identity and position.
    func updateSessionMetadata(_ update: () -> Void) {
        let wasUpdating = updatingSessionMetadata
        updatingSessionMetadata = true
        defer { updatingSessionMetadata = wasUpdating }
        update()
    }

    private(set) var recentIndexByID: [String: Int] = [:]
    private(set) var pinnedIndexByID: [String: Int] = [:]
    private(set) var allBotIndexByID: [String: Int] = [:]
    private(set) var sessionIndexRevision: UInt64 = 0
    private let archivedSidebarMutations = CurrentValueSubject<UInt64, Never>(0)
    var archivedSidebarMutationRevision: UInt64 { archivedSidebarMutations.value }
    var archivedSidebarMutationUpdates: AnyPublisher<UInt64, Never> {
        archivedSidebarMutations.eraseToAnyPublisher()
    }

    func invalidateArchivedSidebar() {
        archivedSidebarMutations.send(archivedSidebarMutationRevision &+ 1)
    }

    private static func indices(_ rows: [HermesSession]) -> [String: Int] {
        Dictionary(rows.indices.lazy.map { (rows[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    @Published var sessions: [HermesSession] = [] {
        didSet {
            sessionIndexRevision &+= 1
            if !updatingSessionMetadata {
                recentIndexByID = Self.indices(sessions)
                syncBotActivitySignals()
            }
        }
    }
    /// What each session is doing right now (its latest tool), read from the
    /// global gateway stream so sessions that are not open can show it too.
    // Only the edge dock consumes these; background tools must not invalidate
    // every workspace view observing DockModel.
    private let sessionActivityLabelSubject = PassthroughSubject<Void, Never>()
    private let sessionActivityLabelChannels =
        NSMapTable<NSString, PassthroughSubject<Void, Never>>.strongToWeakObjects()
    private(set) var sessionActivityLabels: [String: String] = [:]

    func setSessionActivityLabel(_ label: String?, sessionID: String) {
        guard sessionActivityLabels[sessionID] != label else { return }
        sessionActivityLabels[sessionID] = label
        sessionActivityLabelChannels.object(forKey: sessionID as NSString)?.send()
        sessionActivityLabelSubject.send()
    }

    var sessionActivityLabelUpdates: AnyPublisher<Void, Never> {
        sessionActivityLabelSubject.prepend(()).eraseToAnyPublisher()
    }

    private let liveBotWorkSubject = PassthroughSubject<Void, Never>()
    private(set) var liveBotWork: [BotLiveWork] = []
    var liveBotWorkUpdates: AnyPublisher<Void, Never> {
        liveBotWorkSubject.eraseToAnyPublisher()
    }

    func updateLiveBotWork(_ work: [BotLiveWork]) {
        guard liveBotWork != work else { return }
        liveBotWork = work
        liveBotWorkSubject.send()
    }

    func observeSessionActivityLabel(
        ids: [String], receive: @escaping (String?) -> Void
    ) -> AnyCancellable {
        let channels = Set(ids).map { id -> PassthroughSubject<Void, Never> in
            let key = id as NSString
            if let channel = sessionActivityLabelChannels.object(forKey: key) { return channel }
            let channel = PassthroughSubject<Void, Never>()
            sessionActivityLabelChannels.setObject(channel, forKey: key)
            return channel
        }
        let subscription = Publishers.MergeMany(channels).prepend(())
            .map { [weak self] in ids.lazy.compactMap { self?.sessionActivityLabels[$0] }.first }
            .removeDuplicates()
            .sink(receiveValue: receive)
        return AnyCancellable { withExtendedLifetime(channels) { subscription.cancel() } }
    }
    @Published var todoPlan: TodoPlan?
    /// Bumped each time the wake phrase wakes voice mode.
    @Published var wakeCount = 0
    @Published var sessionProjectionState: HermesProjectionState<[HermesSession]> = .empty
    @Published var isShowingSessions = false
    @Published var isLoadingSessions = false
    /// Background polls stay unpublished: flipping `isLoadingSessions` rebuilt
    /// the whole sidebar rail twice per poll and stuttered its scrolling.
    var isPollingSessions = false
    /// Older rows are reused between full history reads. Each `/api/sessions`
    /// page ranks every stored session in Hermes, so a full walk costs one
    /// ranking per 100 sessions; only cold start, a profile switch, an explicit
    /// refresh, or an expired window pays for it.
    var sessionHistoryLoadedAt: (profileID: String?, date: Date)?
    /// Each visited profile's last conversation list and open chat, by
    /// profile ID, so switching back shows it while Hermes is re-read.
    var retainedProfileSessions: [String: RetainedProfileSessions] = [:]
    // Pin evidence is independent of whether the older history pages finished.
    var knownProfilePins: [ProfileScopedID: HermesSession] = [:]
    var supersededPinScanByProfile: [String: Task<Void, Never>] = [:]
    var supersededPinScanBySession: [ProfileScopedID: Task<Void, Never>] = [:]
    /// Set by a profile switch and cleared by the scoped read that carries the
    /// target profile's authoritative pins, so the merged Pinned section keeps
    /// the rows it already knew while that read is in flight.
    var awaitingScopedPinsAfterSwitch = false {
        didSet {
            guard awaitingScopedPinsAfterSwitch != oldValue else { return }
            sidebarPinChanges.send()
        }
    }
    let sidebarPinChanges = PassthroughSubject<Void, Never>()
    /// When the last session index read finished, for spacing activity refreshes.
    var lastSessionIndexReadAt: Date?
    /// One deferred read that absorbs a burst of completion/database events.
    var sessionIndexRefreshTask: Task<Void, Never>?
    let refreshesSessionIndexFromEvents: Bool
    /// ponytail: fixed 3s spacing between activity-driven index reads; tune if
    /// sidebar titles feel late after back-to-back bot turns.
    var sessionIndexActivitySpacing: TimeInterval = 3
    /// A live event can arrive while the initial session index is loading.
    /// Retain one follow-up refresh so the navigation list cannot get stuck on
    /// the snapshot that predated that event.
    var pendingSessionIndexRefresh = false
    @Published var deletingSessionID: String?
    @Published var sessionDeletionError: String?
    @Published var sessionVisibilityError: String?
    @Published var updatingSessionVisibilityID: String?
    /// Sessions carrying Hermes' durable pin flag (`sessions.pinned`) — the
    /// same flag Hermes Desktop's Pinned section and `hermes sessions pin` use.
    @Published var pinnedSessions: [HermesSession] = [] {
        didSet {
            sessionIndexRevision &+= 1
            if !updatingSessionMetadata {
                pinnedIndexByID = Self.indices(pinnedSessions)
                syncBotActivitySignals()
            }
        }
    }
    @Published var pinningSessionID: String?
    /// The conversation a `session.workspace.move` is in flight for.
    @Published var movingSessionToProjectID: String?
    /// Recent sessions across every bot profile, for the agent-grouped sidebar.
    @Published var allBotSessionsState: HermesProjectionState<[HermesSession]> = .loading {
        didSet {
            if !updatingSessionMetadata {
                switch allBotSessionsState {
                case .ready(let rows):
                    allBotIndexByID = Self.indices(rows)
                    if allBotSessionsTask == nil, !isPatchingAllProfilePins { reconcileScannedPins(rows) }
                case .stale(let rows, _): allBotIndexByID = Self.indices(rows)
                default: allBotIndexByID = [:]
                }
                syncBotActivitySignals()
            }
        }
    }
    var allBotSessionsTask: Task<Void, Never>? {
        didSet {
            if let task = oldValue, allBotSessionsTask == nil {
                // Equal scan results do not republish Recents, but are new pin evidence.
                if allBotSessionsLoadedAt != pinScanStartedWithLoadedAt, case .ready(let rows) = allBotSessionsState {
                    reconcileScannedPins(rows, from: task)
                }
                supersededPinScanByProfile = supersededPinScanByProfile.filter { $0.value != task }
                supersededPinScanBySession = supersededPinScanBySession.filter { $0.value != task }
            } else if allBotSessionsTask != nil {
                pinScanStartedWithLoadedAt = allBotSessionsLoadedAt
            }
        }
    }
    private var pinScanStartedWithLoadedAt: Date?
    var isPatchingAllProfilePins = false
    var sessionTranscriptPreloadTask: Task<Void, Never>?
    var allBotSessionsLoadedAt: Date?
    /// Coalesces Bot activity signal syncs into one pass per main-actor turn.
    var botActivitySyncPending = false
    /// `botMode` is lazy and binding it starts group-chat and roster reads,
    /// so session events never create it; it syncs once when it is built.
    var isBotModeLoaded = false
    /// Throttles roster reads asked for by sessions no list holds yet.
    var unknownSessionRosterRefreshAt: Date?
    let sessionPinService = HermesSessionPinService()
    var actionErrors = DockActionErrorCenter.shared
    @Published var renamingSessionID: String?
    @Published var isRestoringSession = false {
        didSet { sessionEventOwnersChanged?() }
    }
    @Published var isCreatingSession = false
    @Published var currentSessionTitle: String?
    var autoTitleAttempts: Set<String> = []
    var conversationActivityPhase: ConversationActivityPhase = .idle {
        didSet { if oldValue != conversationActivityPhase { scheduleActivityPresentation() } }
    }
    @Published var interruptState: InterruptState = .idle
    @Published var isShowingReasoning = false
    @Published private(set) var browserActivityID: String?
    var activeToolCalls: [ActiveToolCall] = [] {
        didSet {
            guard oldValue != activeToolCalls else { return }
            let browser = activeToolCalls.last { !$0.isComplete && $0.name.hasPrefix("browser_") }?.id
            if browserActivityID != browser { browserActivityID = browser }
            if streamingMessageID != nil {
                Self.upsert(
                    splitOffCallIDs.isEmpty
                        ? activeToolCalls : activeToolCalls.filter { !splitOffCallIDs.contains($0.id) },
                    into: &streamingTurnActivity)
            }
            scheduleActivityPresentation()
            narrateLatestToolSteps()
        }
    }
    /// Voice-stage state the notch, island and Talk views observe instead of the whole model.
    let voiceStage = VoiceStageState()
    /// One-shot Hermes reminders counting down in the notch; Control Center feeds it the cron list.
    let voiceTimers: VoiceTimerBoard
    var toolNarrations: [String: String] {
        get { voiceStage.toolNarrations }
        set { voiceStage.toolNarrations = newValue }
    }
    var dismissedVoicePreviewTurn: UUID?? {
        get { voiceStage.dismissedVoicePreviewTurn }
        set { voiceStage.dismissedVoicePreviewTurn = newValue }
    }
    var voiceRevealedTab: VoiceTabReveal? {
        get { voiceStage.voiceRevealedTab }
        set { voiceStage.voiceRevealedTab = newValue }
    }
    var pendingToolNarrations: Set<String> = []
    /// Every tool call of the in-flight response. `activeToolCalls` resets on
    /// each `message.start`; this log survives until the turn commits onto
    /// its message.
    var streamingTurnActivity: [ActiveToolCall] = []
    /// Calls already committed to an earlier row of a split live turn, so
    /// `activeToolCalls` doesn't re-add them to the new row.
    var splitOffCallIDs: Set<String> = []
    /// The turn log of a session left while its turn was still running,
    /// keyed by stored session ID, so returning to it restores its steps.
    var inFlightTurnActivityBySessionID: [String: [ActiveToolCall]] = [:]
    /// User messages sent into a running turn that Hermes may not have stored
    /// yet (a steer waits in memory for the current tool batch), keyed like
    /// `inFlightTurnActivityBySessionID`, so a reload cannot drop them.
    var unconfirmedUserMessagesBySessionID: [String: [ChatMessage]] = [:]
    @Published var hasUnreadResponse = false
    @Published var completionNotificationsEnabled: Bool
    var recentEvents: [AgentEvent] = [] { didSet { if oldValue != recentEvents { scheduleActivityPresentation() } } }
    var activeSubagents: [HermesSubagent] = [] {
        didSet { if oldValue != activeSubagents { scheduleActivityPresentation() } }
    }
    var sessionAgents: [HermesSubagent] = [] {
        didSet { if oldValue != sessionAgents { scheduleActivityPresentation() } }
    }
    var agentActivities: [AgentActivity] = [] {
        didSet { if oldValue != agentActivities { scheduleActivityPresentation() } }
    }
    /// The sole UI invalidation signal for high-frequency agent activity.
    /// Canonical arrays above update immediately; this revision is coalesced.
    let activityPresentation = DockActivityPresentation()
    var activityPresentationRevision: Int {
        get { activityPresentation.revision }
        set { activityPresentation.revision = newValue }
    }
    /// Changes whenever the active session proves an exact Kanban task
    /// reference through a Hermes tool event. Views observe this instead of
    /// waiting for their periodic Kanban refresh.
    @Published var observedKanbanTaskRevision = 0
    @Published var backgroundTasks: [HermesBackgroundTask] = []
    @Published var runtimeConfiguration: HermesRuntimeConfiguration?
    var runtimeConfigurationRefresh = HermesRuntimeConfigurationRefresh()
    var isRuntimeModelMutationPending = false
    var runtimeModelMutationError: String?
    @Published var isLoadingRuntimeConfiguration = false
    @Published var runtimeConfigurationError: String?
    @Published var runtimeModelOptionsError: String?
    @Published var isLoadingRuntimeModelOptions = false
    @Published var runtimeConfigurationProjectionState: HermesProjectionState<HermesRuntimeConfiguration> = .empty
    @Published var runtimeModelOptions: [HermesModelOption] = []
    var runtimeModelOptionsRefreshGeneration = 0
    @Published var sessionModelOptionID: String?
    /// Hermes' resolved default provider/model, reported by sessionless `model.options`.
    @Published var defaultModelOptionID: String?
    /// The canonical session response can provide a model before the optional
    /// catalog has resolved its provider/model option identity.
    @Published var sessionModelValue: String?
    @Published var isUpdatingSessionModel = false
    @Published var sessionReasoningVariant: HermesReasoningVariant?
    @Published var sessionReasoningWire: String?
    /// Hermes' live service tier for the session (`fast` in session info); nil until reported.
    @Published var sessionFastEnabled: Bool?
    @Published var pendingSessionFastEnabled: Bool?
    @Published var isUpdatingSessionFast = false
    var sessionFastRevision = 0
    var sessionInfoSequencesBySessionID: [String: Int] = [:]
    @Published var sessionWorkspace: HermesSessionWorkspace?
    var sessionWorkspaceRevision = 0
    var pendingWorktreeDirectory: String?
    var pendingWorktreeDirectories: [String: String] = [:]
    @Published var isUpdatingSessionReasoning = false
    @Published var defaultReasoningVariant: HermesReasoningVariant?
    @Published var draftReasoningVariant: HermesReasoningVariant?
    @Published var sessionReasoningStale = false
    @Published var effortCatalog: HermesEffortCatalog?
    var sessionReasoningRevision = 0
    var sessionReasoningMutationToken, sessionModelMutationToken: UUID?
    @Published var voiceState: HermesVoiceState = .inactive {
        didSet {
            if oldValue != voiceState {
                syncVoiceCapture(
                    preservingUtterance: oldValue == .thinking && voiceState == .listening && voiceReplySilenced)
            }
        }
    }
    @Published var voiceTelemetry = VoiceTurnTelemetry()
    @Published var voiceSpokenCaption: String?
    /// Spoken replies are enabled only for the conversation that owns voice.
    @Published var voiceRepliesEnabled = true
    /// Keeps the call open with the microphone closed.
    @Published var isVoiceMicMuted = false {
        didSet { if oldValue != isVoiceMicMuted { syncVoiceCapture() } }
    }
    /// The one on-device voice engine. Every voice surface (Talk tab, notch)
    /// reads it, so capture never depends on which view is mounted.
    lazy var voiceMic = MicLevelMeter()
    let voiceCapture: VoiceCaptureCoordinator
    var mountedTalkStages: Int {
        get { voiceStage.mountedTalkStages }
        set { voiceStage.mountedTalkStages = newValue }
    }
    /// Words said after a cold "hey <name>", sent once the call is listening.
    var pendingWakeRequest: String?
    let voiceAssistant = VoiceAssistantSession()
    /// The idle wake-word preference last applied to the mic.
    var appliedIdleWake = false
    @Published var composerFocusRequest = 0
    @Published var isComposerEditing = false
    @Published var scrollToLatestMessageRequest = 0
    var positionsAtUnreadOnResume = true
    @Published var unreadDividerMessageID: UUID?

    /// The default bot's name from Hermes' roster, so a rename reaches the
    /// menu bar and the voice wake phrase without editing SOUL.md.
    @Published var defaultBotName: String?

    let gateway: HermesGateway?
    var focusProjectedSession: ((HermesSession, String?) -> Bool)?
    var richGenerationContextProvider: ((QuickDestination) -> RichGenerationContext)?
    let sessionRPCClient: HermesRPCClientProtocol
    lazy var sessionUnreadReplies = SessionUnreadReplies(client: sessionRPCClient)
    var quickWorkflowClient: HermesRPCClientProtocol { sessionRPCClient }
    let interruptRPC: HermesControlRPC
    let eventRouter = HermesEventRouter()
    var sessionEventOwnersChanged: (() -> Void)?
    @Published var sessionID: String? {
        didSet {
            sessionEventOwnersChanged?()
            if let voiceSessionID, voiceSessionID != sessionID { stopVoiceConversation() }
        }
    }
    @Published var sessionControl: HermesSessionControl?
    @Published var sessionControlOwner: String?
    @Published var sessionControlStale = false
    var sessionControlEventGeneration = 0
    /// Authoritative `session.usage` total, keyed by the session it was read for
    /// so a switch never shows the previous chat's count.
    @Published var sessionTokenUsage: (sessionID: String, total: Int)?
    /// Context-window occupancy from the same usage payloads (`context_used` is
    /// the last prompt size, not lifetime throughput). Hermes omits the fields
    /// right after a compaction until the next API call measures again, so
    /// the previous reading is kept rather than cleared.
    @Published var sessionContextUsage: (sessionID: String, used: Int, max: Int)?
    /// Set by `status.update` `compacting`/`compressing`, cleared by
    /// `compacted`/`ready` or turn end.
    @Published var compactingSessionID: String?
    /// Canonical Hermes profile used by new chats and profile-owned
    /// navigation projections. This is intentionally separate from
    /// `activeBotProfileID`, which identifies an open canonical Bot Chat.
    @Published var profileScopeID: String?
    @Published var profileScopeUnavailable = false

    @Published var sessionProfileID: String? {
        didSet {
            if voiceSessionID != nil,
                (voiceProfileID ?? "default") != (sessionProfileID ?? profileScopeID ?? "default")
            {
                stopVoiceConversation()
            }
        }
    }
    /// Profile identity for a profile-scoped Bot Chat. This is authoritative
    /// session context, not an inference from the assistant's prose.
    @Published var activeBotProfileID: String?
    @Published var activeBotDisplayName: String?
    /// Explicit Bot dispatches are retained by their origin session. This is
    /// presentation state, not a second transcript or task database.
    @Published var botActivityBySessionID: [String: [BotActivityRecord]] = [:]
    @Published var botActivityRevision = 0
    /// The latest step each working Bot DM is on, keyed by record id.
    @Published var botLiveSteps: [String: String] = [:]
    var inFlightBotActivities: [String: InFlightBotActivity] = [:] {
        didSet { sessionEventOwnersChanged?() }
    }
    let botActivityStore: BotActivityStore
    let botActivityWriter: BotActivityWriter
    @Published var sessionStorageID: String? {
        didSet { sessionEventOwnersChanged?() }
    }
    /// The id session.list rows carry for the open chat. Hermes streams under
    /// a runtime alias (`session_id`) that differs from the stored key.
    var navigationSessionID: String? { sessionStorageID ?? sessionID }
    /// The durable identifier selected by the user for session-scoped durable
    /// projections. Gateway resume may return a transient alias for streaming,
    /// which must not replace the Kanban attribution boundary.
    var kanbanAttributionSessionID: String? {
        didSet { sessionEventOwnersChanged?() }
    }
    /// A Kanban task may legitimately have no `session_id` in Hermes' durable
    /// store. Keep only exact task IDs seen in a tool command/result for the
    /// owning chat session; do not infer ownership from titles or assignees.
    var observedKanbanTaskIDsBySessionID: [String: Set<String>] = [:]
    let transcriptPresentationChanges = PassthroughSubject<Void, Never>()
    var streamingMessageID: UUID? { didSet { transcriptPresentationChanges.send() } }
    var streamingResponseStartedAt: Date?
    /// When the AI began the current turn, per session. Survives session switches and live-row rebuilds; cleared when the turn completes.
    var turnStartedAtBySession: [String: Date] = [:]
    var streamingMessageSessionID: String?
    /// A clarification resumes an already-running Hermes turn. Some Hermes
    /// versions continue with deltas only, without another `message.start`.
    /// Reserve the next transcript slot so those deltas stay after the user's
    /// answer instead of updating the pre-clarification assistant row.
    var isAwaitingClarificationResume = false
    // Keep one append-only buffer. Joining every received chunk during each
    // UI flush made long responses progressively more expensive.
    var streamingMessageBuffer = ""
    var streamingMessagePendingPresentationDelta = ""
    var streamingMessagePublishedSuffix = ""
    var streamingMessageFlushTask: Task<Void, Never>?
    var activityPresentationTask: Task<Void, Never>?
    var streamingMessageGeneration = 0
    var streamingMessageIsVisionNotice = false
    /// A single backend turn may report the same failure through both `error`
    /// and `message.complete`. Keep terminal error presentation idempotent for
    /// that turn without collapsing identical errors from later turns.
    var didAppendTerminalErrorForCurrentTurn = false
    var streamingReasoningBuffer = ""
    var reasoningFlushTask: Task<Void, Never>?
    var lastAgentStateCacheAt: Date?
    var agentStateCacheTrailingTask: Task<Void, Never>?
    var didRestoreLatestSession = false
    /// A backend session may only be created after the user explicitly starts
    /// a new chat. Resuming an existing session never grants this permission.
    var newSessionCreationAuthorized = false
    var newSessionProjectPath: String?
    /// True when the user picked `newSessionProjectPath` in the new-chat project picker, so the
    /// created session is grouped under that project straight away.
    var newSessionProjectWasPicked = false
    /// Called with the stable session id and project path once a picked-project chat exists.
    var onPickedProjectSessionCreated: ((String, String) -> Void)?
    /// Project path each chat was created in, so project navigation can place
    /// a new chat before the project tree reports it.
    var createdSessionProjectPaths: [String: String] = [:]
    var currentModelName: String?
    var isPopoverVisible = false
    var isRefreshingDelegationStatus = false
    var delegationRefreshTask: Task<Void, Never>?
    var delegationRefreshRequested = false
    var lastDelegationRefreshAt: Date = .distantPast
    /// Hermes stamps gateway events with a per-session sequence. Keep a
    /// bounded de-duplication window so reconnect replay and live delivery
    /// can safely share the same projection path.
    var gatewayReplayEpoch: String?
    var processedGatewaySequencesBySessionID: [String: Set<Int>] = [:]
    var highestGatewaySequenceBySessionID: [String: Int] = [:]
    var gatewayReplayTask: Task<Void, Never>?
    var gatewayReplayInFlight = Set<String>()
    var delegationMonitoringTask: Task<Void, Never>?
    var externalTurnWatchTask: Task<Void, Never>?
    var synthesizedSubagentIDs: Set<String> = []
    var cachedAgentSnapshot: AgentPresentationSnapshot?
    var cachedAgentSnapshotInputs: ([HermesSubagent], [AgentActivity], [ActiveToolCall])?
    var agentSnapshotRevision: UInt = 0
    var agentStateBySessionID: [String: SessionAgentState] = [:]
    let agentStateStore: SessionAgentStateStore
    let agentStateWriter: SessionAgentStateWriter
    /// The latest ordered agent-state commit; tests await it before relaunching.
    var agentStateCommit: Task<Void, Never>?
    var sessionResumeGeneration = 0
    var confirmedBotSelection: (generation: Int, profileID: String, runtimeID: String, pointer: String)?
    // Gateway ownership is independent of the cursor displayed by the reader.
    enum StoredTranscriptAttach {
        case awaitingOwnership
        case publishing
    }
    var storedTranscriptAttach: StoredTranscriptAttach?
    var pendingAttachedEvents: [(type: String, params: [String: Any])] = []
    let sessionTranscriptCache: SessionTranscriptCache
    let ownsSessionTranscriptCache: Bool
    @Published var sessionTranscriptPreview: SessionTranscriptPreview?
    @Published var sessionTranscriptLoadState: SessionTranscriptLoadState = .ready
    var sessionActionsReady: Bool { sessionTranscriptLoadState.allowsActions }
    var displayedTranscriptMessages: [ChatMessage] { sessionTranscriptPreview?.messages ?? messages }
    var cachedTranscriptPresentationID: (profileID: String?, sessionID: String, value: String)?
    var transcriptPresentationID: String? {
        guard let sessionID else { return nil }
        let stored = sessionStorageID.flatMap { id in
            id == sessionID || storageIDsByRuntimeID[sessionID] == id ? id : nil
        }
        let owner = stored ?? sessionID
        if let cached = cachedTranscriptPresentationID,
            cached.profileID == sessionProfileID, cached.sessionID == owner
        {
            return cached.value
        }
        let value = WorkspaceIdentity.session(profileID: sessionProfileID, sessionID: owner)
        cachedTranscriptPresentationID = (sessionProfileID, owner, value)
        return value
    }
    var sessionResumeTask: Task<Bool, Never>?
    var transcriptTimelineTask: Task<Void, Never>?
    var runtimeModelOptionsTask: Task<Void, Never>?
    var runtimeModelOptionsRequestKey: (sessionID: String?, profileID: String?, generation: Int)?
    var gatewayAuthenticationObserver: AnyCancellable?
    var sessionSwitchStartedAt: UInt64 = 0
    var sessionSwitchToken = ""
    var sessionSwitchCachedLayoutRecorded = false
    var sessionSwitchFreshLayoutRecorded = false
    /// Older rows of the active transcript still stored in Hermes. Nil when the
    /// whole transcript was delivered inline (legacy resume or a new session).
    var transcriptHistoryCursor: TranscriptHistoryCursor? {
        didSet {
            messageNavigatorRevision &+= 1
            navigatorChangedRows = nil
        }
    }
    var storedSearchCache: (NavigatorHistorySearchKey, NavigatorStoredSearchIndex)?
    var storedSearchTask:
        (
            key: NavigatorHistorySearchKey, id: UUID, task: Task<NavigatorStoredSearchIndex, Error>
        )?
    var transcriptSearchHosts = Set<ObjectIdentifier>()
    var isLoadingEarlierTranscript = false
    var earlierTranscriptRetryAfter: Date?
    var transcriptPrependGeneration = 0
    /// Set in the same main-actor step that prepends older history, so the
    /// transcript view can tell a prepend from an append on the count change.
    var lastTranscriptPrepend: TranscriptHistoryPrepend? { didSet { transcriptPresentationChanges.send() } }
    /// Every stored prompt of the active paged transcript, oldest first.
    var transcriptTimeline: [TranscriptTimelineEntry] = [] {
        didSet {
            messageNavigatorRevision &+= 1
            messageNavigatorTimelineRevision &+= 1
            navigatorChangedRows = nil
            transcriptPresentationChanges.send()
        }
    }
    private(set) var transcriptMessageIDsByRowID: [Int: UUID] = [:]
    private var transcriptRowsByMessageID: [UUID: (first: Int, additional: [Int])] = [:]

    func replaceTranscriptRowIDs(_ rows: [Int: UUID]) {
        transcriptMessageIDsByRowID = rows
        transcriptRowsByMessageID = [:]
        transcriptRowsByMessageID.reserveCapacity(rows.count)
        for (row, message) in rows { indexTranscriptRow(row, message: message) }
    }

    func mergeTranscriptRowIDs(_ rows: [Int: UUID]) {
        for (row, message) in rows where transcriptMessageIDsByRowID[row] == nil {
            transcriptMessageIDsByRowID[row] = message
            indexTranscriptRow(row, message: message)
        }
    }

    func setTranscriptRowID(_ row: Int, message: UUID) {
        if let previous = transcriptMessageIDsByRowID[row] {
            guard previous != message else { return }
            if var indexed = transcriptRowsByMessageID[previous] {
                if indexed.first == row {
                    if let replacement = indexed.additional.popLast() {
                        indexed.first = replacement
                        transcriptRowsByMessageID[previous] = indexed
                    } else {
                        transcriptRowsByMessageID.removeValue(forKey: previous)
                    }
                } else {
                    indexed.additional.removeAll { $0 == row }
                    transcriptRowsByMessageID[previous] = indexed
                }
            }
        }
        transcriptMessageIDsByRowID[row] = message
        indexTranscriptRow(row, message: message)
    }

    func hasStoredTranscriptRow(for message: UUID) -> Bool {
        transcriptRowsByMessageID[message] != nil
    }

    private func indexTranscriptRow(_ row: Int, message: UUID) {
        if transcriptRowsByMessageID[message] == nil {
            transcriptRowsByMessageID[message] = (row, [])
        } else {
            transcriptRowsByMessageID[message]?.additional.append(row)
        }
    }

    func transcriptRowIDs(for messages: [ChatMessage]) -> [Int: UUID] {
        var rows: [Int: UUID] = [:]
        for message in messages {
            guard let indexed = transcriptRowsByMessageID[message.id] else { continue }
            rows[indexed.first] = message.id
            for row in indexed.additional { rows[row] = message.id }
        }
        return rows
    }
    /// True while a jump or explicit history action reads older history in one step.
    @Published var isLoadingTranscriptHistory = false
    var restoreGeneration = 0
    var interruptGeneration = 0
    var nativeVoiceCapture = NativeVoiceCaptureLifecycle()
    var voiceConversationGeneration = 0
    var voiceSessionID: String?
    var voiceProfileID: String?
    var voiceRecorderSessionID: String?
    var voiceRecorderEnabled = false
    var canTranscribeVoice: () -> Bool = { MicLevelMeter.canTranscribe }
    let voicePlayback: HermesVoicePlaybackProtocol
    var voicePlaybackTask: Task<Void, Never>?
    var voiceReplyStream: VoiceReplyStream?
    var voiceSpeechQueue: [String] = []
    var voiceCompletionAnnouncements: [String] = []
    var voicePlaybackGeneration = 0
    /// The user interrupted a generating turn; its `message.complete` has no
    /// speech left to drain, so listening resumes immediately.
    var skipNextVoicePlaybackDrain = false
    /// Cutting in silences the rest of this stream, but does not cancel the turn or its visual.
    var voiceReplySilenced = false
    /// An approval or clarify question is being asked aloud.
    var isVoicePromptActive = false
    /// On-device recognition failed this conversation; Hermes' whisper takes over.
    var localVoiceTranscriptionFailed = false
    /// Set once Herm went back from Hermes' recorder to on-device recognition, so the two can't loop.
    var retriedLocalVoiceTranscription = false
    var nativeCaptureIsLocal = false
    /// The opening listen waits for the user; only follow-ups go to sleep.
    var preparingVoiceMessageID: UUID?
    /// What Hermes last said aloud, to recognize the mic hearing it back.
    var lastVoiceSpeech = ""
    /// Notices spoken with no call open, through the local Mac voice; see `VoiceAnnouncer`.
    var voiceAnnouncedAt: Date?
    var voiceAnnouncementTask: Task<Void, Never>?
    lazy var voiceAnnouncementPlayback = LocalVoicePlayback()
    /// Today's facts for a spoken briefing; `ControlCenterModel.bind(to:)` supplies them.
    var isNotchVoiceConversation = false
    weak var notchVoiceNoticeTarget: DockModel?
    var briefingFacts: (@MainActor () async -> VoiceBriefing.Facts)?
    /// Session recorder controls must reach Hermes in order, including cleanup.
    var voiceRequestChain: Task<Void, Never>?
    var hasShutDown = false
    let completionNotificationsKey = "hermes.control.notifications.completion.v1"
    let lastSessionIDKey = "hermes.session.last-active.v1"
    let profileScopeKey = "hermes.dock.selected-profile.v1"
    let unreadSessionIDsKey = "hermes.dock.unread-session-ids.v1"
    let defaults: UserDefaults
    let playApprovalSound: () -> Void
    var sessionLoadTask: Task<Void, Never>?
    var sessionLoadGeneration: UInt64 = 0
    var sessionActivityGeneration: UInt64 = 0

    var streamingMessageIDForPresentation: UUID? { streamingMessageID }

    var reasoningState: ReasoningState? {
        didSet {
            guard oldValue != reasoningState else { return }
            if let reasoningState { recordTurnThinking(reasoningState) }
            scheduleActivityPresentation()
        }
    }

    init(
        sessionAgentStateFileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        approvalSoundPlayer: @escaping () -> Void = { NSSound.beep() },
        initialSessionID: String? = nil,
        botActivityFileURL: URL? = nil,
        loadArchives: Bool = true,
        rpcClient: HermesRPCClientProtocol? = nil,
        voicePlayback: HermesVoicePlaybackProtocol? = nil,
        refreshesSessionIndexFromEvents: Bool = true,
        sessionTranscriptCache: SessionTranscriptCache? = nil,
        voiceTimers: VoiceTimerBoard? = nil,
        voiceCapture: VoiceCaptureCoordinator? = nil
    ) {
        let agentStateStore = SessionAgentStateStore(fileURL: sessionAgentStateFileURL)
        self.messagePinStore = MessagePinStore(
            fileURL: sessionAgentStateFileURL?.deletingLastPathComponent()
                .appendingPathComponent("message-pins-v1.json"))
        self.agentStateStore = agentStateStore
        self.agentStateWriter = SessionAgentStateWriter(store: agentStateStore)
        self.agentStateBySessionID = loadArchives ? agentStateStore.load() : [:]
        let botActivityStore = BotActivityStore(fileURL: botActivityFileURL)
        self.botActivityStore = botActivityStore
        self.botActivityWriter = BotActivityWriter(store: botActivityStore)
        self.botActivityBySessionID = loadArchives ? botActivityStore.load() : [:]
        self.defaults = defaults
        self.voiceTimers = voiceTimers ?? VoiceTimerBoard()
        self.voiceCapture = voiceCapture ?? VoiceCaptureCoordinator()
        self.refreshesSessionIndexFromEvents = refreshesSessionIndexFromEvents
        self.sessionTranscriptCache = sessionTranscriptCache ?? SessionTranscriptCache()
        self.ownsSessionTranscriptCache = sessionTranscriptCache == nil
        self.playApprovalSound = approvalSoundPlayer
        self.sessionID = initialSessionID
        let initialProfileID = Self.normalizedProfileID(defaults.string(forKey: profileScopeKey))
        self.profileScopeID = initialProfileID
        self.profileScopeUnavailable = false
        self.sessionProfileID = initialProfileID
        self.sessionStorageID = initialSessionID
        self.kanbanAttributionSessionID = initialSessionID
        let client: HermesRPCClientProtocol
        if let rpcClient {
            self.gateway = nil
            client = rpcClient
        } else {
            let gateway = HermesGateway()
            self.gateway = gateway
            client = gateway
        }
        self.interruptRPC = HermesControlRPC(client: client)
        self.sessionRPCClient = client
        if !GatewayConnectionStore.isLocalBackend {
            runtimeConfigurationRefresh = HermesRuntimeConfigurationRefresh(reader: { _ in
                await HermesRuntimeInspector.inspectRemote(fetch: client.fetchHTTP)
            })
        }
        self.voicePlayback = voicePlayback ?? VoicePlayback()
        completionNotificationsEnabled = defaults.bool(forKey: completionNotificationsKey)
        DebugLog.write("model: initialized")
        voiceStage.observe(self)
        if let gateway { observeOwnedGateway(gateway) }
        observeGatewayAuthentication()
    }

    private func observeOwnedGateway(_ gateway: HermesGateway) {
        gateway.onEvent = { [weak self] type, params in
            self?.receiveGatewayEvent(type, params: params)
        }
        gateway.onConnectionChange = { [weak self, weak gateway] connected in
            guard let self, let gateway else { return }
            let wasConnected = isHermesConnected
            let issue = connected ? nil : gateway.lastFailure
            if isHermesConnected != connected { isHermesConnected = connected }
            if hermesConnectionIssue != issue { hermesConnectionIssue = issue }
            DebugLog.write("model: Hermes connection \(connected ? "online" : "offline")")
            if connected, !wasConnected {
                replayTrackedGatewayEvents()
                if gateway.isLocal { HermesBundledPlugins.ensure(client: gateway) }
            } else if !connected, wasConnected {
                gatewayReplayTask?.cancel()
                DeveloperWorkflowModel.shared.turnBaselines.removeAll()
            }
        }
    }

    private func observeGatewayAuthentication() {
        gatewayAuthenticationObserver = NotificationCenter.default.publisher(for: .hermGatewayAuthenticationChanged)
            .sink { [weak self] notification in
                let changedURL = notification.object as? URL
                MainActor.assumeIsolated {
                    let settings = GatewayConnectionStore.shared.launchSettings
                    guard let self, settings.authentication == .signIn, let changedURL,
                        (try? GatewayConnectionSettings.normalizedURL(settings.remoteURL)) == changedURL
                            || (settings.mode == .cloud && changedURL == GatewayWebAuthentication.portalURL)
                    else {
                        return
                    }
                    self.invalidateGatewayAuthenticationProjection()
                    // The connection owner reopens the socket for all its projections.
                    if let gateway = self.gateway {
                        gateway.close()
                        Task { try? await gateway.connect() }
                    }
                }
            }
    }

    func invalidateGatewayAuthenticationProjection() {
        sessionResumeGeneration &+= 1
        storedTranscriptAttach = nil
        pendingAttachedEvents.removeAll()
        restoreGeneration &+= 1
        isRestoringSession = false
        sessionTranscriptCache.removeAll()
        retainedProfileSessions.removeAll()
        knownProfilePins.removeAll()
        supersededPinScanByProfile.removeAll()
        supersededPinScanBySession.removeAll()
        awaitingScopedPinsAfterSwitch = false
        sessionTranscriptPreview = nil
        sessionResumeTask?.cancel()
        sessionResumeTask = nil
        allBotSessionsTask?.cancel()
        sessionTranscriptPreloadTask?.cancel()
        runtimeModelOptionsTask?.cancel()
        clearStoredTranscriptProjection()
        if sessionID != nil {
            sessionTranscriptLoadState = .failed("Connection changed. Retry loading this conversation.")
            status = .offline
        }
    }

    var sendQueuedPromptAfterInterrupt = false
    /// Set once Hermes acknowledges Stop: the stopped turn still unwinds and
    /// emits its tail (deltas, tools, terminal frame), which is dropped until
    /// the next `message.start`.
    var isDiscardingStoppedTurn = false

    var composerMentionProfiles: [String] = []
    var composerMentionBots: [BotSummary] = []

    // MARK: - Slash commands and @ references (Hermes desktop parity)

    /// `/name` -> Hermes' `desktop` disposition (terminal, messaging, hidden…)
    /// from `commands.catalog`; a non-nil value means no desktop surface.
    var slashCommandDispositions: [String: String] = [:]
    var hasLoadedSlashCatalog = false
    /// `/btw` and `/bg` task IDs whose answer lands in this transcript.
    var slashSideTaskIDs: Set<String> = []

    /// Slash dispositions per bot profile: each bot enables its own commands.
    var profileSlashDispositions: [String: [String: String]] = [:]

    /// Control-center actions share the user-facing Hermes gateway so they do
    /// not create a second backend or bypass the normal approval/event stream.
    var controlRPCClient: HermesRPCClientProtocol { sessionRPCClient }

    /// Keyed Hermes notifications replace their earlier card in place.
    var systemEventMessageIDs: [String: UUID] = [:]

    /// Text of earlier rows of the split live turn, so `message.complete`'s
    /// full text doesn't re-add what they already show.
    var turnCommittedText = ""

    /// Tool call input/result strings are shown as short previews in the
    /// activity list and are persisted verbatim into a per-session cache
    /// (`session-agent-state-v1.json`) that lives for the whole session
    /// lifetime. Full tool payloads (raw file listings, page dumps, etc.) can
    /// be hundreds of KB each; leaving them unbounded made that cache file
    /// grow into the multi-MB range for long sessions, which was observed to
    /// make session restoration fail with "connection to Hermes was lost".
    /// Cap what we keep to a size that comfortably covers the UI preview.
    nonisolated static let toolPayloadPersistenceLimit = 4000

    static let visionUnsupportedNotice =
        "This model can't read images. Use a vision-capable model in Hermes to analyze images."
    nonisolated(unsafe) static let kanbanNoticeHead = /([^\p{L}\p{N}\s\[@`*#>-]\S*) (.*\bt_[0-9a-f]{8}\b.*)/

}
