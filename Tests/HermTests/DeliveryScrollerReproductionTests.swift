import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DeliveryScrollerReproductionTests {
    @Test func nativeScrollerInstallationPreservesTheSystemStyle() {
        _ = NSApplication.shared
        _ = NSScrollView.installDockScrollers
        #expect(DockScroller.isCompatibleWithOverlayScrollers)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 2000))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.orderOut(nil) }
        #expect(
            scroll.scrollerStyle == .legacy,
            "An always-visible system scrollbar must not become an autohiding overlay")
    }
}
