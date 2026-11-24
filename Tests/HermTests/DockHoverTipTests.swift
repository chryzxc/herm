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

    @Test(arguments: [DockThemeID.clean, DockThemeID.storm])
    func botProfilePreviewStaysBesideTheRail(theme: DockThemeID) throws {
        let oldTheme = DockThemeRuntime.current
        DockThemeRuntime.current = theme
        DockThemeRuntime.revision &+= 1
        let window = makeWindow()
        let presenter = DockHoverTipPresenter()
        defer {
            presenter.dismiss()
            window.orderOut(nil)
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        let bot = BotSummary(
            id: "cypher", name: "Cypher", title: "Security",
            description: "Reviews security risks and remediation evidence. Reports findings and suggested fixes.",
            model: nil, isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: false)
        let anchor = DockHoverTipAnchorView(frame: CGRect(x: 10, y: 8, width: 44, height: 44))
        window.contentView?.addSubview(anchor)
        anchor.text = BotRosterPresentation.railTooltip(for: bot)
        anchor.edge = .trailing
        anchor.gap = 8
        anchor.preview = DockHoverTipPreview(
            contentID: bot.id, content: AnyView(BotRailProfileTip(bot: bot, imageData: nil)))
        presenter.show(anchor)

        let panel = try #require(presenter.panel)
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.visibleAnchorRect, to: nil))
        #expect(panel.frame.minX >= anchorFrame.maxX + anchor.gap)
        #expect(panel.frame.width == 288)
        #expect(panel.frame.height > 90)
        #expect(panel.hasShadow && panel.ignoresMouseEvents && !panel.canBecomeKey)
        try writeSnapshot(of: panel, named: "bot-tooltip-\(theme.rawValue).png")
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
        for _ in 0..<60 where presenter.panel == nil { try await Task.sleep(for: .milliseconds(50)) }
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

    @Test(arguments: [DockThemeID.glass, DockThemeID.storm])
    func pinnedMessagePreviewHasAnOpaqueReadingSurface(theme: DockThemeID) throws {
        _ = DockThemeStore.shared
        let oldTheme = DockThemeRuntime.current
        DockThemeRuntime.current = theme
        DockThemeRuntime.revision &+= 1
        let window = makeWindow()
        window.appearance = DockThemeStore.nsAppearance(for: theme) ?? NSAppearance(named: .aqua)
        let presenter = DockHoverTipPresenter()
        defer {
            presenter.dismiss()
            window.orderOut(nil)
            DockThemeRuntime.current = oldTheme
            DockThemeRuntime.revision &+= 1
        }
        let pin = PinnedMessage(
            rowID: 1, uid: "pinned-message", role: "assistant",
            preview: "The release notes are ready. The follow-up list covers the remaining accessibility checks.")
        let anchor = DockHoverTipAnchorView(frame: CGRect(x: 14, y: 8, width: 180, height: 44))
        window.contentView?.addSubview(anchor)
        anchor.text = "Jump to pinned message"
        anchor.edge = .leading
        anchor.preview = DockHoverTipPreview(
            contentID: pin.id, content: AnyView(MessagePinLabel(pin: pin, showsJump: false)))
        presenter.show(anchor)

        let panel = try #require(presenter.panel)
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.visibleAnchorRect, to: nil))
        #expect(!panel.frame.intersects(anchorFrame))
        #expect(panel.hasShadow && panel.ignoresMouseEvents && !panel.canBecomeKey)
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.colorAt(x: bitmap.pixelsWide - 16, y: bitmap.pixelsHigh / 2)?.alphaComponent == 1)
        try writeSnapshot(of: panel, named: "pinned-message-\(theme.rawValue).png")
        if ProcessInfo.processInfo.environment["TOOLTIP_SNAPSHOT_DIR"] != nil {
            presenter.dismiss()
            window.contentView = NSHostingView(
                rootView: SidebarReorderDragPreview(title: "Release notes and accessibility", icon: .pushPin)
                    .frame(width: 400, height: 60)
                    .dockThemedRoot())
            try writeSnapshot(of: window, named: "pinned-drag-\(theme.rawValue).png")
        }
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
                // `.help` mounts its anchor only under the pointer; mount it directly.
                Button("Sentry") {}.background(
                    DockHoverTipAnchor(
                        text: String(repeating: "Sentry is running. Crypto is done. ", count: 8),
                        edge: .bottom, gap: 6, hovering: false))
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
        for _ in 0..<60 where presenter.panel == nil { try await Task.sleep(for: .milliseconds(50)) }
        let panel = try #require(presenter.panel)
        #expect(panel.parent === window)
        #expect(panel.frame.width <= 334)
        #expect(panel.frame.height > 28)
        #expect(
            !panel.frame.intersects(
                window.convertToScreen(anchor.convert(anchor.visibleAnchorRect, to: nil))))
        #expect(window.screen?.visibleFrame.contains(panel.frame) == true)
        #expect(!window.frame.contains(panel.frame))
        try writeSnapshot(of: panel, named: "tooltip.png")
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        #expect(presenter.panel == nil)
    }

    private func writeSnapshot(of panel: NSWindow, named filename: String) throws {
        if let directory = ProcessInfo.processInfo.environment["TOOLTIP_SNAPSHOT_DIR"],
            let view = panel.contentView
        {
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(filename))
        }
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

    @Test func mountingAlreadyHoveredControlShowsTooltipAndRemovalDismissesIt() async throws {
        let window = makeWindow()
        let presenter = DockHoverTipPresenter.shared
        presenter.dismiss()
        let host = NSHostingView(
            rootView: Button("Open session") {}.background(
                DockHoverTipAnchor(text: "Open session help", edge: .bottom, gap: 6, hovering: true)))
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func findAnchor(_ view: NSView) -> DockHoverTipAnchorView? {
            if let anchor = view as? DockHoverTipAnchorView { return anchor }
            return view.subviews.lazy.compactMap { findAnchor($0) }.first
        }
        let anchor = try #require(findAnchor(host))
        #expect(anchor.window === window)
        try #require(anchor.hovering, "Mounting an already-hovered control must preserve its hover state")
        for _ in 0..<60 where presenter.panel == nil { try await Task.sleep(for: .milliseconds(50)) }
        let panel = try #require(presenter.panel)
        #expect(presenter.activeAnchor === anchor)
        #expect(anchor.text == "Open session help")
        #expect(panel.parent === window)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        window.contentView = NSView()
        for _ in 0..<20 where presenter.panel != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(presenter.panel == nil)

        let earlyHost = NSHostingView(
            rootView: Button("Open session") {}.background(
                DockHoverTipAnchor(text: "Open session help", edge: .bottom, gap: 6, hovering: true)))
        window.contentView = earlyHost
        earlyHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let earlyAnchor = try #require(findAnchor(earlyHost))
        try #require(earlyAnchor.hovering)
        window.contentView = NSView()
        try await Task.sleep(for: .milliseconds(550))
        #expect(presenter.panel == nil)
        #expect(presenter.activeAnchor == nil)
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
