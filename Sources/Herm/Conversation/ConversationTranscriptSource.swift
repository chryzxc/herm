import AppKit
import Combine
import Foundation

/// A disposable projection of Hermes-owned messages. Equality never walks body
/// text or image bytes, and descriptors are built only for the mounted window.
struct ConversationTranscriptSnapshot: Equatable {
    struct Row: Equatable {
        let index: Int
        let message: ChatMessage
        static func == (lhs: Self, rhs: Self) -> Bool {
            let a = lhs.message
            let b = rhs.message
            return lhs.index == rhs.index && a.id == b.id && a.contentRevision == b.contentRevision
                && a.role == b.role && a.images.map(ObjectIdentifier.init) == b.images.map(ObjectIdentifier.init)
                && a.timestamp == b.timestamp && a.modelName == b.modelName
                && a.responseDuration == b.responseDuration && a.tokenCount == b.tokenCount
                && a.isSteering == b.isSteering && a.steeringStatus == b.steeringStatus && a.isError == b.isError
                && a.botProfileID == b.botProfileID && a.botDisplayName == b.botDisplayName
                && a.activity == b.activity && a.kanbanNotice == b.kanbanNotice && a.systemEvent == b.systemEvent
                && a.isBotHandoffReply == b.isBotHandoffReply
        }
    }

    struct Context: Equatable {
        let status: HermesStatus
        let streamingID: UUID?
        let streamingActivity: [ActiveToolCall]
        let streamingStartedAt: Date?
        let activeBotID: String?
        let sessionProfileID: String?
        let compactingID: String?
        let approval: ApprovalPresentation?
        let approvalTitle: String?
        let approvalText: String?
        let respondingToApproval: Bool
        let clarification: String?
        let choices: [String]
        let multiSelect: Bool
        let clarificationProgress: String?
        let clarificationRequestID: String?
        let respondingToClarification: Bool
        let valuePrompt: ValuePrompt?
        let valuePromptError: String?
        let respondingToValuePrompt: Bool
        let restoring: Bool
        let dispatches: [String: BotActivityRecord]
        let workingBots: [BotActivityRecord]
        let mentions: [BotActivityRecord]
        let botSteps: [String: String]
        let rosterRevision: Int
        let selectedProfileID: String?
        let pinSupport: Bool
        let pinnedIDs: Set<String>
        let pinnedRows: Set<Int>
        let storedReferences: [UUID: StoredMessageReference]
        let updatingPin: Int?
        let pendingActions: [UUID: ConversationMessageActionKind]
        let speakingID: UUID?
        let historyLoading: Bool
        let latestRequest: Int
    }

    let sessionID: String?
    let layoutGeneration: UInt64
    let messages: [ChatMessage]
    let range: Range<Int>
    let rows: [Row]
    let context: Context
    let prepend: TranscriptHistoryPrepend?
    let navigator: MessageNavigatorSnapshot
    var navigatorItems: [MessageNavigatorItem] { navigator.items }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.layoutGeneration == rhs.layoutGeneration
            && lhs.messages.count == rhs.messages.count
            && lhs.range == rhs.range && lhs.rows == rhs.rows && lhs.context == rhs.context
            && lhs.prepend == rhs.prepend && lhs.navigator === rhs.navigator
    }
}

/// Subscribe to transcript-specific publishers, never objectWillChange. A
/// run-loop coalescer reads canonical values after Published's willSet delivery.
@MainActor
final class ConversationTranscriptSource: ObservableObject {
    @Published private(set) var snapshot: ConversationTranscriptSnapshot
    private(set) var publicationCount = 0
    private let model: DockModel
    private let bots: BotModeModel
    private let actions: ConversationMessageActionState
    private let voice: VoiceOutput
    let coordinator: ConversationTranscriptCoordinator
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshScheduled = false
    private var isActive = true
    let markdownPrefetch = ConversationMarkdownPrefetch()

    init(
        model: DockModel, bots: BotModeModel, actions: ConversationMessageActionState,
        voice: VoiceOutput, coordinator: ConversationTranscriptCoordinator
    ) {
        self.model = model
        self.bots = bots
        self.actions = actions
        self.voice = voice
        self.coordinator = coordinator
        coordinator.synchronize(model: model)
        snapshot = Self.makeSnapshot(
            model: model, bots: bots, actions: actions, voice: voice, range: coordinator.mountedRange,
            generation: coordinator.generation)
        observe(model.$messages)
        observe(model.$sessionID)
        observe(model.$status)
        observe(model.$activeBotProfileID)
        observe(model.$sessionProfileID)
        observe(model.$compactingSessionID)
        observe(model.$activityPresentationRevision)
        observe(model.$botActivityRevision)
        observe(model.$botActivityBySessionID)
        observe(model.$botLiveSteps)
        observe(model.$approvalTitle)
        observe(model.$approvalText)
        observe(model.$approvalDetails)
        observe(model.$isRespondingToApproval)
        observe(model.$clarificationQuestion)
        observe(model.$clarificationChoices)
        observe(model.$clarificationMultiSelect)
        observe(model.$clarificationProgress)
        observe(model.$clarificationRequestID)
        observe(model.$isRespondingToClarification)
        observe(model.$valuePrompt)
        observe(model.$valuePromptError)
        observe(model.$isRespondingToValuePrompt)
        observe(model.$isRestoringSession)
        observe(model.$messagePinsSupported)
        observe(model.$pinnedMessages)
        observe(model.$storedMessageReferences)
        observe(model.$updatingMessagePinRowID)
        observe(model.$isLoadingTranscriptHistory)
        observe(model.$scrollToLatestMessageRequest)
        observe(bots.$inventory)
        observe(bots.$avatarImages)
        observe(bots.$selectedProfileID)
        observe(actions.$pendingActions)
        observe(voice.$speakingMessageID)
        observe(coordinator.$mountedRange)
        observe(model.transcriptPresentationChanges.prepend(()))
        prefetch()
    }

    private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher.dropFirst().sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
    }

    private func scheduleRefresh() {
        guard isActive, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard isActive else { return }
        coordinator.synchronize(model: model)
        let next = Self.makeSnapshot(
            model: model, bots: bots, actions: actions, voice: voice, range: coordinator.mountedRange,
            generation: coordinator.generation)
        guard next != snapshot else { return }
        publicationCount += 1
        snapshot = next
        prefetch()
    }

    func resume() {
        isActive = true
        refresh()
        prefetch()
    }

    func suspend() {
        isActive = false
        markdownPrefetch.cancel()
    }

    func prefetch() {
        guard isActive else { return }
        let sessionID = snapshot.sessionID
        markdownPrefetch.update(
            messages: snapshot.messages, range: snapshot.range, sessionID: snapshot.sessionID,
            streamingID: snapshot.context.streamingID
        ) { [weak model] id, revision in
            model?.sessionID == sessionID && model?.messages.first(where: { $0.id == id })?.contentRevision == revision
        }
    }

    private static func makeSnapshot(
        model: DockModel, bots: BotModeModel, actions: ConversationMessageActionState,
        voice: VoiceOutput, range: Range<Int>, generation: UInt64
    ) -> ConversationTranscriptSnapshot {
        let clamped = ConversationMessageWindow.visibleRange(range, totalCount: model.messages.count)
        let range =
            clamped.isEmpty && !model.messages.isEmpty
            ? ConversationMessageWindow.tailRange(totalCount: model.messages.count) : clamped
        let streamingID = model.streamingMessageIDForPresentation
        let streamingMounted = range.contains { model.messages[$0].id == streamingID }
        let dispatches = model.botDispatchesByToolCallID
        let workingBots = model.workingBotDispatches
        let mentions = model.pendingBotMentions
        let botRecordIDs = Set(dispatches.values.map(\.id) + workingBots.map(\.id) + mentions.map(\.id))
        let botSteps = Dictionary(uniqueKeysWithValues: botRecordIDs.compactMap { id in
            model.botLiveSteps[id].map { (id, $0) }
        })
        return ConversationTranscriptSnapshot(
            sessionID: model.sessionID, layoutGeneration: generation, messages: model.messages, range: range,
            rows: range.map { .init(index: $0, message: model.messages[$0]) },
            context: .init(
                status: model.status, streamingID: streamingID,
                // The canonical turn keeps accumulating while its row is unmounted.
                streamingActivity: streamingMounted ? model.streamingTurnActivity : [],
                streamingStartedAt: streamingMounted ? model.streamingResponseStartedAt : nil,
                activeBotID: model.activeBotProfileID, sessionProfileID: model.sessionProfileID,
                compactingID: model.compactingSessionID, approval: model.approvalDetails,
                approvalTitle: model.approvalTitle, approvalText: model.approvalText,
                respondingToApproval: model.isRespondingToApproval,
                clarification: model.clarificationQuestion, choices: model.clarificationChoices,
                multiSelect: model.clarificationMultiSelect, clarificationProgress: model.clarificationProgress,
                clarificationRequestID: model.clarificationRequestID,
                respondingToClarification: model.isRespondingToClarification,
                valuePrompt: model.valuePrompt, valuePromptError: model.valuePromptError,
                respondingToValuePrompt: model.isRespondingToValuePrompt, restoring: model.isRestoringSession,
                dispatches: dispatches, workingBots: workingBots,
                mentions: mentions, botSteps: botSteps,
                rosterRevision: bots.rosterRevision, selectedProfileID: bots.selectedProfileID,
                pinSupport: model.messagePinsSupported, pinnedIDs: model.pinnedMessageUIDs,
                pinnedRows: model.pinnedMessageRowIDs,
                storedReferences: model.storedMessageReferences, updatingPin: model.updatingMessagePinRowID,
                pendingActions: actions.pendingActions, speakingID: voice.speakingMessageID,
                historyLoading: model.isLoadingTranscriptHistory, latestRequest: model.scrollToLatestMessageRequest
            ), prepend: model.lastTranscriptPrepend, navigator: model.messageNavigatorSnapshot
        )
    }
}

extension ConversationTranscriptSource {
    func message(for target: MessageNavigatorTarget) -> ChatMessage? {
        guard target.sessionID == model.sessionID else { return nil }
        return model.messages.first { $0.id == target.messageID }
    }

    func perform(_ kind: ConversationMessageActionKind, target: MessageNavigatorTarget) {
        guard let message = message(for: target) else { return }
        switch kind {
        case .copy:
            actions.copy(message)
        case .readAloud:
            voice.toggle(messageID: message.id, text: GenerativeUIIntegration.readableText(message))
        case .reply:
            model.replyQuote = ReplyQuote(
                author: message.botDisplayName ?? bots.botsByID[message.botProfileID ?? model.activeBotProfileID ?? ""]?
                    .name ?? "Hermes",
                text: GenerativeUIIntegration.readableText(message))
        case .branch:
            actions.run(message.id, action: kind) { [weak self] in
                guard let self, let current = self.message(for: target) else { return }
                await self.model.branchConversation(from: current)
            }
        case .refresh:
            actions.run(message.id, action: kind) { [weak self] in
                guard let self, self.message(for: target) != nil else { return }
                await self.model.refreshCurrentSession()
            }
        case .pin:
            actions.run(message.id, action: kind) { [weak self] in
                guard let self, let current = self.message(for: target) else { return }
                await self.model.toggleMessagePinned(current)
            }
        }
    }
}
