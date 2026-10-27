import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockTitleRowHitTests {
    @Test func pageHeaderDragRegionLeavesActionsOutsideItsBounds() async throws {
        let root = VStack(spacing: 0) {
            DockPageHeader(title: "Settings", subtitle: "Preferences", onRefresh: {}) {
                Button("Action") {}.buttonStyle(.dockSecondary)
            }
            Spacer()
        }
        .environment(\.dockTitleRow, DockTitleRow(height: 52, leadingClearance: 80))
        .frame(width: 900, height: 600)
        .dockThemedRoot()
        let host = NSHostingView(rootView: root)
        host.safeAreaRegions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "header-hit-test")
        window.toolbarStyle = .unified
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
        }
        func strips(_ view: NSView) -> [NSView] {
            (view is TitlebarDoubleClickArea.Strip ? [view] : []) + view.subviews.flatMap(strips)
        }
        let strip = try #require(strips(host).first)
        let rect = host.convert(strip.bounds, from: strip)
        #expect(rect.minX > 100)
        #expect(rect.maxX < 800)
        #expect(rect.height <= 52)
    }
}
