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

struct ConversationPageReadiness {
    let count: Int
    let preparedPage: ConversationPreparedPage?
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
        var preparedPage: ConversationPreparedPage? = nil
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
    private var lastResponseCount = 0
    private var countedMessagesRevision: UInt64?
    private var consumedPrependGeneration = 0
    private var queuedDirection: CGFloat = 0
    private var preparingDirection: CGFloat = 0
    private struct HistoryRequest {
        let id = UUID()
        let target: Range<Int>
        let direction: CGFloat
    }
    private var historyRequest: HistoryRequest?
    var hasHistoryRequest: Bool { historyRequest != nil }
    private var deferredScroll: Task<Void, Never>?
    var onEarlierHistory: () -> Void = {}
    var onAcceptedLayout: (String?) -> Void = { _ in }
    var onScrollToBottom: ((Bool) -> Void)?
    var pageReadiness: ((Range<Int>, CGFloat) -> ConversationPageReadiness)?
    var onPreparationCancelled: () -> Void = {}
    var onPreparationInvalidated: () -> Void = {}
    private var navigationAfterLayout: (@MainActor () -> Void)?

    init(controller: ConversationScrollController = ConversationScrollController()) {
        self.controller = controller
    }

    func reset(sessionID: String?, totalCount: Int, bubbleCount: Int) {
        invalidate()
        self.sessionID = sessionID
        self.totalCount = totalCount
        lastResponseCount = bubbleCount
        countedMessagesRevision = nil
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
        controller.preparedPage = nil
        navigationAfterLayout = nil
        queuedDirection = 0
        cancelHistoryRequest()
        onPreparationInvalidated()
        deferredScroll?.cancel()
        deferredScroll = nil
        controller.cancelPendingAdjustments()
    }

    private func setRange(_ range: Range<Int>) {
        generation &+= 1
        mountedRange = range
    }

    func userMoved(_ geometry: ConversationScrollGeometry, delta: CGFloat) {
        presentation.isUserScrolling = true
        pendingPage?.anchor.recordUserScroll(delta: delta)
        if let request = historyRequest, request.direction * delta < 0 {
            cancelHistoryRequest()
        }
        if historyRequest != nil { preparingDirection = 0 }
        if delta < 0 { presentation.isAtBottom = false }
        if delta > 0, geometry.distanceToBottom <= ConversationScrollMetrics.pastEndTolerance {
            updatePosition(geometry)
        }
        checkEdge(geometry, direction: delta)
    }

    func settled(_ geometry: ConversationScrollGeometry) {
        performance.recordScrollSettled()
        presentation.isUserScrolling = false
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

    func cancelHistoryRequest() {
        historyRequest = nil
        preparingDirection = 0
        onPreparationCancelled()
    }

    private func checkEdge(_ geometry: ConversationScrollGeometry, direction delta: CGFloat) {
        guard delta != 0 else { return }
        let direction: CGFloat = delta < 0 ? -1 : 1
        guard pendingPage == nil else {
            queuedDirection = direction
            return
        }
        let distance = max(480, geometry.visibleHeight)
        let range = ConversationMessageWindow.visibleRange(mountedRange, totalCount: totalCount)
        let proposed: Range<Int>
        if direction < 0, geometry.visibleTop < distance {
            guard range.lowerBound > 0 else {
                cancelHistoryRequest()
                onEarlierHistory()
                return
            }
            proposed = ConversationMessageWindow.revealEarlier(
                range, totalCount: totalCount, visibleSpan: visibleSpan(geometry))
        } else if direction > 0, geometry.distanceToBottom < distance {
            proposed = ConversationMessageWindow.revealLater(
                range, totalCount: totalCount, visibleSpan: visibleSpan(geometry))
        } else {
            if historyRequest != nil { preparingDirection = direction }
            return
        }
        if preparingDirection == direction { return }
        guard proposed != range,
            let row = rowViewports.filter({
                $0.maxY > geometry.visibleTop && $0.minY < geometry.visibleTop + geometry.visibleHeight
            }).min(by: { $0.index < $1.index })
        else { return }
        if historyRequest == nil {
            let target = direction < 0 ? proposed.lowerBound..<range.lowerBound : range.upperBound..<proposed.upperBound
            historyRequest = HistoryRequest(target: target, direction: direction)
        }
        guard let request = historyRequest, request.direction == direction else { return }
        let readiness =
            pageReadiness?(request.target, direction)
            ?? ConversationPageReadiness(count: request.target.count, preparedPage: nil)
        guard historyRequest?.id == request.id else { return }
        let ready = min(max(0, readiness.count), request.target.count)
        let available =
            direction < 0
            ? range.lowerBound - max(request.target.lowerBound, request.target.upperBound - ready)
            : min(request.target.upperBound, request.target.lowerBound + ready) - range.upperBound
        guard available > 0 else {
            preparingDirection = direction
            return
        }
        let next =
            direction < 0
            ? ConversationMessageWindow.revealEarlier(
                range, totalCount: totalCount, visibleSpan: visibleSpan(geometry), count: available)
            : ConversationMessageWindow.revealLater(
                range, totalCount: totalCount, visibleSpan: visibleSpan(geometry), count: available)
        if ready == request.target.count {
            cancelHistoryRequest()
        } else {
            preparingDirection = direction
        }
        controller.preparedPage = readiness.preparedPage
        controller.cancelPendingAdjustments()
        setRange(next)
        pendingPage = PageTransaction(
            sessionID: sessionID, generation: generation, range: next,
            anchor: ConversationScrollAnchor(
                messageID: row.target.messageID, offset: row.minY - geometry.visibleTop),
            preparedPage: readiness.preparedPage)
        performance.recordPageTransaction()
    }

    func retryPreparedPage() {
        guard preparingDirection != 0, pendingPage == nil, let geometry = controller.geometry else { return }
        let direction = preparingDirection
        preparingDirection = 0
        checkEdge(geometry, direction: direction)
    }

    func receiveLayout(_ layout: ConversationTranscriptLayout) {
        guard layout.sessionID == sessionID, layout.generation == generation,
            layout.range == mountedRange,
            layout.rows.count == mountedRange.count,
            Set(layout.rows.map(\.index)) == Set(mountedRange)
        else { return }
        onAcceptedLayout(layout.sessionID)
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
            self.controller.preparedPage = nil
            let direction = self.queuedDirection
            self.queuedDirection = 0
            self.scheduleScroll { [weak self] in
                guard let self, let geometry = self.controller.geometry else { return }
                if self.historyRequest != nil {
                    self.retryPreparedPage()
                } else {
                    self.checkEdge(geometry, direction: direction)
                }
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
            lastResponseCount = bubbleCount
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
        let added = max(0, bubbleCount - lastResponseCount)
        lastResponseCount = bubbleCount
        if newCount < oldCount { presentation.unseenMessageCount = 0 }
        if presentation.isAtBottom {
            if newCount > oldCount || added > 0 { followTail() }
        } else if newCount >= oldCount {
            presentation.unseenMessageCount += added
        }
    }

    func synchronize(model: DockModel) {
        let messages = model.displayedTranscriptMessages
        let presentationID = model.transcriptPresentationID
        let count = messages.count
        guard sessionID != presentationID || totalCount != count || countedMessagesRevision != model.messagesRevision
        else {
            reconcileAnchor(messages: messages)
            return
        }
        let responses = ConversationUnreadMessagePolicy.assistantResponseCount(messages)
        if countedMessagesRevision != nil, countedMessagesRevision != model.messagesRevision, historyRequest != nil {
            cancelHistoryRequest()
        }
        if sessionID != presentationID {
            reset(sessionID: presentationID, totalCount: count, bubbleCount: responses)
        } else if let prepend = model.lastTranscriptPrepend,
            prepend.generation != consumedPrependGeneration, prepend.removedCount > 0,
            prepend.resultingCount == count, !presentation.isAtBottom
        {
            consumedPrependGeneration = prepend.generation
            promotePreview(model: model)
        } else {
            messagesChanged(
                oldCount: totalCount, newCount: count, bubbleCount: responses,
                prepend: model.lastTranscriptPrepend)
        }
        countedMessagesRevision = model.messagesRevision
        reconcileAnchor(messages: messages)
    }

    func promotePreview(model: DockModel) {
        let messages = model.messages
        guard sessionID == model.transcriptPresentationID, !presentation.isAtBottom else {
            synchronize(model: model)
            return
        }
        guard let geometry = controller.geometry,
            let row = rowViewports.filter({
                $0.maxY > geometry.visibleTop && $0.minY < geometry.visibleTop + geometry.visibleHeight
            }).min(by: { $0.index < $1.index }),
            let index = messages.firstIndex(where: { $0.id == row.target.messageID })
        else {
            reset(
                sessionID: model.transcriptPresentationID, totalCount: messages.count,
                bubbleCount: ConversationUnreadMessagePolicy.assistantResponseCount(messages))
            return
        }
        invalidate()
        totalCount = messages.count
        lastResponseCount = ConversationUnreadMessagePolicy.assistantResponseCount(messages)
        countedMessagesRevision = model.messagesRevision
        setRange(ConversationMessageWindow.jumpWindow(aroundIndex: index, totalCount: messages.count))
        pendingPage = PageTransaction(
            sessionID: sessionID, generation: generation, range: mountedRange,
            anchor: ConversationScrollAnchor(
                messageID: row.target.messageID, offset: row.minY - geometry.visibleTop))
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
        let tail = ConversationMessageWindow.tailRange(totalCount: totalCount)
        let tailAlreadyMounted = mountedRange == tail && pendingPage == nil
        invalidate()
        presentation.isAtBottom = true
        presentation.unseenMessageCount = 0
        // Publish even an unchanged range so row geometry carries the new generation.
        setRange(tail)
        if tailAlreadyMounted {
            followTail(animated: animated && !reduceMotion)
            return
        }
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
