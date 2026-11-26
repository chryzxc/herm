import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct SessionSidebarScrollInteractionTests {
    @Test func pinnedHeaderAcceptsClicksWhileRowHitTestingIsPaused() async throws {
        _ = NSApplication.shared
        var headerClicks = 0
        var rowClicks = 0
        let view = HoverPausingScrollView(usesAppKitScrollPhase: true, pausesAllHitTesting: false) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    Group {
                        Text("Conversation")
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture { rowClicks += 1 }
                        Color.clear.frame(height: 400)
                    }
                    .dockPauseHitTestingWhileScrolling()
                } header: {
                    Text("Pinned")
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .onTapGesture { headerClicks += 1 }
                }
            }
        }
        .frame(width: 300, height: 400)
        let frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        let window = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.alphaValue = 0
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let scroll = try #require(scrollView(in: host))
        let notifications = NotificationCenter.default

        try click(y: 385, in: window)
        try click(y: 348, in: window)
        #expect(headerClicks == 1)
        #expect(rowClicks == 1)

        notifications.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        try await Task.sleep(for: .milliseconds(50))
        try click(y: 385, in: window)
        try click(y: 348, in: window)
        #expect(headerClicks == 2)
        #expect(rowClicks == 1)

        notifications.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await Task.sleep(for: .milliseconds(50))
        try click(y: 348, in: window)
        #expect(rowClicks == 2)
    }

    private func click(y: CGFloat, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 150, y: y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
