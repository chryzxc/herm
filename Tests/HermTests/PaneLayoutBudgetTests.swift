import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Layout budget for scrolling inside a split pane.
///
/// Scrolling the transcript must not re-lay out the sibling pane, and the
/// root host's relayouts must stay bounded. Pane hosts keep SwiftUI's
/// per-commit `needsUpdateConstraints` from reaching the split's SwiftUI
/// parent (`containsConstraintInvalidation`), which halved root layouts.
/// The one root layout left per tick comes from SwiftUI itself:
/// `ScrollViewCommitMutation.apply` dirties an attribute in the root graph.
/// See docs/chat-performance.md.
@MainActor
@Suite("Pane layout budget", .serialized)
struct PaneLayoutBudgetTests {
    private static let steps = 30
    /// Measured 20 November 2026 over 30 steps: root 62 before pane hosts
    /// contained constraint invalidation, 30 after; panelLeading 30,
    /// panelTrailing 0.
    private static let rootLayoutsPerStep = 1
    private static let slack = 2

    private struct Shell: View {
        var body: some View {
            VStack(spacing: 0) {
                Text("Header").frame(height: 52)
                FullscreenPanelSplitView(
                    leading: ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(0..<400, id: \.self) { index in
                                Text("Row \(index) with some text that wraps across the width of the pane")
                                    .padding(8)
                            }
                        }
                    },
                    trailing: VStack {
                        ForEach(0..<30, id: \.self) { Text("Inspector \($0)") }
                    }
                )
            }
        }
    }

    @Test func scrollingLeadingPaneStaysWithinLayoutBudget() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        let root = DockWindowHostingView(rootView: AnyView(Shell()))
        root.sizingOptions = []
        root.safeAreaRegions = []
        window.contentView = root
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 { try await settle(window) }

        let scrollView = try #require(Self.scrollViews(in: root).first)
        var counts: [String: Int] = [:]
        DockHostLayoutTiming.layoutObserver = { counts[$0, default: 0] += 1 }
        defer { DockHostLayoutTiming.layoutObserver = nil }

        for step in 1...Self.steps {
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 40))
            scrollView.reflectScrolledClipView(clip)
            try await settle(window)
        }

        #expect(counts["panelTrailing", default: 0] == 0, "sibling pane re-laid out while scrolling: \(counts)")
        #expect(
            counts["panelLeading", default: 0] <= Self.steps + Self.slack,
            "scrolled pane re-laid out more than once per step: \(counts)")
        #expect(
            counts["root", default: 0] <= Self.steps * Self.rootLayoutsPerStep + Self.slack,
            "root host re-laid out more than \(Self.rootLayoutsPerStep)× per scroll step: \(counts)")
    }

    private func settle(_ window: NSWindow) async throws {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(17))
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
