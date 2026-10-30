import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The production transcript container is also mounted by native scroll fixtures.
struct ConversationTranscriptView: View, Equatable {
    let model: DockModel
    let controlCenter: ControlCenterModel
    let botMode: BotModeModel
    let messageActionState: ConversationMessageActionState
    let voiceOutput: VoiceOutput
    let conversationMetrics: ConversationWorkspaceMetrics
    let conversationHermFaceID: String?
    let trailingContentInset: CGFloat
    let latestJumpRequest: Int
    @Binding var isShowingMessageSearch: Bool
    @Binding var pinnedMessageJumpID: UUID?
    @Binding var selectedChatImage: ChatImagePreview?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @StateObject var source: ConversationTranscriptSource
    var coordinator: ConversationTranscriptCoordinator { source.coordinator }
    private let themeRevision: Int
    private let searchPresented: Bool
    private let jumpID: UUID?

    init(
        model: DockModel, controlCenter: ControlCenterModel, botMode: BotModeModel,
        messageActionState: ConversationMessageActionState, voiceOutput: VoiceOutput,
        conversationMetrics: ConversationWorkspaceMetrics, conversationHermFaceID: String?,
        isShowingMessageSearch: Binding<Bool>, pinnedMessageJumpID: Binding<UUID?>,
        selectedChatImage: Binding<ChatImagePreview?>,
        trailingContentInset: CGFloat = 0,
        latestJumpRequest: Int = 0,
        coordinator: @autoclosure @escaping () -> ConversationTranscriptCoordinator =
            ConversationTranscriptCoordinator()
    ) {
        self.model = model
        self.controlCenter = controlCenter
        self.botMode = botMode
        self.messageActionState = messageActionState
        self.voiceOutput = voiceOutput
        self.conversationMetrics = conversationMetrics
        self.conversationHermFaceID = conversationHermFaceID
        self.trailingContentInset = trailingContentInset
        self.latestJumpRequest = latestJumpRequest
        self._isShowingMessageSearch = isShowingMessageSearch
        self._pinnedMessageJumpID = pinnedMessageJumpID
        self._selectedChatImage = selectedChatImage
        themeRevision = DockThemeRuntime.revision
        searchPresented = isShowingMessageSearch.wrappedValue
        jumpID = pinnedMessageJumpID.wrappedValue
        _source = StateObject(
            wrappedValue: ConversationTranscriptSource(
                model: model, bots: botMode, actions: messageActionState, voice: voiceOutput,
                coordinator: coordinator()))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.controlCenter === rhs.controlCenter
            && lhs.botMode === rhs.botMode
            && lhs.messageActionState === rhs.messageActionState && lhs.voiceOutput === rhs.voiceOutput
            && lhs.conversationMetrics == rhs.conversationMetrics
            && lhs.conversationHermFaceID == rhs.conversationHermFaceID
            && lhs.trailingContentInset == rhs.trailingContentInset
            && lhs.latestJumpRequest == rhs.latestJumpRequest
            && lhs.searchPresented == rhs.searchPresented && lhs.jumpID == rhs.jumpID
            && lhs.themeRevision == rhs.themeRevision
    }

    var effectiveMountedRange: Range<Int> { source.snapshot.range }

    var renderedMessageBubbleCount: Int {
        ConversationUnreadMessagePolicy.renderedMessageCount(
            model.messages, streamingID: model.streamingMessageIDForPresentation)
    }

    var body: some View {
        let snapshot = source.snapshot
        let _ = coordinator.performance.recordTranscriptEvaluation()
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        VStack(spacing: 0) {
                            VStack(spacing: 0) {
                                if snapshot.messages.isEmpty && snapshot.context.status != .working {
                                    StartupAssistantView(hermFaceID: conversationHermFaceID)
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: max(300, viewport.size.height - 16))
                                } else if snapshot.messages.isEmpty {
                                    DockLoadingState(
                                        title: "Loading conversation…", minHeight: max(300, viewport.size.height - 16))
                                }
                                let range = effectiveMountedRange
                                let generation = snapshot.layoutGeneration
                                let sessionID = snapshot.sessionID
                                let dispatches = snapshot.context.dispatches
                                let defaultBot = botMode.visibleBots.first(where: \.isDefault)
                                ForEach(snapshot.rows, id: \.message.id) { descriptor in
                                    let message = descriptor.message
                                    // Activity and body are sibling views. One container must own
                                    // geometry and identity, including a zero-height hidden row.
                                    VStack(spacing: 0) {
                                        messageRow(message, dispatches: dispatches, defaultBot: defaultBot)
                                    }
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: ConversationTranscriptLayoutPreferenceKey.self,
                                                value: ConversationTranscriptLayout(
                                                    sessionID: sessionID, generation: generation, range: range,
                                                    rows: [
                                                        MessageNavigatorViewport(
                                                            target: MessageNavigatorTarget(
                                                                sessionID: sessionID ?? "", messageID: message.id),
                                                            index: descriptor.index,
                                                            minY: geometry.frame(
                                                                in: .named("conversation-document")
                                                            ).minY,
                                                            maxY: geometry.frame(
                                                                in: .named("conversation-document")
                                                            ).maxY)
                                                    ]))
                                        }
                                    }
                                    .id(message.id)
                                }
                                ConversationPromptRows(model: model, conversationMetrics: conversationMetrics)
                                botHandoffRow
                                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: workingCrewIDs)
                            }
                            .task(id: [snapshot.sessionID ?? ""] + model.workingBotDispatches.map(\.id)) {
                                guard !model.workingBotDispatches.isEmpty else { return }
                                var tick = 0
                                repeat {
                                    if tick % 3 == 0 {
                                        await model.reconcileBotDispatches()
                                        await model.reconcileKanbanAssignments { cardID in
                                            await controlCenter.sessionKanbanTaskDetail(
                                                KanbanTaskSummary(
                                                    id: cardID, title: cardID, status: "", detail: nil, priority: nil,
                                                    assignee: nil)
                                            ).map { ($0.status, $0.latestSummary ?? $0.result) }
                                        }
                                    }
                                    await model.refreshBotLiveSteps()
                                    tick += 1
                                    try? await Task.sleep(for: .seconds(5))
                                } while !Task.isCancelled && !model.workingBotDispatches.isEmpty
                            }
                            .dockPadding(.vertical, 12)
                            .frame(maxWidth: conversationMetrics.readingWidth)
                            .frame(maxWidth: .infinity)
                            .dockPadding(.trailing, trailingContentInset)
                            Color.clear.frame(height: 1).id("conversation-bottom")
                        }
                        .background {
                            ConversationScrollEventObserver(
                                controller: coordinator.controller,
                                onScroll: { coordinator.userMoved($0, delta: $1) },
                                onScrollSettled: { coordinator.settled($0) },
                                onScrollAwayFromBottom: { coordinator.presentation.isAtBottom = false },
                                onContentResize: { coordinator.contentResized() }
                            )
                        }
                        .coordinateSpace(name: "conversation-document")
                    }
                    .id(snapshot.sessionID)
                    .onPreferenceChange(ConversationTranscriptLayoutPreferenceKey.self) { layout in
                        if let layout { coordinator.receiveLayout(layout) }
                    }
                    .onChange(of: snapshot.context.latestRequest) { _, _ in
                        if coordinator.presentation.isAtBottom { coordinator.jumpToLatest() }
                    }
                    .onChange(of: latestJumpRequest) { _, _ in
                        coordinator.jumpToLatest(animated: true, reduceMotion: reduceMotion)
                    }
                    ConversationLatestMessageControl(presentation: coordinator.presentation) {
                        coordinator.jumpToLatest(animated: true, reduceMotion: reduceMotion)
                    }
                    .dockPadding(.trailing, trailingContentInset)
                    let showsMap =
                        snapshot.navigatorItems.count >= MessageNavigator.minimumMessagesToShowNavigator
                        && viewport.size.width - trailingContentInset >= 820
                    if showsMap || isShowingMessageSearch {
                        ConversationScrollNavigator(
                            presentation: coordinator.presentation, snapshot: snapshot.navigator,
                            sessionID: snapshot.sessionID ?? "", isSearchPresented: $isShowingMessageSearch,
                            showsMap: showsMap, isLoadingHistory: snapshot.context.historyLoading,
                            onSearch: {
                                guard model.hasUnloadedTranscript, !snapshot.context.historyLoading else { return }
                                Task { await model.loadTranscriptHistory(through: nil) }
                            },
                            onSelect: { jumpToMessage($0, proxy: proxy) }
                        )
                        .frame(width: 286, height: viewport.size.height)
                        .dockPadding(.leading, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .onAppear {
                    coordinator.onScrollToBottom = { [weak coordinator = coordinator] animated in
                        if animated {
                            withAnimation(.dockEase(duration: 0.22)) {
                                proxy.scrollTo("conversation-bottom", anchor: .bottom)
                            }
                        } else {
                            coordinator?.controller.scrollToBottom()
                        }
                    }
                }
                .onChange(of: pinnedMessageJumpID) { _, id in
                    guard let id, let item = snapshot.navigatorItems.first(where: { $0.messageID == id })
                    else { return }
                    jumpToMessage(item, proxy: proxy)
                    pinnedMessageJumpID = nil
                }
            }
        }
        .environment(\.conversationScrollController, coordinator.controller)
        .onAppear {
            reset()
            source.resume()
        }
        .onChange(of: themeRevision) { _, _ in source.prefetch() }
        .onDisappear {
            coordinator.invalidate()
            coordinator.onScrollToBottom = nil
            source.suspend()
        }
    }

    private func reset() {
        coordinator.reset(
            sessionID: model.sessionID, totalCount: model.messages.count,
            bubbleCount: renderedMessageBubbleCount)
        coordinator.onEarlierHistory = { [weak model] in model?.loadEarlierTranscriptIfAvailable() }
    }

    private func jumpToMessage(_ item: MessageNavigatorItem, proxy: ScrollViewProxy) {
        coordinator.select(item, model: model) { messageID in
            proxy.scrollTo(messageID, anchor: .center)
        }
    }

    var workingCrew: [BotSummary] {
        var seen = Set<String>()
        return model.workingBotDispatches.compactMap { record in
            seen.insert(record.botID).inserted ? botMode.botsByID[record.botID] : nil
        }
    }

    @ViewBuilder
    var botHandoffRow: some View {
        let fromID = model.activeBotProfileID ?? model.sessionProfileID ?? botMode.selectedProfileID
        let from =
            fromID.flatMap { botMode.botsByID[$0] } ?? botMode.visibleBots.first(where: \.isDefault)
        let partners = workingCrew.filter { $0.id != from?.id }
        let mentions = model.pendingBotMentions
        let replying = mentionedBots
        // While the turn runs the huddle is its loading row instead.
        if model.streamingMessageIDForPresentation == nil {
            VStack(alignment: .leading, spacing: 4) {
                if let lead = replying.first {
                    BotCrewRow(
                        from: lead, partners: Array(replying.dropFirst()),
                        since: mentions.map(\.createdAt).min() ?? .now,
                        avatars: botMode.avatarImages, repliesToUser: true,
                        steps: Dictionary(
                            mentions.compactMap { record in
                                source.snapshot.context.botSteps[record.id].map { (record.botID, $0) }
                            }, uniquingKeysWith: { first, _ in first })
                    )
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity),
                            removal: .opacity.combined(with: .offset(y: -6))))
                }
                if let from, !partners.isEmpty {
                    BotCrewRow(
                        from: from, partners: partners,
                        since: model.workingBotDispatches.map(\.createdAt).min() ?? .now,
                        avatars: botMode.avatarImages,
                        steps: Dictionary(
                            model.workingBotDispatches.compactMap { record in
                                source.snapshot.context.botSteps[record.id].map { (record.botID, $0) }
                            }, uniquingKeysWith: { first, _ in first })
                    )
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .dockPadding(.horizontal, conversationMetrics.contentInset + 4)
            .dockPadding(.top, replying.isEmpty && partners.isEmpty ? 0 : 8)
            .id("bot-handoff")
        }
    }

    /// Bots answering an @mention right now, one entry per Bot.
    var mentionedBots: [BotSummary] {
        var seen = Set<String>()
        return model.pendingBotMentions.compactMap { record in
            seen.insert(record.botID).inserted ? botMode.botsByID[record.botID] : nil
        }
    }

    var workingCrewIDs: [String] { mentionedBots.map { "@" + $0.id } + workingCrew.map(\.id) }

    @ViewBuilder
    func messageRow(
        _ message: ChatMessage, dispatches: [String: BotActivityRecord], defaultBot: BotSummary?
    ) -> some View {
        let target = MessageNavigatorTarget(sessionID: model.sessionID ?? "", messageID: message.id)
        let isStreaming = message.id == model.streamingMessageIDForPresentation
        let activity = isStreaming ? source.snapshot.context.streamingActivity : message.activity
        let workingBotID =
            message.botProfileID ?? model.activeBotProfileID ?? model.sessionProfileID
            ?? botMode.selectedProfileID
        // An unknown or unset profile falls back to the default Bot, as the handoff row does.
        let workingBot = workingBotID.flatMap { botMode.botsByID[$0] } ?? defaultBot
        if message.role == .hermes, isStreaming || !activity.isEmpty {
            let rowDispatches = Dictionary(
                activity.compactMap { call in
                    dispatches[call.id].map { (call.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            let rowSteps = Dictionary(
                rowDispatches.values.compactMap { record in
                    source.snapshot.context.botSteps[record.id].map { (record.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            TurnActivityView(
                activity: activity,
                runningSince: isStreaming ? (model.streamingResponseStartedAt ?? message.timestamp) : nil,
                duration: message.responseDuration,
                bot: isStreaming ? workingBot : nil,
                botAvatar: workingBot.flatMap { botMode.avatarImages[$0.id] },
                dispatches: rowDispatches,
                botLiveSteps: rowSteps,
                crew: isStreaming ? workingCrew : [],
                botsByID: botMode.botsByID,
                avatars: botMode.avatarImages,
                rosterRevision: botMode.rosterRevision,
                liveReasoning: isStreaming ? model.liveReasoning : nil
            )
            .equatable()
            .dockPadding(.horizontal, conversationMetrics.contentInset + 4)
            .dockPadding(.top, 8)
        }
        if message.role == .hermes && !message.hasBodyText && message.images.isEmpty && !isStreaming {
            EmptyView()
        } else {
            ConversationMessageRow(
                message: message,
                isStreamingMessage: message.id == model.streamingMessageIDForPresentation,
                streamingMood: message.id == model.streamingMessageIDForPresentation
                    ? BotMood(
                        status: model.status,
                        compacting: model.compactingSessionID != nil
                            && model.compactingSessionID == model.sessionID)
                    : nil,
                streamingText: model.streamingText,
                activeBotProfileID: model.activeBotProfileID,
                botsByID: botMode.botsByID,
                avatarImages: botMode.avatarImages,
                botRosterRevision: botMode.rosterRevision,
                onImagePreview: { image in
                    guard source.message(for: target) != nil else { return }
                    selectedChatImage = ChatImagePreview(image: image)
                },
                pendingAction: messageActionState.pendingAction(for: message.id),
                areSessionActionsAvailable:
                    !(model.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                isSpeaking: voiceOutput.speakingMessageID == message.id,
                metrics: conversationMetrics,
                actionTarget: target,
                onCopy: { source.perform(.copy, target: target) },
                onBranch: { source.perform(.branch, target: target) },
                onReadAloud: { source.perform(.readAloud, target: target) },
                onRefresh: { source.perform(.refresh, target: target) },
                onReply: { source.perform(.reply, target: target) },
                showsPinAction: model.messagePinsSupported
                    && model.storedMessageReferences[message.id] != nil
                    && message.systemEvent == nil && message.kanbanNotice == nil && !message.isError,
                isPinAvailable: model.canPinMessage(message),
                isPinned: model.isMessagePinned(message),
                onPin: { source.perform(.pin, target: target) },
                onOpenInTab: {
                    guard let current = source.message(for: target) else { return }
                    SessionMessageTabs.shared.open(current, in: WorkspaceIdentity.session(model))
                },
                forwardContent: { bot, dismiss in
                    guard let current = source.message(for: target) else { return AnyView(EmptyView()) }
                    return AnyView(
                        ForwardToBotPopover(
                            model: model, botMode: botMode, bot: bot, messageText: current.text, dismiss: dismiss)
                    )
                },
                loadKanbanDetail: { notice in
                    await controlCenter.sessionKanbanTaskDetail(notice.taskSummary)
                }
            )
            .equatable()
            .generativeUIMessage(model: model, message: message)
        }
    }

}
