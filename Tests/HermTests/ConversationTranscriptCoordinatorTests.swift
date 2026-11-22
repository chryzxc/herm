import AppKit
import Testing

@testable import Herm

@MainActor
struct ConversationTranscriptCoordinatorTests {
    @Test func unreadRepliesIncludeSameRowCompletionButExcludeUserAndActivityRows() {
        let model = DockModel(initialSessionID: "unread-replies")
        model.messages = [ChatMessage(role: .user, text: "Question")]
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.synchronize(model: model)
        coordinator.presentation.isAtBottom = false
        let replyID = UUID()
        model.messages.append(ChatMessage(id: replyID, role: .hermes, text: ""))
        coordinator.synchronize(model: model)
        #expect(coordinator.presentation.unseenMessageCount == 0)
        model.messages[1] = ChatMessage(id: replyID, role: .hermes, text: "Final reply")
        coordinator.synchronize(model: model)
        coordinator.synchronize(model: model)
        #expect(coordinator.presentation.unseenMessageCount == 1)
        model.messages.append(ChatMessage(role: .user, text: "Follow-up"))
        model.messages.append(ChatMessage(role: .hermes, text: "Activity", systemEvent: SystemEvent(label: "System")))
        coordinator.synchronize(model: model)
        #expect(coordinator.presentation.unseenMessageCount == 1)
        model.messages.append(ChatMessage(role: .hermes, text: "Second reply"))
        coordinator.synchronize(model: model)
        #expect(coordinator.presentation.unseenMessageCount == 2)
        coordinator.jumpToLatest(reduceMotion: true)
        #expect(coordinator.presentation.unseenMessageCount == 0)
    }

    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    private func layout(
        _ coordinator: ConversationTranscriptCoordinator, range: Range<Int>? = nil,
        generation: UInt64? = nil
    ) -> ConversationTranscriptLayout {
        let range = range ?? coordinator.mountedRange
        return ConversationTranscriptLayout(
            sessionID: coordinator.sessionID, generation: generation ?? coordinator.generation,
            range: range,
            rows: range.map { index in
                MessageNavigatorViewport(
                    target: .init(sessionID: coordinator.sessionID ?? "", messageID: identities[index]),
                    index: index,
                    minY: CGFloat(index - range.lowerBound) * 300,
                    maxY: CGFloat(index - range.lowerBound + 1) * 300)
            })
    }
    private let identities = (0..<500).map { _ in UUID() }

    @Test func historyWaitsForPreparationAndRejectsAReversedGesture() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 3_600))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.receiveLayout(layout(coordinator))
        controller.shiftVisibleTop(by: 40)
        let original = coordinator.mountedRange
        var ready = false
        coordinator.pageReadiness = { range, _ in
            .init(count: ready ? range.count : 0, preparedPage: nil)
        }
        coordinator.userMoved(try #require(controller.geometry), delta: -10)
        #expect(coordinator.mountedRange == original)
        #expect(coordinator.pendingPage == nil)
        coordinator.userMoved(try #require(controller.geometry), delta: 10)
        ready = true
        coordinator.retryPreparedPage()
        #expect(coordinator.mountedRange == original)
        coordinator.userMoved(try #require(controller.geometry), delta: -10)
        #expect(coordinator.mountedRange.lowerBound == original.lowerBound - ConversationMessageWindow.pageSize)
        #expect(coordinator.pendingPage != nil)
    }

    @Test func reopeningAViewedSessionSkipsTheUnreadJump() {
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.reset(sessionID: "one", totalCount: 10, bubbleCount: 10)
        #expect(!coordinator.restoresViewedPosition)
        coordinator.reset(sessionID: "two", totalCount: 10, bubbleCount: 10)
        #expect(!coordinator.restoresViewedPosition)
        coordinator.reset(sessionID: "one", totalCount: 12, bubbleCount: 12)
        #expect(coordinator.restoresViewedPosition)
        // Re-synchronizing the same session keeps the decision.
        coordinator.reset(sessionID: "one", totalCount: 13, bubbleCount: 13)
        #expect(coordinator.restoresViewedPosition)
    }

    @Test func partialHistoryRetainsItsRequestAcrossLayoutAndReversalCancelsIt() async throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 3_600))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.receiveLayout(layout(coordinator))
        controller.shiftVisibleTop(by: 40)
        let original = coordinator.mountedRange
        var ready = 2
        var targets: [Range<Int>] = []
        coordinator.pageReadiness = { range, _ in
            targets.append(range)
            return .init(count: ready, preparedPage: nil)
        }
        coordinator.userMoved(try #require(controller.geometry), delta: -10)
        #expect(coordinator.mountedRange.lowerBound == original.lowerBound - 2)
        #expect(coordinator.hasHistoryRequest)
        let newLayout = layout(coordinator)
        document.setFrameSize(NSSize(width: 640, height: CGFloat(newLayout.range.count) * 300))
        coordinator.receiveLayout(newLayout)
        for _ in 0..<10 { await Task.yield() }
        #expect(coordinator.pendingPage == nil)
        // Continue after the reader returns to the edge; the original target stays fixed.
        controller.shiftVisibleTop(by: -1_000)
        ready = 4
        coordinator.userMoved(try #require(controller.geometry), delta: -1_000)
        #expect(coordinator.mountedRange.lowerBound == original.lowerBound - 4)
        #expect(targets.count >= 2 && targets.first == targets.last)
        #expect(coordinator.hasHistoryRequest)
        coordinator.userMoved(try #require(controller.geometry), delta: 10)
        #expect(!coordinator.hasHistoryRequest)
    }

    @Test func readyHistoryMountsInTwoLayoutsDuringScroll() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 3_600))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        let original = layout(coordinator)
        coordinator.receiveLayout(original)
        var requests: [Range<Int>] = []
        coordinator.pageReadiness = { range, _ in
            requests.append(range)
            return .init(count: range.count, preparedPage: nil)
        }
        controller.userScrollDidMove()
        for batch in 1...2 {
            controller.shiftVisibleTop(by: 40 - (try #require(controller.geometry)).visibleTop)
            let current = try #require(controller.geometry)
            let anchor = try #require(coordinator.rowViewports.first)
            coordinator.userMoved(current, delta: -10)
            #expect(coordinator.mountedRange.lowerBound == original.range.lowerBound - batch * 4)
            #expect(coordinator.hasHistoryRequest == (batch == 1))

            let mounted = layout(coordinator)
            document.setFrameSize(NSSize(width: 640, height: CGFloat(mounted.rows.count) * 300))
            coordinator.receiveLayout(mounted)
            let retained = try #require(coordinator.rowViewports.first { $0.target == anchor.target })
            let settled = try #require(controller.geometry)
            #expect(abs(retained.minY - settled.visibleTop - (anchor.minY - current.visibleTop)) <= 0.5)
            #expect(coordinator.pendingPage == nil)
            // Recheck with the new geometry before simulating the next movement.
            coordinator.retryPreparedPage()
        }
        #expect(requests.count == 2 && requests.first == requests.last)
    }

    @Test func laterHistoryRevealsOnlyTheReadyContiguousRows() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 7_500))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.jump(to: 250)
        coordinator.receiveLayout(layout(coordinator))
        let original = coordinator.mountedRange
        controller.shiftVisibleTop(by: 6_850)
        coordinator.pageReadiness = { _, _ in .init(count: 3, preparedPage: nil) }
        coordinator.userMoved(try #require(controller.geometry), delta: 12)
        #expect(coordinator.mountedRange.upperBound == original.upperBound + 3)
        #expect(coordinator.hasHistoryRequest)
        #expect(coordinator.pendingPage != nil)
        coordinator.reset(sessionID: "two", totalCount: 500, bubbleCount: 500)
        #expect(!coordinator.hasHistoryRequest)
        #expect(coordinator.pendingPage == nil)
    }

    @Test func aPartialPageWaitsForHalfAPageUntilTheReaderNearsTheEdge() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 7_500))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.jump(to: 250)
        coordinator.receiveLayout(layout(coordinator))
        let original = coordinator.mountedRange
        // 500 points of mounted content remain below: inside the reveal distance, not urgent.
        controller.shiftVisibleTop(by: 6_400)
        var ready = 3
        coordinator.pageReadiness = { _, _ in .init(count: ready, preparedPage: nil) }
        coordinator.userMoved(try #require(controller.geometry), delta: 12)
        #expect(coordinator.mountedRange == original)
        #expect(coordinator.pendingPage == nil)
        #expect(coordinator.hasHistoryRequest)
        // Half a page mounts as one transaction.
        ready = ConversationMessageWindow.minimumPartialPage
        coordinator.retryPreparedPage()
        #expect(coordinator.mountedRange.upperBound == original.upperBound + ready)
        #expect(coordinator.pendingPage != nil)
    }

    @Test func wheelTicksRecheckAWaitingPageOnlyWhenItBecomesUrgent() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 7_500))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.jump(to: 250)
        coordinator.receiveLayout(layout(coordinator))
        let original = coordinator.mountedRange
        var checks = 0
        coordinator.pageReadiness = { _, _ in
            checks += 1
            return .init(count: 1, preparedPage: nil)
        }

        controller.shiftVisibleTop(by: 6_400)
        coordinator.userMoved(try #require(controller.geometry), delta: 12)
        for _ in 0..<10 {
            controller.shiftVisibleTop(by: 8)
            coordinator.userMoved(try #require(controller.geometry), delta: 8)
        }
        #expect(checks == 1)
        #expect(coordinator.mountedRange == original)

        controller.shiftVisibleTop(by: 150)
        coordinator.userMoved(try #require(controller.geometry), delta: 150)
        #expect(checks == 2)
        #expect(coordinator.mountedRange.upperBound == original.upperBound + 1)
    }

    @Test func partialPagePolicyMountsWholePagesHalfPagesAndUrgentRows() {
        let policy = ConversationMessageWindow.mountsPartialPage
        #expect(!policy(0, true, 0, 600))
        #expect(policy(2, true, 500, 600))
        #expect(policy(ConversationMessageWindow.minimumPartialPage, false, 500, 600))
        #expect(!policy(1, false, 300, 600))
        #expect(policy(1, false, 299, 600))
    }

    @Test func repinningMidGestureCompactsOnlyOnceTheScrollSettles() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 6_600))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.jump(to: 490, afterLayout: {})
        coordinator.receiveLayout(layout(coordinator))
        let widened = coordinator.mountedRange
        #expect(widened.upperBound == 500 && widened.count > ConversationMessageWindow.initialLimit)
        controller.shiftVisibleTop(by: 6_000)
        coordinator.userMoved(try #require(controller.geometry), delta: 12)
        #expect(coordinator.presentation.isAtBottom)
        #expect(coordinator.mountedRange == widened)
        coordinator.settled(try #require(controller.geometry))
        #expect(coordinator.mountedRange == ConversationMessageWindow.compactedRange(totalCount: 500))
    }

    @Test func historyDoesNotMountAnUnpreparedPageAfterOneSecond() async throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 3_600))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.receiveLayout(layout(coordinator))
        controller.shiftVisibleTop(by: 40)
        let original = coordinator.mountedRange
        var ready = false
        coordinator.pageReadiness = { range, _ in
            .init(count: ready ? range.count : 0, preparedPage: nil)
        }
        coordinator.userMoved(try #require(controller.geometry), delta: -10)
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(coordinator.mountedRange == original)
        #expect(coordinator.pendingPage == nil)
        ready = true
        coordinator.retryPreparedPage()
        #expect(coordinator.mountedRange.lowerBound == original.lowerBound - ConversationMessageWindow.pageSize)
        #expect(coordinator.pendingPage != nil)
    }

    @Test func settleCannotCompleteAnUnlaidOutPageAndOldGeometryCannotRestoreIt() async throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 3_600))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        let original = layout(coordinator)
        coordinator.receiveLayout(original)
        controller.shiftVisibleTop(by: 40)
        coordinator.userMoved(try #require(controller.geometry), delta: -10)
        let page = try #require(coordinator.pendingPage)
        coordinator.settled(try #require(controller.geometry))
        #expect(coordinator.pendingPage?.generation == page.generation)
        coordinator.receiveLayout(original)
        #expect(coordinator.performance.anchorCorrections == 0)
        // Another upward delta arrives while the new rows are being measured.
        controller.shiftVisibleTop(by: -20)
        coordinator.userMoved(try #require(controller.geometry), delta: -20)
        let updated = layout(coordinator)
        document.setFrameSize(NSSize(width: 640, height: CGFloat(updated.range.count) * 300))
        coordinator.receiveLayout(updated)
        for _ in 0..<5 { await Task.yield() }
        let anchor = try #require(updated.rows.first { $0.target.messageID == page.anchor.messageID })
        #expect(abs(anchor.minY - (controller.geometry?.visibleTop ?? 0) + 20) < 1)
        #expect(coordinator.pendingPage == nil)
        #expect(coordinator.performance.pageTransactions == 1)
        #expect(coordinator.performance.anchorCorrections == 1)
    }

    @Test func sessionReplacementAndExplicitNavigationRejectOldTransactions() throws {
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.receiveLayout(layout(coordinator))
        coordinator.userMoved(
            .init(visibleTop: 40, visibleHeight: 600, documentHeight: 3_600), delta: -20)
        let stale = layout(coordinator)
        #expect(coordinator.pendingPage != nil)
        coordinator.reset(sessionID: "two", totalCount: 500, bubbleCount: 500)
        coordinator.receiveLayout(stale)
        #expect(coordinator.rowViewports.isEmpty)
        #expect(coordinator.pendingPage == nil)
        coordinator.jump(to: 250)
        #expect(coordinator.mountedRange == 238..<263)
        #expect(!coordinator.presentation.isAtBottom)
        coordinator.jumpToLatest(reduceMotion: true)
        #expect(coordinator.mountedRange == 488..<500)
        #expect(coordinator.presentation.isAtBottom)
    }

    @Test func prependKeepsMountedIdentityAndDoesNotCancelAnUnloadedNavigatorRequest() {
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.reset(sessionID: "one", totalCount: 100, bubbleCount: 100)
        coordinator.jump(to: 20)
        let original = coordinator.mountedRange
        let navigation = coordinator.navigationGeneration
        coordinator.messagesChanged(
            oldCount: 100, newCount: 120, bubbleCount: 120,
            prepend: .init(generation: 1, count: 20, resultingCount: 120))
        #expect(coordinator.mountedRange == (original.lowerBound + 20)..<(original.upperBound + 20))
        #expect(coordinator.navigationGeneration == navigation)
        #expect(coordinator.presentation.unseenMessageCount == 0)
    }

    @Test func aLargeSameSessionReplacementKeepsAShortTranscriptMounted() {
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.jump(to: 450)
        coordinator.messagesChanged(oldCount: 500, newCount: 3, bubbleCount: 3, prepend: nil)
        #expect(coordinator.mountedRange == 0..<3)
        coordinator.receiveLayout(layout(coordinator))
        #expect(coordinator.rowViewports.count == 3)
        #expect(coordinator.pendingPage == nil)
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.jump(to: 450)
        coordinator.messagesChanged(oldCount: 500, newCount: 100, bubbleCount: 100, prepend: nil)
        #expect(coordinator.mountedRange == 88..<100)
    }

    @Test func settlingProgrammaticGeometryNeverStartsAnotherPage() {
        let coordinator = ConversationTranscriptCoordinator()
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        coordinator.receiveLayout(layout(coordinator))
        let edge = ConversationScrollGeometry(visibleTop: 40, visibleHeight: 600, documentHeight: 3_600)
        coordinator.settled(edge)
        #expect(coordinator.performance.pageTransactions == 0)
        coordinator.userMoved(edge, delta: -10)
        #expect(coordinator.performance.pageTransactions == 1)
        coordinator.settled(edge)
        #expect(coordinator.performance.pageTransactions == 1)
    }

    @Test func navigationWaitsForItsOwnLayoutAndCancellationRejectsIt() async {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 3_600))
        controller.clipView = scroll.contentView
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500)
        let stale = layout(coordinator)
        var jumps = 0
        coordinator.jump(to: 200) { jumps += 1 }
        coordinator.receiveLayout(stale)
        for _ in 0..<5 { await Task.yield() }
        #expect(jumps == 0)
        coordinator.receiveLayout(layout(coordinator))
        for _ in 0..<5 { await Task.yield() }
        #expect(jumps == 1)
        coordinator.jump(to: 300) { jumps += 1 }
        coordinator.receiveLayout(layout(coordinator))
        coordinator.reset(sessionID: "two", totalCount: 10, bubbleCount: 10)
        for _ in 0..<5 { await Task.yield() }
        #expect(jumps == 1)
        coordinator.messagesChanged(oldCount: 10, newCount: 3, bubbleCount: 3, prepend: nil)
        #expect(coordinator.mountedRange.upperBound <= 3)
    }

    @Test func firstMessagesLandAtTheTailOnceTheirRowsHaveLaidOut() async throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 3_600))
        controller.clipView = scroll.contentView
        let initialTop = try #require(controller.geometry).visibleTop
        coordinator.reset(sessionID: "opening", totalCount: 0, bubbleCount: 0)
        coordinator.messagesChanged(oldCount: 0, newCount: 500, bubbleCount: 500, prepend: nil)

        coordinator.contentResized()
        for _ in 0..<10 { await Task.yield() }
        #expect(controller.geometry?.visibleTop == initialTop)

        coordinator.receiveLayout(layout(coordinator))
        #expect(controller.geometry?.distanceToBottom == 0)
    }

    private func messages() -> [ChatMessage] {
        identities.map { ChatMessage(id: $0, role: .hermes, text: "message") }
    }

    private func leaveAwayFromBottom(
        _ coordinator: ConversationTranscriptCoordinator, controller: ConversationScrollController, id: String
    ) {
        coordinator.reset(sessionID: id, totalCount: 500, bubbleCount: 500, messages: messages())
        coordinator.receiveLayout(layout(coordinator))
        controller.shiftVisibleTop(by: 40)
        coordinator.presentation.isAtBottom = false
    }

    @Test func sessionReturnRestoresTheReadingAnchor() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 20_000))
        controller.clipView = scroll.contentView
        leaveAwayFromBottom(coordinator, controller: controller, id: "one")
        let anchored = try #require(coordinator.mountedRange.first)
        coordinator.reset(sessionID: "two", totalCount: 500, bubbleCount: 500, messages: messages())
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500, messages: messages())
        #expect(coordinator.mountedRange.contains(anchored))
        #expect(coordinator.pendingPage?.anchor.messageID == identities[anchored])
        #expect(coordinator.pendingPage?.anchor.offset == -40)
        #expect(!coordinator.presentation.isAtBottom)
    }

    @Test func restoredAnchorStaysPinnedWhileRowsAboveSettle() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 20_000))
        controller.clipView = scroll.contentView
        leaveAwayFromBottom(coordinator, controller: controller, id: "one")
        coordinator.reset(sessionID: "two", totalCount: 500, bubbleCount: 500, messages: messages())
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500, messages: messages())
        let anchor = try #require(coordinator.pendingPage?.anchor)
        coordinator.receiveLayout(layout(coordinator))
        #expect(coordinator.pendingPage == nil)
        let grown = { (by: CGFloat) in
            let base = self.layout(coordinator)
            return ConversationTranscriptLayout(
                sessionID: base.sessionID, generation: base.generation, range: base.range,
                rows: base.rows.map {
                    MessageNavigatorViewport(target: $0.target, index: $0.index, minY: $0.minY + by, maxY: $0.maxY + by)
                })
        }
        // A row above the anchor finishes measuring 30pt taller.
        coordinator.receiveLayout(grown(30))
        let row = try #require(grown(30).rows.first { $0.target.messageID == anchor.messageID })
        let top = try #require(controller.geometry).visibleTop
        #expect(row.minY - top == anchor.offset)
        // Once the reader scrolls, later layout changes no longer move the view.
        coordinator.userMoved(try #require(controller.geometry), delta: 5)
        coordinator.receiveLayout(grown(60))
        #expect(try #require(controller.geometry).visibleTop == top)
    }

    @Test func restoredAnchorLandsWhenTheSessionScrollViewAttachesAfterLayout() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 20_000))
        controller.clipView = scroll.contentView
        leaveAwayFromBottom(coordinator, controller: controller, id: "one")
        coordinator.reset(sessionID: "two", totalCount: 500, bubbleCount: 500, messages: messages())
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500, messages: messages())
        let anchor = try #require(coordinator.pendingPage?.anchor)
        // The per-session scroll view is replaced; its first layout precedes the attach.
        controller.clipView = nil
        coordinator.receiveLayout(layout(coordinator))
        #expect(coordinator.pendingPage != nil)
        let fresh = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        fresh.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 20_000))
        controller.clipView = fresh.contentView
        coordinator.contentResized()
        #expect(coordinator.pendingPage == nil)
        let row = try #require(layout(coordinator).rows.first { $0.target.messageID == anchor.messageID })
        #expect(row.minY - (try #require(controller.geometry).visibleTop) == anchor.offset)
    }

    @Test func sessionReturnRestoresAReparsedTranscriptByPosition() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 20_000))
        controller.clipView = scroll.contentView
        leaveAwayFromBottom(coordinator, controller: controller, id: "one")
        let anchored = try #require(coordinator.mountedRange.first)
        coordinator.reset(sessionID: "two", totalCount: 500, bubbleCount: 500, messages: messages())
        // The returning transcript was parsed again and carries new message ids.
        let reparsed = identities.map { _ in ChatMessage(role: .hermes, text: "message") }
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500, messages: reparsed)
        #expect(coordinator.pendingPage?.anchor.messageID == reparsed[anchored].id)
        #expect(coordinator.pendingPage?.anchor.offset == -40)
        #expect(!coordinator.presentation.isAtBottom)
    }

    @Test func sessionReturnWithoutAnAnchorMountsTheTail() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 20_000))
        controller.clipView = scroll.contentView
        let tail = ConversationMessageWindow.rangeForSessionReplacement(totalCount: 500)
        // At the bottom nothing is saved.
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500, messages: messages())
        coordinator.receiveLayout(layout(coordinator))
        coordinator.reset(sessionID: "two", totalCount: 500, bubbleCount: 500, messages: messages())
        coordinator.reset(sessionID: "one", totalCount: 500, bubbleCount: 500, messages: messages())
        #expect(coordinator.mountedRange == tail)
        #expect(coordinator.pendingPage == nil)
        // An anchored message that is no longer shown falls back to the tail.
        leaveAwayFromBottom(coordinator, controller: controller, id: "gone")
        coordinator.reset(sessionID: "two", totalCount: 500, bubbleCount: 500, messages: messages())
        coordinator.reset(
            sessionID: "gone", totalCount: 1, bubbleCount: 1, messages: [ChatMessage(role: .hermes, text: "new")])
        #expect(coordinator.pendingPage == nil)
        #expect(coordinator.presentation.isAtBottom)
    }

    @Test func savedReadingAnchorsAreCappedAtEightSessions() throws {
        let controller = ConversationScrollController()
        let coordinator = ConversationTranscriptCoordinator(controller: controller)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 20_000))
        controller.clipView = scroll.contentView
        for index in 0..<9 { leaveAwayFromBottom(coordinator, controller: controller, id: "s\(index)") }
        coordinator.reset(sessionID: "s0", totalCount: 500, bubbleCount: 500, messages: messages())
        #expect(coordinator.pendingPage == nil)
        #expect(coordinator.mountedRange == ConversationMessageWindow.rangeForSessionReplacement(totalCount: 500))
        coordinator.reset(sessionID: "s1", totalCount: 500, bubbleCount: 500, messages: messages())
        #expect(coordinator.pendingPage != nil)
    }

    @Test func invalidatingCancelsNativeRemainders() async throws {
        let controller = ConversationScrollController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 640, height: 800))
        scroll.documentView = document
        controller.clipView = scroll.contentView
        controller.shiftVisibleTop(by: 2_000)
        controller.cancelPendingAdjustments()
        document.setFrameSize(NSSize(width: 640, height: 4_000))
        for _ in 0..<5 { await Task.yield() }
        #expect(try #require(controller.geometry).visibleTop == 200)
    }
}
