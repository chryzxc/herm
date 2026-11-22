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

    @Test(arguments: [false, true])
    func scrollingLeadingPaneStaysWithinLayoutBudget(wheel: Bool) async throws {
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
        let initialRows = seenRows
        var counts: [String: Int] = [:]
        DockHostLayoutTiming.layoutObserver = { counts[$0, default: 0] += 1 }
        defer {
            DockHostLayoutTiming.layoutObserver = nil
            DockScrollActivity.recordScroll(at: -.infinity)
        }

        for step in 1...Self.steps {
            if wheel { DockScrollActivity.recordScroll(at: ProcessInfo.processInfo.systemUptime) }
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

    @MainActor
    private final class Toggle: ObservableObject { @Published var expanded = true }

    private struct CollapsingPane: View {
        @ObservedObject var toggle: Toggle
        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        if toggle.expanded {
                            ForEach(0..<40, id: \.self) { Text("Pinned \($0)").frame(height: 40) }
                        }
                    } header: {
                        Text("Pinned").frame(height: 30)
                    }
                    Section {
                        ForEach(0..<5, id: \.self) { Text("Recent \($0)").frame(height: 40) }
                    } header: {
                        Text("Recents").frame(height: 30)
                    }
                }
            }
        }
    }

    /// A section collapse resizes the scroll content; the pane must lay it out at the new size.
    @Test func collapsingASectionResizesThePanesScrollContent() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        let toggle = Toggle()
        let root = DockWindowHostingView(
            rootView: AnyView(
                FullscreenPanelSplitView(leading: CollapsingPane(toggle: toggle), trailing: Text("Inspector"))))
        root.sizingOptions = []
        root.safeAreaRegions = []
        window.contentView = root
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<3 { try await settle(window) }
        let scrollView = try #require(Self.scrollViews(in: root).first)
        let expandedHeight = try #require(scrollView.documentView).frame.height
        // As the header does: an animated toggle, then only AppKit's own display cycle.
        var roles: [String] = []
        DockHostLayoutTiming.layoutObserver = { roles.append($0) }
        defer { DockHostLayoutTiming.layoutObserver = nil }
        withAnimation(.easeInOut(duration: 0.2)) { toggle.expanded = false }
        try await Task.sleep(for: .milliseconds(600))
        let collapsedHeight = try #require(scrollView.documentView).frame.height
        #expect(collapsedHeight < expandedHeight - 1000, "expanded \(expandedHeight), collapsed \(collapsedHeight)")
        // Once the animation settles, the pane stops invalidating and re-laying itself out.
        roles.removeAll()
        try await Task.sleep(for: .milliseconds(300))
        #expect(roles.isEmpty, "pane kept re-laying out after the collapse: \(roles.count) passes")
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
