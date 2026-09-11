import AppKit
import Combine
import SwiftUI
import UserNotifications

struct CommandDoubleTapDetector {
    static let maximumInterval: TimeInterval = 0.35

    private(set) var isCommandDown = false
    private var lastReleaseTime: TimeInterval?
    private var interveningKeyOccurred = false

    mutating func handle(isCommandDown: Bool, at time: TimeInterval) -> Bool {
        guard isCommandDown != self.isCommandDown else { return false }
        self.isCommandDown = isCommandDown

        if isCommandDown {
            let isCleanPair = lastReleaseTime.map { time - $0 <= Self.maximumInterval } ?? false
            let triggered = isCleanPair && !interveningKeyOccurred
            lastReleaseTime = nil
            interveningKeyOccurred = false
            return triggered
        }

        if interveningKeyOccurred {
            interveningKeyOccurred = false
            lastReleaseTime = nil
        } else {
            lastReleaseTime = time
        }
        return false
    }

    mutating func noteKeyActivity() {
        interveningKeyOccurred = true
    }
}

@MainActor
final class HermesAgentDockDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = DockModel()
    private var dockPanel: DockPanelController?
    private var commandDoubleTapDetector = CommandDoubleTapDetector()
    private var commandEventMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockPanel = DockPanelController(model: model)
        // The panel is intentionally created lazily, but its menu-bar identity
        // must still reflect the configured SOUL.md name at launch.
        model.refreshRuntimeConfiguration()
        if HermesAppRuntime.supportsUserNotifications {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        } else {
            DebugLog.write("model: UserNotifications unavailable outside an app bundle")
        }
        installCommandDoubleTapShortcut()
        writeStatusItemDiagnosticIfRequested()
        if CommandLine.arguments.contains("--show-panel") {
            // The production app starts quietly in the menu bar. The debug
            // launcher passes this explicit argument so a manual run provides
            // immediate visible confirmation that the freshly built app is up.
            DispatchQueue.main.async { [weak self] in
                self?.dockPanel?.showFromDebugLaunch()
            }
        }
    }

    private func writeStatusItemDiagnosticIfRequested() {
        guard CommandLine.arguments.contains("--status-item-diagnostics") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let button = self.dockPanel?.statusItemDiagnostic
            let frame = button.flatMap { button in
                button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            }
            let detail = [
                "title=\(button?.title ?? "")",
                "visible=\(self.dockPanel?.statusItemIsVisible ?? false)",
                "button_hidden=\(button?.isHidden ?? true)",
                "button_frame=\(frame.map(NSStringFromRect) ?? "nil")",
                "screen_count=\(NSScreen.screens.count)"
            ].joined(separator: "\n") + "\n"
            try? detail.write(
                to: URL(fileURLWithPath: "/private/tmp/hermes-status-item-diagnostic.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func installCommandDoubleTapShortcut() {
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.handleCommandEvent(event)
            return event
        }

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            commandEventMonitors.append(localMonitor)
        }
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleCommandEvent(event)
        }) {
            commandEventMonitors.append(globalMonitor)
        }
        // Two rapid Command shortcuts (⌘C then ⌘V) must not read as a
        // double-tap. Observing key activity between releases invalidates the
        // pair; events are inspected only for timing and never retained.
        if let localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler) {
            commandEventMonitors.append(localKeyMonitor)
        }
        if let globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.commandDoubleTapDetector.noteKeyActivity()
        }) {
            commandEventMonitors.append(globalKeyMonitor)
        }
    }

    private func handleCommandEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            commandDoubleTapDetector.noteKeyActivity()
            return
        }
        // 54 and 55 are the right and left Command keys on macOS keyboards.
        guard event.keyCode == 54 || event.keyCode == 55 else { return }
        if commandDoubleTapDetector.handle(
            isCommandDown: event.modifierFlags.contains(.command),
            at: event.timestamp
        ) {
            dockPanel?.toggleFromShortcut()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // This is deliberately explicit: a menu-bar app can terminate without
        // releasing its delegate/model graph, so deinit is not a process-life
        // cycle hook for the local Hermes backend.
        model.shutdown()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let attentionID = response.notification.request.content.userInfo["attention_id"] as? String
        await MainActor.run { [weak self] in
            if let attentionID {
                self?.model.requestControlAttention(attentionID)
            } else {
                self?.model.requestControlInbox()
            }
            self?.dockPanel?.showFromNotification()
        }
    }
}

private final class UnreadBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class DockPanelController: NSObject, NSWindowDelegate {
    private enum Metrics {
        static let compactWidth: CGFloat = 420
        // Keep the chat compact while giving the right Control workspace
        // enough room to reach the screen edge on wide displays.
        static let workspaceWidth: CGFloat = 960
        static let height: CGFloat = 720
        static let screenInset: CGFloat = 12
        static let menuGap: CGFloat = 8
        /// The shortcut begins as a compact capsule, then opens horizontally
        /// from the left edge before settling into the normal Dock workspace.
        static let shortcutIslandWidth: CGFloat = 56
        static let shortcutIslandHeight: CGFloat = 56
        static let shortcutAnimationDuration: TimeInterval = 0.42
    }

    private let model: DockModel
    private let statusItem: NSStatusItem
    private let unreadBadge = UnreadBadgeView(frame: .zero)
    private let panel: DockPanel
    private let panelPresentation = DockPanelPresentation()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitors: [Any] = []
    private var desiredWidth = Metrics.workspaceWidth
    private var isFullscreen = false
    private var isPanelContentInstalled = false

    var statusItemDiagnostic: NSStatusBarButton? { statusItem.button }
    var statusItemIsVisible: Bool { statusItem.isVisible }

    init(model: DockModel) {
        self.model = model
        // Use a variable-width item with a text fallback. A square custom
        // template image can be visually lost by the modern Control Center
        // status-item host even though the item is registered successfully.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Without a stable autosave name, newer macOS Control Center hosts
        // this as an ephemeral item and can omit it from the visible bar on a
        // subsequent launch. Persist the item identity and opt it in to the
        // visible status area before configuring its button.
        statusItem.autosaveName = "com.christian.HermesAgentDock.statusItem"
        statusItem.isVisible = true
        panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.workspaceWidth, height: Metrics.height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureStatusItem()
        configurePanel()
        installOutsideClickMonitors()
        observeModel()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = robotStatusImage()
        button.title = model.agentDisplayName
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp])

        unreadBadge.translatesAutoresizingMaskIntoConstraints = false
        unreadBadge.wantsLayer = true
        unreadBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
        unreadBadge.layer?.cornerRadius = 3.5
        unreadBadge.isHidden = true
        unreadBadge.setAccessibilityElement(false)
        button.addSubview(unreadBadge)
        NSLayoutConstraint.activate([
            unreadBadge.widthAnchor.constraint(equalToConstant: 7),
            unreadBadge.heightAnchor.constraint(equalToConstant: 7),
            unreadBadge.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            unreadBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2)
        ])
    }

    private func configurePanel() {
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Dismissal is handled by the explicit outside-click monitors below.
        // Keeping this false is important for status-item activation: AppKit
        // can deactivate the agent while processing the click that opens it.
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.hide() }
    }

    /// Creating `DockPopover` starts its restore task. Keep that work out of
    /// a quiet menu-bar launch so the launcher does not claim a session before
    /// the user has opened this surface.
    private func installPanelContentIfNeeded() {
        guard !isPanelContentInstalled else { return }
        isPanelContentInstalled = true
        let hostingView = NSHostingView(
            rootView: DockPopover(model: model, panelPresentation: panelPresentation, availableWorkspaceWidth: { [weak self] in
                self?.availableWorkspaceWidth() ?? .greatestFiniteMagnitude
            }, onWorkspaceWidthChange: { [weak self] width in
                self?.resizePanel(to: width) ?? width
            }, onClose: { [weak self] in
                self?.hide()
            }, onFullscreenToggle: { [weak self] in
                self?.toggleFullscreen()
            })
        )
        hostingView.wantsLayer = true
        // DockPopover owns the contour so a shortcut can attach cleanly to the
        // screen edge while ordinary presentations remain fully rounded.
        hostingView.layer?.masksToBounds = false
        panel.contentView = hostingView
    }

    private func observeModel() {
        model.$hasUnreadResponse
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hasUnreadResponse in
                self?.updateStatusIcon(hasUnreadResponse: hasUnreadResponse)
            }
            .store(in: &cancellables)

        model.$runtimeConfiguration
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemIdentity()
            }
            .store(in: &cancellables)
    }

    private func installOutsideClickMonitors() {
        let handler: (NSEvent) -> NSEvent? = { [weak self] event in
            self?.dismissIfOutside(event)
            return event
        }

        if let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: handler
        ) {
            outsideClickMonitors.append(localMonitor)
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                self?.dismissIfOutside(event)
            }
        ) {
            outsideClickMonitors.append(globalMonitor)
        }
    }

    private func dismissIfOutside(_ event: NSEvent) {
        guard panel.isVisible, !isFullscreen else { return }
        let point = NSEvent.mouseLocation
        guard !panel.frame.contains(point), !statusItemFrame.contains(point) else { return }
        hide()
    }

    private var statusItemFrame: NSRect {
        guard let button = statusItem.button,
              let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func updateStatusIcon(hasUnreadResponse: Bool) {
        statusItem.button?.image = robotStatusImage()
        updateStatusItemIdentity(hasUnreadResponse: hasUnreadResponse)
        unreadBadge.isHidden = !hasUnreadResponse
        DebugLog.write("status item: unread badge \(hasUnreadResponse ? "shown" : "hidden")")
    }

    private func updateStatusItemIdentity(hasUnreadResponse: Bool? = nil) {
        let name = model.agentDisplayName
        let unread = hasUnreadResponse ?? model.hasUnreadResponse
        statusItem.button?.title = name
        statusItem.button?.image?.accessibilityDescription = unread ? "\(name) AI agent, unread update" : "\(name) AI agent"
        statusItem.button?.toolTip = unread ? "\(name) AI agent — unread update" : "\(name) AI agent"
    }

    private func robotStatusImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()

        let ink = NSColor.black
        ink.setStroke()
        ink.setFill()

        let antenna = NSBezierPath()
        antenna.lineWidth = 1.4
        antenna.move(to: NSPoint(x: 9, y: 14.5))
        antenna.line(to: NSPoint(x: 9, y: 16.5))
        antenna.stroke()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 16, width: 2, height: 2)).fill()

        let head = NSBezierPath(
            roundedRect: NSRect(x: 2.5, y: 4, width: 13, height: 11),
            xRadius: 2.5,
            yRadius: 2.5
        )
        head.lineWidth = 1.5
        head.stroke()

        NSBezierPath(ovalIn: NSRect(x: 5.5, y: 9, width: 2, height: 2)).fill()
        NSBezierPath(ovalIn: NSRect(x: 10.5, y: 9, width: 2, height: 2)).fill()

        let mouth = NSBezierPath()
        mouth.lineWidth = 1.2
        mouth.move(to: NSPoint(x: 6, y: 6.5))
        mouth.line(to: NSPoint(x: 12, y: 6.5))
        mouth.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    @objc private func togglePanel() {
        panel.isVisible ? hide() : show()
    }

    func toggleFromShortcut() {
        if panel.isVisible {
            hide()
        } else {
            show(fromShortcut: true)
            model.requestComposerFocus()
        }
    }

    func showFromNotification() {
        if !panel.isVisible { show() }
    }

    func showFromDebugLaunch() {
        // An accessory/menu-bar app may register its item in an overflow area
        // or on a different display. A debug launch must still reveal a
        // concrete surface on the active desktop.
        show()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func show(fromShortcut: Bool = false) {
        installPanelContentIfNeeded()
        panelPresentation.isEdgeAttached = fromShortcut && !isFullscreen
        if isFullscreen {
            guard let screen = NSScreen.main else { return }
            panel.setFrame(screen.visibleFrame, display: true)
        } else if fromShortcut {
            showWithShortcutIslandAnimation()
        } else {
            resizePanel(to: desiredWidth, animated: false)
        }
        // `swift run` leaves Terminal as the active app. A status-bar panel can
        // become key visually without receiving keyboard input until its agent
        // application is explicitly activated.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        model.markPopoverVisible()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            DebugLog.write("panel: shown (app active: \(NSApp.isActive), frontmost: \(frontmost), key: \(self.panel.isKeyWindow), responder: \(self.panel.responderDescription))")
        }
    }

    /// A double-Command invocation should have an immediate visual origin even
    /// when the menu-bar item is far away. Start with a small top-left capsule
    /// and let it grow across the workspace rather than dropping down from the
    /// status item. The final geometry is still the same usable Dock panel.
    private func showWithShortcutIslandAnimation() {
        guard let screen = shortcutScreen else {
            resizePanel(to: desiredWidth, animated: false)
            return
        }

        let target = shortcutPanelFrame(in: screen)
        let origin = NSRect(
            x: target.minX,
            y: target.maxY - Metrics.shortcutIslandHeight,
            width: Metrics.shortcutIslandWidth,
            height: Metrics.shortcutIslandHeight
        )

        panel.setFrame(origin, display: true)
        panel.alphaValue = 0.96
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.shortcutAnimationDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard panel.isVisible else { return }
        if isFullscreen {
            exitFullscreen()
        }
        panel.orderOut(nil)
        panelPresentation.isEdgeAttached = false
        model.markPopoverHidden()
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        if isFullscreen {
            enterFullscreen()
        } else {
            exitFullscreen()
        }
    }

    private func enterFullscreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.styleMask.insert(.resizable)
        panel.styleMask.insert(.closable)
        panel.styleMask.insert(.miniaturizable)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .normal
        // The fullscreen surface owns horizontal drag gestures for its split
        // view. Letting AppKit move the borderless window by its background
        // would intercept those gestures before SwiftUI sees the divider.
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        if let hostingView = panel.contentView {
            hostingView.wantsLayer = true
            hostingView.layer?.masksToBounds = false
            hostingView.layer?.cornerRadius = 0
            hostingView.layer?.cornerCurve = .continuous
            hostingView.frame = NSRect(origin: .zero, size: screenFrame.size)
            hostingView.autoresizingMask = [.width, .height]
            hostingView.setNeedsDisplay(hostingView.bounds)
            hostingView.invalidateIntrinsicContentSize()
        }

        // Switching to the fullscreen split layout while AppKit animates a
        // compact panel to screen width briefly gives SwiftUI an intermediate
        // width. That stretches the conversation before the split settles.
        // Resize atomically so the first fullscreen layout pass has its final
        // dimensions.
        panel.setFrame(screenFrame, display: true, animate: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeMain()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.panel.makeKey()
            self?.panel.makeMain()
            self?.panel.orderFrontRegardless()
        }
    }

    private func exitFullscreen() {
        panel.isFloatingPanel = true
        panel.styleMask.remove(.resizable)
        panel.styleMask.remove(.closable)
        panel.styleMask.remove(.miniaturizable)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .statusBar
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        if let hostingView = panel.contentView {
            hostingView.layer?.masksToBounds = false
            hostingView.autoresizingMask = []
        }

        if panel.isVisible {
            resizePanel(to: desiredWidth, animated: true)
        }
    }

    @discardableResult
    private func resizePanel(to width: CGFloat, animated: Bool = true) -> CGFloat {
        desiredWidth = width
        guard !isFullscreen, let button = statusItem.button else { return width }

        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? button.window?.screen
            ?? NSScreen.main
        guard let screen else { return width }

        let visibleFrame = screen.visibleFrame
        let fittedWidth = min(width, max(Metrics.compactWidth, visibleFrame.width - Metrics.screenInset * 2))
        let maxX = visibleFrame.maxX - Metrics.screenInset
        let minX = visibleFrame.minX + Metrics.screenInset
        let preferredX = (buttonRect?.midX ?? visibleFrame.midX) - fittedWidth / 2
        let x = min(max(preferredX, minX), maxX - fittedWidth)
        let preferredY = (buttonRect?.minY ?? visibleFrame.maxY) - Metrics.height - Metrics.menuGap
        let y = max(visibleFrame.minY + Metrics.screenInset, preferredY)
        let frame = NSRect(x: x, y: y, width: fittedWidth, height: Metrics.height)

        // Session selection may re-evaluate the layout. Setting an identical
        // frame through the animator still visibly relayouts the host tree.
        guard !panel.frame.equalTo(frame) else { return fittedWidth }

        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        return fittedWidth
    }

    /// Reads the capacity of the display hosting the menu-bar item without
    /// resizing the live panel. SwiftUI uses this only for layout decisions.
    private func availableWorkspaceWidth() -> CGFloat {
        guard let button = statusItem.button else { return .greatestFiniteMagnitude }
        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? button.window?.screen
            ?? NSScreen.main
        guard let screen else { return .greatestFiniteMagnitude }
        return max(Metrics.compactWidth, screen.visibleFrame.width - Metrics.screenInset * 2)
    }

    /// The display hosting the status item is the display the Dock belongs to;
    /// do not use `NSScreen.main` because the active app may be elsewhere.
    private var shortcutScreen: NSScreen? {
        guard let button = statusItem.button else { return NSScreen.main }
        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? button.window?.screen
            ?? NSScreen.main
    }

    private func shortcutPanelFrame(in screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        let width = min(desiredWidth, visibleFrame.width)
        return NSRect(
            x: visibleFrame.minX,
            y: max(visibleFrame.minY, visibleFrame.maxY - Metrics.height),
            width: width,
            height: Metrics.height
        )
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DebugLog.write("panel: became key (responder: \(panel.responderDescription))")
    }

    func windowDidResignKey(_ notification: Notification) {
        DebugLog.write("panel: resigned key")
    }
}

@MainActor
private final class DockPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    var responderDescription: String {
        firstResponder.map { String(describing: type(of: $0)) } ?? "none"
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            DebugLog.write("panel: keyDown code=\(event.keyCode) repeat=\(event.isARepeat) responder=\(responderDescription)")
        }
        super.sendEvent(event)
    }
}
