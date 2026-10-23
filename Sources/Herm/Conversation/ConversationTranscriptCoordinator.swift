import Combine
import SwiftUI

struct ConversationTranscriptLayout: Equatable {
    let sessionID: String?
    let generation: UInt64
    let range: Range<Int>
    var rows: [MessageNavigatorViewport]
}

struct ConversationTranscriptLayoutPreferenceKey: PreferenceKey {
    static let defaultValue: ConversationTranscriptLayout? = nil
    static func reduce(
        value: inout ConversationTranscriptLayout?, nextValue: () -> ConversationTranscriptLayout?
    ) {
        guard let next = nextValue() else { return }
        if value?.sessionID == next.sessionID, value?.generation == next.generation,
            value?.range == next.range
        {
            value?.rows += next.rows
        } else {
            value = next
        }
    }
}

/// One owner for session-local mounting, page anchors, and deferred scroll work.
/// Only range changes publish; native geometry and transaction progress do not.
@MainActor
final class ConversationTranscriptCoordinator: ObservableObject {
    struct PageTransaction {
        let sessionID: String?
        let generation: UInt64
        let range: Range<Int>
        var anchor: ConversationScrollAnchor
        var isRestoring = false
    }

    @Published private(set) var mountedRange: Range<Int> = 0..<0
    private(set) var sessionID: String?
    private(set) var generation: UInt64 = 0
    private(set) var pendingPage: PageTransaction?
    private(set) var rowViewports: [MessageNavigatorViewport] = []
    let controller: ConversationScrollController
    let presentation = ConversationScrollPresentationState()
    let performance = ConversationPerformanceMonitor()
    private(set) var navigationGeneration: UInt64 = 0
    private var totalCount = 0
    private var lastBubbleCount = 0
    private var consumedPrependGeneration = 0
    private var queuedDirection: CGFloat = 0
    private var deferredScroll: Task<Void, Never>?
    var onEarlierHistory: () -> Void = {}
    var onScrollToBottom: ((Bool) -> Void)?
    private var navigationAfterLayout: (@MainActor () -> Void)?

    init(controller: ConversationScrollController = ConversationScrollController()) {
        self.controller = controller
    }

    func reset(sessionID: String?, totalCount: Int, bubbleCount: Int) {
        invalidate()
        self.sessionID = sessionID
        self.totalCount = totalCount
        lastBubbleCount = bubbleCount
        consumedPrependGeneration = 0
        rowViewports = []
        presentation.reset()
        setRange(ConversationMessageWindow.rangeForSessionReplacement(totalCount: totalCount))
        navigationAfterLayout = { [weak self] in self?.followTail() }
    }

    func invalidate() {
        navigationGeneration &+= 1
        cancelMounting()
    }

    private func cancelMounting() {
        generation &+= 1
        pendingPage = nil
        navigationAfterLayout = nil
        queuedDirection = 0
        deferredScroll?.cancel()
        deferredScroll = nil
        controller.cancelPendingAdjustments()
    }

    private func setRange(_ range: Range<Int>) {
        generation &+= 1
        mountedRange = range
    }

    func userMoved(_ geometry: ConversationScrollGeometry, delta: CGFloat) {
        pendingPage?.anchor.recordUserScroll(delta: delta)
        if delta < 0 { presentation.isAtBottom = false }
        if delta > 0, geometry.distanceToBottom <= ConversationScrollMetrics.pastEndTolerance {
            updatePosition(geometry)
        }
        checkEdge(geometry, direction: delta)
    }

    func settled(_ geometry: ConversationScrollGeometry) {
        performance.recordScrollSettled()
        guard pendingPage == nil else { return }
        updatePosition(geometry)
        presentation.visibleTargets = Set(
            rowViewports.filter {
                $0.maxY >= geometry.visibleTop && $0.minY <= geometry.visibleTop + geometry.visibleHeight
            }.map(\.target))
    }

    private func updatePosition(_ geometry: ConversationScrollGeometry) {
        let wasAtBottom = presentation.isAtBottom
        presentation.updatePosition(
            geometry,
            isLiveTail: ConversationMessageWindow.isLiveTail(mountedRange, totalCount: totalCount))
        if ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: wasAtBottom, isAtBottom: presentation.isAtBottom,
            range: mountedRange, totalCount: totalCount
        ) {
            invalidate()
            setRange(ConversationMessageWindow.compactedRange(totalCount: totalCount))
            followTail()
        } else if ConversationScrollMetrics.isPastEnd(
            topMinY: -geometry.visibleTop, bottomMaxY: geometry.documentHeight - geometry.visibleTop,
            viewportHeight: geometry.visibleHeight
        ) {
            scheduleScroll { [weak self] in
                guard let self, self.pendingPage == nil else { return }
                self.controller.scrollToBottom()
            }
        }
    }

    func contentResized() {
        guard pendingPage == nil, presentation.isAtBottom else { return }
        followTail()
    }

    private func visibleSpan(_ geometry: ConversationScrollGeometry) -> ClosedRange<Int>? {
        let visible = rowViewports.filter {
            $0.maxY > geometry.visibleTop && $0.minY < geometry.visibleTop + geometry.visibleHeight
        }
        guard let lower = visible.map(\.index).min(), let upper = visible.map(\.index).max() else {
            return nil
        }
        return lower...upper
    }

    private func checkEdge(_ geometry: ConversationScrollGeometry, direction: CGFloat) {
        guard direction != 0 else { return }
        guard pendingPage == nil else {
            queuedDirection = direction
            return
        }
        let distance = max(480, geometry.visibleHeight)
        let range = ConversationMessageWindow.visibleRange(mountedRange, totalCount: totalCount)
        let next: Range<Int>
        if direction < 0, geometry.visibleTop < distance {
            guard range.lowerBound > 0 else {
                onEarlierHistory()
                return
            }
            next = ConversationMessageWindow.revealEarlier(
                range, totalCount: totalCount, visibleSpan: visibleSpan(geometry))
        } else if direction > 0, geometry.distanceToBottom < distance {
            next = ConversationMessageWindow.revealLater(
                range, totalCount: totalCount, visibleSpan: visibleSpan(geometry))
        } else {
            return
        }
        guard next != range,
            let row = rowViewports.filter({
                $0.maxY > geometry.visibleTop && $0.minY < geometry.visibleTop + geometry.visibleHeight
            })
            .min(by: { $0.index < $1.index })
        else { return }
        controller.cancelPendingAdjustments()
        setRange(next)
        pendingPage = PageTransaction(
            sessionID: sessionID, generation: generation, range: next,
            anchor: ConversationScrollAnchor(
                messageID: row.target.messageID, offset: row.minY - geometry.visibleTop))
        performance.recordPageTransaction()
    }

    func receiveLayout(_ layout: ConversationTranscriptLayout) {
        guard layout.sessionID == sessionID, layout.generation == generation,
            layout.range == mountedRange,
            layout.rows.count == mountedRange.count,
            Set(layout.rows.map(\.index)) == Set(mountedRange)
        else { return }
        rowViewports = layout.rows
        if let navigate = navigationAfterLayout {
            navigationAfterLayout = nil
            scheduleScroll(navigate)
            return
        }
        if pendingPage == nil, queuedDirection != 0, let geometry = controller.geometry {
            let direction = queuedDirection
            queuedDirection = 0
            checkEdge(geometry, direction: direction)
            return
        }
        guard let page = pendingPage, !page.isRestoring,
            page.sessionID == sessionID, page.generation == generation, page.range == mountedRange,
            let row = layout.rows.first(where: { $0.target.messageID == page.anchor.messageID }),
            let geometry = controller.geometry
        else { return }
        pendingPage?.isRestoring = true
        performance.recordAnchorCorrection()
        controller.shiftVisibleTop(
            by: page.anchor.correction(rowMinY: row.minY, visibleTop: geometry.visibleTop)
        ) { [weak self] in
            guard let self, self.generation == page.generation else { return }
            self.pendingPage = nil
            let direction = self.queuedDirection
            self.queuedDirection = 0
            self.scheduleScroll { [weak self] in
                guard let self, let geometry = self.controller.geometry else { return }
                self.checkEdge(geometry, direction: direction)
            }
        }
    }

    func reconcileAnchor(messages: [ChatMessage]) {
        guard let page = pendingPage, !messages.contains(where: { $0.id == page.anchor.messageID })
        else { return }
        cancelMounting()
        setRange(ConversationMessageWindow.visibleRange(mountedRange, totalCount: messages.count))
    }

    func messagesChanged(
        oldCount: Int, newCount: Int, bubbleCount: Int, prepend: TranscriptHistoryPrepend?
    ) {
        totalCount = newCount
        if let prepend, prepend.resultingCount == newCount, newCount - oldCount == prepend.count {
            guard prepend.generation != consumedPrependGeneration else { return }
            consumedPrependGeneration = prepend.generation
            let range = ConversationMessageWindow.visibleRange(mountedRange, totalCount: oldCount)
            cancelMounting()
            lastBubbleCount = bubbleCount
            if !range.isEmpty {
                setRange((range.lowerBound + prepend.count)..<(range.upperBound + prepend.count))
            }
            // Fresh row geometry is required before revealing the prepended rows.
            queuedDirection = -1
            return
        }
        let clamped = ConversationMessageWindow.visibleRange(
            ConversationMessageWindow.rangeAfterCountChange(
                mountedRange, oldCount: oldCount, newCount: newCount, isAtBottom: presentation.isAtBottom),
            totalCount: newCount)
        let lostWindow =
            newCount < oldCount
            && (newCount <= ConversationMessageWindow.initialLimit || mountedRange.lowerBound >= newCount)
        let range = lostWindow ? ConversationMessageWindow.tailRange(totalCount: newCount) : clamped
        if range != mountedRange {
            cancelMounting()
            setRange(range)
        }
        let added = max(0, bubbleCount - lastBubbleCount)
        lastBubbleCount = bubbleCount
        if newCount < oldCount { presentation.unseenMessageCount = 0 }
        if newCount > oldCount, added > 0 {
            if presentation.isAtBottom { followTail() } else { presentation.unseenMessageCount += added }
        }
    }

    func synchronize(model: DockModel) {
        let count = model.messages.count
        guard sessionID != model.sessionID || totalCount != count else {
            reconcileAnchor(messages: model.messages)
            return
        }
        let bubbles = ConversationUnreadMessagePolicy.renderedMessageCount(
            model.messages, streamingID: model.streamingMessageIDForPresentation)
        if sessionID != model.sessionID {
            reset(sessionID: model.sessionID, totalCount: count, bubbleCount: bubbles)
        } else if totalCount != count {
            messagesChanged(
                oldCount: totalCount, newCount: count, bubbleCount: bubbles,
                prepend: model.lastTranscriptPrepend)
        }
        reconcileAnchor(messages: model.messages)
    }

    func select(
        _ item: MessageNavigatorItem, model: DockModel, onScroll: @escaping @MainActor (UUID) -> Void
    ) {
        guard item.sessionID == model.sessionID else { return }
        let sessionID = model.sessionID
        invalidate()
        let requestGeneration = navigationGeneration
        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            var messageID = item.messageID
            if let rowID = item.storedRowID {
                guard let loadedID = await model.loadTranscriptHistory(through: rowID) else { return }
                messageID = loadedID
            }
            guard model.sessionID == sessionID, self.navigationGeneration == requestGeneration,
                let index = model.messages.firstIndex(where: { $0.id == messageID })
            else { return }
            self.synchronize(model: model)
            self.jump(to: index) { onScroll(messageID) }
        }
    }

    func jump(to index: Int, afterLayout: (@MainActor () -> Void)? = nil) {
        invalidate()
        presentation.isAtBottom = false
        presentation.unseenMessageCount = 0
        setRange(ConversationMessageWindow.jumpWindow(aroundIndex: index, totalCount: totalCount))
        navigationAfterLayout = afterLayout
    }

    func jumpToLatest(animated: Bool = false, reduceMotion: Bool = false) {
        invalidate()
        presentation.isAtBottom = true
        presentation.unseenMessageCount = 0
        setRange(ConversationMessageWindow.tailRange(totalCount: totalCount))
        navigationAfterLayout = { [weak self] in self?.followTail(animated: animated && !reduceMotion) }
        if totalCount == 0 {
            navigationAfterLayout?()
            navigationAfterLayout = nil
        }
    }

    func followTail(animated: Bool = false) {
        guard presentation.isAtBottom, pendingPage == nil else { return }
        scheduleScroll { [weak self] in
            guard let self, self.presentation.isAtBottom, self.pendingPage == nil else { return }
            if let scroll = self.onScrollToBottom {
                scroll(animated)
            } else {
                self.controller.scrollToBottom()
            }
        }
    }

    private func scheduleScroll(_ action: @escaping @MainActor () -> Void) {
        deferredScroll?.cancel()
        let token = generation
        deferredScroll = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.generation == token else { return }
            action()
        }
    }
}
