import AppKit
import SwiftUI

/// Standalone reproduction against the real DockScroller when the package's first build is too slow.
/// Compile with Sources/Herm/DesignSystem/DockScroller.swift; this file is outside the package test target.
@main
struct ConversationScrollbarReproduction {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        _ = NSScrollView.installDockScrollers
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 2000))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        defer { window.orderOut(nil) }
        var failures = 0
        if scroll.scrollerStyle != .legacy {
            print("FAIL: mounting a scroll view replaces explicit legacy system scrolling with overlay scrolling")
            failures += 1
        } else {
            print("PASS: mounting preserves explicit legacy system scrolling")
        }
        let split = FractionPreservingSplitView()
        let overlayCompatible = DockScroller.isCompatibleWithOverlayScrollers
        print("OVERLAY_COMPATIBLE=\(overlayCompatible)")
        split.isVertical = true
        split.fraction = 0.6
        let host = NSHostingView(
            rootView: ScrollView {
                VStack { ForEach(0..<100) { Text("Conversation message \($0)").frame(maxWidth: .infinity) } }
            })
        host.sizingOptions = []
        split.addArrangedSubview(host)
        split.addArrangedSubview(NSView())
        window.contentView = split
        window.setContentSize(NSSize(width: 900, height: 600))
        if !overlayCompatible {
            print("FAIL: DockScroller does not declare compatibility with the overlay style it installs")
            failures += 1
        }
        for collapsed in [false, true, false] {
            split.setTrailingCollapsed(collapsed)
            for _ in 0..<5 {
                split.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
            guard let nativeScroll = descendantScroll(host), let scroller = nativeScroll.verticalScroller else {
                print("FAIL: missing native conversation scroller; collapsed=\(collapsed)")
                failures += 1
                continue
            }
            let frame = scroller.convert(scroller.bounds, to: split)
            let inHost = scroller.convert(scroller.bounds, to: host)
            let visible = inHost.intersection(host.bounds)
            print(
                "SCROLLER collapsed=\(collapsed) frame=\(frame) visible=\(visible) "
                    + "hidden=\(scroller.isHidden) style=\(nativeScroll.scrollerStyle.rawValue)")
            if visible.width < 1 || frame.maxX > split.bounds.maxX + 1 {
                print("FAIL: conversation scroller clipped when collapsed=\(collapsed)")
                failures += 1
            }
        }
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    static func descendantScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { descendantScroll($0) }.first
    }
}
