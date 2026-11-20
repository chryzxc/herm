import AppKit
import SwiftUI
import Testing

@testable import Herm

/// The scrolled pane can invalidate its constraints while its sibling stays idle.
@MainActor
@Suite("Pane layout budget", .serialized)
struct PaneLayoutBudgetTests {
    private static let steps = 30
    private static let slack = 2

    private struct Shell: View {
        let onAppearRow: (Int) -> Void

        var body: some View {
            VStack(spacing: 0) {
                Text("Header").frame(height: 52)
                FullscreenPanelSplitView(
                    leading: ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(0..<400, id: \.self) { index in
                                Text("Row \(index) with some text that wraps across the width of the pane")
                                    .padding(8)
                                    .onAppear { onAppearRow(index) }
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

    @Test func paneSchedulesConstraintUpdates() throws {
        let pane = splitPaneHost()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = pane
        window.layoutIfNeeded()
        pane.updateConstraintsForSubtreeIfNeeded()
        try #require(!pane.needsUpdateConstraints)
        pane.needsUpdateConstraints = true
        #expect(pane.needsUpdateConstraints)
    }

    @Test func unchangedLeadingContentSkipsDeliveryUntilPresentationChanges() {
        let split = FullscreenPanelSplitView(leading: Text("Chats"), trailing: EmptyView())
        let coordinator = split.makeCoordinator()
        var environment = EnvironmentValues()
        let text = Text("Chats")
        #expect(coordinator.acceptsLeading(text, environment: environment, collapsed: false, matches: ==))
        #expect(!coordinator.acceptsLeading(text, environment: environment, collapsed: false, matches: ==))
        environment.dockWorkspaceScale = 1.5
        #expect(coordinator.acceptsLeading(text, environment: environment, collapsed: false, matches: ==))
        #expect(coordinator.acceptsLeading(text, environment: environment, collapsed: true, matches: ==))
        #expect(coordinator.acceptsLeading(Text("Bots"), environment: environment, collapsed: true, matches: ==))
    }

    @Test func scrollingLeadingPaneStaysWithinLayoutBudget() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        var seenRows = Set<Int>()
        let root = DockWindowHostingView(rootView: AnyView(Shell { seenRows.insert($0) }))
        root.sizingOptions = []
        root.safeAreaRegions = []
        window.contentView = root
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 { try await settle(window) }

        let scrollView = try #require(Self.scrollViews(in: root).first)
        let scrollPoint = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
        let initialRows = seenRows
        var counts: [String: Int] = [:]
        DockHostLayoutTiming.layoutObserver = { counts[$0, default: 0] += 1 }
        defer {
            DockHostLayoutTiming.layoutObserver = nil
            DockScrollActivity.recordScroll(in: nil, at: .zero, now: -.infinity)
        }

        for step in 1...Self.steps {
            DockScrollActivity.recordScroll(in: window, at: scrollPoint, now: ProcessInfo.processInfo.systemUptime)
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 40))
            scrollView.reflectScrolledClipView(clip)
            try await settle(window)
        }

        #expect(!seenRows.subtracting(initialRows).isEmpty, "new rows never appeared while the pane was scrolling")
        #expect(counts["panelTrailing", default: 0] == 0, "sibling pane re-laid out while scrolling: \(counts)")
        #expect(
            counts["panelLeading", default: 0] <= Self.steps + Self.slack,
            "scrolled pane re-laid out more than once per step: \(counts)")
        #expect(
            counts["root", default: 0] <= Self.steps + Self.slack,
            "scrolling the pane scheduled an extra outer layout per step: \(counts)")
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
