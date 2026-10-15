import AppKit
import SwiftUI
import Testing
@testable import Herm

@MainActor
struct ConversationScrollObserverTests {
    private final class Recorder {
        var deltas: [CGFloat] = []
        var settledTops: [CGFloat] = []
        var scrollsAwayFromBottom = 0
        var tailScrolls = 0
    }

    /// The observer must live inside the scrolled content: as a background of
    /// the ScrollView it is a sibling of the NSScrollView, never attaches, and
    /// history paging silently stops.
    @Test func observerAttachesAndReportsScrollDirection() async throws {
        let controller = ConversationScrollController()
        let recorder = Recorder()
        let tailScroll = ConversationTailScrollScheduler()
        defer { tailScroll.cancel() }
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
                        tailScroll.cancel()
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

        // Even a small upward movement must cancel a pending stream scroll
        // synchronously, before the 80ms settled callback.
        tailScroll.schedule { recorder.tailScrolls += 1 }
        let settledCount = recorder.settledTops.count
        let clip = try #require(controller.clipView)
        let document = try #require(clip.documentView)
        let offset: CGFloat = document.isFlipped ? -12 : 12
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + offset))
        #expect(recorder.scrollsAwayFromBottom == 1)
        #expect(recorder.settledTops.count == settledCount)
        try await Task.sleep(for: .milliseconds(160))
        #expect(recorder.tailScrolls == 0)

        recorder.deltas.removeAll()
        recorder.scrollsAwayFromBottom = 0
        controller.shiftVisibleTop(by: -geometry.visibleTop)
        #expect(recorder.deltas.contains { $0 < 0 })
        #expect(controller.geometry?.visibleTop ?? .infinity < 1)
        #expect(recorder.scrollsAwayFromBottom == 0, "History anchor restoration must not stop following the tail")
    }
}
