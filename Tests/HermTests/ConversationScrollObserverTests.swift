import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ConversationScrollObserverTests {
    private final class TranscriptContent: ObservableObject {
        @Published var tailHeight: CGFloat = 40
        @Published var viewportHeight: CGFloat = 400
    }

    private struct GrowingTranscript: View {
        @ObservedObject var content: TranscriptContent
        let controller: ConversationScrollController
        let presentation: ConversationScrollPresentationState

        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { index in
                        Text("Row \(index)").frame(height: 40)
                    }
                    Color.clear.frame(height: content.tailHeight)
                    Color.clear.frame(height: 1)
                }
                .background {
                    ConversationScrollEventObserver(
                        controller: controller,
                        onScroll: { geometry, delta in
                            if delta > 0, geometry.distanceToBottom <= ConversationScrollMetrics.pastEndTolerance {
                                presentation.updatePosition(geometry, isLiveTail: true)
                            }
                        },
                        onScrollSettled: { presentation.updatePosition($0, isLiveTail: true) },
                        onScrollAwayFromBottom: { presentation.isAtBottom = false },
                        onContentResize: {
                            if presentation.isAtBottom { controller.scrollToBottom() }
                        }
                    )
                }
            }
            .frame(width: 300, height: content.viewportHeight)
        }
    }

    private final class Recorder {
        var deltas: [CGFloat] = []
        var settledTops: [CGFloat] = []
        var scrollsAwayFromBottom = 0
    }

    /// The observer must live inside the scrolled content: as a background of
    /// the ScrollView it is a sibling of the NSScrollView, never attaches, and
    /// history paging silently stops.
    @Test func observerAttachesAndReportsScrollDirection() async throws {
        let controller = ConversationScrollController()
        let recorder = Recorder()
        let presentation = ConversationScrollPresentationState()
        let content = ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<80, id: \.self) { index in
                    Text("Row \(index)").frame(height: 40)
                }
            }
            .frame(maxWidth: .infinity)
            .background {
                ConversationScrollEventObserver(
                    controller: controller,
                    onScroll: { _, delta in recorder.deltas.append(delta) },
                    onScrollSettled: { geometry in recorder.settledTops.append(geometry.visibleTop) },
                    onScrollAwayFromBottom: {
                        recorder.scrollsAwayFromBottom += 1
                        presentation.isAtBottom = false
                    }
                )
            }
        }
        .defaultScrollAnchor(.bottom)
        .frame(width: 300, height: 400)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let geometry = try #require(controller.geometry)
        #expect(geometry.documentHeight > 3000)
        #expect(geometry.distanceToBottom < 1)
        #expect(!recorder.settledTops.isEmpty)

        // Even a small upward movement must stop follow synchronously,
        // before the 80ms settled callback.
        let settledCount = recorder.settledTops.count
        let clip = try #require(controller.clipView)
        let document = try #require(clip.documentView)
        let offset: CGFloat = document.isFlipped ? -0.5 : 0.5
        for _ in 0..<3 {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + offset))
        }
        #expect(recorder.scrollsAwayFromBottom == 1)
        #expect(!presentation.isAtBottom)
        #expect(controller.isUserScrolling)
        #expect(recorder.settledTops.count == settledCount)

        recorder.deltas.removeAll()
        recorder.scrollsAwayFromBottom = 0
        controller.shiftVisibleTop(by: -geometry.visibleTop)
        #expect(recorder.deltas.isEmpty, "Anchor corrections must not trigger edge paging")
        #expect(controller.geometry?.visibleTop ?? .infinity < 1)
        #expect(recorder.scrollsAwayFromBottom == 0, "History anchor restoration must not stop following the tail")
        // The 80ms settle timer runs late on a loaded CI runner.
        for _ in 0..<200 where controller.isUserScrolling { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isUserScrolling)
        controller.shiftVisibleTop(by: 40)
        #expect(!controller.isUserScrolling, "Programmatic anchor corrections must not pause live rendering")
    }

    @Test func resizeClampingDoesNotBecomeUserScrollOrRequestAnotherPage() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 4_000))
        scroll.documentView = document
        let controller = ConversationScrollController()
        var deltas: [CGFloat] = []
        let observer = ConversationScrollEventObserver.Coordinator(
            controller: controller, onScroll: { _, delta in deltas.append(delta) },
            onScrollSettled: { _ in }
        )
        observer.attachIfNeeded(from: document)
        defer { observer.detach() }
        document.setFrameSize(NSSize(width: 300, height: 2_000))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(deltas.isEmpty)
        #expect(!controller.isUserScrolling)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        #expect(!deltas.isEmpty)
        #expect(controller.isUserScrolling)
    }

    @Test func aSilentResizePreservesTheNextGestureButNeverInventsOne() {
        let previous = ConversationScrollGeometry(visibleTop: 200, visibleHeight: 600, documentHeight: 3_000)
        let grown = ConversationScrollGeometry(visibleTop: 600, visibleHeight: 600, documentHeight: 3_400)
        #expect(grown.userScrollDelta(from: previous, isFlipped: false) == 0)
        let preservingTop = ConversationScrollGeometry(visibleTop: 200, visibleHeight: 600, documentHeight: 3_400)
        #expect(preservingTop.userScrollDelta(from: previous, isFlipped: false) == 0)
        #expect(preservingTop.userScrollDelta(from: previous, isFlipped: true) == 0)
        let atBottom = ConversationScrollGeometry(visibleTop: 2_800, visibleHeight: 600, documentHeight: 3_400)
        #expect(atBottom.userScrollDelta(from: previous, isFlipped: false) == 2_200)
        #expect(atBottom.userScrollDelta(from: previous, isFlipped: true) == 2_600)
        let shrinkClamp = ConversationScrollGeometry(visibleTop: 0, visibleHeight: 600, documentHeight: 2_000)
        #expect(shrinkClamp.userScrollDelta(from: previous, isFlipped: false) == 0)
        let oldBottom = ConversationScrollGeometry(visibleTop: 2_400, visibleHeight: 600, documentHeight: 3_000)
        let newBottom = ConversationScrollGeometry(visibleTop: 1_400, visibleHeight: 600, documentHeight: 2_000)
        #expect(newBottom.userScrollDelta(from: oldBottom, isFlipped: true) == 0)
    }

    @Test func streamingGrowthFollowsOnlyWhileAtTheBottom() async throws {
        let content = TranscriptContent()
        let controller = ConversationScrollController()
        let presentation = ConversationScrollPresentationState()
        let host = NSHostingView(
            rootView: GrowingTranscript(
                content: content, controller: controller, presentation: presentation
            ))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func waitForLayout(_ stage: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(2)
            repeat {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < deadline
            #expect(
                condition(),
                "\(stage): geometry=\(String(describing: controller.geometry)), following=\(presentation.isAtBottom)")
        }

        try await waitForLayout("Initial bottom") {
            controller.geometry.map { $0.documentHeight > 1_000 && $0.distanceToBottom < 1 } ?? false
        }
        content.tailHeight += 2_000
        try await waitForLayout("Follow growth") {
            controller.geometry.map { $0.documentHeight > 3_000 && $0.distanceToBottom < 1 } ?? false
        }
        #expect(presentation.isAtBottom)

        content.viewportHeight = 320
        try await waitForLayout("Follow viewport resize") {
            controller.geometry.map { $0.visibleHeight == 320 && $0.distanceToBottom < 1 } ?? false
        }

        let clip = try #require(controller.clipView)
        let document = try #require(clip.documentView)
        let offset: CGFloat = document.isFlipped ? -200 : 200
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + offset))
        #expect(!presentation.isAtBottom)
        let readingTop = try #require(controller.geometry).visibleTop
        content.tailHeight += 400
        content.viewportHeight = 280
        try await waitForLayout("Growth and resize while reading history") {
            controller.geometry.map { $0.documentHeight > 3_400 && $0.visibleHeight == 280 } ?? false
        }
        try await Task.sleep(for: .milliseconds(160))
        #expect(abs((controller.geometry?.visibleTop ?? 0) - readingTop) < 1)
        #expect(!presentation.isAtBottom)

        let bottom = document.isFlipped ? document.bounds.height - clip.bounds.height : 0
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bottom))
        #expect(presentation.isAtBottom, "Returning to the bottom must resume follow before another delta arrives")
        content.tailHeight += 400
        try await waitForLayout("Follow after returning to bottom") {
            controller.geometry.map { $0.documentHeight > 3_800 && $0.distanceToBottom < 1 } ?? false
        }
        #expect(presentation.isAtBottom)
    }
}
