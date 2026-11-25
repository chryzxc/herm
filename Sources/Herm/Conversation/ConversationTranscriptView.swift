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
    @Environment(\.dockHostVisible) private var hostVisible
    @StateObject var source: ConversationTranscriptSource
    /// Message a jump just landed on; shown with a brief spotlight so it is easy to find.
    @State private var spotlightMessageID: UUID?
    var coordinator: ConversationTranscriptCoordinator { source.coordinator }
    private let themeRevision: Int
    private let searchPresented: Bool
    private let jumpID: UUID?
    /// False where a welcome layer above the transcript already owns the animated orb.
    private let animatesEmptyState: Bool

    init(
        model: DockModel, controlCenter: ControlCenterModel, botMode: BotModeModel,
        messageActionState: ConversationMessageActionState, voiceOutput: VoiceOutput,
        conversationMetrics: ConversationWorkspaceMetrics, conversationHermFaceID: String?,
        isShowingMessageSearch: Binding<Bool>, pinnedMessageJumpID: Binding<UUID?>,
        selectedChatImage: Binding<ChatImagePreview?>,
        trailingContentInset: CGFloat = 0,
        latestJumpRequest: Int = 0,
        animatesEmptyState: Bool = true,
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
        self.animatesEmptyState = animatesEmptyState
        self._isShowingMessageSearch = isShowingMessageSearch
        self._pinnedMessageJumpID = pinnedMessageJumpID
        self._selectedChatImage = selectedChatImage
        themeRevision = DockThemeRuntime.revision
        searchPresented = isShowingMessageSearch.wrappedValue
        jumpID = pinnedMessageJumpID.wrappedValue
        _source = StateObject(
            wrappedValue: ConversationTranscriptSource(
                model: model, bots: botMode, actions: messageActionState, voice: voiceOutput,
                coordinator: coordinator(), needsNavigator: false))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.controlCenter === rhs.controlCenter
            && lhs.botMode === rhs.botMode
            && lhs.messageActionState === rhs.messageActionState && lhs.voiceOutput === rhs.voiceOutput
            && lhs.conversationMetrics == rhs.conversationMetrics
            && lhs.conversationHermFaceID == rhs.conversationHermFaceID
            && lhs.trailingContentInset == rhs.trailingContentInset
            && lhs.latestJumpRequest == rhs.latestJumpRequest
            && lhs.animatesEmptyState == rhs.animatesEmptyState
            && lhs.searchPresented == rhs.searchPresented && lhs.jumpID == rhs.jumpID
            && lhs.themeRevision == rhs.themeRevision
    }

    var body: some View {
        let snapshot = source.snapshot
        let hasEmptyPreview = snapshot.isPreview && model.sessionTranscriptPreview?.messages.isEmpty == true
        let _ = coordinator.performance.recordTranscriptEvaluation()
        let _ = HermPerformanceRecorder.countBody("ConversationTranscriptView")
        GeometryReader { viewport in
            let mapFits = viewport.size.width - trailingContentInset >= 820
            let showsMap = mapFits && snapshot.navigatorCount >= MessageNavigator.minimumMessagesToShowNavigator
            let needsTimeline = hostVisible && mapFits && snapshot.hasEarlierHistory
            let needsNavigator = hostVisible && (showsMap || isShowingMessageSearch)
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    // Each scroll frame otherwise re-hit-tests every mounted
                    // row's hover, tooltip and action-button region.
                    // Use AppKit's gesture boundaries without observing SwiftUI scroll state.
                    HoverPausingScrollView(usesAppKitScrollPhase: true) {
                        VStack(spacing: 0) {
                            VStack(spacing: 0) {
                                if snapshot.messages.isEmpty && snapshot.context.conversationApproval == nil
                                    && (hasEmptyPreview
                                        || (model.sessionTranscriptLoadState != .loading
                                            && model.sessionTranscriptLoadState != .refreshing
                                            && snapshot.context.status != .working))
                                {
                                    StartupAssistantView(
                                        hermFaceID: conversationHermFaceID, isActive: hostVisible && animatesEmptyState
                                    )
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: max(300, viewport.size.height - 16))
                                } else if snapshot.messages.isEmpty && snapshot.context.conversationApproval == nil {
                                    ConversationLoadingState(
                                        minHeight: max(300, viewport.size.height - 16))
                                }
                                let defaultBot = botMode.visibleBots.first(where: \.isDefault)
                                ForEach(snapshot.rows, id: \.message.id) { descriptor in
                                    let message = descriptor.message
                                    // The activity and reply share one measured row, including when hidden.
                                    VStack(spacing: 0) {
                                        if message.id == snapshot.unreadDividerMessageID {
                                            unreadDivider
                                        }
                                        messageRow(
                                            message, index: descriptor.index, snapshot: snapshot,
                                            defaultBot: defaultBot)
                                    }
                                    .opacity(spotlightMessageID == nil || spotlightMessageID == message.id ? 1 : 0.3)
                                    .conversationRowBounds(
                                        target: .init(sessionID: snapshot.sessionID ?? "", messageID: message.id),
                                        index: descriptor.index
                                    )
                                    .id(message.id)
                                }
                                if model.sessionActionsReady || snapshot.context.conversationApproval != nil {
                                    ConversationPromptRows(
                                        model: model, conversationMetrics: conversationMetrics,
                                        conversationApproval: snapshot.context.conversationApproval,
                                        approvalAnswer: snapshot.context.approvalAnswer, transcriptMode: true)
                                }
                                if model.sessionActionsReady {
                                    botHandoffRow(context: snapshot.context)
                                        .animation(
                                            reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8),
                                            value: workingCrewIDs)
                                }
                            }
                            .task(
                                id: [
                                    snapshot.sessionID ?? "", snapshot.context.actionsReady ? "ready" : "loading",
                                    hostVisible ? "visible" : "hidden",
                                ]
                                    + snapshot.context.workingBots.map(\.id)
                            ) {
                                guard hostVisible, snapshot.context.actionsReady, !snapshot.context.workingBots.isEmpty
                                else { return }
                                var tick = 0
                                repeat {
                                    if tick % 3 == 0 {
                                        await model.reconcileBotDispatches()
                                        await model.reconcileKanbanAssignments { cardID in
                                            await controlCenter.sessionKanbanTaskDetail(
                                                KanbanTaskSummary(
                                                    id: cardID, title: cardID, status: "", detail: nil, priority: nil,
                                                    assignee: nil),
                                                sessionIDs: Set(model.botActivitySessionIDs.compactMap { $0 })
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
                            .padding(.trailing, trailingContentInset)
                            Color.clear.frame(height: 1).id("conversation-bottom")
                        }
                        .conversationRowGeometry { rows in
                            Color.clear.preference(
                                key: ConversationTranscriptLayoutPreferenceKey.self,
                                value: rows.isEmpty
                                    ? nil
                                    : ConversationTranscriptLayout(
                                        sessionID: snapshot.layoutSessionID, generation: snapshot.layoutGeneration,
                                        range: snapshot.range, rows: rows))
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
                    }
                    .id(snapshot.layoutSessionID)
                    .onPreferenceChange(ConversationTranscriptLayoutPreferenceKey.self) { layout in
                        if let layout { coordinator.receiveLayout(layout) }
                    }
                    .onChange(of: snapshot.context.latestRequest) { _, _ in
                        if coordinator.presentation.isAtBottom { coordinator.jumpToLatest() }
                    }
                    .onChange(of: latestJumpRequest) { _, _ in
                        coordinator.jumpToLatest(animated: true, reduceMotion: reduceMotion)
                    }
                    ConversationLatestMessageControl(
                        presentation: coordinator.presentation,
                        isWorking: !snapshot.isPreview && snapshot.context.status == .working
                    ) {
                        coordinator.jumpToLatest(animated: true, reduceMotion: reduceMotion)
                    }
                    .padding(.trailing, trailingContentInset)
                    if needsNavigator {
                        ConversationScrollNavigator(
                            presentation: coordinator.presentation, snapshot: snapshot.navigator,
                            sessionID: snapshot.sessionID ?? "", isSearchPresented: $isShowingMessageSearch,
                            showsMap: showsMap, isLoadingHistory: snapshot.context.historyLoading,
                            searchHistory: { try await model.searchTranscript($0) },
                            onSelect: { jumpToMessage($0, proxy: proxy) }
                        )
                        .frame(width: 286, height: viewport.size.height)
                        .dockPadding(.leading, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .onAppear {
                    coordinator.onScrollToBottom = { [weak coordinator = coordinator] animated in
                        if animated, coordinator?.controller.clipView?.window?.isVisible == true {
                            withAnimation(.dockEase(duration: 0.22)) {
                                proxy.scrollTo("conversation-bottom", anchor: .bottom)
                            }
                        } else {
                            coordinator?.controller.scrollToBottom()
                        }
                    }
                }
                .onChange(of: pinnedMessageJumpID) { _, id in
                    guard let id, !snapshot.isPreview,
                        let sessionID = model.sessionID,
                        let index = model.messages.firstIndex(where: { $0.id == id })
                    else { return }
                    let item = MessageNavigator.item(
                        for: model.messages[index], ordinal: index + 1, sessionID: sessionID)
                    jumpToMessage(item, proxy: proxy)
                    pinnedMessageJumpID = nil
                }
                .onChange(of: needsNavigator, initial: true) { _, demanded in source.setNavigatorDemand(demanded) }
                .onChange(of: needsTimeline, initial: true) { _, demanded in source.setTimelineDemand(demanded) }
            }
        }
        .background {
            if hostVisible && !reduceMotion { DockConversationWallpaper() }
        }
        .environment(\.conversationScrollController, coordinator.controller)
        .onAppear {
            reset()
            if hostVisible { source.resume() } else { source.suspend() }
        }
        .onChange(of: hostVisible) { _, visible in
            if visible { source.resume() } else { source.suspend() }
        }
        .onChange(of: themeRevision) { _, _ in source.prefetch() }
        .onChange(of: hostVisible && isShowingMessageSearch, initial: true) { _, searching in
            model.setTranscriptSearchDemand(ObjectIdentifier(source), active: searching)
        }
        .onDisappear {
            model.setTranscriptSearchDemand(ObjectIdentifier(source), active: false)
            coordinator.invalidate()
            coordinator.onScrollToBottom = nil
            source.suspend()
        }
    }

    private func reset() {
        coordinator.synchronize(model: model)
        coordinator.onEarlierHistory = { [weak model] in model?.loadEarlierTranscriptIfAvailable() }
    }

    private func jumpToMessage(_ item: MessageNavigatorItem, proxy: ScrollViewProxy) {
        coordinator.select(item, model: model) { messageID in
            proxy.scrollTo(messageID, anchor: .center)
            spotlight(messageID)
        }
    }

    private var unreadDivider: some View {
        HStack(spacing: 8) {
            DockAccentColor.unreadBadgeFill.opacity(0.55).frame(height: 1)
            Text("Unread messages")
                .dockFont(.metadata, weight: .semibold)
                .foregroundStyle(DockAccentColor.unreadBadgeText)
                .dockPill(tint: DockAccentColor.unreadBadgeFill, solid: true)
                .fixedSize()
            DockAccentColor.unreadBadgeFill.opacity(0.55).frame(height: 1)
        }
        .dockPadding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unread messages begin here")
    }

    private func spotlight(_ id: UUID) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.3)) { spotlightMessageID = id }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard spotlightMessageID == id else { return }
            withAnimation(reduceMotion ? nil : .dockEase(duration: 0.6)) { spotlightMessageID = nil }
        }
    }

    var workingCrew: [BotSummary] {
        var seen = Set<String>()
        return model.workingBotDispatches.compactMap { record in
            seen.insert(record.botID).inserted ? botMode.botsByID[record.botID] : nil
        }
    }

    @ViewBuilder
    func botHandoffRow(context: ConversationTranscriptSnapshot.Context) -> some View {
        let fromID = model.activeBotProfileID ?? model.sessionProfileID ?? botMode.selectedProfileID
        let from =
            fromID.flatMap { botMode.botsByID[$0] } ?? botMode.visibleBots.first(where: \.isDefault)
        let partners = workingCrew.filter { $0.id != from?.id }
        let mentions = context.mentions
        let replying = mentionedBots
        // The streaming turn includes both mentions and dispatches in its huddle.
        if context.streamingID == nil {
            VStack(alignment: .leading, spacing: 4) {
                if let lead = replying.first {
                    BotCrewRow(
                        from: lead, partners: Array(replying.dropFirst()),
                        since: mentions.map(\.createdAt).min() ?? .now,
                        avatars: botMode.avatarImages, repliesToUser: true,
                        steps: Dictionary(
                            mentions.compactMap { record in
                                context.botSteps[record.id].map { (record.botID, $0) }
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
                                context.botSteps[record.id].map { (record.botID, $0) }
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
        _ message: ChatMessage, index: Int, snapshot: ConversationTranscriptSnapshot, defaultBot: BotSummary?
    ) -> some View {
        let target = MessageNavigatorTarget(sessionID: snapshot.sessionID ?? "", messageID: message.id)
        let context = snapshot.context
        let isStreaming = message.id == context.streamingID
        let activity = isStreaming ? context.streamingActivity : message.activity
        let workingBotID =
            message.botProfileID ?? model.activeBotProfileID ?? model.sessionProfileID
            ?? botMode.selectedProfileID
        // An unknown or unset profile falls back to the default Bot, as the handoff row does.
        let workingBot = workingBotID.flatMap { botMode.botsByID[$0] } ?? defaultBot
        if message.role == .hermes, isStreaming || !activity.isEmpty {
            let rowDispatches = Dictionary(
                activity.compactMap { call in
                    context.dispatches[call.id].map { (call.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            let rowSteps = Dictionary(
                rowDispatches.values.compactMap { record in
                    context.botSteps[record.id].map { (record.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            TurnActivityView(
                activity: activity,
                runningSince: isStreaming ? (context.streamingStartedAt ?? message.timestamp) : nil,
                duration: message.responseDuration,
                expandsByDefault: !message.hasBodyText && message.images.isEmpty,
                bot: isStreaming ? workingBot : nil,
                botAvatar: workingBot.flatMap { botMode.avatarImages[$0.id] },
                dispatches: rowDispatches,
                botLiveSteps: rowSteps,
                crew: isStreaming ? context.streamingCrew(botsByID: botMode.botsByID) : [],
                crewSteps: isStreaming
                    ? Dictionary(
                        context.mentions.compactMap { record in
                            context.botSteps[record.id].map { (record.botID, $0) }
                        }, uniquingKeysWith: { first, _ in first }) : [:],
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
            let owner = model.composerDraftKey
            let generation = model.sessionResumeGeneration
            ConversationMessageRow(
                message: message,
                changes: ConversationChangeSummary.turnFiles(
                    messages: snapshot.messages, at: index, streamingID: context.streamingID),
                isStreamingMessage: isStreaming,
                streamingMood: isStreaming
                    ? BotMood(
                        status: context.status,
                        compacting: context.compactingID != nil && context.compactingID == target.sessionID)
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
                    context.actionsReady && !target.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isSpeaking: voiceOutput.speakingMessageID == message.id,
                metrics: conversationMetrics,
                actionTarget: target,
                delivery: context.deliveryStates[message.id],
                deliveryChecking: context.deliveryChecking,
                deliveryCheckNote: context.deliveryCheckNote,
                deliveryCheckAvailable: context.deliveryCheckAvailable,
                onCheckDelivery: {
                    Task { await model.checkDeliveryStatus(owner: owner, generation: generation) }
                },
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
                isSpotlit: spotlightMessageID == message.id,
                onPin: { source.perform(.pin, target: target) },
                onOpenInTab: {
                    guard model.sessionActionsReady, let current = source.message(for: target) else { return }
                    SessionMessageTabs.shared.open(current, in: WorkspaceIdentity.session(model))
                },
                forwardContent: { bot, dismiss in
                    guard model.sessionActionsReady, let current = source.message(for: target) else {
                        return AnyView(EmptyView())
                    }
                    let draft = model.forwardDraft(
                        for: .init(
                            sourceSession: WorkspaceIdentity.session(
                                profileID: model.sessionProfileID, sessionID: model.navigationSessionID),
                            messageID: current.id, recipientID: bot.id))
                    return AnyView(
                        ForwardToBotPopover(
                            model: model, botMode: botMode, bot: bot, messageText: current.text,
                            draft: draft, dismiss: dismiss)
                    )
                },
                loadKanbanDetail: { notice in
                    await controlCenter.sessionKanbanTaskDetail(
                        notice.taskSummary, sessionIDs: Set(model.botActivitySessionIDs.compactMap { $0 }))
                }
            )
            .equatable()
            .generativeUIMessage(model: model, message: message)
        }

    }

}
