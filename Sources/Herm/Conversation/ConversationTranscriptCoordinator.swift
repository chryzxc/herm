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
        var generation: UInt64
        var range: Range<Int>
        var anchor: ConversationScrollAnchor
        var isCorrecting = false
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
    /// A reading position survives a transcript re-parse (new message ids) by
    /// its Hermes row id, then by its distance from the end.
    private struct SavedPosition {
        var anchor: ConversationScrollAnchor
        var rowID: Int?
        var fromEnd: Int
    }
    private var savedAnchors: [String: SavedPosition] = [:]
    private var messageIDsByRowID: [Int: UUID] = [:]
    /// A session reopened before its transcript arrived restores once it does.
    private var awaitingRestore: SavedPosition?
    private var savedAnchorOrder: [String] = []
    private var positionedUnread = false
    private var viewedSessionIDs: [String] = []
    /// The reader already saw this session in this run: reopening keeps their
    /// last position (or the live tail) instead of jumping to the unread divider.
    private(set) var restoresViewedPosition = false
    /// A restored session position stays pinned while rows above it finish
    /// measuring, until the reader scrolls or navigates.
    private var restoredAnchor: ConversationScrollAnchor?
    private var lastResponseCount = 0
    private var countedMessagesRevision: UInt64?
    private var consumedPrependGeneration = 0
    private var queuedDirection: CGFloat = 0
    private var preparingDirection: CGFloat = 0
    private enum HistoryProximity {
        case preparing, revealing, urgent
    }
    private struct HistoryRequest {
        let id = UUID()
        let target: Range<Int>
        let direction: CGFloat
        var proximity: HistoryProximity
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
    private var laidOutGeneration: UInt64?
    /// The reader repinned to the bottom of a widened window during a gesture.
    private var compactsWhenSettled = false

    private func storedRowID(for messageID: UUID) -> Int? {
        messageIDsByRowID.first { $0.value == messageID }?.key
    }

    init(controller: ConversationScrollController = ConversationScrollController()) {
        self.controller = controller
    }

    /// Remembers where the reader was in the session being left; capped like the transcript cache.
    private func saveAnchor() {
        guard let id = sessionID, !presentation.isAtBottom, let geometry = controller.geometry,
            let row = rowViewports.filter({
                $0.maxY > geometry.visibleTop && $0.minY < geometry.visibleTop + geometry.visibleHeight
            }).min(by: { $0.index < $1.index })
        else { return }
        savedAnchors[id] = SavedPosition(
            anchor: ConversationScrollAnchor(messageID: row.target.messageID, offset: row.minY - geometry.visibleTop),
            rowID: storedRowID(for: row.target.messageID), fromEnd: totalCount - row.index)
        savedAnchorOrder.removeAll { $0 == id }
        savedAnchorOrder.append(id)
        if savedAnchorOrder.count > 8 { savedAnchors[savedAnchorOrder.removeFirst()] = nil }
    }

    func reset(
        sessionID: String?, totalCount: Int, bubbleCount: Int, messages: [ChatMessage] = [], rowIDs: [Int: UUID] = [:]
    ) {
        if self.sessionID != sessionID {
            positionedUnread = false
            saveAnchor()
            if let left = self.sessionID, self.totalCount > 0 {
                viewedSessionIDs.removeAll { $0 == left }
                viewedSessionIDs.append(left)
                if viewedSessionIDs.count > 64 { viewedSessionIDs.removeFirst() }
            }
            restoresViewedPosition = sessionID.map(viewedSessionIDs.contains) ?? false
        }
        invalidate()
        self.sessionID = sessionID
        self.totalCount = totalCount
        lastResponseCount = bubbleCount
        countedMessagesRevision = nil
        consumedPrependGeneration = 0
        rowViewports = []
        compactsWhenSettled = false
        presentation.reset()
        awaitingRestore = nil
        if let sessionID, let saved = savedAnchors.removeValue(forKey: sessionID) {
            savedAnchorOrder.removeAll { $0 == sessionID }
            if messages.isEmpty {
                awaitingRestore = saved
                presentation.isAtBottom = false
                setRange(0..<0)
                return
            }
            if restore(saved, messages: messages, rowIDs: rowIDs) { return }
        }
        setRange(ConversationMessageWindow.rangeForSessionReplacement(totalCount: totalCount))
        if totalCount > 0 { queueTailLanding(afterAttachment: true) }
    }

    private func restore(_ saved: SavedPosition, messages: [ChatMessage], rowIDs: [Int: UUID]) -> Bool {
        let byID = messages.firstIndex { $0.id == saved.anchor.messageID }
        let byRow = saved.rowID.flatMap { rowIDs[$0] }.flatMap { id in messages.firstIndex { $0.id == id } }
        let fromEnd = messages.count - saved.fromEnd
        guard let sessionID,
            let index = byID ?? byRow ?? (messages.indices.contains(fromEnd) ? fromEnd : nil)
        else { return false }
        landAtAnchor(
            ConversationScrollAnchor(messageID: messages[index].id, offset: saved.anchor.offset),
            index: index, count: messages.count, sessionID: sessionID)
        return true
    }

    func positionAtOpeningUnread(model: DockModel) {
        guard !positionedUnread, model.positionsAtUnreadOnResume, !restoresViewedPosition,
            model.sessionActionsReady, model.sessionTranscriptPreview == nil,
            let sessionID, let id = model.unreadDividerMessageID,
            let index = model.messages.firstIndex(where: { $0.id == id })
        else { return }
        positionedUnread = true
        presentation.unseenMessageCount = 0
        landAtAnchor(.init(messageID: id, offset: 0), index: index, count: model.messages.count, sessionID: sessionID)
    }

    private func landAtAnchor(_ anchor: ConversationScrollAnchor, index: Int, count: Int, sessionID: String) {
        invalidate()
        totalCount = count
        setRange(ConversationMessageWindow.jumpWindow(aroundIndex: index, totalCount: count))
        presentation.isAtBottom = false
        pendingPage = PageTransaction(sessionID: sessionID, generation: generation, range: mountedRange, anchor: anchor)
        restoredAnchor = anchor
        concealUntilLanding()
    }

    private func concealUntilLanding() {
        controller.isConcealed = true
        let landing = generation
        // ponytail: fixed failsafe; a page that never measures still reveals.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.generation == landing else { return }
            self.controller.isConcealed = false
        }
    }

    func invalidate() {
        navigationGeneration &+= 1
        restoredAnchor = nil
        cancelMounting()
    }

    private func cancelMounting() {
        generation &+= 1
        pendingPage = nil
        controller.isConcealed = false
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
        pendingPage?.anchor.recordUserScroll(delta: delta)
        restoredAnchor = nil
        if let request = historyRequest, request.direction * delta < 0 {
            cancelHistoryRequest()
        }
        if delta < 0 { presentation.isAtBottom = false }
        if delta > 0, geometry.distanceToBottom <= ConversationScrollMetrics.pastEndTolerance {
            updatePosition(geometry, compacts: false)
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

    /// Compaction unmounts most of the window, so a reader who repins
    /// mid-gesture compacts once the scroll settles, not under momentum.
    private func updatePosition(_ geometry: ConversationScrollGeometry, compacts: Bool = true) {
        let wasAtBottom = presentation.isAtBottom
        presentation.updatePosition(
            geometry,
            isLiveTail: ConversationMessageWindow.isLiveTail(mountedRange, totalCount: totalCount))
        if ConversationMessageWindow.shouldCompactAfterRepinning(
            wasAtBottom: wasAtBottom, isAtBottom: presentation.isAtBottom,
            range: mountedRange, totalCount: totalCount
        ) {
            compactsWhenSettled = true
        }
        if !presentation.isAtBottom { compactsWhenSettled = false }
        let compactsNow =
            compacts && compactsWhenSettled
            && ConversationMessageWindow.isLiveTail(mountedRange, totalCount: totalCount)
            && mountedRange.count > ConversationMessageWindow.initialLimit
        if compacts { compactsWhenSettled = false }
        if compactsNow {
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

    /// Runs the navigation queued for this layout once the session's scroll
    /// view is attached; before that a scroll lands nowhere and is lost.
    private func runNavigationIfAttached() -> Bool {
        guard let navigate = navigationAfterLayout else { return false }
        guard controller.geometry != nil, laidOutGeneration == generation else { return true }
        navigationAfterLayout = nil
        navigate()
        return true
    }

    private func queueTailLanding(afterAttachment: Bool = false) {
        concealUntilLanding()
        navigationAfterLayout = { [weak self] in
            guard let self else { return }
            let land: @MainActor () -> Void = {
                if self.presentation.isAtBottom { self.controller.scrollToBottom() }
                self.controller.isConcealed = false
            }
            if afterAttachment { self.scheduleScroll(land) } else { land() }
        }
    }

    func contentResized() {
        if runNavigationIfAttached() { return }
        if restoredAnchor != nil || pendingPage != nil {
            applyAnchor()
            return
        }
        guard presentation.isAtBottom, let geometry = controller.geometry else {
            retryPreparedPage()
            return
        }
        // A collapse can already have clamped the native clip to the new tail.
        let bottom = max(0, geometry.documentHeight - geometry.visibleHeight)
        guard abs(geometry.visibleTop - bottom) > 0.5 else { return }
        followTail()
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
        let edgeDistance = direction < 0 ? geometry.visibleTop : geometry.distanceToBottom
        let revealDistance = max(480, geometry.visibleHeight)
        guard edgeDistance < 2 * revealDistance else {
            preparingDirection = 0
            return
        }
        let range = ConversationMessageWindow.visibleRange(mountedRange, totalCount: totalCount)
        if direction < 0, range.lowerBound <= 2 * ConversationMessageWindow.pageSize {
            onEarlierHistory()
        }
        if direction < 0, range.lowerBound == 0 {
            if historyRequest != nil { cancelHistoryRequest() }
            return
        }
        let proximity: HistoryProximity =
            ConversationMessageWindow.isNearHistoryEdge(edgeDistance, geometry.visibleHeight)
            ? .urgent : edgeDistance < revealDistance ? .revealing : .preparing
        // Preparation reports progress itself. Wheel events only recheck when crossing a threshold.
        if preparingDirection == direction, historyRequest?.proximity == proximity { return }
        let visible = rowViewports.lazy.filter {
            $0.maxY > geometry.visibleTop && $0.minY < geometry.visibleTop + geometry.visibleHeight
        }
        guard let row = visible.min(by: { $0.index < $1.index }) else { return }
        let span = row.index...(visible.map(\.index).max() ?? row.index)
        let proposed: Range<Int>
        if direction < 0 {
            proposed = ConversationMessageWindow.revealEarlier(
                range, totalCount: totalCount, visibleSpan: span)
        } else {
            proposed = ConversationMessageWindow.revealLater(
                range, totalCount: totalCount, visibleSpan: span)
        }
        guard proposed != range else { return }
        if historyRequest == nil {
            let target = direction < 0 ? proposed.lowerBound..<range.lowerBound : range.upperBound..<proposed.upperBound
            historyRequest = HistoryRequest(target: target, direction: direction, proximity: proximity)
        }
        guard let request = historyRequest, request.direction == direction else { return }
        historyRequest?.proximity = proximity
        let readiness =
            pageReadiness?(request.target, direction)
            ?? ConversationPageReadiness(count: request.target.count, preparedPage: nil)
        guard historyRequest?.id == request.id else { return }
        let ready = min(max(0, readiness.count), request.target.count)
        let available =
            direction < 0
            ? range.lowerBound - max(request.target.lowerBound, request.target.upperBound - ready)
            : min(request.target.upperBound, request.target.lowerBound + ready) - range.upperBound
        let isFullyReady = ready == request.target.count
        guard proximity != .preparing,
            ConversationMessageWindow.mountsPartialPage(
                available: available, isFullyReady: isFullyReady,
                edgeDistance: edgeDistance,
                visibleHeight: geometry.visibleHeight)
        else {
            preparingDirection = direction
            return
        }
        let count =
            controller.isUserScrolling ? min(ConversationMessageWindow.minimumPartialPage, available) : available
        let next =
            direction < 0
            ? ConversationMessageWindow.revealEarlier(
                range, totalCount: totalCount, visibleSpan: span, count: count)
            : ConversationMessageWindow.revealLater(
                range, totalCount: totalCount, visibleSpan: span, count: count)
        if isFullyReady, count == available {
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
        HermPerformanceRecorder.mark("transcript.rowsMounted", count: count)
    }

    func retryPreparedPage() {
        guard preparingDirection != 0, pendingPage == nil, let geometry = controller.geometry else { return }
        let direction = preparingDirection
        if historyRequest?.proximity == .preparing {
            let distance = direction < 0 ? geometry.visibleTop : geometry.distanceToBottom
            // The prefetcher already knows the requested rows. Check readiness when they can mount.
            guard distance < max(480, geometry.visibleHeight) else { return }
        }
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
        laidOutGeneration = layout.generation
        if runNavigationIfAttached() { return }
        if pendingPage == nil, queuedDirection != 0, let geometry = controller.geometry {
            let direction = queuedDirection
            queuedDirection = 0
            checkEdge(geometry, direction: direction)
            return
        }
        applyAnchor()
    }

    /// Lands the pending page, or keeps a restored session position pinned,
    /// against the latest mounted rows. The transcript gets a new scroll view
    /// per session that attaches after its first layout, so this also runs on attach.
    private func applyAnchor() {
        guard pendingPage != nil || restoredAnchor != nil else { return }
        guard laidOutGeneration == generation, let geometry = controller.geometry else { return }
        if pendingPage == nil, let anchor = restoredAnchor,
            let row = rowViewports.first(where: { $0.target.messageID == anchor.messageID })
        {
            let correction = anchor.correction(rowMinY: row.minY, visibleTop: geometry.visibleTop)
            if abs(correction) > 0.5 { controller.shiftVisibleTop(by: correction) }
            return
        }
        guard let page = pendingPage,
            page.sessionID == sessionID, page.generation == generation, page.range == mountedRange,
            let row = rowViewports.first(where: { $0.target.messageID == page.anchor.messageID })
        else { return }
        if !page.isCorrecting {
            pendingPage?.isCorrecting = true
            performance.recordAnchorCorrection()
        }
        // Re-checked on every layout and resize: a shift clamped by a document
        // that has not grown yet, or superseded by another adjustment (a new
        // session scroll view), is applied again until the row has landed.
        controller.shiftVisibleTop(
            by: page.anchor.correction(rowMinY: row.minY, visibleTop: geometry.visibleTop)
        ) { [weak self] in
            guard let self, self.generation == page.generation, self.pendingPage != nil else { return }
            self.pendingPage = nil
            self.controller.isConcealed = false
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
            // A refill can arrive while a local page is still landing. Its identity and
            // geometry stay the same after the stored rows shift its indices.
            if pendingPage == nil {
                cancelMounting()
            } else {
                controller.cancelPendingAdjustments()
                cancelHistoryRequest()
            }
            lastResponseCount = bubbleCount
            if !range.isEmpty {
                setRange((range.lowerBound + prepend.count)..<(range.upperBound + prepend.count))
                pendingPage?.generation = generation
                pendingPage?.range = mountedRange
            }
            // Only a reader at the end of the local buffer needs an immediate reveal.
            if range.lowerBound == 0, !presentation.isAtBottom, queuedDirection == 0 {
                queuedDirection = -1
            }
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
            if oldCount == 0, !range.isEmpty {
                queueTailLanding()
            } else if newCount > oldCount || added > 0 {
                followTail()
            }
        } else if newCount >= oldCount {
            presentation.unseenMessageCount += added
        }
    }

    /// On a first visit, only a covered read tail can paint before unread review.
    func openingMessages(model: DockModel) -> [ChatMessage] {
        if model.sessionTranscriptLoadState == .loading,
            sessionID != model.transcriptPresentationID || totalCount == 0
        {
            return []
        }
        if model.positionsAtUnreadOnResume,
            model.sessionTranscriptLoadState == .loading || model.sessionTranscriptLoadState == .refreshing,
            model.sessionTranscriptPreview?.readCoverage == nil,
            let id = model.transcriptPresentationID, !viewedSessionIDs.contains(id)
        {
            return []
        }
        if let preview = model.sessionTranscriptPreview, let id = model.transcriptPresentationID,
            model.sessionTranscriptLoadState == .refreshing,
            let saved = sessionID == id ? awaitingRestore : savedAnchors[id],
            !preview.messages.contains(where: { $0.id == saved.anchor.messageID }),
            saved.rowID.flatMap({ preview.rowIDs[$0] }) == nil
        {
            return []
        }
        return model.displayedTranscriptMessages
    }

    func synchronize(model: DockModel) {
        let messages = openingMessages(model: model)
        let presentationID = model.transcriptPresentationID
        let count = messages.count
        guard sessionID != presentationID || totalCount != count || countedMessagesRevision != model.messagesRevision
        else {
            reconcileAnchor(messages: messages)
            return
        }
        let responses: Int
        if sessionID == presentationID, model.sessionTranscriptPreview == nil, let countedMessagesRevision,
            let prepend = model.lastTranscriptPrepend,
            prepend.isInsertion(
                after: countedMessagesRevision, previousCount: totalCount, revision: model.messagesRevision,
                count: count)
        {
            responses =
                lastResponseCount
                + ConversationUnreadMessagePolicy.assistantResponseCount(
                    Array(messages.prefix(prepend.count)))
        } else {
            responses = ConversationUnreadMessagePolicy.assistantResponseCount(messages)
        }
        if countedMessagesRevision != nil, countedMessagesRevision != model.messagesRevision, historyRequest != nil {
            cancelHistoryRequest()
        }
        let rowIDs = model.sessionTranscriptPreview?.rowIDs ?? model.transcriptMessageIDsByRowID
        defer { messageIDsByRowID = rowIDs }
        if sessionID != presentationID {
            reset(
                sessionID: presentationID, totalCount: count, bubbleCount: responses, messages: messages, rowIDs: rowIDs
            )
        } else if let saved = awaitingRestore, count > 0 {
            awaitingRestore = nil
            lastResponseCount = responses
            if !restore(saved, messages: messages, rowIDs: rowIDs) {
                invalidate()
                totalCount = count
                presentation.isAtBottom = true
                setRange(ConversationMessageWindow.rangeForSessionReplacement(totalCount: count))
                queueTailLanding()
            }
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

    func promotePreview(model: DockModel, previewRows: [ConversationTranscriptSnapshot.Row] = []) {
        let messages = model.messages
        // Fresh history may add hundreds of older rows above exactly the same visible window.
        // Rebase its indices while preserving the native viewport and the reader’s scroll offset.
        if sessionID == model.transcriptPresentationID, pendingPage == nil, awaitingRestore == nil,
            navigationAfterLayout == nil, let first = previewRows.first,
            first.index == mountedRange.lowerBound, previewRows.count == mountedRange.count,
            let start = messages.firstIndex(where: { $0.id == first.message.id })
        {
            let end = start + previewRows.count
            if end <= messages.count, !presentation.isAtBottom || end == messages.count,
                zip(previewRows, messages[start..<end]).allSatisfy({ $0.message.id == $1.id })
            {
                if mountedRange != start..<end {
                    cancelMounting()
                    setRange(start..<end)
                }
                totalCount = messages.count
                countedMessagesRevision = model.messagesRevision
                lastResponseCount = ConversationUnreadMessagePolicy.assistantResponseCount(messages)
                messageIDsByRowID = model.transcriptMessageIDsByRowID
                return
            }
        }
        guard sessionID == model.transcriptPresentationID, !presentation.isAtBottom else {
            synchronize(model: model)
            return
        }
        // A restore still in flight carries over to the fresh transcript.
        let carried =
            awaitingRestore
            ?? restoredAnchor.map { SavedPosition(anchor: $0, rowID: storedRowID(for: $0.messageID), fromEnd: -1) }
        let rowIDs = model.transcriptMessageIDsByRowID
        messageIDsByRowID = rowIDs
        if let carried, restoredAnchor != nil,
            let index = messages.firstIndex(where: { $0.id == carried.anchor.messageID }),
            mountedRange == ConversationMessageWindow.jumpWindow(aroundIndex: index, totalCount: messages.count)
        {
            // Stable row identity keeps the existing anchor through the refresh.
            totalCount = messages.count
            lastResponseCount = ConversationUnreadMessagePolicy.assistantResponseCount(messages)
            countedMessagesRevision = model.messagesRevision
            return
        }
        if let carried {
            awaitingRestore = nil
            lastResponseCount = ConversationUnreadMessagePolicy.assistantResponseCount(messages)
            countedMessagesRevision = model.messagesRevision
            if restore(carried, messages: messages, rowIDs: rowIDs) { return }
        }
        guard let geometry = controller.geometry,
            let row = rowViewports.filter({
                $0.maxY > geometry.visibleTop && $0.minY < geometry.visibleTop + geometry.visibleHeight
            }).min(by: { $0.index < $1.index }),
            let index = messages.firstIndex(where: { $0.id == row.target.messageID })
        else {
            reset(
                sessionID: model.transcriptPresentationID, totalCount: messages.count,
                bubbleCount: ConversationUnreadMessagePolicy.assistantResponseCount(messages), messages: messages,
                rowIDs: rowIDs)
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
        navigationAfterLayout = { [weak self] in
            self?.scheduleScroll(afterLayout ?? { [weak self] in self?.alignTop(index) })
        }
    }

    /// Puts a mounted row at the top of the viewport natively, from its measured position.
    private func alignTop(_ index: Int) {
        guard let geometry = controller.geometry, let row = rowViewports.first(where: { $0.index == index }) else {
            return
        }
        controller.shiftVisibleTop(by: row.minY - geometry.visibleTop)
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
            if let geometry = self.controller.geometry, geometry.distanceToBottom <= 0.5 { return }
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
