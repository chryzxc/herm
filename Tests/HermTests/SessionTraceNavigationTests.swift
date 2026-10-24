import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionTraceNavigationTests {
    @Test func offscreenStepsKeepNavigationAtBothEdges() throws {
        let viewport = CGRect(x: 92_000, y: 0, width: 400, height: 34)
        let earlier = SessionTraceBarLayout(offset: 2_207, elapsed: 1, scale: 12, contentWidth: 100_000)
        #expect(earlier.offscreen(in: viewport) == .earlier)
        let revealed = CGRect(
            x: try #require(earlier.revealOffset(in: viewport, contentWidth: 100_000)),
            y: 0, width: viewport.width, height: viewport.height)
        #expect(earlier.offscreen(in: revealed) == nil)

        let later = SessionTraceBarLayout(offset: 7_800, elapsed: 1, scale: 12, contentWidth: 100_000)
        #expect(later.offscreen(in: revealed) == .later)
        #expect(later.revealOffset(in: viewport, contentWidth: 100_000) == 93_588)
    }

    @Test func visibleAndInstantStepsDoNotMoveTheViewport() {
        let viewport = CGRect(x: 100, y: 0, width: 400, height: 34)
        for (offset, elapsed) in [(100.0, 0.0), (98, 0), (0, 600), (499, 20)] {
            let bar = SessionTraceBarLayout(offset: offset, elapsed: elapsed, scale: 1, contentWidth: 1_000)
            #expect(bar.width >= 4)
            #expect(bar.offscreen(in: viewport) == nil)
            #expect(bar.revealOffset(in: viewport, contentWidth: 1_000) == nil)
        }
        let fitted = SessionTraceBarLayout(offset: 7_800, elapsed: 0, scale: 0.04, contentWidth: 400)
        #expect(fitted.width == 4)
        #expect(fitted.revealOffset(in: CGRect(x: 0, y: 0, width: 400, height: 34), contentWidth: 400) == nil)
        let tail = SessionTraceBarLayout(offset: 995, elapsed: 5, scale: 1, contentWidth: 1_000)
        #expect(tail.revealOffset(in: viewport, contentWidth: 1_000) == 600)
    }

    @Test func selectionAndFitMoveTheNativeHorizontalViewport() {
        let native = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 100_000, height: 200))
        native.documentView = document
        let host = NSView(frame: document.bounds)
        document.addSubview(host)
        let scroll = SessionTraceScroll()
        scroll.host = host
        native.contentView.scroll(to: NSPoint(x: 92_000, y: 0))
        let bar = SessionTraceBarLayout(offset: 2_207, elapsed: 1, scale: 12, contentWidth: 100_000)
        scroll.reveal(bar)
        #expect(native.contentView.bounds.minX == 26_472)
        #expect(bar.offscreen(in: native.contentView.bounds) == nil)
        scroll.reset()
        #expect(native.contentView.bounds.minX == 0)
    }

    @Test func initialSelectionRevealsItsBarAfterTheScrollViewMounts() async throws {
        let start = Date().addingTimeInterval(-7_800)
        let rows = [
            SessionTraceRow(id: "model", kind: .model, title: "Model", start: start, duration: 15, timing: .observed),
            SessionTraceRow(
                id: "earlier", kind: .tool, title: "Earlier step", start: start.addingTimeInterval(2_207),
                duration: 1, timing: .runtime),
            SessionTraceRow(
                id: "live", kind: .compaction, title: "Compacting context", start: start.addingTimeInterval(7_690),
                timing: .observed, active: true),
        ]
        let host = NSHostingView(
            rootView: SessionTraceCanvas(
                turns: [.init(id: "long", title: "Long request", start: start, rows: rows)],
                connected: true, isVisible: false, initialSelectionID: "earlier", listMaxHeight: 240))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 640)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        func horizontal(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView,
                (scroll.documentView?.bounds.width ?? 0) > scroll.contentView.bounds.width
            {
                return scroll
            }
            return view.subviews.lazy.compactMap(horizontal).first
        }
        let viewport = try #require(horizontal(host)).contentView.bounds
        let bar = SessionTraceBarLayout(offset: 2_207, elapsed: 1, scale: 12, contentWidth: 100_000)
        #expect(viewport.minX == 26_472)
        #expect(bar.offscreen(in: viewport) == nil)
    }
}
