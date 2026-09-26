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
}

@MainActor
final class DockModel: ObservableObject {
    nonisolated static func safeUserDiagnostic(_ raw: String) -> String {
        HermesDiagnosticsService.safeSummary(raw)
    }
    @Published var status: HermesStatus = .idle
    @Published private(set) var isHermesConnected = false
    @Published var messages: [ChatMessage] = [] {
        didSet { cachedMessageNavigatorItems = nil }
    }
    private var cachedMessageNavigatorItems: (sessionID: String, items: [MessageNavigatorItem])?

    /// Invalidate at the canonical array mutation boundary, not by hashing
    /// the entire history again on each scroll or live-tail layout update.
    var messageNavigatorItems: [MessageNavigatorItem] {
        let owner = sessionID ?? ""
        if let cached = cachedMessageNavigatorItems, cached.sessionID == owner {
            return cached.items
        }
        let items = MessageNavigator.items(
            messages: messages,
            earlierPrompts: unloadedTranscriptPrompts,
            sessionID: owner
        )
        cachedMessageNavigatorItems = (owner, items)
        return items
    }
    let composer = ComposerText()
    let streamingText = StreamingText()

    /// Compatibility accessor over the composer's draft so send, steering,
    /// clarification, and external writers (voice transcripts, quick prompts)
    /// read and clear the same text the composer edits.
    var draft: String {
        get { composer.text }
        set { composer.text = newValue }
    }
    @Published var pendingImages: [ImageAttachment] = []
    @Published private(set) var pendingPDFURL: URL?
    @Published private(set) var pendingPDFError: String?
    @Published private(set) var pendingAttachmentError: String?
    @Published var isSending = false
    @Published private(set) var steeringError: String?
    /// Prompts typed during a turn that could not reach it (attachments, a
    /// blocked approval, or a turn that ended first). Not yet submitted, so
    /// removable; sent one per turn once Hermes settles (desktop parity).
    @Published private(set) var queuedPrompts: [QueuedPrompt] = []
    @Published var approvalTitle: String?
    @Published var approvalText: String?
    /// Approval requests arrive on the shared gateway stream, including while
    /// another conversation is selected. Retain the latest unresolved request
    /// by Hermes session identity and project only the selected session here.
    /// This is intentionally process-local: Hermes remains the authority after
    /// a runtime restart, so stale approval payloads are never restored from disk.
    private struct PendingApproval: Equatable {
        let title: String
        let detail: String
    }
    private var pendingApprovalsBySessionID: [String: PendingApproval] = [:]
    private var pendingApprovalAliasesBySessionID: [String: Set<String>] = [:]
    private struct PendingClarification: Equatable {
        let question: String
        let choices: [String]
        let requestID: String?

        var transcriptText: String {
            choices.isEmpty
                ? question
                : "\(question)\n\nSuggested responses:\n" + choices.map { "- \($0)" }.joined(separator: "\n")
        }
    }
    private var pendingClarificationsBySessionID: [String: PendingClarification] = [:]
    private var pendingClarificationAliasesBySessionID: [String: Set<String>] = [:]
    private var resolvedClarificationRequestIDs = Set<String>()
    private var resolvedClarificationRequestIDOrder: [String] = []
    @Published private(set) var clarificationQuestion: String?
    @Published private(set) var clarificationChoices: [String] = []
    /// Hermes assigns this identifier to the blocking clarify request. A reply
    /// must echo it so the backend can release the exact waiting turn.
    @Published private(set) var clarificationRequestID: String?
    /// A clarification request is an event with a stable Hermes ID. Gate a
    /// replay at the event boundary so it cannot become a second transcript
    /// bubble after the user has already answered it.
    private var presentedClarificationRequestIDs = Set<String>()
    @Published private(set) var clarificationResponseError: String?
    @Published private(set) var isRespondingToClarification = false
    @Published private(set) var isRespondingToApproval = false
    @Published var sessions: [HermesSession] = []
    /// What each session is doing right now (its latest tool), read from the
    /// global gateway stream so sessions that are not open can show it too.
    @Published private(set) var sessionActivityLabels: [String: String] = [:]
    @Published private(set) var sessionProjectionState: HermesProjectionState<[HermesSession]> = .empty
    @Published var isShowingSessions = false
    @Published var isLoadingSessions = false
    /// A live event can arrive while the initial session index is loading.
    /// Retain one follow-up refresh so the navigation list cannot get stuck on
    /// the snapshot that predated that event.
    private var pendingSessionIndexRefresh = false
    @Published private(set) var deletingSessionID: String?
    @Published private(set) var sessionDeletionError: String?
    @Published private(set) var sessionVisibilityError: String?
    @Published private(set) var updatingSessionVisibilityID: String?
    /// Sessions carrying Hermes' durable pin flag (`sessions.pinned`) — the
    /// same flag Hermes Desktop's Pinned section and `hermes sessions pin` use.
    @Published private(set) var pinnedSessions: [HermesSession] = []
    @Published private(set) var pinningSessionID: String?
    @Published private(set) var renamingSessionID: String?
    @Published private(set) var isRestoringSession = false
    @Published private(set) var isCreatingSession = false
    @Published var currentSessionTitle: String?
    var reasoningState: ReasoningState? {
        didSet {
            guard oldValue != reasoningState else { return }
            if let reasoningState { recordTurnThinking(reasoningState) }
            scheduleActivityPresentation()
        }
    }
    private(set) var conversationActivityPhase: ConversationActivityPhase = .idle { didSet { if oldValue != conversationActivityPhase { scheduleActivityPresentation() } } }
    @Published private(set) var interruptState: InterruptState = .idle
    @Published var isShowingReasoning = false
    var activeToolCalls: [ActiveToolCall] = [] {
        didSet {
            guard oldValue != activeToolCalls else { return }
            if streamingMessageID != nil { Self.upsert(activeToolCalls, into: &streamingTurnActivity) }
            scheduleActivityPresentation()
        }
    }
    /// Every tool call of the in-flight response. `activeToolCalls` resets on
    /// each `message.start`; this log survives until the turn commits onto
    /// its message.
    private(set) var streamingTurnActivity: [ActiveToolCall] = []
    /// The turn log of a session left while its turn was still running,
    /// keyed by stored session ID, so returning to it restores its steps.
    private var inFlightTurnActivityBySessionID: [String: [ActiveToolCall]] = [:]
    @Published var hasUnreadResponse = false
    @Published private(set) var completionNotificationsEnabled: Bool
    var recentEvents: [AgentEvent] = [] { didSet { if oldValue != recentEvents { scheduleActivityPresentation() } } }
    var activeSubagents: [HermesSubagent] = [] { didSet { if oldValue != activeSubagents { scheduleActivityPresentation() } } }
    var sessionAgents: [HermesSubagent] = [] { didSet { if oldValue != sessionAgents { scheduleActivityPresentation() } } }
    var agentActivities: [AgentActivity] = [] { didSet { if oldValue != agentActivities { scheduleActivityPresentation() } } }
    /// The sole UI invalidation signal for high-frequency agent activity.
    /// Canonical arrays above update immediately; this revision is coalesced.
    @Published private(set) var activityPresentationRevision = 0
    /// Changes whenever the active session proves an exact Kanban task
    /// reference through a Hermes tool event. Views observe this instead of
    /// waiting for their periodic Kanban refresh.
    @Published private(set) var observedKanbanTaskRevision = 0
    @Published private(set) var backgroundTasks: [HermesBackgroundTask] = []
    @Published var runtimeConfiguration: HermesRuntimeConfiguration?
    @Published var isLoadingRuntimeConfiguration = false
    @Published var runtimeConfigurationError: String?
    @Published var runtimeModelOptionsError: String?
    @Published var isLoadingRuntimeModelOptions = false
    @Published private(set) var runtimeConfigurationProjectionState: HermesProjectionState<HermesRuntimeConfiguration> = .empty
    @Published var runtimeModelOptions: [HermesModelOption] = []
    private var runtimeModelOptionsRefreshGeneration = 0
    @Published private(set) var sessionModelOptionID: String?
    /// The canonical session response can provide a model before the optional
    /// catalog has resolved its provider/model option identity.
    @Published private(set) var sessionModelValue: String?
    @Published private(set) var isUpdatingSessionModel = false
    @Published private(set) var sessionReasoningVariant: HermesReasoningVariant?
    @Published private(set) var isUpdatingSessionReasoning = false
    @Published private(set) var defaultReasoningVariant: HermesReasoningVariant?
    @Published private(set) var isUpdatingDefaultReasoning = false
    @Published private(set) var voiceState: HermesVoiceState = .inactive
    @Published private(set) var voiceTelemetry = VoiceTurnTelemetry()
    /// Mirrors Hermes' process-wide `HERMES_VOICE_TTS` flag for this voice chat.
    @Published private(set) var voiceRepliesEnabled = true
    @Published private(set) var composerFocusRequest = 0
    @Published var isComposerEditing = false
    @Published private(set) var controlInboxRequest = 0
    @Published private(set) var requestedAttentionID: String?
    @Published private(set) var scrollToLatestMessageRequest = 0

    var agentDisplayName: String {
        if let name = runtimeConfiguration?.agentName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "Hermes"
    }

    private let gateway = HermesGateway()
    private let sessionRPCClient: HermesRPCClientProtocol
    private let interruptRPC: HermesControlRPC
    let eventRouter = HermesEventRouter()
    @Published private(set) var sessionID: String?
    /// Authoritative `session.usage` total, keyed by the session it was read for
    /// so a switch never shows the previous chat's count.
    @Published private(set) var sessionTokenUsage: (sessionID: String, total: Int)?
    /// Context-window occupancy from the same usage payloads (`context_used` is
    /// the last prompt size, not lifetime throughput). Hermes omits the fields
    /// right after a compaction until the next API call measures again, so
    /// the previous reading is kept rather than cleared.
    @Published private(set) var sessionContextUsage: (sessionID: String, used: Int, max: Int)?
    /// Set by `status.update` `compacting`/`compressing`, cleared by
    /// `compacted`/`ready` or turn end.
    @Published private(set) var compactingSessionID: String?
    /// Canonical Hermes profile used by new chats and profile-owned
    /// navigation projections. This is intentionally separate from
    /// `activeBotProfileID`, which identifies an open canonical Bot Chat.
    @Published private(set) var profileScopeID: String?
    @Published private(set) var profileScopeUnavailable = false

    /// The rail subscribes only to fields it renders. Keeping this publisher
    /// separate from `objectWillChange` prevents transcript deltas and other
    /// workspace activity from invalidating the navigation projection.
    var sidebarPresentationChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            $sessionID.map { _ in () }.eraseToAnyPublisher(),
            $profileScopeID.map { _ in () }.eraseToAnyPublisher(),
            $runtimeConfiguration.map { _ in () }.eraseToAnyPublisher(),
            $status.map { _ in () }.eraseToAnyPublisher(),
            $sessions.map { _ in () }.eraseToAnyPublisher(),
            $sessionProjectionState.map { _ in () }.eraseToAnyPublisher(),
            $isLoadingSessions.map { _ in () }.eraseToAnyPublisher(),
            $deletingSessionID.map { _ in () }.eraseToAnyPublisher(),
            $renamingSessionID.map { _ in () }.eraseToAnyPublisher(),
            $updatingSessionVisibilityID.map { _ in () }.eraseToAnyPublisher(),
            $pinnedSessions.map { _ in () }.eraseToAnyPublisher(),
            $isCreatingSession.map { _ in () }.eraseToAnyPublisher()
        ).eraseToAnyPublisher()
    }
    @Published private(set) var sessionProfileID: String?
    /// Profile identity for a profile-scoped Bot Chat. This is authoritative
    /// session context, not an inference from the assistant's prose.
    @Published private(set) var activeBotProfileID: String?
    @Published private(set) var activeBotDisplayName: String?
    /// Explicit Bot dispatches are retained by their origin session. This is
    /// presentation state, not a second transcript or task database.
    @Published private(set) var botActivityBySessionID: [String: [BotActivityRecord]] = [:]
    @Published private(set) var botActivityRevision = 0
    private struct InFlightBotActivity: Equatable {
        let activityID: String
        let originSessionID: String
        let botID: String
        var botChatSessionID: String?
        var clarificationRequestID: String?
    }
    private var inFlightBotActivities: [String: InFlightBotActivity] = [:]
    private let botActivityStore: BotActivityStore
    private let botActivityWriter: BotActivityWriter
    private var sessionStorageID: String?
    /// The id session.list rows carry for the open chat. Hermes streams under
    /// a runtime alias (`session_id`) that differs from the stored key.
    var navigationSessionID: String? { sessionStorageID ?? sessionID }
    /// Every id the open chat answers to: runtime alias, stored row, and the
    /// id it was opened by.
    var currentSessionIDs: Set<String> {
        Set([sessionID, sessionStorageID, kanbanAttributionSessionID].compactMap { $0 })
    }

    /// Maps the open chat's runtime alias onto its stored row id.
    private func rowSessionID(_ id: String) -> String {
        id == sessionID ? (sessionStorageID ?? id) : id
    }
    /// The durable identifier selected by the user for session-scoped durable
    /// projections. Gateway resume may return a transient alias for streaming,
    /// which must not replace the Kanban attribution boundary.
    private var kanbanAttributionSessionID: String?
    /// A Kanban task may legitimately have no `session_id` in Hermes' durable
    /// store. Keep only exact task IDs seen in a tool command/result for the
    /// owning chat session; do not infer ownership from titles or assignees.
    private var observedKanbanTaskIDsBySessionID: [String: Set<String>] = [:]
    var kanbanSessionID: String? {
        Self.kanbanAttributionID(
            requestedSessionID: kanbanAttributionSessionID,
            runtimeID: sessionID,
            storageID: sessionStorageID
        )
    }

    /// Exact Kanban IDs observed in Hermes tool activity for this selected
    /// session. A worker can create a card without copying the originating
    /// session into the task row; the `kanban show <id>` command is still a
    /// definitive, session-scoped association and lets the UI recover it.
    var observedKanbanTaskIDs: [String] {
        let aliases = [sessionID, sessionStorageID, kanbanAttributionSessionID, kanbanSessionID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var ids = Set(aliases.flatMap { observedKanbanTaskIDsBySessionID[$0] ?? [] })
        // Exact references survive process restarts in the bounded activity
        // archive. They are identifiers only; prompts and tool results are
        // never needed to restore the session-to-card association.
        for alias in aliases {
            ids.formUnion(
                botActivityBySessionID[alias, default: []]
                    .filter(\.isKanbanReference)
                    .compactMap(\.linkedCardID)
            )
        }
        // `recentEvents` is the bounded, persisted activity history. Include
        // it so a completed terminal command observed before this view opens
        // can still recover its exact Kanban card after session restoration.
        let values = agentActivities.map(\.text)
            + activeToolCalls.map { $0.input + " " + $0.context }
            + recentEvents.map(\.detail)
        for value in values where value.localizedCaseInsensitiveContains("kanban") {
            ids.formUnion(Self.kanbanTaskIDs(in: value))
        }
        return ids.sorted()
    }

    var botActivitySessionIDs: [String?] {
        [sessionID, sessionStorageID, kanbanAttributionSessionID, kanbanSessionID]
    }
    private var streamingMessageID: UUID?
    private(set) var streamingResponseStartedAt: Date?
    private var streamingMessageSessionID: String?
    /// A clarification resumes an already-running Hermes turn. Some Hermes
    /// versions continue with deltas only, without another `message.start`.
    /// Reserve the next transcript slot so those deltas stay after the user's
    /// answer instead of updating the pre-clarification assistant row.
    private var isAwaitingClarificationResume = false
    // Keep one append-only buffer. Joining every received chunk during each
    // UI flush made long responses progressively more expensive.
    private var streamingMessageBuffer = ""
    private var streamingMessagePendingPresentationDelta = ""
    private var streamingMessagePublishedText = ""
    private var streamingMessageFlushTask: Task<Void, Never>?
    private var activityPresentationTask: Task<Void, Never>?
    private var streamingMessageGeneration = 0
    private var streamingMessageIsVisionNotice = false
    /// A single backend turn may report the same failure through both `error`
    /// and `message.complete`. Keep terminal error presentation idempotent for
    /// that turn without collapsing identical errors from later turns.
    private var didAppendTerminalErrorForCurrentTurn = false
    private var streamingReasoningBuffer = ""
    private var reasoningFlushTask: Task<Void, Never>?
    private var lastAgentStateCacheAt: Date?
    private var agentStateCacheTrailingTask: Task<Void, Never>?
    private var didRestoreLatestSession = false
    /// A backend session may only be created after the user explicitly starts
    /// a new chat. Resuming an existing session never grants this permission.
    private var newSessionCreationAuthorized = false
    private var newSessionProjectPath: String?
    /// Project path each chat was created in, so project navigation can place
    /// a new chat before the project tree reports it.
    private(set) var createdSessionProjectPaths: [String: String] = [:]
    private var currentModelName: String?
    private var isPopoverVisible = false
    private var isRefreshingDelegationStatus = false
    private var delegationRefreshTask: Task<Void, Never>?
    private var delegationRefreshRequested = false
    private var lastDelegationRefreshAt: Date = .distantPast
    /// Hermes stamps gateway events with a per-session sequence. Keep a
    /// bounded de-duplication window so reconnect replay and live delivery
    /// can safely share the same projection path.
    private var gatewayReplayEpoch: String?
    private var processedGatewaySequencesBySessionID: [String: Set<Int>] = [:]
    private var highestGatewaySequenceBySessionID: [String: Int] = [:]
    private var gatewayReplayTask: Task<Void, Never>?
    private var gatewayReplayInFlight = Set<String>()
    private var delegationMonitoringTask: Task<Void, Never>?
    private var synthesizedSubagentIDs: Set<String> = []
    private var cachedAgentSnapshot: AgentPresentationSnapshot?
    private var cachedAgentSnapshotInputs: ([HermesSubagent], [AgentActivity], [ActiveToolCall])?
    private var agentSnapshotRevision: UInt = 0
    private var agentStateBySessionID: [String: SessionAgentState] = [:]
    private let agentStateStore: SessionAgentStateStore
    private let agentStateWriter: SessionAgentStateWriter
    private var sessionResumeGeneration = 0
    /// Older rows of the active transcript still stored in Hermes. Nil when the
    /// whole transcript was delivered inline (legacy resume or a new session).
    private var transcriptHistoryCursor: TranscriptHistoryCursor?
    private var isLoadingEarlierTranscript = false
    private var earlierTranscriptRetryAfter: Date?
    private var transcriptPrependGeneration = 0
    /// Set in the same main-actor step that prepends older history, so the
    /// transcript view can tell a prepend from an append on the count change.
    private(set) var lastTranscriptPrepend: TranscriptHistoryPrepend?
    /// Every stored prompt of the active paged transcript, oldest first.
    private var transcriptTimeline: [TranscriptTimelineEntry] = [] {
        didSet { cachedMessageNavigatorItems = nil }
    }
    private var transcriptMessageIDsByRowID: [Int: UUID] = [:]
    /// True while search or a jump reads older history in one step.
    @Published private(set) var isLoadingTranscriptHistory = false
    private var restoreGeneration = 0
    private var interruptGeneration = 0
    private var nativeVoiceCapture = NativeVoiceCaptureLifecycle()
    private var voiceConversationGeneration = 0
    /// The user interrupted a generating turn; its `message.complete` has no
    /// speech left to drain, so listening resumes immediately.
    private var skipNextVoicePlaybackDrain = false
    private var hasShutDown = false
    private let completionNotificationsKey = "hermes.control.notifications.completion.v1"
    private let lastSessionIDKey = "hermes.session.last-active.v1"
    private let profileScopeKey = "hermes.dock.selected-profile.v1"
    private let unreadSessionIDsKey = "hermes.dock.unread-session-ids.v1"
    private let defaults: UserDefaults
    private let playApprovalSound: () -> Void
    private var sessionLoadTask: Task<Void, Never>?
    private var sessionLoadGeneration: UInt64 = 0

    /// Presentation-only union for the Agent map and pipeline. Hermes'
    /// `delegation.status.active` owns liveness; cached agents are retained as
    /// completed history so a finished delegation remains inspectable without
    /// falsely animating as current work.
    var currentSessionBackgroundTasks: [HermesBackgroundTask] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        return backgroundTasks.filter { $0.parentSessionID == sessionID }
    }

    var displayedSubagents: [HermesSubagent] {
        let liveIDs = Set(activeSubagents.map(\.id))
        let historical = sessionAgents
            .filter { !liveIDs.contains($0.id) }
            .map { agent -> HermesSubagent in
                guard !Self.isTerminalAgentStatus(agent.status) else { return agent }
                var completed = agent
                completed.status = "complete"
                return completed
            }
        return activeSubagents + historical
    }

    var streamingMessageIDForPresentation: UUID? { streamingMessageID }

    var agentPresentationSnapshot: AgentPresentationSnapshot {
        let displayed = displayedSubagents
        let inputs = (displayed, agentActivities, activeToolCalls)
        if let cachedAgentSnapshot,
           let cachedAgentSnapshotInputs,
           cachedAgentSnapshotInputs.0 == inputs.0,
           cachedAgentSnapshotInputs.1 == inputs.1,
           cachedAgentSnapshotInputs.2 == inputs.2 {
            return cachedAgentSnapshot
        }
        let pipeline = AgentActivityPresentation.pipeline(
            activities: agentActivities,
            toolCalls: activeToolCalls,
            subagents: displayed
        )
        var counts: [String: Int] = [:]
        for activity in agentActivities {
            if let agentID = activity.agentID { counts[agentID, default: 0] += 1 }
        }
        let snapshot = AgentPresentationSnapshot(
            displayedSubagents: displayed,
            pipeline: pipeline,
            activityCountsByAgentID: counts,
            activeAgentIDs: Set(activeSubagents.filter { AgentActivityPresentation.isActiveStatus($0.status) }.map(\.id)),
            revision: agentSnapshotRevision &+ 1
        )
        agentSnapshotRevision &+= 1
        cachedAgentSnapshotInputs = inputs
        cachedAgentSnapshot = snapshot
        return snapshot
    }

    init(
        sessionAgentStateFileURL: URL? = nil,
        defaults: UserDefaults = .standard,
        approvalSoundPlayer: @escaping () -> Void = { NSSound.beep() },
        initialSessionID: String? = nil,
        botActivityFileURL: URL? = nil,
        rpcClient: HermesRPCClientProtocol? = nil
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
        completionNotificationsEnabled = defaults.bool(forKey: completionNotificationsKey)
        DebugLog.write("model: initialized")
        gateway.onEvent = { [weak self] type, params in
            self?.receiveGatewayEvent(type, params: params)
        }
        gateway.onConnectionChange = { [weak self] connected in
            self?.isHermesConnected = connected
            DebugLog.write("model: Hermes connection \(connected ? "online" : "offline")")
            if connected { self?.replayTrackedGatewayEvents() }
        }
    }

    /// The app delegate owns terminal cleanup. Relying on `HermesGateway`'s
    /// deinitializer leaves its child `hermes serve` process running when
    /// AppKit tears down the application without releasing the model first.
    func shutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        streamingMessageFlushTask?.cancel()
        sessionLoadTask?.cancel()
        delegationRefreshTask?.cancel()
        delegationMonitoringTask?.cancel()
        gatewayReplayTask?.cancel()
        nativeVoiceCapture.reset()
        gateway.close()
        detachInFlightBotActivities(as: .canceled)
        Task {
            await agentStateWriter.flush()
            await botActivityWriter.flush()
        }
        DebugLog.write("model: shutdown complete")
    }

    /// Sends the composer draft, or `queued` (a prompt parked during the
    /// previous turn) without touching whatever the composer holds now.
    func send(_ queued: QueuedPrompt? = nil) {
        let prompt = (queued?.text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedImages = queued?.images ?? pendingImages
        let attachedPDF = queued == nil ? pendingPDFURL : queued?.pdfURL
        guard (!prompt.isEmpty || !attachedImages.isEmpty || attachedPDF != nil),
              !isSending,
              !isUpdatingSessionModel,
              !isRestoringSession,
              sessionID != nil || (newSessionCreationAuthorized && !isCreatingSession) else { return }

        if attachedImages.isEmpty, attachedPDF == nil, let command = ComposerSlashCommand(prompt) {
            if queued == nil { draft = "" }
            runSlashCommand(command, echo: prompt)
            return
        }

        let text: String
        if !prompt.isEmpty {
            text = ComposerCompletion.pathifyingBareRefs(prompt)
        } else if attachedPDF != nil {
            text = attachedImages.isEmpty ? "What does this document contain?" : "What do you see in these attachments?"
        } else {
            text = "What do you see in these images?"
        }
        let sessionBeforeSend = sessionID
        let botActivityID = sessionBeforeSend.flatMap { eventSessionID in
            inFlightBotActivities.values.first { $0.botChatSessionID == eventSessionID }?.activityID
        }
        let sendGeneration = sessionResumeGeneration
        if queued == nil { draft = "" }
        let transcriptText = attachedPDF.map { "[PDF: \($0.lastPathComponent)]\n\(text)" } ?? text
        messages.append(ChatMessage(role: .user, text: transcriptText, images: attachedImages.map(\.image)))
        status = .working
        isSending = true
        DebugLog.write("model: send started (\(prompt.count) characters, images: \(attachedImages.count))")

        Task {
            do {
                try await sessionRPCClient.connect()
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == sessionBeforeSend else { return }
                if sessionID == nil {
                    _ = try await createAuthorizedSession(source: "herm")
                }
                guard let sessionID else { throw HermesGateway.GatewayError.malformedResponse }
                // Keep this operation bound to the session selected above. A
                // late resume must not redirect a prompt into another chat.
                let promptSessionID = sessionID
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == promptSessionID else { return }
                touchSession(sessionID: promptSessionID, at: Date(), preview: text)

                for attachedImage in attachedImages {
                    let accessing = attachedImage.fileURL.startAccessingSecurityScopedResource()
                    defer { if accessing { attachedImage.fileURL.stopAccessingSecurityScopedResource() } }
                    let imageData = try Data(contentsOf: attachedImage.fileURL)
                    let base64 = imageData.base64EncodedString()
                    let attachResult = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.imageAttachBytes.rawValue,
                        params: scopedSessionParams([
                            "session_id": promptSessionID,
                            "content_base64": base64,
                            "filename": attachedImage.fileName
                        ])
                    )
                    let attached = (attachResult["attached"] as? Bool) ?? false
                    guard attached else {
                        throw HermesGateway.GatewayError.imageAttachFailed(
                            (attachResult["message"] as? String) ?? "Hermes could not attach the image."
                        )
                    }
                    DebugLog.write("model: image attached")
                    cleanupImageAttachment(attachedImage)
                }

                if let attachedPDF {
                    let accessing = attachedPDF.startAccessingSecurityScopedResource()
                    defer { if accessing { attachedPDF.stopAccessingSecurityScopedResource() } }
                    let pdfData = try Data(contentsOf: attachedPDF)
                    guard pdfData.count <= 25 * 1024 * 1024 else {
                        throw HermesGateway.GatewayError.imageAttachFailed("PDF attachments are limited to 25 MB.")
                    }
                    let result = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.pdfAttach.rawValue,
                        params: scopedSessionParams([
                            "session_id": promptSessionID,
                            "content_base64": pdfData.base64EncodedString(),
                            "filename": attachedPDF.lastPathComponent
                        ])
                    )
                    guard result["attached"] as? Bool == true else {
                        throw HermesGateway.GatewayError.imageAttachFailed(
                            (result["message"] as? String) ?? "Hermes could not attach the PDF."
                        )
                    }
                    if queued == nil { pendingPDFURL = nil }
                }

                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == promptSessionID else { return }
                _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.promptSubmit.rawValue, params: scopedSessionParams(["session_id": promptSessionID, "text": text]))
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == promptSessionID else { return }
                pendingImages.removeAll { attachedImage in
                    attachedImages.contains { $0.id == attachedImage.id }
                }
                DebugLog.write("model: prompt submitted")
            } catch {
                // A request from a previous session must not publish its error
                // into whichever conversation the user opened meanwhile.
                guard self.sessionResumeGeneration == sendGeneration,
                      sessionBeforeSend == nil || self.sessionID == sessionBeforeSend else { return }
                DebugLog.write("model: send failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
                cleanupImageAttachments(attachedImages)
                pendingImages.removeAll { pendingImage in
                    attachedImages.contains { $0.id == pendingImage.id }
                }
                let transportFailure: Bool
                if let gatewayError = error as? HermesGateway.GatewayError {
                    switch gatewayError {
                    case .backendUnavailable, .disconnected, .httpError:
                        transportFailure = true
                    case .malformedResponse, .imageAttachFailed, .httpRefused:
                        transportFailure = false
                    }
                } else {
                    let nsError = error as NSError
                    transportFailure = nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain
                }
                let message = transportFailure
                    ? "I couldn’t connect to Hermes: \(Self.safeUserDiagnostic(error.localizedDescription))"
                    : "Hermes couldn’t process this request: \(Self.safeUserDiagnostic(error.localizedDescription))"
                messages.append(ChatMessage(role: .hermes, text: message, modelName: currentModelName))
                if let botActivityID {
                    markBotActivityFailed(id: botActivityID, result: message)
                }
                status = transportFailure ? .offline : .idle
                isSending = false
            }
        }
    }

    /// Mid-turn input, as Hermes desktop handles it: plain text redirects the
    /// live turn (`session.redirect`) and lands in the transcript at once as an
    /// ordinary user message. Anything a redirect can't carry (attachments,
    /// slash commands, a turn parked on an approval) or a redirect Hermes
    /// refuses because the turn already ended goes to `queuedPrompts` instead.
    func steerDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, !sessionID.isEmpty else { return }
        guard !text.isEmpty, pendingImages.isEmpty, pendingPDFURL == nil,
              status == .working, ComposerSlashCommand(text) == nil else {
            queueDraft()
            return
        }

        draft = ""
        steeringError = nil
        let steeringGeneration = sessionResumeGeneration
        // Redirect cancels the model request, so its completion can race the
        // RPC response: record the correction first, below what already
        // streamed, and let the resumed output continue in a fresh row under it.
        let hadLiveStream = streamingMessageID != nil
        if hadLiveStream {
            if streamingMessageBuffer.isEmpty, streamingTurnActivity.isEmpty {
                discardStreamingMessage()
            } else {
                commitStreamingMessage()
            }
        }
        let correction = ChatMessage(role: .user, text: text)
        messages.append(correction)
        if hadLiveStream { beginStreamingMessage() }
        let resumedRowID = hadLiveStream ? streamingMessageID : nil

        Task {
            let result = try? await sessionRPCClient.request(
                HermesFeatureIDs.ID.sessionRedirect.rawValue,
                params: ["session_id": sessionID, "text": text]
            )
            guard self.sessionResumeGeneration == steeringGeneration,
                  self.sessionID == sessionID else { return }
            switch (result?["status"] as? String)?.lowercased() {
            case "redirected":
                DebugLog.write("model: turn redirected")
            case "queued":
                // Build window or compaction: Hermes runs it as the next turn.
                if let index = messages.firstIndex(where: { $0.id == correction.id }) {
                    messages.append(messages.remove(at: index))
                }
            default:
                // Refused (turn ended first) or failed: keep the words as the next turn.
                messages.removeAll {
                    $0.id == correction.id
                        || ($0.id == resumedRowID && $0.id != streamingMessageID && $0.text.isEmpty && $0.activity.isEmpty)
                }
                queuedPrompts.append(QueuedPrompt(sessionID: sessionID, text: text, images: [], pdfURL: nil))
                drainQueuedPromptIfIdle()
            }
        }
    }

    /// Parks the whole composer payload until the active turn settles.
    func queueDraft() {
        guard let sessionID else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || pendingPDFURL != nil else { return }
        queuedPrompts.append(QueuedPrompt(sessionID: sessionID, text: text, images: pendingImages, pdfURL: pendingPDFURL))
        draft = ""
        pendingImages = []
        pendingPDFURL = nil
    }

    func removeQueuedPrompt(_ id: UUID) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return }
        cleanupImageAttachments(queuedPrompts.remove(at: index).images)
    }

    /// Sends the oldest queued prompt of the open session, one per settled turn.
    private func drainQueuedPromptIfIdle() {
        guard !isSending, status == .idle, !isRestoringSession, !isUpdatingSessionModel,
              let sessionID,
              let index = queuedPrompts.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        send(queuedPrompts.remove(at: index))
    }

    func submitComposerInput() {
        if status == .needsClarification {
            respondToClarification(draft)
        } else if isSending, sessionID != nil {
            steerDraft()
        } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pendingImages.isEmpty, pendingPDFURL == nil {
            drainQueuedPromptIfIdle()
        } else {
            send()
        }
    }

    // MARK: - Slash commands and @ references (Hermes desktop parity)

    /// `/name` -> Hermes' `desktop` disposition (terminal, messaging, hidden…)
    /// from `commands.catalog`; a non-nil value means no desktop surface.
    private var slashCommandDispositions: [String: String] = [:]
    private var hasLoadedSlashCatalog = false
    /// `/btw` and `/bg` task IDs whose answer lands in this transcript.
    private var slashSideTaskIDs: Set<String> = []

    private func loadSlashCatalogIfNeeded() async {
        guard !hasLoadedSlashCatalog else { return }
        var params: [String: Any] = [:]
        if let sessionID { params["session_id"] = sessionID }
        guard let catalog = try? await sessionRPCClient.request(HermesFeatureIDs.ID.commandsCatalog.rawValue, params: params) else { return }
        let commands = catalog["commands"] as? [String: [String: Any]] ?? [:]
        slashCommandDispositions = commands.compactMapValues { $0["desktop"] as? String }
            .reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        hasLoadedSlashCatalog = true
    }

    private func isSlashCommandHidden(_ command: String) -> Bool {
        slashCommandDispositions[command] != nil || ComposerCompletion.terminalOnlyCommands.contains(command)
    }

    func composerCompletions(for trigger: ComposerCompletionTrigger, bots: [ComposerCompletionItem]) async -> ComposerCompletion.Result {
        do {
            try await sessionRPCClient.connect()
            var params: [String: Any] = [:]
            if let sessionID {
                params["session_id"] = sessionID
            } else if let newSessionProjectPath, !newSessionProjectPath.isEmpty {
                params["cwd"] = newSessionProjectPath
            }
            switch trigger {
            case .slash(let text):
                await loadSlashCatalogIfNeeded()
                params["text"] = text
                let payload = try await sessionRPCClient.request(HermesFeatureIDs.ID.completeSlash.rawValue, params: params)
                return ComposerCompletion.slashResult(from: payload, hidden: isSlashCommandHidden)
            case .skill(let token):
                params["text"] = token
                let payload = try await sessionRPCClient.request(HermesFeatureIDs.ID.completeSlash.rawValue, params: params)
                var result = ComposerCompletion.slashResult(from: payload) { _ in false }
                result.items.removeAll { $0.group != "Skills" }
                return result
            case .mention(let word):
                params["word"] = word
                let payload = try await sessionRPCClient.request(HermesFeatureIDs.ID.completePath.rawValue, params: params)
                return ComposerCompletion.mentionResult(from: payload, bots: bots)
            }
        } catch {
            return ComposerCompletion.Result(items: bots)
        }
    }

    /// Mirrors Hermes desktop's slash dispatcher: a few client-owned actions,
    /// then `slash.exec`, falling back to `command.dispatch` for skills,
    /// bundles, quick commands and prompt builtins.
    private func runSlashCommand(_ command: ComposerSlashCommand, echo: String) {
        let key = "/\(command.name)"
        switch command.name {
        case "new", "reset":
            newChat(projectPath: sessionID.flatMap { createdSessionProjectPaths[$0] } ?? newSessionProjectPath)
            return
        case "stop":
            _ = stop()
            return
        case "resume":
            let query = command.arg.lowercased()
            guard !query.isEmpty,
                  let session = sessions.first(where: { $0.id == command.arg || $0.title.lowercased() == query })
                    ?? sessions.first(where: { $0.id.hasPrefix(command.arg) || $0.title.lowercased().contains(query) }) else {
                messages.append(ChatMessage(role: .user, text: echo))
                messages.append(ChatMessage(role: .hermes, text: command.arg.isEmpty
                    ? "Pick a session from the sidebar, or type `/resume <title>`."
                    : "No session matches “\(command.arg)”.", isError: !command.arg.isEmpty))
                return
            }
            resumeSession(session)
            return
        default:
            break
        }

        messages.append(ChatMessage(role: .user, text: echo))
        if command.name == "model" {
            // Desktop opens its picker here (`desktop="hidden"` in the catalog); Herm matches the arg.
            // ponytail: `--global` is ignored, the pick is session-scoped like Herm's model menu.
            let query = command.arg.split(separator: " ").filter { !$0.hasPrefix("--") }.joined(separator: " ").lowercased()
            guard !query.isEmpty else {
                messages.append(ChatMessage(role: .hermes, text: "Model: \(sessionModelValue ?? "Hermes default"). Type `/model <name>` or use the model menu."))
                return
            }
            guard let option = runtimeModelOptions.first(where: { $0.model.lowercased() == query })
                    ?? runtimeModelOptions.first(where: { $0.displayName.lowercased().contains(query) }) else {
                messages.append(ChatMessage(role: .hermes, text: "No model matches “\(query)”. Open the model menu to see what’s available.", isError: true))
                return
            }
            updateSessionModel(option)
            messages.append(ChatMessage(role: .hermes, text: "Switched to \(option.displayName)."))
            return
        }
        if isSlashCommandHidden(key) {
            let reason = slashCommandDispositions[key] ?? "terminal"
            messages.append(ChatMessage(role: .hermes, text: "`\(key)` isn’t available in Herm (\(reason)-only).", isError: true))
            return
        }

        let generation = sessionResumeGeneration
        isSending = true
        Task {
            defer { if self.sessionResumeGeneration == generation, self.status != .working { self.isSending = false } }
            do {
                try await sessionRPCClient.connect()
                let sessionID = try await createAuthorizedSession(source: "herm")
                guard self.sessionResumeGeneration == generation else { return }
                switch command.name {
                case "compress", "compact":
                    // session.compress, not slash.exec: the worker times out on large sessions.
                    _ = try await interruptRPC.compress(sessionID: sessionID, focusTopic: command.arg)
                    appendSlashOutput("Context compressed.", generation: generation)
                case "title" where !command.arg.isEmpty:
                    _ = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.sessionTitle.rawValue,
                        params: scopedSessionParams(["session_id": sessionID, "title": command.arg])
                    )
                    currentSessionTitle = command.arg
                    loadSessions()
                    appendSlashOutput("Renamed to “\(command.arg)”.", generation: generation)
                case "btw", "bg", "background":
                    guard !command.arg.isEmpty else {
                        appendSlashOutput("Usage: `\(key) <prompt>`", generation: generation, isError: true)
                        return
                    }
                    let isBtw = command.name == "btw"
                    let result = try await sessionRPCClient.request(
                        (isBtw ? HermesFeatureIDs.ID.promptBtw : .promptBackground).rawValue,
                        params: ["session_id": sessionID, "text": command.arg]
                    )
                    guard let taskID = result["task_id"] as? String, !taskID.isEmpty else {
                        appendSlashOutput("Hermes did not return a task ID.", generation: generation, isError: true)
                        return
                    }
                    slashSideTaskIDs.insert(taskID)
                    if !isBtw { registerBackgroundTask(id: taskID, prompt: command.arg, parentSessionID: sessionID) }
                    appendSlashOutput(isBtw ? "Asking on the side…" : "Started in the background.", generation: generation)
                default:
                    try await execSlashCommand(command, sessionID: sessionID, generation: generation)
                }
            } catch {
                appendSlashOutput("`\(key)` failed: \(Self.safeUserDiagnostic(error.localizedDescription))", generation: generation, isError: true)
            }
        }
    }

    private func execSlashCommand(_ command: ComposerSlashCommand, sessionID: String, generation: Int) async throws {
        let payload: [String: Any]
        do {
            let line = command.arg.isEmpty ? command.name : "\(command.name) \(command.arg)"
            payload = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.slashExec.rawValue,
                params: ["session_id": sessionID, "command": line]
            )
        } catch {
            // Skills, bundles and pending-input builtins refuse slash.exec.
            payload = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.commandDispatch.rawValue,
                params: ["session_id": sessionID, "name": command.name, "arg": command.arg]
            )
        }
        guard self.sessionResumeGeneration == generation else { return }

        let message = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let notice = (payload["notice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty {
            appendSlashOutput(notice, generation: generation)
        }
        switch payload["type"] as? String {
        case "alias":
            let target = (payload["target"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let aliased = ComposerSlashCommand("/\(target) \(command.arg)"), aliased.name != command.name {
                try await execSlashCommand(aliased, sessionID: sessionID, generation: generation)
            }
        case "prefill":
            if !message.isEmpty { draft = message }
        case "send", "skill":
            guard !message.isEmpty else {
                appendSlashOutput("`/\(command.name)`: empty message", generation: generation, isError: true)
                return
            }
            // The expanded skill body is model-facing; the transcript keeps the typed command.
            status = .working
            isSending = true
            _ = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.promptSubmit.rawValue,
                params: scopedSessionParams(["session_id": sessionID, "text": message])
            )
        default:
            let output = (payload["output"] as? String) ?? "(no output)"
            let warning = (payload["warning"] as? String).map { "warning: \($0)\n" } ?? ""
            appendSlashOutput(warning + output, generation: generation)
        }
    }

    private func appendSlashOutput(_ text: String, generation: Int, isError: Bool = false) {
        guard sessionResumeGeneration == generation else { return }
        if isError, status == .working {
            status = .idle
            isSending = false
        }
        messages.append(ChatMessage(role: .hermes, text: text, isError: isError))
    }

    /// Moves through the user prompts already present in the active session.
    /// Down past the newest prompt restores the draft that was present before
    /// history navigation began.
    func navigateComposerHistory(direction: Int) -> Bool {
        composer.navigate(direction: direction, history: userPromptHistory)
    }

    private var userPromptHistory: [String] {
        messages
            .filter { $0.role == .user }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    @discardableResult
    func pasteImageFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        // Text fields should keep their normal paste behavior. Some clipboard
        // managers publish image representations alongside textual content.
        guard pasteboard.string(forType: .string) == nil else {
            return false
        }
        let imageType = pasteboard.types?.first { $0 == .png || $0 == .tiff }
        guard let imageType else {
            return false
        }
        guard let data = pasteboard.data(forType: imageType),
              let nsImage = NSImage(data: data) else {
            pendingAttachmentError = "Could not paste image: the clipboard image could not be read."
            return false
        }
        return stageImage(nsImage)
    }

    func stageImageFile(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let nsImage = NSImage(contentsOf: url) else {
            pendingAttachmentError = "Could not attach image: \(url.lastPathComponent) could not be read."
            DebugLog.write("model: could not load image at \(url.path)")
            return
        }
        pendingImages.append(ImageAttachment(image: nsImage, fileURL: url))
        DebugLog.write("model: picked image \(url.lastPathComponent)")
    }

    func stagePDFFile(at url: URL) {
        pendingPDFError = nil
        guard url.pathExtension.lowercased() == "pdf" else {
            pendingPDFError = "Only PDF files can be attached as documents."
            return
        }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            pendingPDFError = "The PDF size could not be read."
            return
        }
        guard size <= 25 * 1024 * 1024 else {
            pendingPDFError = "PDF attachments are limited to 25 MB."
            return
        }
        pendingPDFURL = url
    }

    func reportPDFError(_ message: String) {
        pendingPDFError = message
    }

    func reportAttachmentError(_ message: String) {
        pendingAttachmentError = message
    }

    func clearAttachmentErrors() {
        pendingAttachmentError = nil
        pendingPDFError = nil
    }

    func removePendingPDF() {
        pendingPDFURL = nil
        pendingPDFError = nil
    }

    func removePendingImage(_ image: ImageAttachment) {
        cleanupImageAttachment(image)
        pendingImages.removeAll { $0.id == image.id }
    }

    func clearPendingImages() {
        cleanupImageAttachments(pendingImages)
        pendingImages = []
    }

    @discardableResult
    private func stageImage(_ nsImage: NSImage) -> Bool {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            pendingAttachmentError = "Could not paste image: the image could not be encoded."
            DebugLog.write("model: failed to encode pasted image as PNG")
            return false
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-paste-\(UUID().uuidString).png")
        do {
            try png.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        } catch {
            pendingAttachmentError = "Could not paste image: the image could not be saved."
            DebugLog.write("model: failed to write image temp file: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
        pendingImages.append(ImageAttachment(image: nsImage, fileURL: tempURL))
        DebugLog.write("model: staged pasted image at \(tempURL.lastPathComponent)")
        return true
    }

    private func cleanupImageAttachments(_ attachments: [ImageAttachment]) {
        attachments.forEach(cleanupImageAttachment)
    }

    private func cleanupImageAttachment(_ attachment: ImageAttachment?) {
        guard let attachment else { return }
        if attachment.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: attachment.fileURL)
        }
    }

    func toggleSessions() {
        isShowingSessions.toggle()
        if isShowingSessions { loadSessions() }
    }

    /// Re-home the foreground session surface and profile-owned conversation
    /// index. The old projection is cleared before the target request starts;
    /// late responses are rejected by the generation guard below.
    func setProfileScope(_ profileID: String?) {
        let normalized = profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = normalized?.isEmpty == false ? normalized : nil
        let nextUnavailable = next == nil
        guard profileScopeID != next || profileScopeUnavailable != nextUnavailable else {
            if sessionProfileID == nil { sessionProfileID = next }
            return
        }
        profileScopeID = next
        profileScopeUnavailable = nextUnavailable
        sessionProfileID = next
        if let next { defaults.set(next, forKey: profileScopeKey) }
        else { defaults.removeObject(forKey: profileScopeKey) }
        sessionLoadGeneration &+= 1
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        isLoadingSessions = false
        sessions = []
        sessionProjectionState = .loading
        newChat()
        loadSessions()
    }

    func artifactMessages(for session: HermesSession) async throws -> [[String: Any]] {
        // Hermes has no `session.messages` RPC; the REST transcript carries raw
        // tool calls, which is where written files are recorded.
        do {
            let result = try await interruptRPC.sessionMessages(sessionID: session.id, profileID: session.profileID)
            return result["data"] as? [[String: Any]] ?? result["messages"] as? [[String: Any]] ?? []
        } catch HermesGateway.GatewayError.httpError(404) {
            return [] // pruned since the session list was read
        }
    }

    func updateCurrentSessionTitle(_ title: String) {
        guard sessionID != nil else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        guard !trimmed.isEmpty,
              normalized != "untitled",
              normalized != "untitled chat",
              normalized != "untitled session",
              normalized != "hermes session" else { return }
        currentSessionTitle = trimmed
    }

    @discardableResult
    func loadSessions(profileID: String? = nil) -> Task<Void, Never>? {
        let scope = profileID ?? profileScopeID
        if profileScopeUnavailable, scope == nil {
            sessions = []
            sessionProjectionState = .empty
            return nil
        }
        guard !isLoadingSessions else { return nil }
        isLoadingSessions = true
        sessionLoadGeneration &+= 1
        let generation = sessionLoadGeneration
        let previousProjectionState = sessionProjectionState
        sessionProjectionState = Self.refreshingProjectionState(sessionProjectionState)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isLoadingSessions = false }
            do {
                try await sessionRPCClient.connect()
                var params: [String: Any] = ["limit": 50]
                if let scope, !scope.isEmpty { params["profile"] = scope }
                let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionList.rawValue, params: params)
                guard self.sessionLoadGeneration == generation, self.profileScopeID == scope else { return }
                guard let rawSessions = result["sessions"] as? [[String: Any]] else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let loaded = rawSessions.compactMap { Self.parseSession($0, profileID: scope) }
                await migrateLegacyLocalPins()
                let pinned = try? await Self.fetchPinnedSessions(client: sessionRPCClient, profileID: scope)
                guard self.sessionLoadGeneration == generation, self.profileScopeID == scope else { return }
                if let pinned { pinnedSessions = pinned }
                // The session index can lag behind the live gateway stream.
                // Keep a newer event timestamp until Hermes publishes an equal
                // or newer canonical row, so navigation never regresses its
                // visible “Updated” time after a completed message.
                let merged = self.applyPersistedUnreadState(Self.mergingSessionIndex(loaded, with: sessions, keeping: self.navigationSessionID))
                sessions = merged
                sessionProjectionState = merged.isEmpty ? .empty : .ready(merged)
                DebugLog.write("model: loaded \(sessions.count) saved sessions")
            } catch {
                guard self.sessionLoadGeneration == generation, self.profileScopeID == scope else { return }
                sessionProjectionState = Self.failedOrStale(previousProjectionState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
                DebugLog.write("model: session list failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
        sessionLoadTask = task
        return task
    }

    @discardableResult
    func deleteSession(_ session: HermesSession) async -> Bool {
        guard session.id != sessionID, session.id != sessionStorageID else {
            sessionDeletionError = "The active session cannot be deleted."
            return false
        }
        guard deletingSessionID == nil else { return false }
        sessionDeletionError = nil
        deletingSessionID = session.id
        defer { deletingSessionID = nil }
        do {
            try await sessionRPCClient.connect()
            var params: [String: Any] = ["session_id": session.id]
            if let profileID = session.profileID ?? profileScopeID { params["profile"] = profileID }
            _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionDelete.rawValue, params: params)
            sessions.removeAll { $0.id == session.id }
            DebugLog.write("model: deleted saved session \(session.id)")
            return true
        } catch {
            sessionDeletionError = "Could not delete the session: \(Self.safeUserDiagnostic(error.localizedDescription))"
            DebugLog.write("model: session delete failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    @discardableResult
    func setSessionHidden(_ session: HermesSession, hidden: Bool) async -> Bool {
        guard updatingSessionVisibilityID == nil else { return false }
        sessionVisibilityError = nil
        updatingSessionVisibilityID = session.id
        defer { updatingSessionVisibilityID = nil }
        do {
            try await sessionRPCClient.connect()
            var params: [String: Any] = ["session_id": session.id, "hidden": hidden]
            if let profileID = session.profileID ?? profileScopeID { params["profile"] = profileID }
            _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionSetHidden.rawValue, params: params)
            loadSessions()
            return true
        } catch {
            sessionVisibilityError = Self.safeUserDiagnostic(error.localizedDescription)
            return false
        }
    }

    func isSessionPinned(_ sessionID: String) -> Bool {
        pinnedSessions.contains { $0.id == sessionID }
    }

    /// Toggles Hermes' pin flag through the same `PATCH /api/sessions/{id}`
    /// Hermes Desktop uses, so a pin made here shows up there and in the CLI.
    @discardableResult
    func toggleSessionPinned(_ session: HermesSession) async -> Bool {
        guard pinningSessionID == nil else { return false }
        let pinned = !isSessionPinned(session.id)
        pinningSessionID = session.id
        defer { pinningSessionID = nil }
        do {
            try await Self.writeSessionPin(client: sessionRPCClient, sessionID: session.id,
                                           profileID: session.profileID ?? profileScopeID, pinned: pinned)
            // ponytail: optimistic local flip; a list page already in flight can
            // briefly show the old pin until the next load (Desktop fences this).
            if pinned { pinnedSessions.append(session) } else { pinnedSessions.removeAll { $0.id == session.id } }
            loadSessions()
            return true
        } catch {
            DebugLog.write("model: session pin failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    /// `/api/sessions` back-fills every pinned row past `limit`, so one row
    /// plus the pins is the full pinned set.
    static func fetchPinnedSessions(client: HermesRPCClientProtocol, profileID: String?) async throws -> [HermesSession] {
        var path = "/api/sessions?limit=1&order=recent"
        if let profileID, !profileID.isEmpty,
           let encoded = profileID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&profile=\(encoded)"
        }
        guard let rows = try await client.fetchHTTP(path)["sessions"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return rows.filter { $0["pinned"] as? Bool == true }.compactMap { parseSession($0, profileID: profileID) }
    }

    static func writeSessionPin(client: HermesRPCClientProtocol, sessionID: String, profileID: String?, pinned: Bool) async throws {
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        var body: [String: Any] = ["pinned": pinned]
        if let profileID, !profileID.isEmpty { body["profile"] = profileID }
        _ = try await client.sendHTTP("PATCH", path: "/api/sessions/\(encoded)", body: body)
    }

    /// One-time move of pins older Herm builds kept in UserDefaults into Hermes.
    /// Pins that fail to write (other than a deleted session) stay for the next load.
    private func migrateLegacyLocalPins() async {
        let key = "hermes.dock.pinned-sessions.v1"
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let references = saved["references"] as? [[String: String]] else { return }
        var remaining: [[String: String]] = []
        for reference in references {
            guard let sessionID = reference["sessionID"] else { continue }
            do {
                try await Self.writeSessionPin(client: sessionRPCClient, sessionID: sessionID,
                                               profileID: reference["profileID"], pinned: true)
            } catch HermesGateway.GatewayError.httpError(404), HermesGateway.GatewayError.httpRefused(404, _) {
                continue
            } catch {
                remaining.append(reference)
            }
        }
        if remaining.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONSerialization.data(withJSONObject: ["references": remaining]) {
            defaults.set(data, forKey: key)
        }
    }

    @discardableResult
    func renameSession(_ session: HermesSession, title: String) async -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, renamingSessionID == nil else { return false }
        renamingSessionID = session.id
        defer { renamingSessionID = nil }
        do {
            try await sessionRPCClient.connect()
            var params: [String: Any] = ["session_id": session.id, "title": cleanTitle]
            if let profileID = session.profileID ?? profileScopeID { params["profile"] = profileID }
            _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionTitle.rawValue, params: params)
            if session.id == sessionID { currentSessionTitle = cleanTitle }
            loadSessions()
            return true
        } catch {
            DebugLog.write("model: session rename failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    func clearSessionVisibilityError() {
        sessionVisibilityError = nil
    }

    func clearSessionDeletionError() {
        sessionDeletionError = nil
    }

    @discardableResult
    func restoreLatestSessionIfNeeded() -> Task<Void, Never>? {
        guard !didRestoreLatestSession else { return nil }
        didRestoreLatestSession = true
        guard !profileScopeUnavailable else {
            isRestoringSession = false
            sessionProjectionState = .empty
            return nil
        }
        restoreGeneration &+= 1
        let generation = restoreGeneration
        isRestoringSession = true
        let previousProjectionState = sessionProjectionState
        let scope = profileScopeID
        sessionProjectionState = .loading
        return Task {
            defer { isRestoringSession = false }
            do {
                try await sessionRPCClient.connect()
                let scopedLastSessionKey = lastSessionIDKey(for: scope)
                if let savedSessionID = defaults.string(forKey: scopedLastSessionKey),
                   !savedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   await resumeSession(HermesSession(id: savedSessionID, title: "", preview: "", startedAt: nil, messageCount: 0, source: ""), reportFailure: false) {
                    return
                }
                var listParams: [String: Any] = ["limit": 1]
                if let scope, !scope.isEmpty { listParams["profile"] = scope }
                let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionList.rawValue, params: listParams)
                guard generation == restoreGeneration else { return }
                guard let rawSessions = result["sessions"] as? [[String: Any]] else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let latest = rawSessions.compactMap { Self.parseSession($0, profileID: scope) }.first
                guard generation == restoreGeneration else { return }
                guard let latest else {
                    sessionProjectionState = .empty
                    defaults.removeObject(forKey: scopedLastSessionKey)
                    DebugLog.write("model: no saved session to restore")
                    return
                }
                guard generation == restoreGeneration else { return }
                sessions = [latest]
                sessionProjectionState = .ready([latest])
                guard generation == restoreGeneration else { return }
                _ = await resumeSession(latest, reportFailure: true)
            } catch {
                guard generation == restoreGeneration else { return }
                sessionProjectionState = Self.failedOrStale(previousProjectionState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
                DebugLog.write("model: latest session restore failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func resumeSession(_ session: HermesSession) {
        Task { _ = await resumeSession(session, reportFailure: true) }
    }

    /// Reloads the selected transcript from Hermes rather than patching the
    /// local array. Hermes remains authoritative for completed responses.
    func refreshCurrentSession() async {
        guard let sessionID, !sessionID.isEmpty else { return }
        _ = await resumeSession(
            HermesSession(
                id: sessionID,
                profileID: sessionProfileID ?? profileScopeID,
                title: currentSessionTitle ?? "",
                preview: "",
                startedAt: nil,
                messageCount: messages.count,
                source: "herm"
            ),
            reportFailure: true
        )
    }

    /// Creates a bounded Hermes branch from one completed message. The
    /// source message ID is sent to Hermes so the source conversation remains
    /// unchanged and the returned branch is the only conversation selected.
    func branchConversation(from message: ChatMessage) async {
        guard let sessionID, !sessionID.isEmpty,
              message.role == .hermes,
              message.hasBodyText else { return }
        do {
            var params: [String: Any] = [
                "session_id": sessionID,
                "message_id": message.id.uuidString
            ]
            if let profileID = sessionProfileID ?? profileScopeID, !profileID.isEmpty {
                params["profile"] = profileID
            }
            let result = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.sessionBranch.rawValue,
                params: params
            )
            let branchID = (result["session_id"] as? String)
                ?? (result["branch_session_id"] as? String)
                ?? (result["id"] as? String)
            guard let branchID, !branchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = await resumeSession(HermesSession(
                id: branchID,
                profileID: sessionProfileID ?? profileScopeID,
                title: "",
                preview: "",
                startedAt: nil,
                messageCount: 0,
                source: "herm"
            ), reportFailure: true)
        } catch {
            DebugLog.write("model: message branch failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
        }
    }

    @discardableResult
    private func resumeSession(_ session: HermesSession, reportFailure: Bool, profileID: String? = nil) async -> Bool {
        let owningProfileID = profileID ?? session.profileID ?? profileScopeID
        // The session queue uses Hermes' durable storage identity, whereas a
        // resume can expose a different runtime identity. Both identify the
        // same active conversation and must retain its unsent composer text.
        let isRefreshingActiveSession = session.id == sessionID || session.id == sessionStorageID
        if let sessionStorageID, streamingMessageID != nil {
            inFlightTurnActivityBySessionID[sessionStorageID] = streamingTurnActivity
        }
        commitStreamingMessage()
        if let sessionStorageID {
            cacheAgentState(for: sessionStorageID)
        }
        // Reopening the selected session refreshes its transcript, but is not
        // a session change. Its composer belongs to that active conversation
        // and must survive navigation through a Control page or a repeated
        // click in the session queue.
        if !isRefreshingActiveSession {
            resetComposerForSessionChange()
            invalidateRuntimeModelOptionsRefresh()
            if profileID == nil {
                detachInFlightBotActivities(as: .canceled)
            }
        }
        // A refresh re-reads at least as much history as the reader already
        // paged in, so refreshing never collapses the transcript they scrolled.
        let refreshedTranscriptRowCount = isRefreshingActiveSession ? (transcriptHistoryCursor?.nextOffset ?? 0) : 0
        sessionResumeGeneration &+= 1
        interruptGeneration &+= 1
        let resumeGeneration = sessionResumeGeneration
        transcriptHistoryCursor = nil
        isLoadingEarlierTranscript = false
        isLoadingTranscriptHistory = false
        earlierTranscriptRetryAfter = nil
        transcriptTimeline = []
        transcriptMessageIDsByRowID = [:]
        sessionID = session.id
        updateSessionActivity(sessionID: session.id, unread: false)
        sessionProfileID = owningProfileID
        kanbanAttributionSessionID = session.id
        activeBotProfileID = profileID
        activeBotDisplayName = profileID == nil ? nil : session.displayTitle
        // The old transcript belongs exclusively to the session that was just
        // left. Clear the visible projection before awaiting the new session's
        // resume response; otherwise the old conversation is rendered under
        // the new session ID during that request's loading window.
        if !isRefreshingActiveSession {
            messages = []
        }
        streamingText.clearPresentation()
        newSessionCreationAuthorized = false
        clarificationQuestion = nil
        clarificationChoices = []
        clarificationRequestID = nil
        presentedClarificationRequestIDs = []
        clarificationResponseError = nil
        approvalTitle = nil
        approvalText = nil
        isRespondingToApproval = false
        isRespondingToClarification = false
        sessionModelOptionID = nil
        sessionModelValue = nil
        sessionReasoningVariant = nil
        sessionStorageID = session.id
        _ = restoreAgentState(for: session.id)
        isShowingSessions = false
        isSending = false
        status = .working
        interruptState = .idle
        reasoningState = nil
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        streamingReasoningBuffer = ""
        streamingMessageID = nil
        streamingMessageSessionID = nil
        streamingMessageIsVisionNotice = false
        currentSessionTitle = session.displayTitle
        restorePendingApproval(for: [session.id])
        do {
            try await sessionRPCClient.connect()
            var resumeParams: [String: Any] = [
                "session_id": session.id,
                "source": "herm",
                // Page the transcript over REST instead of shipping it whole in
                // this response: long sessions produced multi-megabyte frames
                // and parsed thousands of rows nobody had scrolled to. Hermes
                // hydrates the model history in the background either way.
                "defer_history": true,
                "omit_messages": true,
            ]
            if let owningProfileID, !owningProfileID.isEmpty { resumeParams["profile"] = owningProfileID }
            let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionResume.rawValue, params: resumeParams)
            guard resumeGeneration == sessionResumeGeneration, sessionID == session.id else { return false }
            let reportedSessionID = (result["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSessionID = (reportedSessionID?.isEmpty == false) ? reportedSessionID! : session.id
            // The response must prove it belongs to the conversation the user
            // opened. While another session is responding, the gateway can
            // resolve `session.resume` to that active session; adopting its
            // identity and transcript here would project one session's
            // conversation into another, so fail closed instead.
            guard Self.resumeResponseProvesSessionOwnership(
                requestedSessionID: session.id,
                resolvedSessionID: resolvedSessionID,
                result: result
            ) else {
                guard resumeGeneration == sessionResumeGeneration, sessionID == session.id else { return false }
                let safeMessage = "Hermes returned a different session than the one requested. Try opening it again."
                sessionProjectionState = Self.failedOrStale(sessionProjectionState, safeMessage: safeMessage)
                if reportFailure {
                    status = .offline
                    messages = [ChatMessage(role: .hermes, text: "I couldn't load that conversation: \(safeMessage)", modelName: currentModelName)]
                    scrollToLatestMessageRequest &+= 1
                }
                DebugLog.write("model: session resume mismatch: requested \(session.id), resolved \(resolvedSessionID)")
                return false
            }
            sessionID = resolvedSessionID
            kanbanAttributionSessionID = Self.kanbanAttributionAfterResume(
                requestedSessionID: session.id,
                resolvedSessionID: resolvedSessionID
            )
            sessionStorageID = Self.stableSessionID(from: result) ?? session.id
            restorePendingApproval(for: [session.id, resolvedSessionID, sessionStorageID])
            persistActiveSessionID(sessionID)
            let model = (result["model"] as? String) ?? (result["model_name"] as? String)
            if let model {
                currentModelName = model
                sessionModelValue = model
            }
            refreshSessionModelOptions()
            refreshSessionReasoningVariant()
            guard result["messages"] is [[String: Any]] else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            var transcriptRows = result["messages"]
            if TranscriptHistoryPaging.resumeResponseDefersTranscript(result),
               let storageID = sessionStorageID {
                let tail = try await loadTranscriptTail(
                    storageSessionID: storageID,
                    profileID: owningProfileID,
                    minimumRowCount: refreshedTranscriptRowCount,
                    fallbackResumeParams: resumeParams
                )
                guard resumeGeneration == sessionResumeGeneration else { return false }
                transcriptRows = tail.rows
                transcriptHistoryCursor = tail.cursor
            }
            let restored = Self.parseMessages(
                transcriptRows,
                defaultBotProfileID: profileID,
                defaultBotDisplayName: profileID == nil ? nil : session.displayTitle
            )
            transcriptMessageIDsByRowID = restored.rowIDs
            // A turn that went live while the transcript loaded keeps its row.
            let liveRow = streamingMessageID.flatMap { id in messages.first { $0.id == id } }
            messages = restored.messages + [liveRow].compactMap { $0 }
            let stashedTurnActivity = sessionStorageID.flatMap { inFlightTurnActivityBySessionID.removeValue(forKey: $0) }
            if liveRow == nil, (result["running"] as? Bool) == true {
                adoptRunningTurn(inflight: result["inflight"] as? [String: Any], activity: stashedTurnActivity ?? [])
            }
            rehydratePendingTranscriptImages(
                restored.pendingImages,
                requestedSessionID: session.id
            )
            if transcriptHistoryCursor?.hasMore == true {
                loadTranscriptTimeline(generation: resumeGeneration)
            }
            restorePendingClarification(for: [session.id, resolvedSessionID, sessionStorageID])
            mergePersistedBotActivities(for: [session.id, sessionStorageID, kanbanAttributionSessionID])
            projectBotMessagesIntoActivity()
            scrollToLatestMessageRequest &+= 1
            cacheCurrentAgentState()
            refreshDelegationStatus()
            startDelegationMonitoring()
            if approvalText == nil, clarificationQuestion == nil, streamingMessageID == nil {
                status = .idle
            }
            DebugLog.write("model: resumed session \(session.id) (\(messages.count) messages, \(activeSubagents.count) rehydrated agents)")
            return true
        } catch {
            guard resumeGeneration == sessionResumeGeneration, sessionID == session.id else { return false }
            sessionProjectionState = Self.failedOrStale(sessionProjectionState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
            if reportFailure, !isRefreshingActiveSession {
                status = .offline
                messages = [ChatMessage(role: .hermes, text: "I couldn't load that conversation: \(Self.safeUserDiagnostic(error.localizedDescription))", modelName: currentModelName)]
                scrollToLatestMessageRequest &+= 1
            } else if reportFailure {
                status = .offline
            }
            DebugLog.write("model: session resume failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    /// Reads the newest stored rows of a paged resume. When the REST read is
    /// unavailable, falls back to one resume that inlines the transcript
    /// (the session is live by now, so Hermes answers from memory).
    private func loadTranscriptTail(
        storageSessionID: String,
        profileID: String?,
        minimumRowCount: Int,
        fallbackResumeParams: [String: Any]
    ) async throws -> (rows: [[String: Any]], cursor: TranscriptHistoryCursor?) {
        let cursor = TranscriptHistoryCursor(storageSessionID: storageSessionID, profileID: profileID)
        let limit = min(
            TranscriptHistoryPaging.maximumPageRowLimit,
            max(TranscriptHistoryPaging.pageRowLimit, minimumRowCount)
        )
        do {
            let loaded = try await fetchEarlierTranscriptRows(
                from: cursor,
                limit: limit,
                minimumDisplayRows: ConversationMessageWindow.initialLimit
            )
            return (loaded.rows, loaded.cursor)
        } catch {
            DebugLog.write("model: transcript page read failed, resuming inline: \(Self.safeUserDiagnostic(error.localizedDescription))")
            var params = fallbackResumeParams
            params.removeValue(forKey: "defer_history")
            params.removeValue(forKey: "omit_messages")
            let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionResume.rawValue, params: params)
            guard let rows = result["messages"] as? [[String: Any]] else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            return (rows, nil)
        }
    }

    /// Reads older pages until at least `minimumDisplayRows` visible messages
    /// arrive or history is exhausted. Returned rows are display-projected and
    /// chronological.
    private func fetchEarlierTranscriptRows(
        from start: TranscriptHistoryCursor,
        limit: Int,
        minimumDisplayRows: Int,
        maximumPages: Int = TranscriptHistoryPaging.maximumPagesPerLoad,
        through targetRowID: Int? = nil
    ) async throws -> (rows: [[String: Any]], cursor: TranscriptHistoryCursor) {
        var cursor = start
        var collected: [[String: Any]] = []
        var pagesRead = 0
        while cursor.hasMore, pagesRead < maximumPages {
            guard let path = TranscriptHistoryPaging.pagePath(
                sessionID: cursor.storageSessionID,
                profileID: cursor.profileID,
                limit: limit,
                offset: cursor.nextOffset
            ) else { throw HermesGateway.GatewayError.malformedResponse }
            guard let page = TranscriptHistoryPaging.page(from: try await sessionRPCClient.fetchHTTP(path)) else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            pagesRead += 1
            let fresh = TranscriptHistoryPaging.advance(&cursor, with: page, limit: limit)
            collected = TranscriptHistoryPaging.displayRows(fromStoredRows: fresh) + collected
            if let targetRowID {
                if cursor.seenRowIDs.contains(targetRowID) { break }
            } else if collected.filter({ !(($0["text"] as? String) ?? "").isEmpty }).count >= minimumDisplayRows {
                break
            }
        }
        return (collected, cursor)
    }

    var canLoadEarlierTranscript: Bool {
        guard let cursor = transcriptHistoryCursor, cursor.hasMore, !isLoadingEarlierTranscript else { return false }
        return cursor.storageSessionID == sessionStorageID
    }

    /// Prepends the next page of stored history once the reader reaches the
    /// oldest loaded message.
    func loadEarlierTranscriptIfAvailable() {
        guard canLoadEarlierTranscript, let cursor = transcriptHistoryCursor else { return }
        if let retryAfter = earlierTranscriptRetryAfter, retryAfter > Date() { return }
        isLoadingEarlierTranscript = true
        let generation = sessionResumeGeneration
        Task { @MainActor in
            defer {
                if generation == sessionResumeGeneration { isLoadingEarlierTranscript = false }
            }
            do {
                let loaded = try await fetchEarlierTranscriptRows(
                    from: cursor,
                    limit: TranscriptHistoryPaging.pageRowLimit,
                    minimumDisplayRows: 1
                )
                guard generation == sessionResumeGeneration,
                      sessionStorageID == cursor.storageSessionID else { return }
                earlierTranscriptRetryAfter = nil
                prependEarlierTranscript(loaded.rows, cursor: loaded.cursor)
            } catch {
                guard generation == sessionResumeGeneration else { return }
                // Scroll events call this continuously at the top edge; back
                // off instead of re-requesting a failing page on every frame.
                earlierTranscriptRetryAfter = Date().addingTimeInterval(5)
                DebugLog.write("model: earlier transcript page failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    private func prependEarlierTranscript(_ rows: [[String: Any]], cursor: TranscriptHistoryCursor) {
        transcriptHistoryCursor = cursor
        // Loaded prompts leave the navigator's unloaded list with the cursor.
        cachedMessageNavigatorItems = nil
        let restored = Self.parseMessages(
            rows,
            defaultBotProfileID: activeBotProfileID,
            defaultBotDisplayName: activeBotDisplayName
        )
        guard !restored.messages.isEmpty else { return }
        transcriptMessageIDsByRowID.merge(restored.rowIDs) { current, _ in current }
        transcriptPrependGeneration &+= 1
        lastTranscriptPrepend = TranscriptHistoryPrepend(
            generation: transcriptPrependGeneration,
            count: restored.messages.count,
            resultingCount: messages.count + restored.messages.count
        )
        messages.insert(contentsOf: restored.messages, at: 0)
        if let sessionID {
            rehydratePendingTranscriptImages(restored.pendingImages, requestedSessionID: sessionID)
        }
        DebugLog.write("model: loaded \(restored.messages.count) earlier messages (offset \(cursor.nextOffset))")
    }

    /// Stored prompts older than the loaded transcript, oldest first.
    var unloadedTranscriptPrompts: [TranscriptTimelineEntry] {
        guard let cursor = transcriptHistoryCursor, cursor.hasMore,
              cursor.storageSessionID == sessionStorageID else { return [] }
        return transcriptTimeline.filter { !cursor.seenRowIDs.contains($0.rowID) }
    }

    /// True while stored history older than the loaded transcript remains.
    var hasUnloadedTranscript: Bool {
        guard let cursor = transcriptHistoryCursor else { return false }
        return cursor.hasMore && cursor.storageSessionID == sessionStorageID
    }

    /// Reads the prompt timeline of the paged transcript so the navigator can
    /// list and search prompts that are not loaded yet. Failure leaves the
    /// navigator covering loaded messages only.
    private func loadTranscriptTimeline(generation: Int) {
        guard let cursor = transcriptHistoryCursor else { return }
        Task { @MainActor in
            var entries: [TranscriptTimelineEntry] = []
            var after = 0
            do {
                for _ in 0..<TranscriptHistoryPaging.maximumTimelinePages {
                    guard let path = TranscriptHistoryPaging.timelinePath(
                        sessionID: cursor.storageSessionID,
                        profileID: cursor.profileID,
                        afterRowID: after
                    ), let page = TranscriptHistoryPaging.timelinePage(
                        from: try await sessionRPCClient.fetchHTTP(path)
                    ) else { break }
                    entries += page.entries
                    guard let next = page.nextCursor, next > after else { break }
                    after = next
                }
            } catch {
                DebugLog.write("model: transcript timeline read failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
            guard generation == sessionResumeGeneration,
                  sessionStorageID == cursor.storageSessionID else { return }
            transcriptTimeline = entries
        }
    }

    /// Loads all older history through `rowID` (or all of it when nil) in one
    /// prepend and returns the loaded message to show for that row. Search and
    /// navigator jumps use this; scrolling keeps reading page by page.
    @discardableResult
    func loadTranscriptHistory(through rowID: Int?) async -> UUID? {
        let generation = sessionResumeGeneration
        while isLoadingEarlierTranscript {
            try? await Task.sleep(for: .milliseconds(20))
            guard generation == sessionResumeGeneration else { return nil }
        }
        if let rowID, let loaded = loadedMessageID(forRowID: rowID) { return loaded }
        guard hasUnloadedTranscript, let cursor = transcriptHistoryCursor else {
            return rowID.flatMap(loadedMessageID(forRowID:))
        }
        isLoadingEarlierTranscript = true
        isLoadingTranscriptHistory = true
        defer {
            if generation == sessionResumeGeneration {
                isLoadingEarlierTranscript = false
                isLoadingTranscriptHistory = false
            }
        }
        do {
            let loaded = try await fetchEarlierTranscriptRows(
                from: cursor,
                limit: TranscriptHistoryPaging.maximumPageRowLimit,
                minimumDisplayRows: .max,
                maximumPages: .max,
                through: rowID
            )
            guard generation == sessionResumeGeneration,
                  sessionStorageID == cursor.storageSessionID else { return nil }
            earlierTranscriptRetryAfter = nil
            prependEarlierTranscript(loaded.rows, cursor: loaded.cursor)
        } catch {
            guard generation == sessionResumeGeneration else { return nil }
            DebugLog.write("model: transcript history read failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return nil
        }
        return rowID.flatMap(loadedMessageID(forRowID:))
    }

    /// The message for a stored row, or the next loaded message after it when
    /// that row itself has no visible message.
    private func loadedMessageID(forRowID rowID: Int) -> UUID? {
        if let exact = transcriptMessageIDsByRowID[rowID] { return exact }
        guard let next = transcriptMessageIDsByRowID.keys.filter({ $0 > rowID }).min(),
              transcriptHistoryCursor?.seenRowIDs.contains(rowID) == true else { return nil }
        return transcriptMessageIDsByRowID[next]
    }

    func resumeBotChat(_ bot: BotSummary) {
        // Every Bot has a canonical, persistent Bot Chat. When the roster row
        // has no canonical session pointer yet, Hermes resolves (and lazily
        // creates) the chat by its exact title during profile-scoped resume.
        let chat = bot.chat ?? BotChatReference(sessionID: BotService.canonicalBotChatTitle, profileID: bot.id)
        Task { _ = await resumeSession(HermesSession(id: chat.sessionID, title: bot.name, preview: chat.preview ?? "", startedAt: chat.lastActive, messageCount: 0, source: "hermes-bot"), reportFailure: true, profileID: chat.profileID) }
    }

    /// Routes an explicit, unambiguous Bot mention through Hermes' relay
    /// contract. Relay owns the Bot Chat turn; this model keeps the foreground
    /// session untouched and projects the returned reply into its transcript.
    /// Generic `delegate_task` workers are never relabelled as the Bot.
    func sendDirectBotRequest(profileID: String, displayName: String, text: String, chatSessionID: String? = nil) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty,
              !isSending,
              !isUpdatingSessionModel,
              !isRestoringSession,
              pendingImages.isEmpty,
              pendingPDFURL == nil,
              let currentSessionID = sessionID,
              !currentSessionID.isEmpty,
              let originSessionID = sessionStorageID ?? sessionID,
              !originSessionID.isEmpty else { return }

        let explicitBotSessionID = chatSessionID
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let activity = BotActivityRecord(originSessionID: originSessionID, botID: profileID, botName: displayName, summary: request, botChatSessionID: explicitBotSessionID)
        inFlightBotActivities[activity.id] = InFlightBotActivity(activityID: activity.id, originSessionID: originSessionID, botID: profileID, botChatSessionID: explicitBotSessionID, clarificationRequestID: nil)
        insertBotActivity(activity)
        if explicitBotSessionID != nil {
            updateBotActivity(id: activity.id, state: .working)
        }
        let sendGeneration = sessionResumeGeneration
        let transcriptText = "@\(displayName) \(request)"
        let relayMessage = Self.botRelayMessage(request: request, transcript: messages)
        draft = ""
        messages.append(ChatMessage(role: .user, text: transcriptText))
        status = .working
        isSending = true
        Task {
            do {
                try await sessionRPCClient.connect()
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == currentSessionID else { return }
                let result = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.botRelayDeliver.rawValue,
                    params: ["profile": profileID, "message": relayMessage]
                )
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == currentSessionID else { return }
                let reply = (result["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let reportedBotSessionID = (result["session_id"] as? String) ?? (result["bot_session_id"] as? String)
                let botSessionID = reportedBotSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let botSessionID, !botSessionID.isEmpty {
                    self.inFlightBotActivities[activity.id]?.botChatSessionID = botSessionID
                    self.updateBotActivity(id: activity.id, state: .working, botChatSessionID: botSessionID)
                }
                if reply.isEmpty {
                    // Relay already accepted and owns the asynchronous turn.
                    // Without Hermes' explicit session correlation, retain
                    // this activity as unresolved rather than guessing or
                    // resubmitting through a canonical Bot Chat.
                    status = .idle
                    isSending = false
                    return
                }
                messages.append(ChatMessage(role: .hermes, text: reply, botProfileID: profileID, botDisplayName: displayName))
                updateBotActivity(id: activity.id, state: .completed, result: reply)
                inFlightBotActivities.removeValue(forKey: activity.id)
                status = .idle
                isSending = false
            } catch {
                guard self.sessionResumeGeneration == sendGeneration,
                      self.sessionID == currentSessionID else { return }
                let message = "\(displayName) couldn’t process this request: \(Self.safeUserDiagnostic(error.localizedDescription))"
                messages.append(ChatMessage(role: .hermes, text: message, isError: true, botProfileID: profileID, botDisplayName: displayName))
                updateBotActivity(id: activity.id, state: .failed, result: message)
                inFlightBotActivities.removeValue(forKey: activity.id)
                status = .idle
                isSending = false
            }
        }
    }

    private func projectBotMessagesIntoActivity() {
        guard let originSessionID = sessionStorageID ?? sessionID, !originSessionID.isEmpty else { return }
        var existing = Set(botActivityBySessionID[originSessionID, default: []].compactMap { $0.result })
        for (index, message) in messages.enumerated() {
            guard let botID = message.botProfileID,
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !existing.contains(message.text) else { continue }
            let request = index > 0 && messages[index - 1].role == .user
                ? messages[index - 1].text
                : "Bot response"
            insertBotActivity(BotActivityRecord(
                originSessionID: originSessionID,
                botID: botID,
                botName: message.botDisplayName ?? botID,
                summary: request,
                state: .completed,
                createdAt: message.timestamp,
                updatedAt: message.timestamp,
                result: message.text
            ))
            existing.insert(message.text)
        }
    }

    static func botRelayMessage(request: String, transcript: [ChatMessage]) -> String {
        let context = transcript.suffix(24).compactMap { message -> String? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let role = message.role == .user ? "User" : (message.botDisplayName ?? "Assistant")
            return "\(role): \(text.prefix(1000))"
        }.joined(separator: "\n")
        guard !context.isEmpty else { return request }
        return "[CURRENT SESSION CONTEXT — reference only]\n\(context)\n[END CURRENT SESSION CONTEXT]\n\nRespond to this request: \(request)"
    }

    private func mergePersistedBotActivities(for sessionIDs: [String?]) {
        var seenActivityIDs = Set<String>()
        for sessionID in sessionIDs.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            guard let records = botActivityBySessionID[sessionID] else { continue }
            for record in records {
                guard seenActivityIDs.insert(record.id).inserted,
                      record.state == .completed,
                      let result = record.result?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !result.isEmpty else { continue }
                let userText = "@\(record.botName) \(record.summary)"
                let alreadyPresent = messages.contains { $0.text == result && $0.botProfileID == record.botID }
                guard !alreadyPresent else { continue }
                messages.append(ChatMessage(role: .user, text: userText, timestamp: record.createdAt))
                messages.append(ChatMessage(role: .hermes, text: result, timestamp: record.updatedAt, botProfileID: record.botID, botDisplayName: record.botName))
            }
        }
        messages.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func insertBotActivity(_ record: BotActivityRecord) {
        botActivityBySessionID[record.originSessionID, default: []].append(record)
        botActivityRevision &+= 1
        enqueueBotActivityPersistence()
    }

    private func updateBotActivity(id: String, state: BotActivityState, result: String? = nil, botChatSessionID: String? = nil) {
        for originSessionID in botActivityBySessionID.keys {
            guard let index = botActivityBySessionID[originSessionID]?.firstIndex(where: { $0.id == id }) else { continue }
            var record = botActivityBySessionID[originSessionID]![index]
            guard record.state != .completed, record.state != .failed, record.state != .canceled else { return }
            record.state = state
            record.updatedAt = Date()
            if result != nil { record.result = result }
            if botChatSessionID != nil { record.botChatSessionID = botChatSessionID }
            botActivityBySessionID[originSessionID]![index] = record
            botActivityRevision &+= 1
            enqueueBotActivityPersistence()
            return
        }
    }

    private func enqueueBotActivityPersistence() {
        let snapshot = botActivityBySessionID
        Task { await botActivityWriter.enqueue(snapshot) }
    }

    private func markBotActivityFailed(originSessionID: String?, result: String) {
        let activities = Array(inFlightBotActivities.values)
        for activity in activities where activity.originSessionID == originSessionID {
            updateBotActivity(id: activity.activityID, state: .failed, result: result)
            inFlightBotActivities.removeValue(forKey: activity.activityID)
        }
    }

    private func markBotActivityFailed(id: String, result: String) {
        guard inFlightBotActivities[id] != nil else { return }
        updateBotActivity(id: id, state: .failed, result: result)
        inFlightBotActivities.removeValue(forKey: id)
    }

    private func updateInFlightBotActivity(for eventSessionID: String?, state: BotActivityState, result: String? = nil) {
        guard let eventSessionID else { return }
        let activities = Array(inFlightBotActivities.values)
        for activity in activities {
            guard activity.botChatSessionID == eventSessionID else { continue }
            updateBotActivity(id: activity.activityID, state: state, result: result)
            if state == .completed || state == .failed || state == .canceled {
                inFlightBotActivities.removeValue(forKey: activity.activityID)
            }
        }
    }

    private func setInFlightBotActivityWorking(for eventSessionID: String?) {
        guard let eventSessionID else { return }
        for activity in inFlightBotActivities.values where activity.botChatSessionID == eventSessionID {
            updateBotActivity(id: activity.activityID, state: .working)
        }
    }

    private func setInFlightBotActivityWaiting(for eventSessionID: String?, requestID: String? = nil) {
        guard let eventSessionID else { return }
        for activity in inFlightBotActivities.values where activity.botChatSessionID == eventSessionID {
            inFlightBotActivities[activity.activityID]?.clarificationRequestID = requestID
            updateBotActivity(id: activity.activityID, state: .waiting)
        }
    }

    private func updateInFlightBotActivity(for requestID: String, state: BotActivityState, result: String?) {
        let activities = Array(inFlightBotActivities.values)
        for activity in activities where activity.clarificationRequestID == requestID {
            updateBotActivity(id: activity.activityID, state: state, result: result)
            if state == .completed || state == .failed || state == .canceled {
                inFlightBotActivities.removeValue(forKey: activity.activityID)
            }
        }
    }

    private func detachInFlightBotActivities(as state: BotActivityState) {
        let activities = Array(inFlightBotActivities.values)
        for activity in activities {
            updateBotActivity(id: activity.activityID, state: state)
        }
        inFlightBotActivities.removeAll()
    }

    private func resetComposerForSessionChange() {
        composer.reset()
        clearPendingImages()
        removePendingPDF()
    }

    func newChat(projectPath: String? = nil) {
        detachInFlightBotActivities(as: .canceled)
        commitStreamingMessage()
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        streamingMessageGeneration &+= 1
        if let sessionStorageID {
            cacheAgentState(for: sessionStorageID)
        }
        resetComposerForSessionChange()
        invalidateRuntimeModelOptionsRefresh()
        sessionResumeGeneration &+= 1
        restoreGeneration &+= 1
        interruptGeneration &+= 1
        delegationMonitoringTask?.cancel()
        delegationMonitoringTask = nil
        sessionID = nil
        activeBotProfileID = nil
        activeBotDisplayName = nil
        sessionProfileID = profileScopeID
        sessionStorageID = nil
        newSessionCreationAuthorized = true
        newSessionProjectPath = projectPath
        clarificationQuestion = nil
        clarificationChoices = []
        clarificationRequestID = nil
        presentedClarificationRequestIDs = []
        clarificationResponseError = nil
        approvalTitle = nil
        approvalText = nil
        isRespondingToApproval = false
        isRespondingToClarification = false
        defaults.removeObject(forKey: lastSessionIDKey(for: sessionProfileID ?? profileScopeID))
        currentSessionTitle = nil
        currentModelName = nil
        sessionModelOptionID = nil
        sessionModelValue = nil
        sessionReasoningVariant = nil
        messages = []
        activeToolCalls = []
        reasoningState = nil
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        streamingReasoningBuffer = ""
        recentEvents = []
        streamingMessageID = nil
        streamingMessageSessionID = nil
        streamingResponseStartedAt = nil
        streamingMessageBuffer = ""
        streamingMessagePendingPresentationDelta = ""
        streamingMessagePublishedText = ""
        conversationActivityPhase = .idle
        streamingMessageIsVisionNotice = false
        isSending = false
        status = .idle
        interruptState = .idle
        isShowingSessions = false
        activeSubagents = []
        sessionAgents = []
        agentActivities = []
        synthesizedSubagentIDs = []
    }

    /// Creates the project-scoped session immediately after a directory is
    /// selected, so the Projects action has an observable result before the
    /// first prompt is typed.
    func startNewChat(in projectPath: String) async {
        newChat(projectPath: projectPath)
        sessionProjectionState = .loading
        do {
            try await sessionRPCClient.connect()
            _ = try await createAuthorizedSession(source: "herm")
        } catch {
            sessionProjectionState = .failed(safeMessage: "Hermes could not start a new session. Try again.")
            DebugLog.write("model: project chat creation failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
        }
    }

    static func failedOrStale<Value: Equatable & Sendable>(_ state: HermesProjectionState<Value>, safeMessage: String) -> HermesProjectionState<Value> {
        switch state {
        case .ready(let value), .stale(let value, _): return .stale(value, safeMessage: safeMessage)
        default: return .failed(safeMessage: safeMessage)
        }
    }

    /// Background session refreshes keep the last authoritative list visible.
    /// Only a projection without a successful value may enter the loading state.
    static func refreshingProjectionState<Value: Equatable & Sendable>(_ state: HermesProjectionState<Value>) -> HermesProjectionState<Value> {
        switch state {
        case .ready(let value), .stale(let value, _):
            return .stale(value, safeMessage: "Refreshing conversations…")
        default:
            return .loading
        }
    }

    func cacheAgentState(for sessionID: String) {
        guard !sessionID.isEmpty else { return }
        agentStateBySessionID[sessionID] = SessionAgentState(
            activeToolCalls: activeToolCalls,
            recentEvents: recentEvents,
            sessionAgents: sessionAgents,
            activeSubagents: activeSubagents,
            agentActivities: agentActivities,
            synthesizedSubagentIDs: synthesizedSubagentIDs
        )
        agentStateStore.save(agentStateBySessionID)
    }

    /// Makes one session snapshot the sole owner of the visible agent board.
    /// Missing snapshots deliberately produce an empty board so another
    /// session's agents can never leak into a newly opened conversation.
    @discardableResult
    func restoreAgentState(for sessionID: String) -> Bool {
        guard let state = agentStateBySessionID[sessionID] else {
            activeToolCalls = []
            recentEvents = []
            sessionAgents = []
            activeSubagents = []
            agentActivities = []
            synthesizedSubagentIDs = []
            return false
        }
        activeToolCalls = state.activeToolCalls
        recentEvents = state.recentEvents
        sessionAgents = state.sessionAgents
        // Persisted spawn rows are history, not proof that a worker is still
        // live. Only a current delegation.status result or fresh subagent.*
        // event may populate the live map.
        activeSubagents = []
        agentActivities = state.agentActivities
        synthesizedSubagentIDs = state.synthesizedSubagentIDs
        return true
    }

    func markPopoverVisible() {
        isPopoverVisible = true
        hasUnreadResponse = false
    }

    /// Debug-only fixture activation. It uses the same session ownership
    /// boundary as gateway events so the streaming fixture can exercise the
    /// production `message.start`/delta/complete path without touching the
    /// transcript array per delta.
    func prepareScrollPerformanceFixtureSession(_ session: HermesSession) {
        sessionID = session.id
        sessionStorageID = session.id
        sessionProfileID = session.profileID
        kanbanAttributionSessionID = session.id
        status = .idle
    }

    func markUnreadUpdate() {
        guard !isPopoverVisible else { return }
        hasUnreadResponse = true
    }

    /// The command center consumes the global Hermes stream, while the
    /// conversation handler below intentionally filters events to its active
    /// session. Own unread state at this shared boundary so attention from a
    /// different session cannot appear in Control without reaching the menu bar.
    func receiveGatewayEvent(_ type: String, params: [String: Any]) {
        guard acceptGatewayEvent(type: type, params: params) else { return }
        captureObservedKanbanTaskIDs(type: type, params: params)
        eventRouter.route(type: type, params: params)
        reconcileDirectBotLifecycle(type: type, params: params)
        capturePendingApproval(type: type, params: params)
        capturePendingClarification(type: type, params: params)
        let eventPayload = params["payload"] as? [String: Any] ?? [:]
        let eventSessionID = (params["session_id"] as? String) ?? (eventPayload["session_id"] as? String)
        if type == "message.start" || type == "message.complete" || type == "sessions.changed" {
            touchSession(sessionID: eventSessionID, at: dateValue(params["timestamp"]) ?? dateValue(eventPayload["timestamp"]) ?? Date())
        }
        if type == "message.start", let eventSessionID {
            updateSessionActivity(sessionID: eventSessionID, isWorking: true)
        }
        if let eventSessionID {
            updateSessionActivityLabel(sessionID: eventSessionID, type: type, payload: eventPayload)
        }
        // `sessions.changed` is a notification, not a new session snapshot.
        // Re-read the authoritative index after a turn completes so titles,
        // previews, and project membership in the left navigation are current.
        // Coalescing keeps a busy stream from issuing an index request for
        // every event.
        if type == "message.complete" || type == "sessions.changed" {
            refreshSessionIndexAfterActivity()
        }
        if Self.isUnreadUpdateEvent(type) {
            markUnreadUpdate()
            if let eventSessionID {
                updateSessionActivity(sessionID: eventSessionID, isWorking: false, unread: eventSessionID != sessionID)
            }
        }
        handleEvent(type, params: params)
    }

    /// Hermes frequently clears completed terminal rows before the next
    /// session-Kanban polling pass. Capture an exact task ID at the gateway
    /// boundary, while the command/result still exists, so a task whose
    /// database row lacks `session_id` can remain visible to its owner.
    private func captureObservedKanbanTaskIDs(type: String, params: [String: Any]) {
        guard type == "tool.call" || type == "tool.start" || type == "tool.use" || type == "tool_use"
                || type == "tool.result" || type == "tool_result" || type == "tool.complete" || type == "tool_complete",
              let currentSessionID = sessionID else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        let envelopeSessionID = params["session_id"] as? String
        let eventSessionID = envelopeSessionID ?? (payload["session_id"] as? String)
        guard Self.eventBelongsToSession(
            type: type,
            envelopeSessionID: envelopeSessionID,
            eventSessionID: eventSessionID,
            payload: payload,
            currentSessionID: currentSessionID,
            agents: sessionAgents + activeSubagents
        ) else { return }

        let text = Self.eventText(payload)
        guard text.localizedCaseInsensitiveContains("kanban") else { return }
        let taskIDs = Self.kanbanTaskIDs(in: text)
        guard !taskIDs.isEmpty else { return }

        let aliases = [currentSessionID, sessionStorageID, kanbanAttributionSessionID, kanbanSessionID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var changed = false
        for alias in aliases {
            let existing = observedKanbanTaskIDsBySessionID[alias, default: []]
            let merged = existing.union(taskIDs)
            if merged != existing {
                observedKanbanTaskIDsBySessionID[alias] = merged
                changed = true
            }
        }
        // Preserve the trusted card reference so a null `task.session_id`
        // remains recoverable after app restart. The hidden reference is not
        // presented as Bot work; `kanban show` remains the source of its
        // lifecycle, title, assignee, and heartbeat.
        let originSessionID = sessionStorageID ?? currentSessionID
        for taskID in taskIDs where !botActivityBySessionID[originSessionID, default: []].contains(where: { $0.isKanbanReference && $0.linkedCardID == taskID }) {
            insertBotActivity(BotActivityRecord(
                id: "kanban-reference:\(originSessionID):\(taskID)",
                originSessionID: originSessionID,
                botID: "kanban-reference",
                botName: "Hermes Kanban",
                summary: "Exact Hermes card reference",
                state: .queued,
                linkedCardID: taskID
            ))
        }
        guard changed else { return }
        observedKanbanTaskRevision &+= 1
        DebugLog.write("kanban: observed exact task reference in session activity")
    }

    /// Relay acknowledgements may not contain the Bot Chat session ID. Bind a
    /// single unattributed in-flight request when its own approval,
    /// clarification, or completion event arrives on the gateway stream.
    /// This keeps direct Bot activity truthful without guessing from prose.
    private func reconcileDirectBotLifecycle(type: String, params: [String: Any]) {
        let payload = params["payload"] as? [String: Any] ?? [:]
        let eventSessionID = (params["session_id"] as? String) ?? (payload["session_id"] as? String)
        guard let eventSessionID, !eventSessionID.isEmpty else { return }
        switch type {
        case "approval.request":
            setInFlightBotActivityWaiting(for: eventSessionID)
        case "clarification.request", "clarify.request":
            let requestID = Self.nestedClarificationString(keys: ["request_id", "id"], in: params)
            setInFlightBotActivityWaiting(for: eventSessionID, requestID: requestID)
        case "clarify.expire", "clarification.expire":
            let requestID = Self.nestedClarificationString(keys: ["request_id", "id"], in: params)
            if let requestID {
                updateInFlightBotActivity(for: requestID, state: .canceled, result: "This question expired before Hermes received an answer.")
            }
        case "message.start":
            setInFlightBotActivityWorking(for: eventSessionID)
        case "message.complete":
            let result = Self.messageCompletionError(from: payload)
            updateInFlightBotActivity(for: eventSessionID, state: result == nil ? .completed : .failed, result: result)
        default:
            break
        }
    }

    /// Accept both current Hermes events (which carry `seq`) and older
    /// gateways (which do not). Replayed events use this same boundary so
    /// de-duplication and ownership remain centralized.
    private func acceptGatewayEvent(type: String, params: [String: Any]) -> Bool {
        if type == "gateway.ready",
           let payload = params["payload"] as? [String: Any],
           let epoch = payload["replay_epoch"] as? String,
           !epoch.isEmpty,
           epoch != gatewayReplayEpoch {
            gatewayReplayEpoch = epoch
            processedGatewaySequencesBySessionID.removeAll()
            highestGatewaySequenceBySessionID.removeAll()
            if sessionID != nil { refreshDelegationStatus() }
            return true
        }

        guard let sequence = (params["seq"] as? NSNumber)?.intValue ?? params["seq"] as? Int,
              let eventSessionID = (params["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventSessionID.isEmpty else {
            return true
        }

        var processed = processedGatewaySequencesBySessionID[eventSessionID, default: []]
        guard !processed.contains(sequence) else { return false }
        let previousHighest = highestGatewaySequenceBySessionID[eventSessionID] ?? 0
        processed.insert(sequence)
        if processed.count > 1024 {
            let floor = max(0, sequence - 512)
            processed = Set(processed.filter { $0 >= floor })
        }
        processedGatewaySequencesBySessionID[eventSessionID] = processed
        highestGatewaySequenceBySessionID[eventSessionID] = max(previousHighest, sequence)

        if previousHighest > 0, sequence > previousHighest + 1 {
            DebugLog.write("activity: gateway sequence gap detected")
            replayGatewayEvents(for: eventSessionID, after: previousHighest)
        }
        return true
    }

    private func replayTrackedGatewayEvents() {
        gatewayReplayTask?.cancel()
        gatewayReplayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ids = Set([
                self.sessionID,
                self.sessionStorageID,
                self.kanbanAttributionSessionID
            ].compactMap { $0 }.filter { !$0.isEmpty })
            for id in ids {
                guard !Task.isCancelled else { return }
                guard let last = self.highestGatewaySequenceBySessionID[id], last > 0 else { continue }
                self.replayGatewayEvents(for: id, after: last)
            }
        }
    }

    private func replayGatewayEvents(for sessionID: String, after sequence: Int) {
        guard !gatewayReplayInFlight.contains(sessionID) else { return }
        gatewayReplayInFlight.insert(sessionID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.gatewayReplayInFlight.remove(sessionID) }
            do {
                let result = try await self.sessionRPCClient.request(
                    HermesFeatureIDs.ID.sessionEventsSince.rawValue,
                    params: ["session_id": sessionID, "last_seen": sequence]
                )
                if let epoch = result["epoch"] as? String, !epoch.isEmpty, epoch != self.gatewayReplayEpoch {
                    self.gatewayReplayEpoch = epoch
                    self.processedGatewaySequencesBySessionID.removeAll()
                    self.highestGatewaySequenceBySessionID.removeAll()
                }
                let frames = result["events"] as? [[String: Any]] ?? []
                for frame in frames.sorted(by: { lhs, rhs in
                    let left = (lhs["seq"] as? NSNumber)?.intValue ?? lhs["seq"] as? Int ?? 0
                    let right = (rhs["seq"] as? NSNumber)?.intValue ?? rhs["seq"] as? Int ?? 0
                    return left < right
                }) {
                    guard let type = frame["type"] as? String else { continue }
                    self.receiveGatewayEvent(type, params: frame)
                }
                if (result["truncated"] as? Bool) == true {
                    self.refreshDelegationStatus()
                }
            } catch {
                DebugLog.write("activity: gateway replay unavailable: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    private func capturePendingApproval(type: String, params: [String: Any]) {
        guard type == "approval.request" else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        guard let ownerSessionID = ((params["session_id"] as? String) ?? (payload["session_id"] as? String) ?? sessionID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !ownerSessionID.isEmpty else { return }
        let approval = ApprovalPresentation.from(payload: payload)
        let pendingApproval = PendingApproval(
            title: approval.title,
            detail: approval.detail
        )
        let aliases = pendingApprovalAliasesBySessionID[ownerSessionID] ?? [ownerSessionID]
        for alias in aliases {
            pendingApprovalsBySessionID[alias] = pendingApproval
        }
    }

    private func restorePendingApproval(for sessionIDs: [String?]) {
        let identities = sessionIDs
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let approval = identities.compactMap({ pendingApprovalsBySessionID[$0] }).first else {
            approvalTitle = nil
            approvalText = nil
            return
        }
        // A resume may reveal runtime and durable aliases for the same
        // conversation. Preserve that alias group so a response from another
        // surface clears the whole request even while this session is hidden.
        var aliases = Set(identities)
        for identity in identities {
            aliases.formUnion(pendingApprovalAliasesBySessionID[identity] ?? [])
        }
        for identity in aliases {
            pendingApprovalsBySessionID[identity] = approval
            pendingApprovalAliasesBySessionID[identity] = aliases
        }
        approvalTitle = approval.title
        approvalText = approval.detail
        status = .needsApproval
    }

    @discardableResult
    private func removePendingApproval(for sessionID: String) -> Set<String> {
        let aliases = pendingApprovalAliasesBySessionID[sessionID] ?? [sessionID]
        for alias in aliases {
            pendingApprovalsBySessionID.removeValue(forKey: alias)
            pendingApprovalAliasesBySessionID.removeValue(forKey: alias)
        }
        return aliases
    }

    private func capturePendingClarification(type: String, params: [String: Any]) {
        guard type == "clarification.request" || type == "clarify.request"
                || type == "clarification.expire" || type == "clarify.expire" else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        guard let ownerSessionID = ((params["session_id"] as? String) ?? (payload["session_id"] as? String) ?? sessionID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !ownerSessionID.isEmpty else { return }

        if type == "clarification.expire" || type == "clarify.expire" {
            let requestID = Self.nestedClarificationString(keys: ["request_id"], in: params)
            if let requestID { markClarificationResolved(requestID) }
            _ = removePendingClarification(for: ownerSessionID, requestID: requestID)
            return
        }

        let clarification = Self.pendingClarification(from: params)
        if let requestID = clarification.requestID,
           resolvedClarificationRequestIDs.contains(requestID) {
            return
        }
        let aliases = pendingClarificationAliasesBySessionID[ownerSessionID] ?? [ownerSessionID]
        for alias in aliases {
            pendingClarificationsBySessionID[alias] = clarification
        }
    }

    private func restorePendingClarification(for sessionIDs: [String?]) {
        let identities = sessionIDs
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let clarification = identities.compactMap({ pendingClarificationsBySessionID[$0] }).first else {
            clarificationQuestion = nil
            clarificationChoices = []
            clarificationRequestID = nil
            clarificationResponseError = nil
            return
        }
        var aliases = Set(identities)
        for identity in identities {
            aliases.formUnion(pendingClarificationAliasesBySessionID[identity] ?? [])
        }
        for identity in aliases {
            pendingClarificationsBySessionID[identity] = clarification
            pendingClarificationAliasesBySessionID[identity] = aliases
        }
        clarificationQuestion = clarification.question
        clarificationChoices = clarification.choices
        clarificationRequestID = clarification.requestID
        clarificationResponseError = nil
        if messages.last?.role != .hermes || messages.last?.text != clarification.transcriptText {
            messages.append(ChatMessage(role: .hermes, text: clarification.transcriptText, modelName: currentModelName))
        }
        status = .needsClarification
    }

    @discardableResult
    private func removePendingClarification(for sessionID: String, requestID: String? = nil) -> Set<String> {
        let aliases = pendingClarificationAliasesBySessionID[sessionID] ?? [sessionID]
        if let requestID,
           !aliases.compactMap({ pendingClarificationsBySessionID[$0]?.requestID }).contains(requestID) {
            return []
        }
        for alias in aliases {
            pendingClarificationsBySessionID.removeValue(forKey: alias)
            pendingClarificationAliasesBySessionID.removeValue(forKey: alias)
        }
        return aliases
    }

    private static func pendingClarification(from params: [String: Any]) -> PendingClarification {
        let question = nestedClarificationString(keys: ["question", "prompt", "query"], in: params)
            ?? nestedClarificationString(keys: ["message", "description", "text", "detail"], in: params)
            ?? "Hermes needs more information."
        let choices = nestedClarificationStrings(keys: ["choices", "options", "suggested_responses"], in: params)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return PendingClarification(
            question: question,
            choices: choices,
            requestID: nestedClarificationString(keys: ["request_id"], in: params)
        )
    }

    private func markClarificationResolved(_ requestID: String) {
        guard resolvedClarificationRequestIDs.insert(requestID).inserted else { return }
        resolvedClarificationRequestIDOrder.append(requestID)
        if resolvedClarificationRequestIDOrder.count > 256 {
            let expiredID = resolvedClarificationRequestIDOrder.removeFirst()
            resolvedClarificationRequestIDs.remove(expiredID)
        }
    }

    /// Bumps a row's recency locally so the rail reorders immediately instead
    /// of waiting for the session index round-trip. The open session is
    /// inserted when the index has not listed it yet (a just-created chat).
    private func touchSession(sessionID rawSessionID: String?, at date: Date, preview: String? = nil) {
        guard let rawSessionID, !rawSessionID.isEmpty else { return }
        let sessionID = rowSessionID(rawSessionID)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            guard sessionID == navigationSessionID else { return }
            sessions.insert(HermesSession(
                id: sessionID,
                profileID: sessionProfileID ?? profileScopeID,
                title: currentSessionTitle ?? "",
                preview: preview ?? "",
                startedAt: date,
                updatedAt: date,
                messageCount: 0,
                source: "herm"
            ), at: 0)
            return
        }
        let session = sessions[index]
        guard session.lastUpdatedAt.map({ date > $0 }) ?? true else { return }
        sessions[index] = HermesSession(
            id: session.id,
            profileID: session.profileID,
            title: session.title,
            preview: preview ?? session.preview,
            startedAt: session.startedAt,
            updatedAt: date,
            messageCount: session.messageCount,
            source: session.source,
            isHidden: session.isHidden,
            isWorking: session.isWorking,
            hasUnreadUpdate: session.hasUnreadUpdate
        )
    }

    /// Tracks working/unread state for a session that is not necessarily the
    /// one currently open, so the dock and sidebars can surface every session
    /// with activity, not just the focused one. Reuses the same gateway
    /// stream and `Self.isUnreadUpdateEvent` predicate that already drive the
    /// current session's `hasUnreadResponse`.
    private func updateSessionActivity(sessionID rawSessionID: String, isWorking: Bool? = nil, unread: Bool? = nil) {
        let sessionID = rowSessionID(rawSessionID)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions[index]
        sessions[index] = HermesSession(
            id: session.id,
            profileID: session.profileID,
            title: session.title,
            preview: session.preview,
            startedAt: session.startedAt,
            updatedAt: session.updatedAt,
            messageCount: session.messageCount,
            source: session.source,
            isHidden: session.isHidden,
            isWorking: isWorking ?? session.isWorking,
            hasUnreadUpdate: unread ?? session.hasUnreadUpdate
        )
        if let unread {
            var unreadIDs = Set(defaults.stringArray(forKey: unreadSessionIDsKey) ?? [])
            if unread { unreadIDs.insert(sessionID) } else { unreadIDs.remove(sessionID) }
            defaults.set(Array(unreadIDs), forKey: unreadSessionIDsKey)
        }
    }

    private func updateSessionActivityLabel(sessionID rawSessionID: String, type: String, payload: [String: Any]) {
        let sessionID = rowSessionID(rawSessionID)
        switch type {
        case "tool.call", "tool.start", "tool.use", "tool_use":
            let name = (payload["name"] as? String) ?? (payload["tool"] as? String) ?? (payload["tool_name"] as? String) ?? "tool"
            let preview = (payload["tool_preview"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            sessionActivityLabels[sessionID] = preview.isEmpty ? "Running \(name)" : "\(name): \(preview)"
        case "message.start":
            sessionActivityLabels[sessionID] = nil
        default:
            if Self.isUnreadUpdateEvent(type) { sessionActivityLabels[sessionID] = nil }
        }
    }

    /// Restores unread state persisted across launches for sessions the
    /// in-memory index does not already carry a live value for.
    private func applyPersistedUnreadState(_ loaded: [HermesSession]) -> [HermesSession] {
        let unreadIDs = Set(defaults.stringArray(forKey: unreadSessionIDsKey) ?? [])
        guard !unreadIDs.isEmpty else { return loaded }
        return loaded.map { session in
            guard unreadIDs.contains(session.id), !session.hasUnreadUpdate else { return session }
            return HermesSession(
                id: session.id,
                profileID: session.profileID,
                title: session.title,
                preview: session.preview,
                startedAt: session.startedAt,
                updatedAt: session.updatedAt,
                messageCount: session.messageCount,
                source: session.source,
                isHidden: session.isHidden,
                isWorking: session.isWorking,
                hasUnreadUpdate: true
            )
        }
    }

    func refreshSessionTokenUsage() {
        guard let id = sessionID, !id.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let result = try? await self?.interruptRPC.sessionUsage(sessionID: id),
                  let self, self.sessionID == id else { return }
            self.sessionTokenUsage = (id, ControlCenterModel.parseSessionUsage(result).totalTokens)
            self.applyContextUsage(result, sessionID: id)
        }
    }

    private func applyContextUsage(_ usage: [String: Any], sessionID id: String) {
        let summary = ControlCenterModel.parseSessionUsage(usage)
        guard let used = summary.contextUsed, let max = summary.contextMax, used > 0, max > 0 else { return }
        sessionContextUsage = (id, used, max)
    }

    // ponytail: ~4 chars/token heuristic for the live stream; session.usage replaces it at turn end.
    static func estimatedTokens(utf8Count: Int) -> Int { (utf8Count + 3) / 4 }

    private func refreshSessionIndexAfterActivity() {
        guard !isLoadingSessions else {
            pendingSessionIndexRefresh = true
            return
        }
        guard let refresh = loadSessions() else { return }
        Task { @MainActor [weak self] in
            await refresh.value
            guard let self, self.pendingSessionIndexRefresh else { return }
            self.pendingSessionIndexRefresh = false
            self.refreshSessionIndexAfterActivity()
        }
    }

    static func isUnreadUpdateEvent(_ type: String) -> Bool {
        switch type {
        case "background.complete", "message.complete", "approval.request",
             "clarification.request", "clarify.request", "error":
            true
        default:
            false
        }
    }

    func requestComposerFocus() {
        composerFocusRequest &+= 1
    }

    func setCompletionNotificationsEnabled(_ enabled: Bool) {
        completionNotificationsEnabled = enabled
        defaults.set(enabled, forKey: completionNotificationsKey)
    }

    func requestControlInbox() {
        requestedAttentionID = nil
        controlInboxRequest &+= 1
    }

    func requestControlAttention(_ id: String) {
        requestedAttentionID = id
        controlInboxRequest &+= 1
    }

    func markPopoverHidden() {
        isPopoverVisible = false
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        guard interruptState != .requesting, let sessionID else { return nil }
        interruptGeneration &+= 1
        let requestGeneration = interruptGeneration
        interruptState = .requesting
        return Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await interruptRPC.interrupt(
                    sessionID: sessionID,
                    profileID: sessionProfileID ?? profileScopeID
                )
                // Hermes' response only acknowledges the request. The local
                // turn remains authoritative until a terminal lifecycle event.
            } catch {
                guard self.interruptGeneration == requestGeneration,
                      self.sessionID == sessionID else { return }
                interruptState = .failed("Hermes could not be interrupted. Try again.")
                DebugLog.write("model: interrupt failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    /// Control-center actions share the user-facing Hermes gateway so they do
    /// not create a second backend or bypass the normal approval/event stream.
    var controlRPCClient: HermesRPCClientProtocol { gateway }

    func requestControl(_ method: HermesFeatureIDs.ID, params: [String: Any]) async throws -> [String: Any] {
        try await gateway.request(method.rawValue, params: params)
    }

    func registerBackgroundTask(id: String, prompt: String, parentSessionID: String, kind: HermesBackgroundTaskKind = .general) {
        guard !id.isEmpty, !backgroundTasks.contains(where: { $0.id == id }) else { return }
        backgroundTasks.append(HermesBackgroundTask(id: id, parentSessionID: parentSessionID, prompt: prompt, kind: kind, status: .running, output: nil, startedAt: .now, completedAt: nil))
        if backgroundTasks.count > 50 { backgroundTasks.removeFirst(backgroundTasks.count - 50) }
    }

    func isSyntheticSubagent(_ id: String) -> Bool {
        synthesizedSubagentIDs.contains(id)
    }

    func submitControlPrompt(_ text: String) async throws {
        guard !isRestoringSession else {
            throw NSError(domain: "Herm", code: 409, userInfo: [NSLocalizedDescriptionKey: "The previous conversation is still loading."])
        }
        try await gateway.connect()
        if sessionID == nil {
            _ = try await createAuthorizedSession(source: "herm-control")
        }
        guard let sessionID else { throw HermesGateway.GatewayError.malformedResponse }
        _ = try await gateway.request(HermesFeatureIDs.ID.promptSubmit.rawValue, params: ["session_id": sessionID, "text": text])
    }

    /// Starts Hermes' native VAD/TTS voice loop. Hermes owns the microphone,
    /// transcription, streaming speech, and spoken barge-in for this mode.
    /// If the locally installed CLI is missing those optional dependencies, the
    /// Dock keeps its existing Apple speech-recognition flow as a clear fallback.
    func startVoiceConversation() {
        guard !isRestoringSession else { return }
        guard sessionID != nil || (newSessionCreationAuthorized && !isCreatingSession) else { return }
        guard voiceState == .inactive || {
            if case .localFallback = voiceState { return true }
            return false
        }() else { return }
        guard !voiceState.isNativeConversationActive else { return }
        voiceConversationGeneration &+= 1
        let generation = voiceConversationGeneration
        nativeVoiceCapture.reset()
        voiceState = .preparing

        Task {
            do {
                try await gateway.connect()
                guard voiceConversationGeneration == generation else { return }
                if sessionID == nil {
                    _ = try await createAuthorizedSession(source: "herm")
                }
                guard sessionID != nil else { throw HermesGateway.GatewayError.malformedResponse }
                guard voiceConversationGeneration == generation else { return }

                let requirements = try await gateway.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "status"])
                guard voiceConversationGeneration == generation else { return }
                guard (requirements["available"] as? Bool) != false,
                      (requirements["stt_available"] as? Bool) != false else {
                    let detail = Self.safeUserDiagnostic(
                        (requirements["details"] as? String) ?? "Hermes voice dependencies are unavailable."
                    )
                    voiceState = .localFallback(detail)
                    return
                }

                let enabled = try await gateway.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "on"])
                guard voiceConversationGeneration == generation else { return }
                if (enabled["tts"] as? Bool) != true {
                    _ = try await gateway.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "tts"])
                }
                guard voiceConversationGeneration == generation else { return }
                voiceRepliesEnabled = true
                skipNextVoicePlaybackDrain = false
                voiceTelemetry.beginListening()
                voiceState = .listening
                armNativeVoiceCapture()
            } catch {
                guard voiceConversationGeneration == generation else { return }
                DebugLog.write("voice: Hermes native voice unavailable: \(Self.safeUserDiagnostic(error.localizedDescription))")
                voiceState = .localFallback(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Creates a backend session only for a New Chat that the user explicitly
    /// requested. Keeping this transition centralized prevents commands such
    /// as send, control prompts, and voice startup from silently creating chats
    /// after startup restoration or a failed resume.
    private func createAuthorizedSession(source: String) async throws -> String {
        if let sessionID { return sessionID }
        guard newSessionCreationAuthorized else {
            throw NSError(
                domain: "Herm",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Start a new chat before sending a message."]
            )
        }
        guard !isCreatingSession else {
            throw NSError(
                domain: "Herm",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "The new chat is still starting."]
            )
        }

        isCreatingSession = true
        defer { isCreatingSession = false }
        var createParams: [String: Any] = ["source": source]
        if let profileID = profileScopeID, !profileID.isEmpty {
            createParams["profile"] = profileID
        }
        if let newSessionProjectPath, !newSessionProjectPath.isEmpty {
            createParams["cwd"] = newSessionProjectPath
        }
        // Hermes rejects sessionless model switches; a new-chat pick rides on
        // session.create as a per-session override instead.
        if let id = sessionModelOptionID,
           let option = runtimeModelOptions.first(where: { $0.id == id }) {
            createParams["model"] = option.model
            createParams["provider"] = option.provider
        }
        let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionCreate.rawValue, params: createParams)
        guard let createdSessionID = result["session_id"] as? String,
              !createdSessionID.isEmpty else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        if let newSessionProjectPath, !newSessionProjectPath.isEmpty {
            createdSessionProjectPaths[createdSessionID] = newSessionProjectPath
        }
        sessionID = createdSessionID
        sessionProfileID = profileScopeID
        sessionStorageID = Self.stableSessionID(from: result) ?? createdSessionID
        kanbanAttributionSessionID = createdSessionID
        persistActiveSessionID(sessionID)
        let model = (result["model"] as? String) ?? (result["model_name"] as? String)
        if let model {
            currentModelName = model
            sessionModelValue = model
        }
        newSessionCreationAuthorized = false
        newSessionProjectPath = nil
        refreshSessionModelOptions()
        refreshSessionReasoningVariant()
        refreshDelegationStatus()
        startDelegationMonitoring()
        DebugLog.write("model: session created (id present: true)")
        return createdSessionID
    }

    func stopVoiceConversation() {
        voiceConversationGeneration &+= 1
        let wasNative = voiceState.isNativeConversationActive
        skipNextVoicePlaybackDrain = false
        nativeVoiceCapture.reset()
        voiceState = .inactive
        guard wasNative else { return }
        Task {
            if let sessionID {
                _ = try? await gateway.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: ["action": "stop", "session_id": sessionID])
            }
            _ = try? await gateway.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "off"])
        }
    }

    /// Ends the current utterance now instead of waiting for Hermes' VAD
    /// silence window (`voice.silence_duration`, 3s by default).
    func finishVoiceUtterance() {
        guard voiceState == .listening, let sessionID else { return }
        voiceState = .transcribing
        Task {
            _ = try? await gateway.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: ["action": "stop", "session_id": sessionID])
        }
    }

    /// Cuts Hermes off mid-thought or mid-sentence. `session.interrupt` also
    /// silences Hermes' streaming TTS, so one request covers both phases.
    func interruptVoiceTurn() {
        switch voiceState {
        case .thinking:
            skipNextVoicePlaybackDrain = true
            _ = stop()
        case .speaking:
            _ = stop()
            resumeVoiceListening(force: true)
        default:
            break
        }
    }

    /// Re-opens the microphone after a no-speech pause (or a cut-off reply).
    func resumeVoiceListening(force: Bool = false) {
        guard voiceState == .paused || force, voiceState.isNativeConversationActive else { return }
        nativeVoiceCapture.reset()
        voiceState = .listening
        armNativeVoiceCapture()
    }

    func toggleVoiceReplies() {
        guard voiceState.isNativeConversationActive else { return }
        let generation = voiceConversationGeneration
        voiceRepliesEnabled.toggle()
        Task {
            let result = try? await gateway.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "tts"])
            guard voiceConversationGeneration == generation else { return }
            if let tts = result?["tts"] as? Bool { voiceRepliesEnabled = tts }
        }
    }

    func respondToApproval(_ choice: String) {
        guard let sessionID else { return }
        guard !isRespondingToApproval else { return }
        let responseGeneration = sessionResumeGeneration
        isRespondingToApproval = true
        Task {
            defer {
                if self.sessionResumeGeneration == responseGeneration,
                   self.sessionID == sessionID {
                    self.isRespondingToApproval = false
                }
            }
            do {
                _ = try await gateway.request(HermesFeatureIDs.ID.approvalRespond.rawValue, params: ["session_id": sessionID, "choice": choice])
                guard self.sessionResumeGeneration == responseGeneration,
                      self.sessionID == sessionID else { return }
                resolveApproval(for: sessionID)
            } catch {
                DebugLog.write("model: approval response failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func respondToClarification(_ response: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRespondingToClarification else { return }
        guard let responseSessionID = sessionID, !responseSessionID.isEmpty else { return }
        let responseGeneration = sessionResumeGeneration
        guard let requestID = clarificationRequestID, !requestID.isEmpty else {
            clarificationResponseError = "Hermes did not provide an ID for this question. Please ask it again."
            return
        }
        draft = ""
        messages.append(ChatMessage(role: .user, text: trimmed))
        beginStreamingMessage()
        isAwaitingClarificationResume = true
        isRespondingToClarification = true
        clarificationResponseError = nil
        status = .working
        isSending = true
        conversationActivityPhase = .thinking
        Task {
            defer {
                if self.sessionResumeGeneration == responseGeneration,
                   self.sessionID == responseSessionID {
                    self.isRespondingToClarification = false
                }
            }
            do {
                _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.clarifyRespond.rawValue, params: [
                    "request_id": requestID,
                    "answer": trimmed
                ])
                markClarificationResolved(requestID)
                _ = removePendingClarification(for: responseSessionID, requestID: requestID)
                guard self.sessionResumeGeneration == responseGeneration,
                      self.sessionID == responseSessionID else { return }
                clarificationQuestion = nil
                clarificationChoices = []
                clarificationRequestID = nil
                setInFlightBotActivityWorking(for: responseSessionID)
            } catch {
                guard self.sessionResumeGeneration == responseGeneration,
                      self.sessionID == responseSessionID else { return }
                removePendingClarificationResumeMessage()
                status = .needsClarification
                isSending = false
                conversationActivityPhase = .idle
                let diagnostic = Self.safeUserDiagnostic(error.localizedDescription)
                clarificationResponseError = diagnostic
                DebugLog.write("model: clarification response failed: \(diagnostic)")
            }
        }
    }

    /// Reconciles an approval answered through another surface, such as Inbox.
    /// Responses for other sessions clear their retained request without
    /// altering the visible conversation.
    func resolveApproval(for resolvedSessionID: String) {
        // A direct Bot relay can pause in its own Bot Chat session while the
        // foreground conversation remains selected. Resolve that activity by
        // its exact event session before applying the foreground approval UI.
        setInFlightBotActivityWorking(for: resolvedSessionID)
        let activeSessionIDs = Set([sessionID, sessionStorageID, kanbanAttributionSessionID].compactMap { $0 })
        let resolvedAliases = removePendingApproval(for: resolvedSessionID)
        guard !activeSessionIDs.isDisjoint(with: resolvedAliases) else { return }
        for activeSessionID in activeSessionIDs {
            _ = removePendingApproval(for: activeSessionID)
        }
        approvalTitle = nil
        approvalText = nil
        if status == .needsApproval {
            status = .working
            setInFlightBotActivityWorking(for: resolvedSessionID)
            setInFlightBotActivityWorking(for: sessionID)
        }
    }

    private func handleEvent(_ type: String, params: [String: Any]) {
        let rawPayload = params["payload"] as? [String: Any] ?? [:]
        let envelopeSessionID = params["session_id"] as? String
        let payloadSessionID = rawPayload["session_id"] as? String
        let eventSessionID = envelopeSessionID ?? payloadSessionID
        // Hermes uses one gateway stream for every session. Once a session is
        // selected, reject events that do not prove ownership by that session
        // before projecting activities, tool calls, or conversation state. The
        // previous code projected first and filtered later, which let a known
        // agent (or an event with a missing session ID) mutate the current
        // session before the later guard ran.
        guard let currentSessionID = sessionID,
              Self.eventBelongsToSession(
                type: type,
                envelopeSessionID: envelopeSessionID,
                eventSessionID: eventSessionID,
                payload: rawPayload,
                currentSessionID: currentSessionID,
                agents: sessionAgents + activeSubagents
              ) else {
            if !Self.isHighFrequencyEvent(type) { DebugLog.write("model: ignoring event \(type) without current-session ownership") }
            return
        }
        let activityProjection = Self.isHighFrequencyEvent(type) ? nil : Self.agentActivityProjection(
            type: type,
            params: params,
            currentSessionID: sessionID,
            agents: sessionAgents + activeSubagents
        )
        if let activityProjection {
            recordAgentActivity(activityProjection.kind, params: params, payload: activityProjection.payload)
            mergeAgentEvent(activityProjection.kind, payload: activityProjection.payload)
            cacheCurrentAgentState()
            if activityProjection.consumesParentEvent { return }
        }
        let payload = activityProjection?.payload ?? rawPayload
        let isRelevantSubagentEvent = activityProjection != nil && type.hasPrefix("subagent.")
        if let eventSessionID,
           !eventSessionID.isEmpty,
           let sessionID, sessionID != eventSessionID,
           !isRelevantSubagentEvent {
            if !Self.isHighFrequencyEvent(type) { DebugLog.write("model: ignoring event \(type) for other session \(eventSessionID)") }
            return
        }
        if !Self.isHighFrequencyEvent(type) { DebugLog.write("model: handling event \(type)") }
        if type == "message.start" {
            recentEvents.removeAll()
        }
        if !Self.isHighFrequencyEvent(type) {
            recordEvent(type, params: params)
        }
        // A turn that started before this session was attached (app relaunch,
        // reopening a busy session) never delivers its `message.start`. Its
        // first mid-turn event opens the live row so the transcript, status and
        // activity follow it like any other turn.
        if streamingMessageID == nil, Self.isMidTurnEvent(type) {
            activeToolCalls = []
            beginStreamingMessage()
            conversationActivityPhase = .responding
            isSending = true
            if status == .idle { status = .working }
        }
        switch type {
        case "session.usage":
            guard let id = sessionID, let usage = payload["usage"] as? [String: Any] else { break }
            applyContextUsage(usage, sessionID: id)
        case "status.update":
            switch payload["kind"] as? String {
            case "compacting", "compressing":
                recordTurnCompaction(isComplete: false)
                compactingSessionID = sessionID
            case "compacted", "ready":
                if compactingSessionID != nil { recordTurnCompaction(isComplete: true) }
                compactingSessionID = nil
                refreshSessionTokenUsage()
            default: break
            }
        case "background.complete", "btw.complete":
            let taskID = (payload["task_id"] as? String) ?? ""
            if slashSideTaskIDs.remove(taskID) != nil, let text = payload["text"] as? String {
                messages.append(ChatMessage(role: .hermes, text: text))
            }
            guard !taskID.isEmpty,
                  let index = backgroundTasks.firstIndex(where: { $0.id == taskID }) else { break }
            backgroundTasks[index].status = .completed
            backgroundTasks[index].output = payload["text"] as? String
            backgroundTasks[index].completedAt = .now
        case "voice.transcript":
            guard voiceState.isNativeConversationActive else { return }
            let transcript = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            nativeVoiceCapture.receivedTranscript(hasText: !transcript.isEmpty)
            if (payload["stop_phrase"] as? Bool) == true {
                stopVoiceConversation()
                return
            }
            if (payload["no_speech_limit"] as? Bool) == true {
                // Hermes gave up after consecutive silent captures. Re-arming
                // here looped forever (beeping) with a deaf or idle microphone.
                voiceState = .paused
                return
            }
            guard !transcript.isEmpty else {
                voiceState = .listening
                armNativeVoiceCapture()
                return
            }
            voiceTelemetry.receivedTranscript()
            submitNativeVoiceTranscript(transcript)
        case "voice.status":
            guard voiceState.isNativeConversationActive else { return }
            // The gateway's response boundary precedes the end of streamed
            // TTS. Ignore recorder status during that drain window: only the
            // playback-drain owner may reopen the ordinary capture path.
            guard !nativeVoiceCapture.isAwaitingPlaybackDrain, voiceState != .paused else { return }
            let state = payload["state"] as? String
            switch state {
            case "recording", "listening":
                voiceState = .listening
            case "transcribing":
                voiceState = .transcribing
            case "idle":
                voiceState = .listening
                if nativeVoiceCapture.receivedIdle() {
                    armNativeVoiceCapture()
                }
            default:
                voiceState = .thinking
            }
        case "voice.interrupted":
            guard voiceState.isNativeConversationActive else { return }
            status = .idle
            isSending = false
            voiceTelemetry.markInterrupted()
            let interruptionGeneration = nativeVoiceCapture.beginInterruption()
            voiceState = .interrupted
            recoverNativeVoiceCaptureIfInterruptedTranscriptIsMissing(generation: interruptionGeneration)
        case "message.start":
            let model = (payload["model"] as? String) ?? (payload["model_name"] as? String)
            if let model {
                currentModelName = model
            }
            // Hermes may send `message.start` after its first resumed delta, or
            // repeat it while reconnecting. Until `message.complete` closes the
            // active stream, it belongs to the already-reserved assistant row.
            if streamingMessageID != nil {
                isAwaitingClarificationResume = false
            } else {
                beginStreamingMessage()
            }
            conversationActivityPhase = .responding
            streamingMessageIsVisionNotice = false
            reasoningState = nil
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        streamingReasoningBuffer = ""
            isShowingReasoning = false
            activeToolCalls = []
        case "message.delta":
            guard let delta = (payload["delta"] as? String) ?? (payload["text"] as? String), streamingMessageID != nil else { return }
            isAwaitingClarificationResume = false
            if streamingMessageIsVisionNotice { return }
            if voiceState.isNativeConversationActive {
                voiceTelemetry.receivedResponse()
            }
            streamingMessageBuffer.append(delta)
            streamingMessagePendingPresentationDelta.append(delta)
            scheduleStreamingMessageFlush()
        case "message.complete":
            isAwaitingClarificationResume = false
            if let completedText = Self.completedMessageText(from: payload),
               !completedText.isEmpty {
                if streamingMessageID == nil {
                    beginStreamingMessage()
                }
                streamingMessageBuffer = completedText
            }
            var turnTokens: Int?
            compactingSessionID = nil
            if let id = sessionID, let usageDict = payload["usage"] as? [String: Any] {
                applyContextUsage(usageDict, sessionID: id)
            }
            if let id = sessionID, let usage = sessionTokenUsage, usage.sessionID == id {
                if let usageDict = payload["usage"] as? [String: Any],
                   case let total = ControlCenterModel.parseSessionUsage(usageDict).totalTokens, total > 0 {
                    if total > usage.total { turnTokens = total - usage.total }
                    sessionTokenUsage = (id, total)
                } else {
                    let streamed = streamingMessageBuffer.utf8.count + streamingReasoningBuffer.utf8.count
                    sessionTokenUsage = (id, usage.total + Self.estimatedTokens(utf8Count: streamed))
                }
            }
            refreshSessionTokenUsage()
            let wasInterrupting = interruptState == .requesting
            interruptState = .idle
            if wasInterrupting {
                let activeSessionIDs = Set([sessionID, sessionStorageID, kanbanAttributionSessionID].compactMap { $0 })
                if let clarificationRequestID {
                    markClarificationResolved(clarificationRequestID)
                }
                for activeSessionID in activeSessionIDs {
                    _ = removePendingApproval(for: activeSessionID)
                    _ = removePendingClarification(for: activeSessionID)
                }
                approvalTitle = nil
                approvalText = nil
                clarificationQuestion = nil
                clarificationChoices = []
                clarificationRequestID = nil
                clarificationResponseError = nil
                steeringError = nil
            }
            if let error = Self.messageCompletionError(from: payload) {
                discardStreamingMessage()
                let text = Self.safeUserDiagnostic(error)
                appendTerminalErrorMessage(text)
                updateInFlightBotActivity(for: eventSessionID, state: .failed, result: text)
                notify(title: "Hermes could not complete the request", body: text, identifier: "failure:\(sessionID ?? "hermes")")
            } else {
                commitStreamingMessage(tokenCount: turnTokens)
                let result = messages.last(where: { $0.role == .hermes })?.text
                updateInFlightBotActivity(for: eventSessionID, state: wasInterrupting ? .canceled : .completed, result: result)
            }
            if wasInterrupting {
                updateInFlightBotActivity(for: eventSessionID, state: .canceled)
            }
            // A few Hermes adapters omit the final tool-result identifier. The
            // response boundary is authoritative, so do not leave those calls
            // displayed as running after the assistant has completed.
            for index in activeToolCalls.indices where !activeToolCalls[index].isComplete {
                activeToolCalls[index].isComplete = true
                activeToolCalls[index].completedAt = Date()
            }
            status = .idle
            conversationActivityPhase = .idle
            isSending = false
            streamingMessageID = nil
            streamingTurnActivity = []
            streamingResponseStartedAt = nil
            if completionNotificationsEnabled {
                let response = messages.last(where: { $0.role == .hermes })?.text ?? "Hermes completed the active request."
                notify(title: "Hermes completed work", body: response, identifier: "completed:\(sessionID ?? "hermes")")
            }
            if voiceState.isNativeConversationActive, skipNextVoicePlaybackDrain || !voiceRepliesEnabled {
                skipNextVoicePlaybackDrain = false
                voiceTelemetry.completedResponse()
                resumeVoiceListening(force: true)
            } else if voiceState.isNativeConversationActive {
                voiceTelemetry.completedResponse()
                voiceState = .speaking
                let response = messages.last(where: { $0.role == .hermes })?.text ?? ""
                let drainGeneration = nativeVoiceCapture.completedResponse()
                awaitNativeVoicePlaybackDrain(
                    generation: drainGeneration,
                    responseText: response
                )
            }
            if let sessionStorageID { cacheAgentState(for: sessionStorageID); Task { await agentStateWriter.flush() } }
            // A stopped turn keeps its queue; Enter on an empty composer sends it.
            if !wasInterrupting { drainQueuedPromptIfIdle() }
        case "approval.request":
            let approval = ApprovalPresentation.from(payload: payload)
            setInFlightBotActivityWaiting(for: eventSessionID)
            let isPresentingApproval = approvalText == nil
            approvalTitle = approval.title
            approvalText = approval.detail
            status = .needsApproval
            if isPresentingApproval {
                playApprovalSound()
            }
            notify(title: approval.title, body: approval.detail, identifier: "approval:\(sessionID ?? "hermes")")
        case "clarification.request", "clarify.request":
            // Hermes adapters have emitted clarification fields both inside
            // `payload` and alongside it in the event params. Prefer the
            // payload, but retain the top-level fields so the actual question
            // is not replaced by the generic fallback text.
            let clarification = Self.pendingClarification(from: params)
            let question = clarification.question
            let choices = clarification.choices
            let requestID = clarification.requestID
            if let requestID, resolvedClarificationRequestIDs.contains(requestID) {
                break
            }
            if let requestID, !requestID.isEmpty,
               !presentedClarificationRequestIDs.insert(requestID).inserted {
                // The gateway may replay a request after an answer has been
                // submitted. Its request ID already owns the transcript row.
                break
            }
            let messageText = clarification.transcriptText
            if messages.last?.role != .hermes || messages.last?.text != messageText {
                messages.append(ChatMessage(role: .hermes, text: messageText, modelName: currentModelName))
            }
            clarificationQuestion = question
            clarificationChoices = choices
            clarificationRequestID = requestID
            clarificationResponseError = nil
            setInFlightBotActivityWaiting(for: eventSessionID, requestID: requestID)
            isSending = false
            status = .needsClarification
            conversationActivityPhase = .idle
            notify(title: "Hermes needs clarification", body: question, identifier: "clarification:\(sessionID ?? "hermes")")
        case "clarify.expire", "clarification.expire":
            let expiredRequestID = Self.nestedClarificationString(keys: ["request_id"], in: params)
            guard expiredRequestID == nil || expiredRequestID == clarificationRequestID else { return }
            clarificationQuestion = nil
            clarificationChoices = []
            clarificationRequestID = nil
            clarificationResponseError = "This question expired before Hermes received an answer."
            if let expiredRequestID {
                updateInFlightBotActivity(
                    for: expiredRequestID,
                    state: .canceled,
                    result: clarificationResponseError
                )
            } else {
                updateInFlightBotActivity(
                    for: eventSessionID,
                    state: .canceled,
                    result: clarificationResponseError
                )
            }
            isSending = false
            status = .idle
            conversationActivityPhase = .idle
        case "error":
            commitStreamingMessage()
            let raw = (payload["message"] as? String) ?? "Hermes reported an error."
            let text = Self.isVisionUnsupportedError(raw)
                ? Self.visionUnsupportedNotice
                : Self.safeUserDiagnostic(raw)
            appendTerminalErrorMessage(text)
            status = .idle
            conversationActivityPhase = .idle
            streamingMessageID = nil
            streamingMessageSessionID = nil
            isSending = false
            if voiceState.isNativeConversationActive {
                skipNextVoicePlaybackDrain = false
                nativeVoiceCapture.reset()
                voiceState = .listening
                armNativeVoiceCapture()
            }
            notify(title: "Hermes encountered an error", body: text, identifier: "failure:\(sessionID ?? "hermes")")
            updateInFlightBotActivity(for: eventSessionID, state: .failed, result: text)

        case "reasoning.start", "thinking":
            conversationActivityPhase = .thinking
            closeTurnThinking()
            reasoningState = ReasoningState(text: "", isComplete: false)
            isShowingReasoning = false
        case "reasoning.delta", "thinking.delta":
            guard reasoningState != nil else { return }
            let delta = (payload["delta"] as? String) ?? (payload["text"] as? String) ?? ""
            guard !delta.isEmpty else { return }
            // Reasoning deltas arrive faster than any UI needs: publishing
            // reasoningState per delta re-rendered the whole popover at the
            // delta rate. Coalesce at the same cadence as message streaming.
            streamingReasoningBuffer += delta
            scheduleReasoningFlush()
            conversationActivityPhase = .thinking
        case "reasoning.complete", "thinking.stop", "thinking.complete":
            guard var state = reasoningState else { return }
            reasoningFlushTask?.cancel()
            reasoningFlushTask = nil
            state.text = streamingReasoningBuffer
            streamingReasoningBuffer = ""
            state.isComplete = true
            reasoningState = state
            conversationActivityPhase = .responding

        case "tool.call", "tool.start", "tool.use", "tool_use":
            let name = (payload["name"] as? String) ?? (payload["tool"] as? String) ?? (payload["tool_name"] as? String) ?? "unknown"
            let childSessionID = (payload["child_session_id"] as? String)
                ?? (params["child_session_id"] as? String)
            let eventAgentID = Self.agentID(
                explicitAgentID: (payload["subagent_id"] as? String)
                    ?? (params["subagent_id"] as? String)
                    ?? (payload["agent_id"] as? String)
                    ?? (params["agent_id"] as? String),
                eventSessionID: eventSessionID,
                childSessionID: childSessionID,
                goal: payload["goal"] as? String,
                taskIndex: (payload["task_index"] as? NSNumber)?.intValue,
                agents: sessionAgents + activeSubagents
            )
            let argsDict = (payload["arguments"] as? [String: Any])
                ?? (payload["input"] as? [String: Any])
                ?? (payload["args"] as? [String: Any])
                ?? Self.parseArgsDict(payload["args_text"])
                ?? [:]
            let input: String
            if let args = payload["arguments"] as? [String: Any] {
                input = args.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", ")
            } else if let args = payload["arguments"] as? String {
                input = args
            } else if let inputStr = payload["input"] as? [String: Any] {
                input = inputStr.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", ")
            } else if let inputString = payload["input"] as? String {
                input = inputString
            } else if let command = payload["command"] as? String {
                input = command
            } else {
                input = ""
            }
            let id = (payload["id"] as? String)
                ?? (payload["tool_id"] as? String)
                ?? (payload["tool_call_id"] as? String)
                ?? (payload["tool_use_id"] as? String)
                ?? (params["id"] as? String)
                ?? (params["tool_id"] as? String)
                ?? (params["tool_call_id"] as? String)
                ?? (params["tool_use_id"] as? String)
                ?? UUID().uuidString
            // A retried or duplicated tool.call event must not create a second
            // row with the same identity: ForEach diffing and the expand toggle
            // key on this id, and duplicates crash the activity list.
            guard !activeToolCalls.contains(where: { $0.id == id }) else { break }
            activeToolCalls.append(ActiveToolCall(
                id: id,
                name: name,
                input: Self.truncatedForPersistence(input),
                context: payload["context"] as? String ?? "",
                startedAt: dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date(),
                result: nil,
                isComplete: false,
                agentID: eventAgentID,
                parentAgentID: payload["parent_id"] as? String,
                childSessionID: childSessionID
            ))
            if Self.isDelegationTool(name) {
                synthesizeSubagent(toolCallID: id, args: argsDict)
            }
        case "tool.result", "tool_result", "tool.complete", "tool_complete":
            let id = (payload["id"] as? String)
                ?? (payload["tool_id"] as? String)
                ?? (payload["tool_call_id"] as? String)
                ?? (payload["tool_use_id"] as? String)
                ?? (params["id"] as? String)
                ?? (params["tool_id"] as? String)
                ?? (params["tool_call_id"] as? String)
                ?? (params["tool_use_id"] as? String)
                ?? ""
            let result = Self.eventText(payload["result"] ?? payload["output"])
            let diffPreview = Self.diffPreview(from: payload)
            if Self.isVisionUnsupportedError(result) {
                activeToolCalls.removeAll { $0.name.lowercased().contains("vision") }
            } else if let index = activeToolCalls.firstIndex(where: { $0.id == id }) {
                let wasDelegation = Self.isDelegationTool(activeToolCalls[index].name)
                if wasDelegation, let args = payload["args"] as? [String: Any] {
                    refreshSynthesizedSubagents(toolCallID: id, args: args)
                }
                activeToolCalls[index].result = result.isEmpty ? nil : Self.truncatedForPersistence(result)
                activeToolCalls[index].isComplete = true
                activeToolCalls[index].completedAt = dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date()
                activeToolCalls[index].diffPreview = diffPreview
                if wasDelegation { completeSynthesizedSubagent(toolCallID: id, result: result, payload: payload) }
            } else if !activeToolCalls.isEmpty, let last = activeToolCalls.lastIndex(where: { !$0.isComplete }) {
                let wasDelegation = Self.isDelegationTool(activeToolCalls[last].name)
                if wasDelegation, let args = payload["args"] as? [String: Any] {
                    refreshSynthesizedSubagents(toolCallID: activeToolCalls[last].id, args: args)
                }
                activeToolCalls[last].result = result.isEmpty ? nil : Self.truncatedForPersistence(result)
                activeToolCalls[last].isComplete = true
                activeToolCalls[last].completedAt = dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date()
                activeToolCalls[last].diffPreview = diffPreview
                if wasDelegation { completeSynthesizedSubagent(toolCallID: activeToolCalls[last].id, result: result, payload: payload) }
            }

        default:
            DebugLog.write("model: unknown event type: \(type) params: \(params.keys.sorted().joined(separator: ", "))")
            break
        }
        if type == "sessions.changed" || type.hasPrefix("tool.") || type.hasPrefix("subagent.")
            || type == "message.start" || type == "message.complete" {
            refreshDelegationStatus()
            cacheCurrentAgentState()
        }
    }

    private func appendTerminalErrorMessage(_ text: String) {
        guard !didAppendTerminalErrorForCurrentTurn else { return }
        didAppendTerminalErrorForCurrentTurn = true
        messages.append(ChatMessage(
            role: .hermes,
            text: text,
            modelName: currentModelName,
            isError: true
        ))
    }

    private static func completedMessageText(from payload: [String: Any]) -> String? {
        if let text = payload["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let message = payload["message"] as? [String: Any] {
            return completedMessageText(from: message)
        }
        if let content = payload["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func beginStreamingMessage() {
        didAppendTerminalErrorForCurrentTurn = false
        let responseStartedAt = Date()
        messages.append(ChatMessage(role: .hermes, text: "", timestamp: responseStartedAt, modelName: currentModelName))
        streamingMessageID = messages.last?.id
        streamingMessageSessionID = sessionID
        streamingResponseStartedAt = responseStartedAt
        streamingMessageBuffer = ""
        streamingMessagePendingPresentationDelta = ""
        streamingMessagePublishedText = ""
        streamingTurnActivity = []
        streamingText.clearPresentation()
        streamingMessageGeneration &+= 1
    }

    /// Reopens the live row of a turn Hermes reports still running on resume,
    /// seeded with what it already streamed, so the turn's remaining deltas
    /// and tool events land in it instead of being dropped.
    private func adoptRunningTurn(inflight: [String: Any]?, activity: [ActiveToolCall]) {
        // The running turn's prompt may not be in stored history yet.
        let prompt = (inflight?["user"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty, messages.last(where: { $0.role == .user })?.text != prompt {
            messages.append(ChatMessage(role: .user, text: prompt))
        }
        beginStreamingMessage()
        streamingTurnActivity = activity
        if let streamed = inflight?["assistant"] as? String, !streamed.isEmpty {
            streamingMessageBuffer = streamed
            streamingMessagePendingPresentationDelta = streamed
            scheduleStreamingMessageFlush()
        }
        conversationActivityPhase = .responding
        isSending = true
        status = .working
        if let sessionStorageID { updateSessionActivity(sessionID: sessionStorageID, isWorking: true) }
    }

    /// Thinking segments share the turn log with tool calls so they keep
    /// their place in the sequence; the text rides in `result`.
    private func recordTurnThinking(_ state: ReasoningState) {
        guard streamingMessageID != nil else { return }
        if let index = streamingTurnActivity.lastIndex(where: { $0.name == ActiveToolCall.thinkingName }),
           !streamingTurnActivity[index].isComplete {
            streamingTurnActivity[index].result = state.text
            if state.isComplete { closeTurnThinking() }
        } else if !state.isComplete || !state.text.isEmpty {
            streamingTurnActivity.append(ActiveToolCall(
                id: "thinking:\(UUID().uuidString)",
                name: ActiveToolCall.thinkingName,
                input: "",
                context: "",
                startedAt: Date(),
                result: state.text,
                isComplete: state.isComplete
            ))
        }
    }

    /// Compaction rides in the turn log like thinking, so the transcript shows
    /// it live and keeps a "Compacted context" step once Hermes finishes.
    private func recordTurnCompaction(isComplete: Bool) {
        guard streamingMessageID != nil else { return }
        if let index = streamingTurnActivity.lastIndex(where: { $0.name == ActiveToolCall.compactionName }),
           !streamingTurnActivity[index].isComplete {
            guard isComplete else { return }
            streamingTurnActivity[index].isComplete = true
            streamingTurnActivity[index].completedAt = Date()
        } else if !isComplete {
            streamingTurnActivity.append(ActiveToolCall(
                id: "compaction:\(UUID().uuidString)",
                name: ActiveToolCall.compactionName,
                input: "",
                context: "",
                startedAt: Date(),
                isComplete: false
            ))
        }
    }

    private func closeTurnThinking() {
        for index in streamingTurnActivity.indices
        where streamingTurnActivity[index].name == ActiveToolCall.thinkingName && !streamingTurnActivity[index].isComplete {
            if !streamingReasoningBuffer.isEmpty { streamingTurnActivity[index].result = streamingReasoningBuffer }
            streamingTurnActivity[index].isComplete = true
            streamingTurnActivity[index].completedAt = Date()
        }
    }

    private static func upsert(_ calls: [ActiveToolCall], into log: inout [ActiveToolCall]) {
        for call in calls {
            if let index = log.firstIndex(where: { $0.id == call.id }) {
                log[index] = call
            } else {
                log.append(call)
            }
        }
    }

    private func removePendingClarificationResumeMessage() {
        guard let streamingMessageID,
              let index = messages.firstIndex(where: { $0.id == streamingMessageID }),
              messages[index].role == .hermes,
              messages[index].text.isEmpty else { return }
        messages.remove(at: index)
        self.streamingMessageID = nil
        streamingMessageSessionID = nil
        streamingResponseStartedAt = nil
        streamingMessageBuffer = ""
        streamingMessagePendingPresentationDelta = ""
        streamingMessagePublishedText = ""
        streamingText.clearPresentation()
        isAwaitingClarificationResume = false
    }

    private func discardStreamingMessage() {
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        if let id = streamingMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages.remove(at: index)
        }
        streamingMessageID = nil
        streamingMessageSessionID = nil
        streamingResponseStartedAt = nil
        streamingMessageBuffer = ""
        streamingMessagePendingPresentationDelta = ""
        streamingMessagePublishedText = ""
        streamingText.clearPresentation()
        streamingMessageGeneration &+= 1
    }

    /// Completion failures are reported by Hermes inside the completion
    /// envelope, rather than as a separate `error` event. Accept both the
    /// plain string form and the structured error form used by the gateway.
    static func messageCompletionError(from payload: [String: Any]) -> String? {
        guard let rawError = payload["error"] else { return nil }
        if let message = rawError as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : message
        }
        if let message = nestedClarificationString(keys: ["message", "detail", "description"], in: rawError) {
            return message
        }
        let serialized = eventText(rawError)
        return serialized.isEmpty ? "Hermes reported an error while completing the request." : serialized
    }

    private static func nestedClarificationString(keys: [String], in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let string = dictionary[key] as? String,
                   !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return string
                }
            }
            for child in dictionary.values {
                if let result = nestedClarificationString(keys: keys, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = nestedClarificationString(keys: keys, in: child) { return result }
            }
        } else if let string = value as? String,
                  let data = string.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) {
            return nestedClarificationString(keys: keys, in: decoded)
        }
        return nil
    }

    private static func nestedClarificationStrings(keys: [String], in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let strings = dictionary[key] as? [String] { return strings }
                if let values = dictionary[key] as? [Any] {
                    let strings = values.compactMap { $0 as? String }
                    if !strings.isEmpty { return strings }
                }
            }
            for child in dictionary.values {
                let result = nestedClarificationStrings(keys: keys, in: child)
                if !result.isEmpty { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                let result = nestedClarificationStrings(keys: keys, in: child)
                if !result.isEmpty { return result }
            }
        } else if let string = value as? String,
                  let data = string.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) {
            return nestedClarificationStrings(keys: keys, in: decoded)
        }
        return []
    }

    private static func isHighFrequencyEvent(_ type: String) -> Bool {
        HermesHighFrequencyEvent.includes(type)
    }

    /// Events only a running turn emits, so seeing one proves a turn is live.
    static func isMidTurnEvent(_ type: String) -> Bool {
        switch type {
        case "tool.call", "tool.start", "tool.use", "tool_use",
             "reasoning.start", "reasoning.delta", "thinking", "thinking.delta":
            true
        default:
            false
        }
    }

    private func scheduleActivityPresentation() {
        guard activityPresentationTask == nil else { return }
        activityPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.activityPresentationTask = nil
            self.activityPresentationRevision &+= 1
        }
    }

    private func scheduleStreamingMessageFlush() {
        guard streamingMessageFlushTask == nil else { return }
        let generation = streamingMessageGeneration
        streamingMessageFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Limit live layout invalidation to a comfortable cadence. As a
            // response grows, wrapping its entire live Text becomes more
            // expensive, so the presentation cadence backs off while the
            // transport buffer remains lossless.
            let interval = ConversationStreamingPresentationPolicy
                .flushIntervalMilliseconds(textLength: self.streamingMessageBuffer.utf8.count)
            try? await Task.sleep(for: .milliseconds(interval))
            guard !Task.isCancelled, self.streamingMessageGeneration == generation else { return }
            self.streamingMessageFlushTask = nil
            self.flushStreamingMessage()
        }
    }

    private func scheduleReasoningFlush() {
        guard reasoningFlushTask == nil else { return }
        reasoningFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.reasoningFlushTask = nil
            guard var state = self.reasoningState else { return }
            state.text = self.streamingReasoningBuffer
            self.reasoningState = state
        }
    }

    private func flushStreamingMessage() {
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        guard streamingMessageID != nil,
              streamingMessageSessionID == sessionID,
              let newText = pendingStreamingText() else { return }
        applyVisionNoticeDetectionIfNeeded(to: newText)
        let publishedText = streamingMessageIsVisionNotice ? Self.visionUnsupportedNotice : newText
        if streamingMessageIsVisionNotice {
            streamingText.replacePresentation(with: publishedText)
        } else {
            let delta = streamingMessagePendingPresentationDelta
            streamingMessagePendingPresentationDelta = ""
            streamingText.appendPresentation(delta)
        }
        streamingMessagePublishedText = publishedText
    }

    /// Commits the buffered stream into the transcript. Callers are response
    /// boundaries (complete, error, stop, chat switch) — the one place the
    /// messages array should change for the streamed response.
    private func commitStreamingMessage(tokenCount: Int? = nil) {
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        guard let id = streamingMessageID,
              streamingMessageSessionID == sessionID,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            streamingText.clearPresentation()
            streamingResponseStartedAt = nil
            return
        }
        applyVisionNoticeDetectionIfNeeded(to: streamingMessageBuffer)
        let publishedText = streamingMessageIsVisionNotice ? Self.visionUnsupportedNotice : streamingMessageBuffer
        // Completion may arrive before the adaptive presentation timer flushes
        // its final delta. Reconcile the live projection first so the native
        // completion handoff can reuse every promoted section.
        streamingText.reconcilePresentation(with: publishedText)
        let message = messages[index]
        let attribution = Self.botAttribution(from: publishedText)
        let botProfileID = attribution?.profileID ?? activeBotProfileID
        let botDisplayName = attribution?.displayName ?? activeBotDisplayName
        closeTurnThinking()
        messages[index] = ChatMessage(
            id: id,
            role: .hermes,
            text: attribution?.body ?? publishedText,
            image: message.image,
            timestamp: message.timestamp,
            modelName: message.modelName,
            responseDuration: Date().timeIntervalSince(message.timestamp),
            tokenCount: tokenCount,
            botProfileID: botProfileID,
            botDisplayName: botDisplayName,
            // The response boundary is authoritative: nothing is still running.
            activity: streamingTurnActivity.map { call in
                var call = call
                call.isComplete = true
                return call
            }
        )
        streamingMessagePendingPresentationDelta = ""
        streamingText.retainCompletionPresentation(for: id)
        streamingText.clearLivePresentation()
        streamingResponseStartedAt = nil
    }

    private func pendingStreamingText() -> String? {
        streamingMessageIsVisionNotice ? Self.visionUnsupportedNotice : streamingMessageBuffer
    }

    private func applyVisionNoticeDetectionIfNeeded(to text: String) {
        if !streamingMessageIsVisionNotice, Self.isVisionUnsupportedError(text) {
            streamingMessageIsVisionNotice = true
            activeToolCalls.removeAll { $0.name.lowercased().contains("vision") }
        }
    }

    private func cacheCurrentAgentState() {
        // Subagent event storms called this per event; each call copies every
        // projection array and enqueues an encode/write. Coalesce to one
        // snapshot per interval with a trailing write for the last event.
        let now = Date()
        if let last = lastAgentStateCacheAt, now.timeIntervalSince(last) < 0.5 {
            if agentStateCacheTrailingTask == nil {
                agentStateCacheTrailingTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    self.agentStateCacheTrailingTask = nil
                    self.writeAgentStateSnapshot()
                }
            }
            return
        }
        lastAgentStateCacheAt = now
        writeAgentStateSnapshot()
    }

    private func writeAgentStateSnapshot() {
        lastAgentStateCacheAt = Date()
        guard let sessionStorageID else { return }
        let snapshot = agentStateBySessionID.merging([sessionStorageID: SessionAgentState(
            activeToolCalls: activeToolCalls,
            recentEvents: recentEvents,
            sessionAgents: sessionAgents,
            activeSubagents: activeSubagents,
            agentActivities: agentActivities,
            synthesizedSubagentIDs: synthesizedSubagentIDs
        )]) { _, new in new }
        Task { await agentStateWriter.enqueue(snapshot) }
    }

    private func persistActiveSessionID(_ sessionID: String?) {
        guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else { return }
        defaults.set(sessionID, forKey: lastSessionIDKey(for: sessionProfileID ?? profileScopeID))
    }

    private func lastSessionIDKey(for profileID: String?) -> String {
        let suffix = Self.normalizedProfileID(profileID) ?? "launch"
        return "\(lastSessionIDKey).\(suffix)"
    }

    private static func normalizedProfileID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func scopedSessionParams(_ params: [String: Any], profileID: String? = nil) -> [String: Any] {
        let scope = profileID ?? sessionProfileID ?? profileScopeID
        guard let scope, !scope.isEmpty else { return params }
        var scoped = params
        scoped["profile"] = scope
        return scoped
    }

    static func stableSessionID(from result: [String: Any]) -> String? {
        for key in ["session_key", "stored_session_id", "resumed"] {
            if let value = result[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// A resume response may legitimately carry a fresh runtime session id —
    /// a forked resumed conversation or the lazily created canonical Bot Chat
    /// resumed by title — but those responses alias the requested session
    /// through a storage key. Any other id (for example the gateway resolving
    /// resume to whichever session is currently responding) belongs to a
    /// different conversation and must not be adopted.
    static func resumeResponseProvesSessionOwnership(
        requestedSessionID: String,
        resolvedSessionID: String,
        result: [String: Any]
    ) -> Bool {
        let requested = requestedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedSessionID == requested { return true }
        if let storageAlias = stableSessionID(from: result),
           storageAlias.trimmingCharacters(in: .whitespacesAndNewlines) == requested {
            return true
        }
        return false
    }

    static func sessionAttributionID(runtimeID: String?, storageID: String?) -> String? {
        for candidate in [storageID, runtimeID] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Once Hermes accepts a resume, its resolved identifier is the identity
    /// that downstream runtime-owned records (including Kanban work) use.
    static func kanbanAttributionAfterResume(
        requestedSessionID: String,
        resolvedSessionID: String
    ) -> String {
        let resolved = resolvedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        return requestedSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func kanbanAttributionID(
        requestedSessionID: String?,
        runtimeID: String?,
        storageID: String?
    ) -> String? {
        if let requestedSessionID = requestedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedSessionID.isEmpty {
            return requestedSessionID
        }
        return sessionAttributionID(runtimeID: runtimeID, storageID: storageID)
    }

    private func armNativeVoiceCapture(generation expectedGeneration: Int? = nil) {
        if let expectedGeneration, !nativeVoiceCapture.isCurrent(generation: expectedGeneration) {
            return
        }
        guard voiceState.isNativeConversationActive,
              !isSending,
              let sessionID,
              nativeVoiceCapture.beginCapture() else { return }
        let captureGeneration = nativeVoiceCapture.generation

        Task {
            do {
                let recording = try await gateway.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: ["action": "start", "session_id": sessionID])
                guard nativeVoiceCapture.isCurrent(generation: captureGeneration),
                      voiceState.isNativeConversationActive else { return }
                if (recording["status"] as? String) == "busy" {
                    let shouldRetry = nativeVoiceCapture.captureStartFailed()
                    if shouldRetry {
                        try? await Task.sleep(for: .milliseconds(300))
                        armNativeVoiceCapture(generation: captureGeneration)
                    } else {
                        voiceState = .localFallback("Hermes microphone stayed busy. Tap the orb to retry voice.")
                    }
                    return
                }
                nativeVoiceCapture.captureStarted()
                voiceState = .listening
            } catch {
                guard nativeVoiceCapture.isCurrent(generation: captureGeneration),
                      voiceState.isNativeConversationActive else { return }
                let shouldRetry = nativeVoiceCapture.captureStartFailed()
                if shouldRetry {
                    try? await Task.sleep(for: .milliseconds(300))
                    armNativeVoiceCapture(generation: captureGeneration)
                } else {
                    voiceState = .localFallback("Hermes could not start the next voice capture: \(Self.safeUserDiagnostic(error.localizedDescription))")
                }
            }
        }
    }

    private func recoverNativeVoiceCaptureIfInterruptedTranscriptIsMissing(generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  self.voiceState.isNativeConversationActive,
                  self.nativeVoiceCapture.interruptionTimedOut(generation: generation) else { return }
            self.voiceState = .listening
            self.armNativeVoiceCapture()
        }
    }

    private func awaitNativeVoicePlaybackDrain(generation: Int, responseText: String) {
        let delay = NativeVoicePlaybackDrain.estimatedDuration(for: responseText)
        let formattedDelay = String(format: "%.1f", delay)
        DebugLog.write("voice: holding microphone for \(formattedDelay)s while TTS drains")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  self.voiceState.isNativeConversationActive,
                  self.nativeVoiceCapture.playbackDrainCompleted(generation: generation) else { return }
            self.voiceTelemetry.beginListening()
            self.voiceState = .listening
            self.armNativeVoiceCapture()
        }
    }

    private func submitNativeVoiceTranscript(_ text: String) {
        guard let sessionID, !isSending else { return }
        let requestGeneration = sessionResumeGeneration
        messages.append(ChatMessage(role: .user, text: text))
        status = .working
        isSending = true
        voiceState = .thinking
        voiceTelemetry.submittedRequest()
        Task {
            do {
                _ = try await gateway.request(
                    HermesFeatureIDs.ID.promptSubmit.rawValue,
                    params: ["session_id": sessionID, "text": text]
                )
                guard self.sessionResumeGeneration == requestGeneration,
                      self.sessionID == sessionID else { return }
            } catch {
                guard self.sessionResumeGeneration == requestGeneration,
                      self.sessionID == sessionID else { return }
                messages.append(ChatMessage(role: .hermes, text: "I couldn’t submit the voice request: \(Self.safeUserDiagnostic(error.localizedDescription))", modelName: currentModelName))
                status = .offline
                isSending = false
                nativeVoiceCapture.reset()
                voiceState = .listening
                armNativeVoiceCapture()
            }
        }
    }

    private func notify(title: String, body: String, identifier: String) {
        guard !isPopoverVisible, HermesAppRuntime.supportsUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.userInfo = ["attention_id": identifier]
        let request = UNNotificationRequest(identifier: "\(identifier)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func startDelegationMonitoring() {
        delegationMonitoringTask?.cancel()
        guard sessionID != nil else { return }
        delegationMonitoringTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let hasLiveWorkers = self.activeSubagents.contains { AgentActivityPresentation.isActiveStatus($0.status) }
                    || self.sessionAgents.contains { AgentActivityPresentation.isActiveStatus($0.status) }
                    || self.status == .working
                let interval: Duration = hasLiveWorkers ? .seconds(3) : .seconds(15)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, self.sessionID != nil else { return }
                self.refreshDelegationStatus()
            }
        }
    }

    func refreshDelegationStatus() {
        guard sessionID != nil else { return }
        delegationRefreshRequested = true
        if isRefreshingDelegationStatus { return }
        guard delegationRefreshTask == nil else { return }
        let delay = max(0, 0.25 - Date().timeIntervalSince(lastDelegationRefreshAt))
        delegationRefreshTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.delegationRefreshTask = nil
            self.delegationRefreshRequested = false
            self.lastDelegationRefreshAt = Date()
            self.performDelegationStatusRefresh()
        }
    }

    private func performDelegationStatusRefresh() {
        guard !isRefreshingDelegationStatus else { return }
        guard let expectedSessionID = sessionID, !expectedSessionID.isEmpty else { return }
        isRefreshingDelegationStatus = true
        Task {
            do {
                let result = try await gateway.request(
                    HermesFeatureIDs.ID.delegationStatus.rawValue,
                    params: ["session_id": expectedSessionID]
                )
                guard sessionID == expectedSessionID else { return }
                // Hermes can return global live workers even when a session is
                // supplied. An unscoped worker must never animate in the
                // current conversation; showing no activity is safer than
                // attributing another session's work to this one.
                let rows = (result["active"] as? [[String: Any]] ?? []).filter {
                    Self.delegationStatusRow($0, belongsTo: expectedSessionID)
                }
                let projections = rows.compactMap { row -> (row: [String: Any], agent: HermesSubagent)? in
                    guard row["subagent_id"] is String,
                          let agent = self.telemetry(from: row, fallbackStatus: "running") else { return nil }
                    return (row, agent)
                }
                for projection in projections {
                    self.reconcileSyntheticPlaceholder(for: projection.agent)
                    self.recordTelemetryActivityIfChanged(row: projection.row, agent: projection.agent)
                }
                // `active` is Hermes' live-worker projection. Do not retain a
                // native worker after it disappears from this response: doing
                // so leaves a finished agent permanently shown as running.
                // Session history remains in sessionAgents; only locally
                // synthesized placeholders survive until Hermes identifies
                // their native worker ID.
                let rpcAgents = projections.map(\.agent)
                for agent in rpcAgents { upsertSessionAgent(agent) }
                activeSubagents = Self.reconciledLiveAgents(
                    authoritative: rpcAgents.filter { AgentActivityPresentation.isActiveStatus($0.status) },
                    current: activeSubagents,
                    synthesizedIDs: synthesizedSubagentIDs
                )
                cacheCurrentAgentState()
            } catch {
                DebugLog.write("workspace: delegation status failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
            self.isRefreshingDelegationStatus = false
            if self.delegationRefreshRequested {
                self.refreshDelegationStatus()
            }
        }
    }

    private static func isTerminalAgentStatus(_ status: String) -> Bool {
        let lower = status.lowercased()
        return lower.contains("complete") || lower.contains("done") || lower.contains("finish")
            || lower.contains("error") || lower.contains("fail") || lower.contains("interrupt")
    }

    static func delegationStatusRow(_ row: [String: Any], belongsTo sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        // Current Hermes registry rows use owner_agent_session_id. The other
        // names are retained only for older gateways that exposed an explicit
        // session owner. `parent_id` is a subagent ID, never a session owner.
        for key in ["owner_agent_session_id", "parent_session_id", "root_session_id", "session_id"] {
            if (row[key] as? String) == sessionID { return true }
        }
        for key in ["parent", "session", "context"] {
            guard let nested = row[key] as? [String: Any] else { continue }
            for sessionKey in ["session_id", "id"] where (nested[sessionKey] as? String) == sessionID {
                return true
            }
        }
        return false
    }

    /// Builds the visible live-worker list from an authoritative Hermes
    /// response. Completed workers remain in session history, not this list.
    static func reconciledLiveAgents(
        authoritative: [HermesSubagent],
        current: [HermesSubagent],
        synthesizedIDs: Set<String>
    ) -> [HermesSubagent] {
        let authoritativeIDs = Set(authoritative.map(\.id))
        let pendingPlaceholders = current.filter {
            synthesizedIDs.contains($0.id) && !authoritativeIDs.contains($0.id)
        }
        return authoritative + pendingPlaceholders
    }

    static func agentStatus(current: String, eventType: String, reportedStatus: String? = nil) -> String {
        let normalizedType = eventType.lowercased()
        let reportedStatus = canonicalAgentStatus(reportedStatus)
        let eventStatus: String? = switch normalizedType {
        case "subagent.spawn_requested": "queued"
        case "subagent.start", "subagent.tool", "subagent.progress", "subagent.thinking": "running"
        case "subagent.complete", "subagent.completed", "subagent.done", "subagent.finished", "subagent.finish": "complete"
        case "subagent.error", "subagent.failed", "subagent.fail": "error"
        case "subagent.interrupt", "subagent.interrupted": "interrupted"
        default: nil
        }
        let nextStatus = reportedStatus ?? eventStatus
        guard let nextStatus else { return current }
        if isTerminalAgentStatus(current), !isTerminalAgentStatus(nextStatus) { return current }
        return nextStatus
    }

    /// Hermes has used both lifecycle event names and status fields for agent
    /// completion. Normalize the latter before it reaches presentation state so
    /// a completed worker cannot remain visually running after a status update.
    static func canonicalAgentStatus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        if normalized.contains("complete") || normalized.contains("done") || normalized.contains("finish") || normalized.contains("success") { return "complete" }
        if normalized.contains("interrupt") || normalized.contains("cancel") || normalized.contains("abort") { return "interrupted" }
        if normalized.contains("error") || normalized.contains("fail") { return "error" }
        if normalized.contains("block") { return "blocked" }
        if normalized.contains("queue") || normalized.contains("pending") || normalized.contains("wait") { return "queued" }
        if normalized.contains("run") || normalized.contains("work") || normalized.contains("active") || normalized.contains("start") { return "running" }
        return normalized
    }

    static func eventBelongsToSession(
        type: String,
        envelopeSessionID: String?,
        eventSessionID: String?,
        payload: [String: Any],
        currentSessionID: String,
        agents: [HermesSubagent]
    ) -> Bool {
        guard !currentSessionID.isEmpty else { return false }
        let payloadSessionID = payload["session_id"] as? String

        // If both the event envelope and payload claim a session, they must
        // agree. Treat conflicting attribution as untrusted rather than
        // silently preferring either source.
        if let envelopeSessionID, !envelopeSessionID.isEmpty,
           let payloadSessionID, !payloadSessionID.isEmpty,
           envelopeSessionID != payloadSessionID {
            return false
        }

        if eventSessionID == currentSessionID {
            // A parent-session event may declare its parent explicitly, but it
            // may not smuggle in a different parent identity.
            if let parentSessionID = payload["parent_session_id"] as? String,
               parentSessionID != currentSessionID {
                return false
            }
            return true
        }

        // A delegated worker has its own child session, but its activity still
        // belongs to the parent session currently shown by the Dock. Require
        // the envelope child identity itself to match a current child agent,
        // and reject every contradictory supplied identifier.
        guard type.hasPrefix("subagent."),
              let envelopeSessionID, !envelopeSessionID.isEmpty,
              let eventSessionID, eventSessionID == envelopeSessionID else {
            return false
        }
        if let parentSessionID = payload["parent_session_id"] as? String,
           parentSessionID != currentSessionID {
            return false
        }
        if let childSessionID = payload["child_session_id"] as? String,
           !childSessionID.isEmpty,
           childSessionID != envelopeSessionID {
            return false
        }
        return agents.contains { $0.childSessionID == envelopeSessionID }
    }

    /// Resolves both native subagent IDs and the child session IDs used by
    /// ordinary events emitted from inside a delegated worker.
    static func agentID(
        explicitAgentID: String?,
        eventSessionID: String?,
        childSessionID: String? = nil,
        goal: String? = nil,
        taskIndex: Int? = nil,
        agents: [HermesSubagent]
    ) -> String? {
        if let explicitAgentID, !explicitAgentID.isEmpty { return explicitAgentID }
        for sessionReference in [childSessionID, eventSessionID].compactMap({ $0 }) where !sessionReference.isEmpty {
            if let match = agents.first(where: {
                $0.id == sessionReference || $0.childSessionID == sessionReference
            }) {
                return match.id
            }
        }
        if let goal {
            let normalizedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matches = agents.filter {
                $0.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedGoal
            }
            if matches.count == 1 { return matches[0].id }
        }
        if let taskIndex {
            let suffix = ":\(taskIndex)"
            let matches = agents.filter { $0.id.hasSuffix(suffix) }
            if matches.count == 1 { return matches[0].id }
        }
        return nil
    }

    static func agentActivityPayload(_ payload: [String: Any], resolvedAgentID: String?) -> [String: Any] {
        guard payload["subagent_id"] == nil, let resolvedAgentID else { return payload }
        var attributed = payload
        attributed["subagent_id"] = resolvedAgentID
        return attributed
    }

    /// Canonical boundary between raw Hermes JSON-RPC envelopes and the
    /// per-agent activity model consumed by both the map and pipeline.
    static func agentActivityProjection(
        type: String,
        params: [String: Any],
        currentSessionID: String?,
        agents: [HermesSubagent]
    ) -> AgentActivityEnvelopeProjection? {
        let rawPayload = params["payload"] as? [String: Any] ?? [:]
        let eventSessionID = (params["session_id"] as? String) ?? (rawPayload["session_id"] as? String)
        let explicitAgentID = (rawPayload["subagent_id"] as? String)
            ?? (params["subagent_id"] as? String)
            ?? (rawPayload["agent_id"] as? String)
            ?? (params["agent_id"] as? String)
        let childSessionID = (rawPayload["child_session_id"] as? String)
            ?? (params["child_session_id"] as? String)
        let resolvedAgentID = agentID(
            explicitAgentID: explicitAgentID,
            eventSessionID: eventSessionID,
            childSessionID: childSessionID,
            goal: rawPayload["goal"] as? String,
            taskIndex: (rawPayload["task_index"] as? NSNumber)?.intValue,
            agents: agents
        )
        let parentSessionID = (rawPayload["parent_id"] as? String)
            ?? (rawPayload["parent_session_id"] as? String)

        if type.hasPrefix("subagent.") {
            let isKnownAgent = resolvedAgentID.map { id in agents.contains(where: { $0.id == id }) } ?? false
            guard eventSessionID == nil || eventSessionID == currentSessionID
                || parentSessionID == currentSessionID || isKnownAgent else { return nil }
            return AgentActivityEnvelopeProjection(
                kind: type,
                payload: agentActivityPayload(rawPayload, resolvedAgentID: resolvedAgentID),
                consumesParentEvent: false
            )
        }

        guard let resolvedAgentID,
              isAgentScopedActivity(
                eventAgentID: resolvedAgentID,
                eventSessionID: eventSessionID,
                parentSessionID: parentSessionID,
                currentSessionID: currentSessionID,
                agents: agents
              ),
              let activityKind = agentActivityKind(for: type) else { return nil }
        return AgentActivityEnvelopeProjection(
            kind: activityKind,
            payload: agentActivityPayload(rawPayload, resolvedAgentID: resolvedAgentID),
            consumesParentEvent: true
        )
    }

    /// The parent delegation call can carry a future subagent ID while still
    /// belonging to the current session. It must reach the normal tool handler
    /// so the agent card is created. Only known workers or events explicitly
    /// attached to a child session are diverted into agent activity history.
    static func isAgentScopedActivity(
        eventAgentID: String,
        eventSessionID: String?,
        parentSessionID: String?,
        currentSessionID: String?,
        agents: [HermesSubagent]
    ) -> Bool {
        if agents.contains(where: { $0.id == eventAgentID }) { return true }
        guard let currentSessionID else { return false }
        return parentSessionID == currentSessionID && eventSessionID != currentSessionID
    }

    /// Stream deltas are intentionally omitted: one row per token would drown
    /// out the useful activity. Lifecycle boundaries and complete tool actions
    /// remain visible.
    static func agentActivityKind(for eventType: String) -> String? {
        switch eventType.lowercased() {
        case "tool.call", "tool.start", "tool.use", "tool_use":
            return "subagent.tool"
        case "tool.result", "tool_result", "tool.complete", "tool_complete":
            return "subagent.tool.complete"
        case "reasoning.start", "thinking":
            return "subagent.thinking"
        case "reasoning.complete", "thinking.stop", "thinking.complete":
            return "subagent.thinking.complete"
        case "message.complete":
            // Delegated workers commonly finish through their child session's
            // ordinary response boundary rather than a separate
            // `subagent.complete` envelope. This method is reached only after
            // the event is proven agent-scoped, so the parent conversation's
            // own message completion is unaffected.
            return "subagent.complete"
        case "error":
            return "subagent.error"
        case "message.delta", "reasoning.delta", "thinking.delta":
            return nil
        default:
            return nil
        }
    }

    private static func inferRole(from title: String) -> String? {
        let lower = title.lowercased()
        let roles: [(needle: String, label: String)] = [
            ("quality assurance", "QA"), ("security reviewer", "Security Reviewer"),
            ("frontend", "Frontend"), ("front-end", "Frontend"),
            ("backend", "Backend"), ("back-end", "Backend"),
            ("security", "Security"), ("qa", "QA"),
            ("planner", "Planner"), ("implementer", "Implementer"),
            ("reviewer", "Reviewer"), ("verifier", "Verifier"),
            ("investigator", "Investigator"), ("researcher", "Researcher"),
            ("tester", "Tester"), ("testing", "QA"), ("architect", "Architect")
        ]
        for role in roles where lower.contains(role.needle) {
            return role.label
        }
        return nil
    }

    /// Converts one Hermes `delegate_task` call into the semantic workers the
    /// call represents. Batch delegation is one tool call but many agents, so
    /// the tool-call ID alone is not a sufficient row identity.
    static func projectedDelegationAgents(toolCallID: String, args: [String: Any], startedAt: Date) -> [HermesSubagent] {
        let taskRows = args["tasks"] as? [[String: Any]]
        let rows = taskRows?.isEmpty == false ? taskRows! : [args]

        return rows.enumerated().map { index, task in
            func value(_ keys: [String]) -> String? {
                for source in [task, args] {
                    for key in keys {
                        guard let raw = source[key] as? String else { continue }
                        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { return clean }
                    }
                }
                return nil
            }

            let goal = value(["goal", "description", "prompt", "task", "instructions", "title"])
                ?? "Delegated agent"
            let orchestrationRole = value(["role"])
            let humanRole = value(["agent_role", "role_label", "specialty", "agent_type"])
                ?? orchestrationRole.flatMap { role in
                    ["leaf", "orchestrator"].contains(role.lowercased()) ? nil : role
                }
                ?? inferRole(from: goal)
            let name = value(["name", "agent_name", "display_name", "label"]) ?? humanRole
            let id = rows.count == 1 ? toolCallID : "\(toolCallID):\(index)"

            return HermesSubagent(
                id: id,
                name: name,
                childSessionID: value(["session_id", "child_session_id"]),
                goal: goal,
                role: humanRole,
                sourceSkill: value(["source_skill", "skill", "workflow"]),
                status: "running",
                model: value(["model"]),
                startedAt: startedAt,
                latestActivity: goal
            )
        }
    }

    static func isBackgroundDelegationDispatch(_ result: String) -> Bool {
        guard let data = result.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let status = (payload["status"] as? String)?.lowercased()
        let mode = (payload["mode"] as? String)?.lowercased()
        return status == "dispatched" || mode == "background"
    }

    /// Tool call input/result strings are shown as short previews in the
    /// activity list and are persisted verbatim into a per-session cache
    /// (`session-agent-state-v1.json`) that lives for the whole session
    /// lifetime. Full tool payloads (raw file listings, page dumps, etc.) can
    /// be hundreds of KB each; leaving them unbounded made that cache file
    /// grow into the multi-MB range for long sessions, which was observed to
    /// make session restoration fail with "connection to Hermes was lost".
    /// Cap what we keep to a size that comfortably covers the UI preview.
    static let toolPayloadPersistenceLimit = 4000

    static func truncatedForPersistence(_ value: String) -> String {
        guard value.count > toolPayloadPersistenceLimit else { return value }
        let prefix = value.prefix(toolPayloadPersistenceLimit)
        return "\(prefix)\n… [truncated \(value.count - toolPayloadPersistenceLimit) chars]"
    }

    static func eventText(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Extract only Hermes' stable Kanban identifiers. This deliberately does
    /// not attribute a card from conversational prose, profile names, titles,
    /// or assignees; callers must first establish a trusted tool-event and
    /// session boundary.
    static func kanbanTaskIDs(in text: String) -> Set<String> {
        let pattern = #"\bt_[A-Za-z0-9][A-Za-z0-9_-]*\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    /// Hermes emits `inline_diff` for edit tool completions. Some adapters use
    /// `diff`, `patch`, or place the patch in a subagent output tail, so accept
    /// those shapes while refusing ordinary tool output.
    static func diffPreview(from payload: [String: Any]) -> String? {
        for key in ["inline_diff", "diff_preview", "diff", "patch"] {
            if let preview = normalizedDiff(payload[key] as? String, requireMarkers: false) {
                return preview
            }
        }
        if let result = payload["result"] as? [String: Any] {
            for key in ["inline_diff", "diff_preview", "diff", "patch"] {
                if let preview = normalizedDiff(result[key] as? String, requireMarkers: false) {
                    return preview
                }
            }
        }
        if let tail = payload["output_tail"] as? [[String: Any]] {
            for entry in tail.reversed() {
                if let preview = normalizedDiff(entry["preview"] as? String, requireMarkers: true) {
                    return preview
                }
            }
        }
        return nil
    }

    private static func normalizedDiff(_ raw: String?, requireMarkers: Bool) -> String? {
        guard let raw else { return nil }
        let clean = HermesRuntimeInspector.stripANSI(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if requireMarkers {
            let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
            let hasMarkers = lines.contains {
                $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix("@@") || $0.hasPrefix("diff --git")
            }
            guard hasMarkers else { return nil }
        }
        return String(clean.prefix(4_000))
    }

    private func telemetry(from row: [String: Any], fallbackStatus: String? = nil) -> HermesSubagent? {
        guard let id = row["subagent_id"] as? String else { return nil }
        let goal = row["goal"] as? String ?? "Hermes subagent"
        let rawRole = (row["agent_role"] as? String)
            ?? (row["role_label"] as? String)
            ?? (row["role"] as? String)
        let role = rawRole.flatMap { value in
            ["leaf", "orchestrator"].contains(value.lowercased()) ? nil : value
        } ?? Self.inferRole(from: goal)
        return HermesSubagent(
            id: id,
            name: (row["name"] as? String) ?? (row["agent_name"] as? String) ?? (row["display_name"] as? String) ?? role,
            parentID: (row["parent_subagent_id"] as? String)
                ?? (row["parent_agent_id"] as? String)
                ?? (row["parent_id"] as? String)
                ?? (row["parent_session_id"] as? String),
            childSessionID: (row["child_session_id"] as? String)
                ?? (row["session_id"] as? String),
            depth: (row["depth"] as? NSNumber)?.intValue ?? 0,
            goal: goal,
            role: role,
            sourceSkill: row["source_skill"] as? String,
            status: Self.canonicalAgentStatus(row["status"] as? String) ?? fallbackStatus ?? "unknown",
            model: row["model"] as? String,
            startedAt: dateValue(row["started_at"]),
            completedAt: dateValue(row["completed_at"]),
            durationSeconds: (row["duration_seconds"] as? NSNumber)?.doubleValue,
            toolCount: (row["tool_count"] as? NSNumber)?.intValue ?? 0,
            latestActivity: (row["tool_preview"] as? String)
                ?? (row["text"] as? String)
                ?? (row["last_tool"] as? String),
            summary: row["summary"] as? String,
            inputTokens: (row["input_tokens"] as? NSNumber)?.intValue,
            outputTokens: (row["output_tokens"] as? NSNumber)?.intValue,
            reasoningTokens: (row["reasoning_tokens"] as? NSNumber)?.intValue,
            apiCalls: (row["api_calls"] as? NSNumber)?.intValue,
            filesRead: row["files_read"] as? [String] ?? [],
            filesWritten: row["files_written"] as? [String] ?? []
        )
    }

    private func mergeAgentEvent(_ type: String, payload: [String: Any]) {
        guard let id = payload["subagent_id"] as? String else { return }
        var agent = sessionAgents.first(where: { $0.id == id })
            ?? activeSubagents.first(where: { $0.id == id })
            ?? HermesSubagent(id: id, goal: payload["goal"] as? String ?? "Hermes subagent", status: "running")
        if let hydrated = telemetry(from: payload.merging(["subagent_id": id]) { current, _ in current }) {
            agent.name = hydrated.name ?? agent.name
            agent.parentID = hydrated.parentID ?? agent.parentID
            agent.childSessionID = hydrated.childSessionID ?? agent.childSessionID
            agent.depth = hydrated.depth
            if !hydrated.goal.isEmpty && hydrated.goal != "Hermes subagent" { agent.goal = hydrated.goal }
            agent.role = hydrated.role ?? agent.role
            agent.sourceSkill = hydrated.sourceSkill ?? agent.sourceSkill
            agent.model = hydrated.model ?? agent.model
            agent.toolCount = max(agent.toolCount, hydrated.toolCount)
            agent.startedAt = hydrated.startedAt ?? agent.startedAt
            agent.durationSeconds = hydrated.durationSeconds ?? agent.durationSeconds
            agent.summary = hydrated.summary ?? agent.summary
            agent.inputTokens = hydrated.inputTokens ?? agent.inputTokens
            agent.outputTokens = hydrated.outputTokens ?? agent.outputTokens
            agent.reasoningTokens = hydrated.reasoningTokens ?? agent.reasoningTokens
            agent.apiCalls = hydrated.apiCalls ?? agent.apiCalls
            agent.filesRead = hydrated.filesRead.isEmpty ? agent.filesRead : hydrated.filesRead
            agent.filesWritten = hydrated.filesWritten.isEmpty ? agent.filesWritten : hydrated.filesWritten
        }
        agent.status = Self.agentStatus(
            current: agent.status,
            eventType: type,
            reportedStatus: (payload["status"] as? String) ?? (payload["state"] as? String)
        )
        if Self.isTerminalAgentStatus(agent.status) {
            agent.completedAt = dateValue(payload["completed_at"]) ?? Date()
            agent.durationSeconds = (payload["duration_seconds"] as? NSNumber)?.doubleValue ?? agent.durationSeconds
        }
        if let preview = payload["tool_preview"] as? String ?? payload["text"] as? String { agent.latestActivity = preview }
        reconcileSyntheticPlaceholder(for: agent)
        upsertSessionAgent(agent)
        upsertActiveAgent(agent)
    }

    private func upsertSessionAgent(_ agent: HermesSubagent) {
        if let index = sessionAgents.firstIndex(where: { $0.id == agent.id }) {
            sessionAgents[index] = agent
        } else {
            sessionAgents.append(agent)
        }
    }

    private func upsertActiveAgent(_ agent: HermesSubagent) {
        if let index = activeSubagents.firstIndex(where: { $0.id == agent.id }) {
            activeSubagents[index] = agent
        } else {
            activeSubagents.append(agent)
        }
    }

    /// Native subagent events have a stable Hermes ID; synthesized rows only
    /// bridge the short gap before that first event. Remove the matching
    /// placeholder so a batch never renders both identities for one worker.
    private func reconcileSyntheticPlaceholder(for nativeAgent: HermesSubagent) {
        guard !synthesizedSubagentIDs.contains(nativeAgent.id) else { return }
        let normalizedGoal = nativeAgent.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedGoal.isEmpty, normalizedGoal != "hermes subagent" else { return }
        guard let placeholder = activeSubagents.first(where: {
            synthesizedSubagentIDs.contains($0.id)
                && $0.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedGoal
        }) else { return }

        synthesizedSubagentIDs.remove(placeholder.id)
        activeSubagents.removeAll { $0.id == placeholder.id }
        sessionAgents.removeAll { $0.id == placeholder.id }
        agentActivities.removeAll { $0.agentID == placeholder.id }
    }

    private static func isDelegationTool(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("delegate") || lower == "spawn" || lower == "spawn_agent"
            || lower == "launch_agent" || lower == "create_subagent" || lower == "dispatch_agent"
    }

    private func synthesizeSubagent(toolCallID: String, args: [String: Any]) {
        let startedAt = Date()
        let agents = Self.projectedDelegationAgents(toolCallID: toolCallID, args: args, startedAt: startedAt)
        guard !agents.isEmpty, agents.contains(where: { !synthesizedSubagentIDs.contains($0.id) }) else { return }

        for agent in agents where !synthesizedSubagentIDs.contains(agent.id) {
            synthesizedSubagentIDs.insert(agent.id)
            upsertSessionAgent(agent)
            upsertActiveAgent(agent)
            agentActivities.append(AgentActivity(
                id: UUID(),
                timestamp: startedAt,
                agentID: agent.id,
                kind: "subagent.start",
                text: agent.goal,
                toolName: nil,
                handoffTarget: nil
            ))
        }
        if agentActivities.count > 250 {
            agentActivities.removeFirst(agentActivities.count - 250)
        }
        DebugLog.write("model: synthesized \(agents.count) subagent row(s) for \(toolCallID)")
    }

    private func refreshSynthesizedSubagents(toolCallID: String, args: [String: Any]) {
        let matchingIDs = synthesizedSubagentIDs.filter { $0 == toolCallID || $0.hasPrefix("\(toolCallID):") }
        guard !matchingIDs.isEmpty else { return }
        synthesizedSubagentIDs.subtract(matchingIDs)
        activeSubagents.removeAll { matchingIDs.contains($0.id) }
        sessionAgents.removeAll { matchingIDs.contains($0.id) }
        agentActivities.removeAll { activity in
            activity.agentID.map(matchingIDs.contains) == true
        }
        synthesizeSubagent(toolCallID: toolCallID, args: args)
    }

    private func completeSynthesizedSubagent(toolCallID: String, result: String, payload: [String: Any]) {
        // Modern Hermes returns immediately after background dispatch. Native
        // subagent.complete events, not this acknowledgement, own completion.
        guard !Self.isBackgroundDelegationDispatch(result) else { return }
        let sessionID = (payload["session_id"] as? String) ?? (payload["child_session_id"] as? String)
        let summary = result.isEmpty ? nil : String(result.prefix(400))
        let matchingIDs = synthesizedSubagentIDs.filter { $0 == toolCallID || $0.hasPrefix("\(toolCallID):") }
        for id in matchingIDs {
            guard let index = activeSubagents.firstIndex(where: { $0.id == id }) else { continue }
            activeSubagents[index].status = "complete"
            activeSubagents[index].completedAt = Date()
            if let sessionID { activeSubagents[index].childSessionID = sessionID }
            if let summary { activeSubagents[index].summary = summary }
            if let sessionIndex = sessionAgents.firstIndex(where: { $0.id == id }) {
                sessionAgents[sessionIndex] = activeSubagents[index]
            }
            agentActivities.append(AgentActivity(
                id: UUID(),
                timestamp: Date(),
                agentID: id,
                kind: "subagent.complete",
                text: summary ?? "Delegated agent finished",
                toolName: nil,
                handoffTarget: nil
            ))
        }
        if agentActivities.count > 250 {
            agentActivities.removeFirst(agentActivities.count - 250)
        }
        DebugLog.write("model: completed synthesized subagent \(toolCallID)")
    }

    private func recordAgentActivity(_ type: String, params: [String: Any], payload: [String: Any]) {
        let agentID = payload["subagent_id"] as? String
        let toolName = (payload["tool_name"] as? String)
            ?? (payload["tool"] as? String)
            ?? (payload["name"] as? String)
        let text = Self.agentActivityText(type: type, payload: payload, toolName: toolName)
        agentActivities.append(AgentActivity(
            id: UUID(),
            timestamp: dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date(),
            agentID: agentID,
            kind: type,
            text: text,
            toolName: toolName,
            handoffTarget: payload["handoff_target"] as? String,
            diffPreview: Self.diffPreview(from: payload),
            parentAgentID: (payload["parent_id"] as? String) ?? (payload["parent_subagent_id"] as? String),
            childSessionID: payload["child_session_id"] as? String
        ))
        if agentActivities.count > 250 { agentActivities.removeFirst(agentActivities.count - 250) }
    }

    static func agentActivityText(type: String, payload: [String: Any], toolName: String?) -> String {
        for key in ["tool_preview", "text", "summary", "message", "description", "question"] {
            if let text = payload[key] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        for key in ["result", "output", "arguments", "input", "args"] {
            let text = eventText(payload[key])
            if !text.isEmpty { return toolName.map { "\($0): \(text)" } ?? text }
        }
        if let toolName, !toolName.isEmpty { return toolName }
        return type.replacingOccurrences(of: "subagent.", with: "").uppercased()
    }

    private func recordTelemetryActivityIfChanged(row: [String: Any], agent: HermesSubagent) {
        let previousAgent = sessionAgents.first(where: { $0.id == agent.id })
            ?? activeSubagents.first(where: { $0.id == agent.id })
        guard let projection = Self.telemetryActivityProjection(
            row: row,
            agent: agent,
            previous: previousAgent
        ) else {
            return
        }
        recordAgentActivity(projection.kind, params: [:], payload: projection.payload)
    }

    /// `delegation.status` exposes the latest child action as `last_tool`, not
    /// the `tool_preview` field used by streamed subagent events. Normalize the
    /// snapshot into the same agent-owned activity envelope. An increasing
    /// tool count is significant even when the child invokes the same tool
    /// repeatedly.
    static func telemetryActivityProjection(
        row: [String: Any],
        agent: HermesSubagent,
        previous: HermesSubagent?
    ) -> AgentActivityEnvelopeProjection? {
        let toolName = (row["tool_name"] as? String) ?? (row["last_tool"] as? String)
        let preview = (row["tool_preview"] as? String)
            ?? (row["text"] as? String)
            ?? toolName
        guard let preview,
              !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let toolCountAdvanced = agent.toolCount > (previous?.toolCount ?? 0)
        guard previous?.latestActivity != preview || toolCountAdvanced else { return nil }

        var payload = row
        payload["subagent_id"] = agent.id
        payload["text"] = preview
        if let toolName, !toolName.isEmpty {
            payload["tool_name"] = toolName
        }
        return AgentActivityEnvelopeProjection(
            kind: toolName?.isEmpty == false ? "subagent.tool" : "subagent.progress",
            payload: payload,
            consumesParentEvent: false
        )
    }

    private func dateValue(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    func refreshRuntimeConfiguration() {
        guard !isLoadingRuntimeConfiguration else { return }
        isLoadingRuntimeConfiguration = true
        runtimeConfigurationError = nil
        let previousProjectionState = runtimeConfigurationProjectionState
        runtimeConfigurationProjectionState = .loading
        Task.detached { [weak self] in
            // Resolve the compact status-item label independently. Full
            // runtime inspection invokes several CLI commands and should not
            // leave the menu bar on its generic fallback while those finish.
            let configurationTask = Task.detached { HermesRuntimeInspector.read() }
            let agentName = HermesRuntimeInspector.readAgentName()
            if let agentName {
                await MainActor.run {
                    self?.runtimeConfiguration = HermesRuntimeConfiguration(
                        agentName: agentName,
                        model: nil,
                        provider: nil,
                        configPath: nil,
                        maxTurns: nil,
                        terminalTimeout: nil,
                        skills: [],
                        skillsInventory: .unavailable(.emptyOutput),
                        mcpServers: [],
                        plugins: []
                    )
                }
            }
            let configuration = await configurationTask.value
            await MainActor.run {
                guard let self else { return }
                if Self.hasRuntimeConfigurationData(configuration) {
                    self.runtimeConfiguration = configuration
                    self.runtimeConfigurationProjectionState = .ready(configuration)
                } else {
                    self.runtimeConfigurationProjectionState = Self.failedOrStale(previousProjectionState, safeMessage: "Hermes runtime inspection is unavailable. Try refreshing.")
                }
                self.isLoadingRuntimeConfiguration = false
            }
        }
    }

    private static func hasRuntimeConfigurationData(_ configuration: HermesRuntimeConfiguration) -> Bool {
        configuration.agentName != nil || configuration.model != nil || configuration.provider != nil || configuration.configPath != nil || configuration.maxTurns != nil || configuration.terminalTimeout != nil || !configuration.skills.isEmpty || !configuration.mcpServers.isEmpty || !configuration.plugins.isEmpty
    }

    enum RuntimeModelOptionsParseError: Error {
        case malformedResponse
    }

    private func invalidateRuntimeModelOptionsRefresh() {
        runtimeModelOptionsRefreshGeneration &+= 1
        isLoadingRuntimeModelOptions = false
        runtimeModelOptionsError = nil
    }

    func refreshRuntimeModelOptions(sessionID: String? = nil) {
        runtimeModelOptionsRefreshGeneration += 1
        let generation = runtimeModelOptionsRefreshGeneration
        isLoadingRuntimeModelOptions = true
        runtimeModelOptionsError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let params = Self.runtimeModelOptionsRequest(sessionID: sessionID)
                let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.modelOptions.rawValue, params: params)
                guard generation == runtimeModelOptionsRefreshGeneration,
                      sessionID == nil || sessionID == self.sessionID else {
                    return
                }
                runtimeModelOptions = try Self.runtimeModelOptions(from: result)
                if let sessionID, sessionID == self.sessionID,
                   let provider = result["provider"] as? String,
                   let model = result["model"] as? String {
                    sessionModelOptionID = HermesModelOption(provider: provider, model: model).id
                    sessionModelValue = HermesModelOption(provider: provider, model: model).displayName
                } else if let sessionID, sessionID == self.sessionID,
                          let model = result["model"] as? String {
                    sessionModelValue = model
                }
            } catch {
                guard generation == runtimeModelOptionsRefreshGeneration,
                      sessionID == nil || sessionID == self.sessionID else {
                    return
                }
                runtimeModelOptionsError = "Hermes could not load its model catalog."
            }
            guard generation == runtimeModelOptionsRefreshGeneration,
                  sessionID == nil || sessionID == self.sessionID else {
                return
            }
            isLoadingRuntimeModelOptions = false
        }
    }

    nonisolated static func runtimeModelOptionsRequest(sessionID: String?) -> [String: Any] {
        var params: [String: Any] = ["explicit_only": true]
        if let sessionID, !sessionID.isEmpty { params["session_id"] = sessionID }
        return params
    }

    nonisolated static func runtimeModelOptions(from result: [String: Any]) throws -> [HermesModelOption] {
        guard let providers = result["providers"] as? [[String: Any]] else {
            throw RuntimeModelOptionsParseError.malformedResponse
        }
        return try providers.flatMap { provider -> [HermesModelOption] in
            guard let name = (provider["slug"] as? String) ?? (provider["name"] as? String),
                  !name.isEmpty,
                  let models = provider["models"] as? [String],
                  models.allSatisfy({ !$0.isEmpty }) else {
                throw RuntimeModelOptionsParseError.malformedResponse
            }
            return models.map { HermesModelOption(provider: name, model: $0) }
        }
    }

    func refreshSessionModelOptions() {
        guard let sessionID, !sessionID.isEmpty else { return }
        refreshRuntimeModelOptions(sessionID: sessionID)
    }

    func refreshSessionReasoningVariant() {
        guard let sessionID, !sessionID.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await gateway.request(HermesFeatureIDs.ID.configGet.rawValue, params: [
                    "key": "reasoning",
                    "session_id": sessionID
                ])
                guard self.sessionID == sessionID,
                      let value = result["value"] as? String else { return }
                self.sessionReasoningVariant = HermesReasoningVariant(rawValue: value.lowercased())
            } catch {
                DebugLog.write("model: session reasoning lookup failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    /// New conversations inherit Hermes' global thinking default until they
    /// receive a session-specific override.
    func refreshDefaultReasoningVariant() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await gateway.request(HermesFeatureIDs.ID.configGet.rawValue, params: ["key": "reasoning"])
                guard let value = result["value"] as? String else { return }
                defaultReasoningVariant = HermesReasoningVariant(rawValue: value.lowercased())
            } catch {
                DebugLog.write("model: default reasoning lookup failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func updateRuntimeModel(_ option: HermesModelOption) {
        guard !isLoadingRuntimeConfiguration else { return }
        isLoadingRuntimeConfiguration = true
        runtimeConfigurationError = nil

        Task { [weak self] in
            guard let self else { return }
            var updateError: String?
            do {
                // Hermes only persists `--global` through a live session. A
                // throwaway draft writes no DB row, so nothing reaches the sidebar.
                var createParams: [String: Any] = ["source": "dock-settings"]
                if let profileID = profileScopeID, !profileID.isEmpty {
                    createParams["profile"] = profileID
                }
                let created = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionCreate.rawValue, params: createParams)
                guard let draftID = created["session_id"] as? String, !draftID.isEmpty else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let request = Self.globalRuntimeModelSwitchRequest(option: option, sessionID: draftID)
                do {
                    _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.configSet.rawValue, params: request.parameters)
                } catch {
                    _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.sessionClose.rawValue, params: ["session_id": draftID])
                    throw error
                }
                _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.sessionClose.rawValue, params: ["session_id": draftID])
            } catch {
                updateError = "Hermes could not apply the provider/model change: \(Self.safeUserDiagnostic(error.localizedDescription))"
            }

            // The gateway is the sole writer. Re-read the persisted projection
            // afterward so settings reflect only what Hermes actually accepted.
            let configuration = await Task.detached {
                HermesRuntimeInspector.read()
            }.value
            runtimeConfiguration = configuration
            runtimeConfigurationError = updateError
            isLoadingRuntimeConfiguration = false
        }
    }

    func updateSessionModel(_ option: HermesModelOption) {
        guard let sessionID, !sessionID.isEmpty else {
            // No session yet: hold the pick until createAuthorizedSession.
            sessionModelOptionID = option.id
            sessionModelValue = option.displayName
            return
        }
        guard !isUpdatingSessionModel else { return }
        isUpdatingSessionModel = true
        runtimeConfigurationError = nil
        let request = Self.sessionRuntimeModelSwitchRequest(option: option, sessionID: sessionID)
        
        // Update UI optimistically so user sees selection immediately
        let previousModelOptionID = sessionModelOptionID
        let previousModelValue = sessionModelValue
        let previousModelName = currentModelName
        sessionModelOptionID = option.id
        sessionModelValue = option.displayName
        currentModelName = option.model

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await gateway.request(HermesFeatureIDs.ID.configSet.rawValue, params: request.parameters)
                if result["deferred"] as? Bool == true {
                    DebugLog.write("model: session provider/model switch queued for the next turn")
                }
            } catch {
                // Revert to previous values on failure
                sessionModelOptionID = previousModelOptionID
                sessionModelValue = previousModelValue
                currentModelName = previousModelName
                runtimeConfigurationError = "Hermes could not apply the session provider/model change: \(Self.safeUserDiagnostic(error.localizedDescription))"
            }
            isUpdatingSessionModel = false
        }
    }

    func updateSessionReasoning(_ variant: HermesReasoningVariant) {
        guard let sessionID, !sessionID.isEmpty, !isUpdatingSessionReasoning else { return }
        isUpdatingSessionReasoning = true
        runtimeConfigurationError = nil

        Task { [weak self] in
            guard let self else { return }
            defer { self.isUpdatingSessionReasoning = false }
            do {
                _ = try await gateway.request(HermesFeatureIDs.ID.configSet.rawValue, params: [
                    "key": "reasoning",
                    "value": variant.rawValue,
                    "session_id": sessionID
                ])
                guard self.sessionID == sessionID else { return }
                self.sessionReasoningVariant = variant
                DebugLog.write("model: session reasoning set to \(variant.rawValue)")
            } catch {
                self.runtimeConfigurationError = "Hermes could not apply the session reasoning change: \(Self.safeUserDiagnostic(error.localizedDescription))"
            }
        }
    }

    /// Updates the global default only; active sessions retain their own
    /// configuration unless the user changes it from an established chat.
    func updateDefaultReasoning(_ variant: HermesReasoningVariant) {
        guard !isUpdatingDefaultReasoning else { return }
        isUpdatingDefaultReasoning = true
        runtimeConfigurationError = nil

        Task { [weak self] in
            guard let self else { return }
            defer { self.isUpdatingDefaultReasoning = false }
            do {
                _ = try await gateway.request(HermesFeatureIDs.ID.configSet.rawValue, params: [
                    "key": "reasoning",
                    "value": variant.rawValue
                ])
                self.defaultReasoningVariant = variant
                DebugLog.write("model: default reasoning set to \(variant.rawValue)")
            } catch {
                self.runtimeConfigurationError = "Hermes could not apply the default thinking depth: \(Self.safeUserDiagnostic(error.localizedDescription))"
            }
        }
    }

    nonisolated static func globalRuntimeModelSwitchRequest(
        option: HermesModelOption,
        sessionID: String
    ) -> HermesRuntimeModelSwitchRequest {
        HermesRuntimeModelSwitchRequest(
            sessionID: sessionID,
            value: "\(option.model) --provider \(option.provider) --global"
        )
    }

    nonisolated static func sessionRuntimeModelSwitchRequest(
        option: HermesModelOption,
        sessionID: String
    ) -> HermesRuntimeModelSwitchRequest {
        HermesRuntimeModelSwitchRequest(
            sessionID: sessionID,
            value: "\(option.model) --provider \(option.provider) --session"
        )
    }

    private func recordEvent(_ type: String, params: [String: Any]) {
        // Tool results can embed very large payloads; serializing the whole
        // params dict on the main thread caused lag spikes during tool storms.
        // Bound the input before serializing.
        let detail: String
        if let data = try? JSONSerialization.data(withJSONObject: Self.boundedEventPayload(params), options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            detail = String(json.prefix(500))
        } else {
            detail = String(String(describing: params).prefix(500))
        }
        // The gateway already logs one line per received event; a duplicate
        // here doubled the per-event logging cost during tool storms.
        recentEvents.append(AgentEvent(
            id: UUID(),
            type: type,
            detail: detail,
            timestamp: dateValue(params["timestamp"]) ?? Date()
        ))
        if recentEvents.count > 40 {
            recentEvents.removeFirst(recentEvents.count - 40)
        }
    }

    private static func boundedEventPayload(_ params: [String: Any], depth: Int = 0) -> [String: Any] {
        var bounded: [String: Any] = [:]
        for (key, value) in params {
            bounded[key] = boundedEventValue(value, depth: depth)
        }
        return bounded
    }

    private static func boundedEventValue(_ value: Any, depth: Int) -> Any {
        if let string = value as? String {
            return string.count > 240 ? String(string.prefix(240)) + "…" : string
        }
        if let array = value as? [Any] {
            guard depth < 3 else { return "\(array.count) items" }
            return array.prefix(8).map { boundedEventValue($0, depth: depth + 1) }
        }
        if let dict = value as? [String: Any] {
            guard depth < 3 else { return "\(dict.count) keys" }
            return boundedEventPayload(dict, depth: depth + 1)
        }
        return value
    }

    private static let visionUnsupportedNotice = "This model can't read images. Use a vision-capable model in Hermes to analyze images."
    private static func isVisionUnsupportedError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("does not support image")
    }

    /// Reconcile delayed index snapshots with newer activity observed directly
    /// from the gateway. The index remains authoritative for session metadata,
    /// while a live event remains authoritative for recency until the index
    /// catches up.
    private static func mergingSessionIndex(_ loaded: [HermesSession], with existing: [HermesSession], keeping openSessionID: String? = nil) -> [HermesSession] {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A just-created chat can be missing from an index read that raced
        // its creation; keep the open row until Hermes lists it.
        let pending = openSessionID.flatMap { id in
            loaded.contains { $0.id == id } ? nil : existingByID[id]
        }
        return (pending.map { [$0] } ?? []) + loaded.map { session in
            guard let observed = existingByID[session.id] else { return session }
            let updatedAt: Date?
            if let observedDate = observed.lastUpdatedAt, observedDate > (session.lastUpdatedAt ?? .distantPast) {
                updatedAt = observedDate
            } else {
                updatedAt = session.updatedAt
            }
            return HermesSession(
                id: session.id,
                profileID: session.profileID,
                title: session.title,
                preview: session.preview,
                startedAt: session.startedAt,
                updatedAt: updatedAt,
                messageCount: session.messageCount,
                source: session.source,
                isHidden: session.isHidden,
                isWorking: observed.isWorking,
                hasUnreadUpdate: observed.hasUnreadUpdate
            )
        }
    }

    private static func parseSession(_ row: [String: Any], profileID: String? = nil) -> HermesSession? {
        guard let id = row["id"] as? String else { return nil }
        let timestamp = (row["started_at"] as? NSNumber)?.doubleValue ?? (row["started_at"] as? Double)
        // Hermes persists canonical recency as `last_activity_at`. Older
        // gateway versions may instead expose one of the legacy aliases.
        let updatedAt = dateValue(row["last_activity_at"])
            ?? dateValue(row["updated_at"])
            ?? dateValue(row["last_active"])
            ?? dateValue(row["last_message_at"])
            ?? timestamp.map { Date(timeIntervalSince1970: $0) }
        return HermesSession(
            id: id,
            profileID: profileID,
            title: row["title"] as? String ?? "",
            preview: row["preview"] as? String ?? "",
            startedAt: timestamp.map { Date(timeIntervalSince1970: $0) },
            updatedAt: updatedAt,
            messageCount: (row["message_count"] as? NSNumber)?.intValue ?? 0,
            source: row["source"] as? String ?? "",
            isHidden: row["hidden"] as? Bool ?? false
        )
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let value, !(value is Bool), let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private func rehydrateSubagents(from value: Any?) {
        guard let rows = value as? [[String: Any]] else { return }
        var delegationCalls: [(id: String, args: [String: Any])] = []
        var resultsByID: [String: String] = [:]
        for row in rows {
            scanForDelegation(in: row["content"], calls: &delegationCalls, results: &resultsByID)
            scanForDelegation(in: row["tool_calls"], calls: &delegationCalls, results: &resultsByID)
            scanForDelegation(in: row["parts"], calls: &delegationCalls, results: &resultsByID)
            if (row["role"] as? String) == "tool",
               let id = (row["tool_call_id"] as? String) ?? (row["tool_use_id"] as? String) {
                resultsByID[id] = (row["content"] as? String) ?? Self.messageText(row["content"])
            }
        }
        for (id, args) in delegationCalls {
            if !synthesizedSubagentIDs.contains(id) {
                synthesizeSubagent(toolCallID: id, args: args)
            }
            let matchingIDs = synthesizedSubagentIDs.filter { $0 == id || $0.hasPrefix("\(id):") }
            let needsCompletion = matchingIDs.contains { matchingID in
                activeSubagents.first(where: { $0.id == matchingID }).map {
                    !Self.isTerminalAgentStatus($0.status)
                } ?? false
            }
            if needsCompletion, let result = resultsByID[id] {
                completeSynthesizedSubagent(toolCallID: id, result: result, payload: [:])
            }
        }
    }

    private func scanForDelegation(in value: Any?, calls: inout [(id: String, args: [String: Any])], results: inout [String: String]) {
        guard let parts = value as? [[String: Any]] else { return }
        for part in parts {
            let partType = (part["type"] as? String)?.lowercased() ?? ""
            if partType.contains("tool_use") || partType == "function_call" || partType == "tool_call" {
                let name = (part["name"] as? String)
                    ?? ((part["function"] as? [String: Any])?["name"] as? String)
                    ?? ""
                if Self.isDelegationTool(name) {
                    let id = (part["id"] as? String) ?? (part["tool_use_id"] as? String) ?? UUID().uuidString
                    let input = (part["input"] as? [String: Any])
                        ?? Self.parseArgsDict((part["function"] as? [String: Any])?["arguments"])
                        ?? Self.parseArgsDict(part["arguments"])
                        ?? [:]
                    calls.append((id, input))
                }
            }
            if partType.contains("tool_result") {
                if let id = (part["tool_use_id"] as? String) ?? (part["id"] as? String) {
                    let content = (part["content"] as? String) ?? Self.messageText(part["content"])
                    results[id] = content
                }
            }
        }
    }

    private static func parseArgsDict(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        if let str = value as? String,
           let data = str.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    /// Reads deferred transcript image files off the main actor and attaches
    /// the decoded images to their messages. Returns the task so tests can
    /// await completion. A stale generation or a session mismatch drops the
    /// payload exactly like a stale resume response.
    @discardableResult
    func rehydratePendingTranscriptImages(
        _ pending: [RestoredTranscript.PendingImages],
        requestedSessionID: String,
        loadData: (@Sendable (URL) -> Data?)? = nil
    ) -> Task<Void, Never> {
        guard !pending.isEmpty else { return Task<Void, Never> {} }
        let generation = sessionResumeGeneration
        return Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) { () -> [(UUID, [Data])] in
                pending.map { entry in
                    (entry.messageID, entry.fileURLs.compactMap { url in
                        loadData.map { loader in loader(url) } ?? (try? Data(contentsOf: url))
                    })
                }
            }.value
            guard generation == sessionResumeGeneration, sessionID == requestedSessionID else { return }
            for entry in loaded where !entry.1.isEmpty {
                let images = entry.1.compactMap { NSImage(data: $0) }
                guard !images.isEmpty,
                      let index = messages.firstIndex(where: { $0.id == entry.0 }) else { continue }
                messages[index] = messages[index].attachingImages(images)
            }
        }
    }

    static func parseMessages(_ value: Any?, defaultBotProfileID: String? = nil, defaultBotDisplayName: String? = nil) -> RestoredTranscript {
        guard let rows = value as? [[String: Any]] else {
            return RestoredTranscript(messages: [], pendingImages: [])
        }
        var messages: [ChatMessage] = []
        var pendingImages: [RestoredTranscript.PendingImages] = []
        var rowIDs: [Int: UUID] = [:]
        // Tool calls since the last visible assistant reply; they attach to
        // the next one so restored turns show the same activity as live ones.
        var pendingActivity: [ActiveToolCall] = []
        var turnStartedAt: Date?
        for row in rows {
            guard let role = row["role"] as? String else { continue }
            let rowTimestamp = (row["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let reasoning = ((row["reasoning"] ?? row["reasoning_content"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
                pendingActivity.append(ActiveToolCall(
                    id: "thinking:\(UUID().uuidString)", name: ActiveToolCall.thinkingName, input: "", context: "",
                    startedAt: rowTimestamp ?? Date(), result: reasoning, isComplete: true
                ))
            }
            pendingActivity.append(contentsOf: historyToolCalls(in: row, timestamp: rowTimestamp ?? Date()))
            // session.resume projects each tool call as its own compact
            // `{role: tool, name, context}` row.
            if role == "tool" {
                let id = (row["tool_call_id"] as? String) ?? (row["tool_use_id"] as? String) ?? UUID().uuidString
                let result = messageText(row["content"])
                if let index = pendingActivity.firstIndex(where: { $0.id == id }) {
                    if !result.isEmpty { pendingActivity[index].result = truncatedForPersistence(result) }
                } else if let name = row["name"] as? String, !name.isEmpty {
                    pendingActivity.append(ActiveToolCall(
                        id: id, name: name, input: "", context: row["context"] as? String ?? "",
                        startedAt: rowTimestamp ?? Date(), result: result.isEmpty ? nil : truncatedForPersistence(result),
                        isComplete: true
                    ))
                }
                continue
            }
            let persisted = persistedImageContent(from: messageText(row["text"] ?? row["content"]))
            let text = persisted.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !persisted.imageFileURLs.isEmpty else { continue }
            let timestamp = rowTimestamp ?? Date()
            guard role == "user" || role == "assistant" || role == "hermes" else { continue }
            let attribution = role == "user" ? nil : botAttribution(from: text)
            var activity: [ActiveToolCall] = []
            if role == "user" {
                pendingActivity = []
                turnStartedAt = rowTimestamp
            } else {
                activity = pendingActivity
                pendingActivity = []
            }
            let message = ChatMessage(
                role: role == "user" ? .user : .hermes,
                text: attribution?.body ?? text,
                images: [],
                timestamp: timestamp,
                responseDuration: activity.isEmpty ? nil : turnStartedAt.flatMap { start in rowTimestamp.map { $0.timeIntervalSince(start) } },
                botProfileID: attribution?.profileID ?? defaultBotProfileID,
                botDisplayName: attribution?.displayName ?? defaultBotDisplayName,
                activity: activity
            )
            messages.append(message)
            if let rowID = TranscriptHistoryPaging.rowID(row, key: "row_id") {
                rowIDs[rowID] = message.id
            }
            if !persisted.imageFileURLs.isEmpty {
                pendingImages.append(RestoredTranscript.PendingImages(
                    messageID: message.id,
                    fileURLs: persisted.imageFileURLs
                ))
            }
        }
        return RestoredTranscript(messages: messages, pendingImages: pendingImages, rowIDs: rowIDs)
    }

    /// Tool calls an assistant history row requested, in either the OpenAI
    /// `tool_calls` shape or Anthropic-style `tool_use` content parts.
    private static func historyToolCalls(in row: [String: Any], timestamp: Date) -> [ActiveToolCall] {
        let parts = ((row["tool_calls"] as? [[String: Any]]) ?? [])
            + ((row["content"] as? [[String: Any]]) ?? []).filter {
                (($0["type"] as? String)?.lowercased() ?? "").contains("tool_use")
            }
        return parts.compactMap { part in
            let function = part["function"] as? [String: Any]
            guard let name = (part["name"] as? String) ?? (function?["name"] as? String), !name.isEmpty else { return nil }
            let args = (part["input"] as? [String: Any]) ?? parseArgsDict(function?["arguments"]) ?? [:]
            let context = ["command", "path", "file_path", "pattern", "query", "url", "goal"]
                .lazy.compactMap { args[$0] as? String }.first ?? ""
            return ActiveToolCall(
                id: (part["id"] as? String) ?? UUID().uuidString,
                name: name,
                input: "",
                context: context,
                startedAt: timestamp,
                isComplete: true
            )
        }
    }

    /// Hermes persists uploaded images as directive lines in the session
    /// transcript. Rehydrate those files for the native transcript instead of
    /// exposing the storage path as user-visible message text. Only file
    /// references are collected here; decoding happens off the main actor in
    /// `rehydratePendingTranscriptImages`.
    static func persistedImageContent(from rawText: String) -> (text: String, imageFileURLs: [URL]) {
        let lines = rawText.components(separatedBy: .newlines)
        var imageFileURLs: [URL] = []
        var removedImageReference = false
        var remainingLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("@image:") else {
                remainingLines.append(line)
                continue
            }

            removedImageReference = true
            var path = String(trimmed.dropFirst("@image:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if path.count >= 2, path.first == "`", path.last == "`" {
                path.removeFirst()
                path.removeLast()
            }
            imageFileURLs.append(URL(fileURLWithPath: path))
        }

        if removedImageReference {
            remainingLines.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[screenshot]" }
        }
        // This boundary feeds every restored transcript message, not only
        // messages with image directives. Preserve real line breaks so the
        // Markdown renderer receives the exact persisted body rather than
        // literal `\\n` source characters.
        return (remainingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), imageFileURLs)
    }

    /// Hermes Bot Mode's documented delivery envelope is:
    /// `Message from 🤖 <sender> (@<profile>): <body>`.
    /// Parse only that exact shape; ordinary assistant prose is untouched.
    static func botAttribution(from text: String) -> (displayName: String, profileID: String, body: String)? {
        let prefix = "Message from 🤖 "
        guard text.hasPrefix(prefix),
              let handleStart = text.firstIndex(of: "("),
              handleStart < text.index(before: text.endIndex) else { return nil }
        let handleMarker = text.index(after: handleStart)
        guard text[handleMarker...].hasPrefix("@"),
              let handleEnd = text[handleStart...].firstIndex(of: ")"),
              handleEnd < text.index(before: text.endIndex) else { return nil }
        let colonIndex = text.index(after: handleEnd)
        guard text[colonIndex...].hasPrefix(":"),
              colonIndex < text.index(before: text.endIndex) else { return nil }
        let nameStart = text.index(text.startIndex, offsetBy: prefix.count)
        let displayName = String(text[nameStart..<handleStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        let profileID = String(text[text.index(handleMarker, offsetBy: 1)..<handleEnd])
        let body = String(text[text.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !profileID.isEmpty, !body.isEmpty else { return nil }
        return (displayName, profileID, body)
    }

    private static func messageText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }.joined()
        }
        return ""
    }

}
