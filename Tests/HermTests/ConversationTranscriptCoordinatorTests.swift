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
        coordinator.isPageReady = { _, _ in ready }
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
        coordinator.isPageReady = { _, _ in ready }
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
        let coordinator = ConversationTranscriptCoordinator()
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
