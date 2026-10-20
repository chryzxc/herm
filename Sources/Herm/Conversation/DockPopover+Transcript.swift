import AppKit
import Combine
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension DockPopover {
    var chatScroll: some View {
        legacyChatScroll
    }

    var legacyChatScroll: some View {
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
                                    StartupAssistantView { model.draft = $0 }
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
                                botHandoffRow
                                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: workingCrewIDs)
                            }
                            // ponytail: 15s check while any Bot shows as working; Hermes has no
                            // reliable process-exit event for Bot DMs. A blocked card is not
                            // re-checked until the session's Bot work changes. Each Bot's
                            // latest step is read every 5s in between.
                            .task(id: [model.sessionID ?? ""] + model.workingBotDispatches.map(\.id)) {
                                var tick = 0
                                repeat {
                                    if tick % 3 == 0 {
                                        await model.reconcileBotDispatches()
                                        await model.reconcileKanbanAssignments { cardID in
                                            await controlCenter.sessionKanbanTaskDetail(
                                                KanbanTaskSummary(id: cardID, title: cardID, status: "", detail: nil, priority: nil, assignee: nil)
                                            ).map { ($0.status, $0.latestSummary ?? $0.result) }
                                        }
                                    }
                                    await model.refreshBotLiveSteps()
                                    tick += 1
                                    try? await Task.sleep(for: .seconds(5))
                                } while !Task.isCancelled && !model.workingBotDispatches.isEmpty
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
                                },
                                onScrollAwayFromBottom: {
                                    guard isConversationAtBottom else { return }
                                    isConversationAtBottom = false
                                    streamingTailScroll.cancel()
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
                                DockIcon(.arrowDown, size: 11, color: Color.dockPrimaryText)
                                Text("\(unseenMessageCount) new \(unseenMessageCount == 1 ? "message" : "messages")")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.dockPrimaryText)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.dockControlSurface).stroke(Color.dockBorder, lineWidth: DockLayout.outline))
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
                        // Clear of the NSScrollView's overlay scroller, whose
                        // AppKit tracking zone along the right edge takes
                        // the mouse before the rail's SwiftUI hover sees it.
                        .padding(.trailing, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    }
                }
                .onChange(of: pinnedMessageJumpID) { _, id in
                    guard let id, let item = model.messageNavigatorItems.first(where: { $0.messageID == id }) else { return }
                    jumpToMessage(item, proxy: proxy)
                    pinnedMessageJumpID = nil
                }
            }
        }
    }

    func jumpToMessage(_ item: MessageNavigatorItem, proxy: ScrollViewProxy) {
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

    var effectiveMountedRange: Range<Int> {
        let total = model.messages.count
        let clamped = ConversationMessageWindow.visibleRange(mountedMessageRange, totalCount: total)
        guard clamped.isEmpty, total > 0 else { return clamped }
        return ConversationMessageWindow.tailRange(totalCount: total)
    }

    /// History pages mount automatically once the reader is within this
    /// distance of a mounted edge, so the next page is laid out before it is
    /// needed.
    func pagingEdgeDistance(_ geometry: ConversationScrollGeometry) -> CGFloat {
        max(480, geometry.visibleHeight)
    }

    func loadEarlierMessagesIfNeeded(_ geometry: ConversationScrollGeometry) {
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

    func loadLaterMessagesIfNeeded(_ geometry: ConversationScrollGeometry) {
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

    func applyPagedRange(
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

    func visibleIndexSpan(in geometry: ConversationScrollGeometry) -> ClosedRange<Int>? {
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

    var renderedMessageBubbleCount: Int {
        ConversationUnreadMessagePolicy.renderedMessageCount(
            model.messages,
            streamingID: model.streamingMessageIDForPresentation
        )
    }

    func updateConversationPosition(
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
                viewportHeight: viewportHeight,
                tolerance: wasAtBottom ? ConversationScrollMetrics.atBottomTolerance : ConversationScrollMetrics.pastEndTolerance
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

    func updateNavigatorVisibility(top: CGFloat, bottom: CGFloat) {
        var next = Set<MessageNavigatorTarget>()
        for row in scrollBookkeeping.rowViewports where row.maxY >= top && row.minY <= bottom {
            next.insert(row.target)
        }
        if next != visibleNavigatorTargets {
            visibleNavigatorTargets = next
        }
    }

    func scheduleHistoryCompaction(_ proxy: ScrollViewProxy) {
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

    func scrollConversationToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        let owningSessionID = model.sessionID
        Task { @MainActor in
            // Let the inserted row participate in layout before targeting the
            // stable footer. This is the only programmatic scroll target in
            // the restored SwiftUI presentation.
            await Task.yield()
            guard owningSessionID == model.sessionID, isConversationAtBottom else { return }
            if animated && !reduceMotion {
                withAnimation(.dockEase(duration: 0.22)) {
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
                return
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            // Lazily measured rows (feed/kanban lines, tall cards) settle one
            // layout pass later; re-target so the tail is not left mid-way.
            await Task.yield()
            guard owningSessionID == model.sessionID, isConversationAtBottom else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    func scheduleStreamingTailScroll(_ proxy: ScrollViewProxy) {
        let owningSessionID = model.sessionID
        streamingTailScroll.schedule {
            guard owningSessionID == model.sessionID, isConversationAtBottom else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    func revealBlockingPrompt() {
        isConversationAtBottom = true
        conversationScrollRequest &+= 1
    }

    func schedulePastEndRepair(_ proxy: ScrollViewProxy) {
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

    /// Bots this session messaged that are still working, one entry per Bot.
    var workingCrew: [BotSummary] {
        var seen = Set<String>()
        return model.workingBotDispatches.compactMap { record in
            seen.insert(record.botID).inserted ? botMode.botsByID[record.botID] : nil
        }
    }

    @ViewBuilder
    var botHandoffRow: some View {
        let fromID = model.activeBotProfileID ?? model.sessionProfileID ?? botMode.selectedProfileID
        let from = fromID.flatMap { botMode.botsByID[$0] } ?? botMode.visibleBots.first(where: \.isDefault)
        let partners = workingCrew.filter { $0.id != from?.id }
        let mentions = model.pendingBotMentions
        let replying = mentionedBots
        // While the turn runs the huddle is its loading row instead.
        if model.streamingMessageIDForPresentation == nil {
            VStack(alignment: .leading, spacing: 4) {
                if let lead = replying.first {
                    BotCrewRow(from: lead, partners: Array(replying.dropFirst()),
                               since: mentions.map(\.createdAt).min() ?? .now,
                               avatars: botMode.avatarImages, repliesToUser: true)
                        .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity),
                                                removal: .opacity.combined(with: .offset(y: -6))))
                }
                if let from, !partners.isEmpty {
                    BotCrewRow(from: from, partners: partners,
                               since: model.workingBotDispatches.map(\.createdAt).min() ?? .now,
                               avatars: botMode.avatarImages)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .padding(.horizontal, conversationMetrics.contentInset + 4)
            .padding(.top, replying.isEmpty && partners.isEmpty ? 0 : 8)
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
    func messageRow(_ message: ChatMessage) -> some View {
        let isStreaming = message.id == model.streamingMessageIDForPresentation
        let activity = isStreaming ? model.streamingTurnActivity : message.activity
        let workingBotID = message.botProfileID ?? model.activeBotProfileID ?? model.sessionProfileID ?? botMode.selectedProfileID
        // An unknown or unset profile falls back to the default Bot, as the handoff row does.
        let workingBot = workingBotID.flatMap { botMode.botsByID[$0] } ?? botMode.visibleBots.first(where: \.isDefault)
        if message.role == .hermes, isStreaming || !activity.isEmpty {
            TurnActivityView(
                activity: activity,
                runningSince: isStreaming ? (model.streamingResponseStartedAt ?? message.timestamp) : nil,
                duration: message.responseDuration,
                bot: isStreaming ? workingBot : nil,
                botAvatar: workingBot.flatMap { botMode.avatarImages[$0.id] },
                dispatches: model.botDispatchesByToolCallID,
                botLiveSteps: model.botLiveSteps,
                crew: isStreaming ? workingCrew : [],
                botsByID: botMode.botsByID,
                avatars: botMode.avatarImages,
                rosterRevision: botMode.rosterRevision
            )
            .equatable()
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
                onReadAloud: { voiceOutput.toggle(messageID: message.id, text: GenerativeUIIntegration.readableText(message)) },
                onRefresh: {
                    messageActionState.run(message.id, action: .refresh) {
                        await model.refreshCurrentSession()
                    }
                },
                onReply: {
                    model.replyQuote = ReplyQuote(author: message.botDisplayName ?? botMode.botsByID[message.botProfileID ?? model.activeBotProfileID ?? ""]?.name ?? "Hermes", text: GenerativeUIIntegration.readableText(message))
                },
                showsPinAction: model.messagePinsSupported && model.storedMessageReferences[message.id] != nil
                    && message.systemEvent == nil && message.kanbanNotice == nil && !message.isError,
                isPinAvailable: model.canPinMessage(message),
                isPinned: model.isMessagePinned(message),
                onPin: {
                    messageActionState.run(message.id, action: .pin) { await model.toggleMessagePinned(message) }
                },
                forwardContent: { bot, dismiss in
                    AnyView(ForwardToBotPopover(model: model, botMode: botMode, bot: bot, messageText: message.text, dismiss: dismiss))
                },
                loadKanbanDetail: { notice in await controlCenter.sessionKanbanTaskDetail(notice.taskSummary) }
            )
            .equatable()
            .generativeUIMessage(model: model, message: message)
        }
    }

    func reasoningBlock(_ reasoning: ReasoningState) -> some View {
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

    func approvalRow(_ approval: ApprovalPresentation) -> some View {
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
                    DockCalloutDisclosure(title: "Scope and limits", text: reason)
                }

                DockCalloutActions {
                    if choices.contains(ApprovalChoice.once) {
                        Button { model.respondToApproval(ApprovalChoice.once) } label: {
                            DockActionLabel(title: "Allow once", pendingTitle: "Allowing…", isPending: isPending, tint: .dockPrimaryText)
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
    var clarificationRow: some View {
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
                                        pendingTitle: "Sending…", isPending: isPending, tint: .dockPrimaryText)
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

    func valuePromptRow(_ prompt: ValuePrompt) -> some View {
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
                    DockTextField("Username or email", text: $valuePromptIdentifier)
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
                        DockActionLabel(title: prompt.asksForLogin ? "Send login" : "Send", pendingTitle: "Sending…", isPending: isPending, tint: .dockPrimaryText)
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

    func quickPromptChip(_ quickPrompt: QuickPrompt) -> some View {
        let requiredCapability = quickPrompt.requiredCapability
        let isAvailable = requiredCapability.map(controlCenter.capabilityAvailable) ?? true
        return Button(quickPrompt.label) {
            selectQuickPrompt(quickPrompt)
        }
        .buttonStyle(.dockCompact)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isAvailable ? Color.dockSecondaryText : Color.dockMetadataText)
        .padding(.horizontal, 9)
        .frame(minHeight: 26)
        .fixedSize(horizontal: true, vertical: false)
        .background(Capsule().fill(Color.dockSurface4).stroke(Color.dockBorderLight, lineWidth: 0.5))
        .disabled(!isAvailable)
        .help(isAvailable ? quickPrompt.label : unavailableCapabilityDetail(requiredCapability))
    }

    var quickPromptOverflowMenu: some View {
        DockMenu {
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
        .fixedSize(horizontal: true, vertical: false)
    }

    func selectQuickPrompt(_ quickPrompt: QuickPrompt) {
        model.draft = quickPrompt.prompt
        model.requestComposerFocus()
    }

    func unavailableCapabilityDetail(_ id: String?) -> String {
        guard let id, let capability = controlCenter.capabilities.first(where: { $0.id == id }) else {
            return "This Hermes capability is unavailable. Open Settings and refresh capabilities."
        }
        return capability.recovery ?? capability.detail
    }
}
