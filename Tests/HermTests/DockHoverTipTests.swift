import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct DockHoverTipTests {
    @Test func placementKeepsEveryEdgeClearOfTheControl() {
        let screen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        let anchor = CGRect(x: -650, y: 450, width: 28, height: 28)
        for edge in [Edge.top, .bottom, .leading, .trailing] {
            let frame = DockHoverTipPlacement.frame(
                anchor: anchor, size: CGSize(width: 240, height: 54),
                edge: edge, gap: 6, visibleFrame: screen)
            #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
            #expect(!frame.intersects(anchor))
        }
    }

    @Test func placementFlipsAtScreenEdgesAndClampsTheOtherAxis() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let cases: [(Edge, CGRect)] = [
            (.top, CGRect(x: 770, y: 560, width: 28, height: 28)),
            (.bottom, CGRect(x: 2, y: 8, width: 28, height: 28)),
            (.leading, CGRect(x: 8, y: 560, width: 28, height: 28)),
            (.trailing, CGRect(x: 764, y: 2, width: 28, height: 28)),
        ]
        for (edge, anchor) in cases {
            let frame = DockHoverTipPlacement.frame(
                anchor: anchor, size: CGSize(width: 240, height: 80),
                edge: edge, gap: 6, visibleFrame: screen)
            #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
            #expect(!frame.intersects(anchor))
        }
    }

    @Test func nestedHelpUsesOnePanelAndNeverTakesFocus() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let row = DockHoverTipAnchorView(frame: CGRect(x: 10, y: 20, width: 360, height: 50))
        row.text = "Row help"
        let button = DockHoverTipAnchorView(frame: CGRect(x: 320, y: 5, width: 28, height: 28))
        button.text = "Button help"
        window.contentView?.addSubview(row)
        row.addSubview(button)
        let presenter = DockHoverTipPresenter()
        defer { presenter.dismiss() }
        row.hovering = true
        button.hovering = true
        presenter.update(button)
        presenter.update(row)
        #expect(presenter.activeAnchor === button)
        try await Task.sleep(for: .milliseconds(550))
        let panel = try #require(presenter.panel)
        #expect(panel.frame.width < 200)
        #expect(panel.parent === window)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.isOpaque)
        #expect(panel.backgroundColor.usingColorSpace(.sRGB)?.alphaComponent == 1)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!window.dockHasInteractiveChildWindow)
        #expect(window.childWindows?.count == 1)
        #expect(row.hitTest(.zero) == nil)
        let popover = NSPanel(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.addChildWindow(popover, ordered: .above)
        #expect(window.dockHasInteractiveChildWindow)
        window.removeChildWindow(popover)
        presenter.dismiss()
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test func placementUsesAnotherSideWhenFlippingWouldCoverTheControl() {
        let cases: [(CGRect, CGRect, CGSize, Edge)] = [
            (
                CGRect(x: 0, y: 0, width: 800, height: 180),
                CGRect(x: 350, y: 72, width: 80, height: 24), CGSize(width: 280, height: 120), .bottom
            ),
            (
                CGRect(x: 0, y: 0, width: 800, height: 600),
                CGRect(x: 300, y: 240, width: 200, height: 28), CGSize(width: 400, height: 80), .leading
            ),
        ]
        for (screen, anchor, size, edge) in cases {
            let frame = DockHoverTipPlacement.frame(
                anchor: anchor, size: size, edge: edge, gap: 6, visibleFrame: screen)
            #expect(screen.insetBy(dx: 8, dy: 8).contains(frame))
            #expect(!frame.intersects(anchor))
            #expect(
                frame.maxY <= anchor.minY - 6 || frame.minY >= anchor.maxY + 6
                    || frame.maxX <= anchor.minX - 6 || frame.minX >= anchor.maxX + 6)
        }
    }

    @Test func tooltipEscapesClippedSwiftUIContentAndWrapsLongText() async throws {
        let window = makeWindow()
        let presenter = DockHoverTipPresenter()
        let content = ScrollView {
            HStack {
                Button("Sentry") {}.help(String(repeating: "Sentry is running. Crypto is done. ", count: 8))
                Spacer()
            }
            .frame(height: 28)
        }
        .frame(width: 400, height: 60)
        .clipped()
        let host = NSHostingView(rootView: content)
        window.contentView = host
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func findAnchor(_ view: NSView) -> DockHoverTipAnchorView? {
            if let anchor = view as? DockHoverTipAnchorView { return anchor }
            return view.subviews.lazy.compactMap { findAnchor($0) }.first
        }
        let anchor = try #require(findAnchor(host))
        anchor.hovering = true
        presenter.update(anchor)
        try await Task.sleep(for: .milliseconds(550))
        let panel = try #require(presenter.panel)
        #expect(panel.parent === window)
        #expect(panel.frame.width <= 334)
        #expect(panel.frame.height > 28)
        #expect(
            !panel.frame.intersects(
                window.convertToScreen(anchor.convert(anchor.visibleAnchorRect, to: nil))))
        #expect(window.screen?.visibleFrame.contains(panel.frame) == true)
        #expect(!window.frame.contains(panel.frame))
        if let directory = ProcessInfo.processInfo.environment["TOOLTIP_SNAPSHOT_DIR"],
            let view = panel.contentView
        {
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tooltip.png"))
        }
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        #expect(presenter.panel == nil)
    }

    @Test func leavingBeforeTheDelayAndEmptyHelpShowNothing() async throws {
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let anchor = DockHoverTipAnchorView(frame: CGRect(x: 10, y: 10, width: 28, height: 28))
        window.contentView?.addSubview(anchor)
        let presenter = DockHoverTipPresenter()
        defer { presenter.dismiss() }
        anchor.text = "   "
        anchor.hovering = true
        presenter.update(anchor)
        #expect(presenter.activeAnchor == nil)
        anchor.text = "Open session"
        presenter.update(anchor)
        anchor.hovering = false
        presenter.update(anchor)
        try await Task.sleep(for: .milliseconds(550))
        #expect(presenter.panel == nil)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        let window = NSWindow(
            contentRect: CGRect(x: screen.midX - 200, y: screen.midY, width: 400, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
}
