import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
/// A parsed session-resume transcript. Image attachment is deferred: only
/// file references are parsed synchronously so session selection never
/// performs disk reads or image decoding on the main actor.
struct RestoredTranscript {
    struct PendingImages: Sendable {
        let messageID: UUID
        let fileURLs: [URL]
    }

    let messages: [ChatMessage]
    let pendingImages: [PendingImages]
    /// Stored Hermes row id of each message that carried one.
    var rowIDs: [Int: UUID] = [:]
    /// Tool calls after the last reply: a turn still running, possibly in
    /// another process (a Bot's `hermes chat -Q`), or one that died.
    var trailingActivity: [ActiveToolCall] = []
}

@MainActor
final class DockModel: ObservableObject {
    var interruptionCoordinator: HermInterruptionCoordinator?
    var completionNoticeIDs: [String: String] = [:]
    var quickSessionOwners: [String: QuickDestination] = [:]
    /// Hermes keeps a runtime alive after Herm switches away; its approval and
    /// clarify requests carry only the runtime sid, so rows need the durable id.
    var storageIDsByRuntimeID: [String: String] = [:]
    @Published var status: HermesStatus = .idle
    @Published var isHermesConnected = false
    @Published var messages: [ChatMessage] = [] {
        didSet { cachedMessageNavigatorItems = nil }
    }
    var cachedMessageNavigatorItems: (sessionID: String, items: [MessageNavigatorItem])?

    let composer = ComposerText()
    let streamingText = StreamingText()
    /// Unflushed-to-step reasoning, observed only by an open live thought row.
    var composerDrafts: [SessionComposerDraft.Key: SessionComposerDraft] = [:]
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
    @Published var isLoadingMessagePins = false
    @Published var updatingMessagePinRowID: Int?
    var isUpdatingMessagePin: Bool { updatingMessagePinRowID != nil }
    @Published var messagePinError: String?
    @Published var storedMessageReferences: [UUID: StoredMessageReference] = [:]
    var submittedMessageIDForPin: UUID?
    @Published var pendingImages: [ImageAttachment] = []
    /// Context chips prepended to the next prompt (Kanban cards, PRs, issues).
    @Published var attachedContexts: [ChatContext] = []
    @Published var pendingPDFURL: URL?
    @Published var pendingPDFError: String?
    @Published var pendingAttachmentError: String?
    @Published var isSending = false
    @Published var steeringError: String?
    /// Prompts typed during a turn that could not reach it (attachments, a
    /// blocked approval, or a turn that ended first). Not yet submitted, so
    /// removable; sent one per turn once Hermes settles (desktop parity).
    @Published var queuedPrompts: [QueuedPrompt] = []
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
    var pendingApprovalsBySessionID: [String: PendingApproval] = [:] {
        didSet { refreshSessionAttention() }
    }
    var pendingApprovalAliasesBySessionID: [String: Set<String>] = [:]
    var activeClarification: PendingClarification?
    var pendingClarificationsBySessionID: [String: PendingClarification] = [:] {
        didSet { refreshSessionAttention() }
    }

    @Published var sessionAttention: [String: SessionAttention] = [:]
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
    @Published var sessions: [HermesSession] = []
    /// What each session is doing right now (its latest tool), read from the
    /// global gateway stream so sessions that are not open can show it too.
    // Only the edge dock consumes these; background tools must not invalidate
    // every workspace view observing DockModel.
    private let sessionActivityLabelSubject = CurrentValueSubject<[String: String], Never>([:])
    var sessionActivityLabels: [String: String] {
        get { sessionActivityLabelSubject.value }
        set {
            guard newValue != sessionActivityLabelSubject.value else { return }
            sessionActivityLabelSubject.send(newValue)
        }
    }
    var sessionActivityLabelChanges: AnyPublisher<[String: String], Never> {
        sessionActivityLabelSubject.eraseToAnyPublisher()
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
    @Published var pinnedSessions: [HermesSession] = []
    @Published var pinningSessionID: String?
    @Published var renamingSessionID: String?
    @Published var isRestoringSession = false
    @Published var isCreatingSession = false
    @Published var currentSessionTitle: String?
    var autoTitleAttempts: Set<String> = []
    var conversationActivityPhase: ConversationActivityPhase = .idle { didSet { if oldValue != conversationActivityPhase { scheduleActivityPresentation() } } }
    @Published var interruptState: InterruptState = .idle
    @Published var isShowingReasoning = false
    var activeToolCalls: [ActiveToolCall] = [] {
        didSet {
            guard oldValue != activeToolCalls else { return }
            if streamingMessageID != nil {
                Self.upsert(splitOffCallIDs.isEmpty ? activeToolCalls : activeToolCalls.filter { !splitOffCallIDs.contains($0.id) },
                            into: &streamingTurnActivity)
            }
            scheduleActivityPresentation()
        }
    }
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
    var activeSubagents: [HermesSubagent] = [] { didSet { if oldValue != activeSubagents { scheduleActivityPresentation() } } }
    var sessionAgents: [HermesSubagent] = [] { didSet { if oldValue != sessionAgents { scheduleActivityPresentation() } } }
    var agentActivities: [AgentActivity] = [] { didSet { if oldValue != agentActivities { scheduleActivityPresentation() } } }
    /// The sole UI invalidation signal for high-frequency agent activity.
    /// Canonical arrays above update immediately; this revision is coalesced.
    @Published var activityPresentationRevision = 0
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
    @Published var isUpdatingSessionReasoning = false
    @Published var defaultReasoningVariant: HermesReasoningVariant?
    @Published var voiceState: HermesVoiceState = .inactive
    @Published var voiceTelemetry = VoiceTurnTelemetry()
    @Published var voiceSpokenCaption: String?
    /// Spoken replies are enabled only for the conversation that owns voice.
    @Published var voiceRepliesEnabled = true
    /// Keeps the call open with the microphone closed.
    @Published var isVoiceMicMuted = false
    @Published var composerFocusRequest = 0
    @Published var isComposerEditing = false
    @Published var scrollToLatestMessageRequest = 0

    /// The default bot's name from Hermes' roster, so a rename reaches the
    /// menu bar and the voice wake phrase without editing SOUL.md.
    @Published var defaultBotName: String?

    let gateway = HermesGateway()
    let sessionRPCClient: HermesRPCClientProtocol
    var quickWorkflowClient: HermesRPCClientProtocol { sessionRPCClient }
    let interruptRPC: HermesControlRPC
    let eventRouter = HermesEventRouter()
    @Published var sessionID: String? {
        didSet {
            if let voiceSessionID, voiceSessionID != sessionID { stopVoiceConversation() }
        }
    }
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
               (voiceProfileID ?? "default") != (sessionProfileID ?? profileScopeID ?? "default") {
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
    var inFlightBotActivities: [String: InFlightBotActivity] = [:]
    let botActivityStore: BotActivityStore
    let botActivityWriter: BotActivityWriter
    var sessionStorageID: String?
    /// The id session.list rows carry for the open chat. Hermes streams under
    /// a runtime alias (`session_id`) that differs from the stored key.
    var navigationSessionID: String? { sessionStorageID ?? sessionID }
    /// The durable identifier selected by the user for session-scoped durable
    /// projections. Gateway resume may return a transient alias for streaming,
    /// which must not replace the Kanban attribution boundary.
    var kanbanAttributionSessionID: String?
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
    var streamingMessagePublishedText = ""
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
    var sessionResumeGeneration = 0
    /// Older rows of the active transcript still stored in Hermes. Nil when the
    /// whole transcript was delivered inline (legacy resume or a new session).
    var transcriptHistoryCursor: TranscriptHistoryCursor?
    var isLoadingEarlierTranscript = false
    var earlierTranscriptRetryAfter: Date?
    var transcriptPrependGeneration = 0
    /// Set in the same main-actor step that prepends older history, so the
    /// transcript view can tell a prepend from an append on the count change.
    var lastTranscriptPrepend: TranscriptHistoryPrepend? { didSet { transcriptPresentationChanges.send() } }
    /// Every stored prompt of the active paged transcript, oldest first.
    var transcriptTimeline: [TranscriptTimelineEntry] = [] {
        didSet { cachedMessageNavigatorItems = nil; transcriptPresentationChanges.send() }
    }
    var transcriptMessageIDsByRowID: [Int: UUID] = [:]
    /// True while search or a jump reads older history in one step.
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
    /// The user interrupted a generating turn; its `message.complete` has no
    /// speech left to drain, so listening resumes immediately.
    var skipNextVoicePlaybackDrain = false
    /// An approval or clarify question is being asked aloud.
    var isVoicePromptActive = false
    /// On-device recognition failed this conversation; Hermes' whisper takes over.
    var localVoiceTranscriptionFailed = false
    var nativeCaptureIsLocal = false
    /// The opening listen waits for the user; only follow-ups go to sleep.
    var voiceFollowUpArmed = false
    /// What Hermes last said aloud, to recognize the mic hearing it back.
    var lastVoiceSpeech = ""
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
        rpcClient: HermesRPCClientProtocol? = nil,
        voicePlayback: HermesVoicePlaybackProtocol? = nil
    ) {
        let agentStateStore = SessionAgentStateStore(fileURL: sessionAgentStateFileURL)
        self.agentStateStore = agentStateStore
        self.agentStateWriter = SessionAgentStateWriter(store: agentStateStore)
        self.agentStateBySessionID = agentStateStore.load()
        let botActivityStore = BotActivityStore(fileURL: botActivityFileURL)
        self.botActivityStore = botActivityStore
        self.botActivityWriter = BotActivityWriter(store: botActivityStore)
        self.botActivityBySessionID = botActivityStore.load()
        self.defaults = defaults
        self.playApprovalSound = approvalSoundPlayer
        self.sessionID = initialSessionID
        let initialProfileID = Self.normalizedProfileID(defaults.string(forKey: profileScopeKey))
        self.profileScopeID = initialProfileID
        self.profileScopeUnavailable = false
        self.sessionProfileID = initialProfileID
        self.sessionStorageID = initialSessionID
        self.kanbanAttributionSessionID = initialSessionID
        self.interruptRPC = HermesControlRPC(client: rpcClient ?? gateway)
        self.sessionRPCClient = rpcClient ?? gateway
        self.voicePlayback = voicePlayback ?? HermesVoicePlayback()
        completionNotificationsEnabled = defaults.bool(forKey: completionNotificationsKey)
        DebugLog.write("model: initialized")
        gateway.onEvent = { [weak self] type, params in
            self?.receiveGatewayEvent(type, params: params)
        }
        gateway.onConnectionChange = { [weak self] connected in
            self?.isHermesConnected = connected
            DebugLog.write("model: Hermes connection \(connected ? "online" : "offline")")
            if connected { self?.replayTrackedGatewayEvents() }
            else { DeveloperWorkflowModel.shared.turnBaselines.removeAll() }
        }
    }

    var sendQueuedPromptAfterInterrupt = false
    /// Set once Hermes acknowledges Stop: the stopped turn still unwinds and
    /// emits its tail (deltas, tools, terminal frame), which is dropped until
    /// the next `message.start`.
    var isDiscardingStoppedTurn = false

    var composerMentionProfiles: [String] = []

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

    static let visionUnsupportedNotice = "This model can't read images. Use a vision-capable model in Hermes to analyze images."
    static let sessionDateFormatter = ISO8601DateFormatter()

    nonisolated(unsafe) static let kanbanNoticeHead = /([^\p{L}\p{N}\s\[@`*#>-]\S*) (.*\bt_[0-9a-f]{8}\b.*)/

}
