import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
@Suite(.serialized)
struct DockTitleRowHitTests {
    @Test(arguments: [900.0, 1280.0], [false, true])
    func toolbarIconDoesNotOfferToDragWindow(width: Double, dark: Bool) async throws {
        _ = NSApplication.shared
        var refreshes = 0
        let root = VStack(spacing: 0) {
            DockPageHeader(title: "Settings", subtitle: "Preferences", onRefresh: { refreshes += 1 }) {
                EmptyView()
            }
            Spacer()
        }
        .environment(\.dockTitleRow, DockTitleRow(height: 52, leadingClearance: 80))
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: width, height: 600)
        .dockThemedRoot()
        let host = splitPaneHost()
        host.rootView = AnyView(root)
        host.safeAreaRegions = []
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: width, height: 600),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "toolbar-icon-drag-test")
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
        let dragRect = host.convert(strip.bounds, from: strip)
        let iconPoint = NSPoint(x: host.bounds.maxX - 26, y: dragRect.midY)
        let hit = try #require(host.hitTest(host.convert(iconPoint, to: host.superview)))
        #expect(!(hit is TitlebarDoubleClickArea.Strip))
        #expect(!hit.mouseDownCanMoveWindow)
        let blankPoint = strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: host.superview)
        let blankHit = try #require(host.hitTest(blankPoint))
        #expect(blankHit is TitlebarDoubleClickArea.Strip)
        #expect(blankHit.mouseDownCanMoveWindow)
        let origin = window.frame.origin
        for (type, offset) in [
            (NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, 40.0), (.leftMouseUp, 40.0),
        ] {
            let point = host.convert(NSPoint(x: iconPoint.x + offset, y: iconPoint.y), to: nil)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(window.frame.origin == origin)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: host.convert(iconPoint, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(refreshes == 1)
    }

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
