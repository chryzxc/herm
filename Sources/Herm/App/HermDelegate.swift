import AppKit
import Combine
import SwiftUI
import UserNotifications

/// The modifier a global shortcut is triggered by double-tapping.
enum DoubleTapShortcut: String, CaseIterable, Identifiable {
    case command, option, control, shift, off

    /// UserDefaults keys, read on every key event so Settings edits apply at once.
    static let workspaceKey = "hermes.shortcut.workspace"
    static let notchKey = "hermes.shortcut.notch"

    static var workspace: Self { stored(workspaceKey, default: .command) }
    static var notch: Self { stored(notchKey, default: .option) }

    private static func stored(_ key: String, default value: Self) -> Self {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? value
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: "Double-tap Command"
        case .option: "Double-tap Option"
        case .control: "Double-tap Control"
        case .shift: "Double-tap Shift"
        case .off: "Off"
        }
    }

    var keycap: String? {
        switch self {
        case .command: "⌘ ⌘"
        case .option: "⌥ ⌥"
        case .control: "⌃ ⌃"
        case .shift: "⇧ ⇧"
        case .off: nil
        }
    }

    /// Left and right key codes on macOS keyboards.
    var keyCodes: Set<UInt16> {
        switch self {
        case .command: [54, 55]
        case .option: [58, 61]
        case .control: [59, 62]
        case .shift: [56, 60]
        case .off: []
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        case .off: []
        }
    }
}

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
final class HermDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model: DockModel
    private let controlCenter: ControlCenterModel
    private var dockPanel: DockPanelController?
    private var edgeDock: EdgeDockController?
    private var commandDoubleTapDetector = CommandDoubleTapDetector()
    private var optionDoubleTapDetector = CommandDoubleTapDetector()
    private var commandEventMonitors: [Any] = []

    override init() {
        // Must run before the models read defaults or state files.
        LegacyAppIdentity.migrate()
        model = DockModel()
        controlCenter = ControlCenterModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the saved theme's appearance before any Dock window draws.
        _ = DockThemeStore.shared
        let edge = EdgeDockController(model: model, controlCenter: controlCenter, openQuota: { [weak self] in
            self?.dockPanel?.showQuota()
        }, openDock: { [weak self] in
            self?.dockPanel?.showFromNotification()
        })
        edgeDock = edge
        dockPanel = DockPanelController(model: model, controlCenter: controlCenter, panel: edge.panel,
            placement: { [weak edge] in edge?.placement },
            onWillShow: { [weak edge] in edge?.prepareForWorkspace() },
            onHide: { [weak edge] in edge?.restoreNotch() })
        NSApp.applicationIconImage = DockAppBrand.icon
        if ScrollPerformanceFixture.isRequested {
            let fixture = ScrollPerformanceFixture.standard
            DebugLog.writePerformance(
                "fixture scenario=\(ScrollPerformanceFixture.requestedScenario?.rawValue ?? ScrollPerformanceFixture.Scenario.idleLongMarkdown.rawValue) projects=\(fixture.projectCount) sessions=\(fixture.sessionCount) messages=\(fixture.messageCount) streaming_bytes=\(fixture.streamingBytes) mounted_row_cap=36"
            )
        }
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
        HermAppUpdater.shared.isBusy = { [model] in model.isSending || model.status == .working }
        HermAppUpdater.shared.start()
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
            self?.optionDoubleTapDetector.noteKeyActivity()
        }) {
            commandEventMonitors.append(globalKeyMonitor)
        }
    }

    private func handleCommandEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            commandDoubleTapDetector.noteKeyActivity()
            optionDoubleTapDetector.noteKeyActivity()
            return
        }
        let workspace = DoubleTapShortcut.workspace
        if workspace.keyCodes.contains(event.keyCode) {
            if commandDoubleTapDetector.handle(isCommandDown: event.modifierFlags.contains(workspace.flag), at: event.timestamp) {
                dockPanel?.toggleFromShortcut()
            }
            return
        }
        let notch = DoubleTapShortcut.notch
        if notch.keyCodes.contains(event.keyCode),
           optionDoubleTapDetector.handle(isCommandDown: event.modifierFlags.contains(notch.flag), at: event.timestamp) {
            edgeDock?.toggleQuickPreview()
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
    }

    private let model: DockModel
    private let controlCenter: ControlCenterModel
    private let preferences = CommandCenterPreferencesStore()
    private let statusItem: NSStatusItem
    private let unreadBadge = UnreadBadgeView(frame: .zero)
    private let panel: DockPanel
    private let panelPresentation = DockPanelPresentation()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitors: [Any] = []
    private var desiredWidth = Metrics.workspaceWidth
    private var isFullscreen = false {
        didSet { panelPresentation.isFullscreen = isFullscreen }
    }
    private var workspaceHost: NSView?
    private var isWorkspaceVisible = false
    private var pointerExitTask: DispatchWorkItem?
    private let placement: () -> EdgeDockPlacement?
    private let onWillShow: () -> Void
    private let onHide: () -> Void

    var statusItemDiagnostic: NSStatusBarButton? { statusItem.button }
    var statusItemIsVisible: Bool { statusItem.isVisible }

    init(model: DockModel, controlCenter: ControlCenterModel, panel: DockPanel, placement: @escaping () -> EdgeDockPlacement?,
         onWillShow: @escaping () -> Void, onHide: @escaping () -> Void) {
        self.model = model
        self.controlCenter = controlCenter
        self.panel = panel
        self.placement = placement
        self.onWillShow = onWillShow
        self.onHide = onHide
        // Temporarily keep the status item hidden: the movable notch is the launcher.
        // Retain its identity so restoring the menu-bar option later is reversible.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "com.christian.Herm.statusItem"
        statusItem.isVisible = false
        super.init()

        configureStatusItem()
        configurePanel()
        installOutsideClickMonitors()
        observeModel()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isWorkspaceVisible else { return }
                self.resizePanel(to: self.desiredWidth, animated: false)
            }.store(in: &cancellables)
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
        panel.hasShadow = false
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
        if let workspaceHost {
            panel.contentView = workspaceHost
            return
        }
        let hostingView = EdgeDockHostingView(
            rootView: DockPopover(model: model, panelPresentation: panelPresentation, controlCenter: controlCenter, availableWorkspaceWidth: { [weak self] in
                self?.availableWorkspaceWidth() ?? .greatestFiniteMagnitude
            }, onWorkspaceWidthChange: { [weak self] width in
                // The split view changes pane count when the inspector toggles.
                // Animating the window at the same time can leave an old
                // divider drawn over the newly positioned conversation.
                self?.resizePanel(to: width, animated: false) ?? width
            }, onClose: { [weak self] in
                self?.hide()
            }, onFullscreenToggle: { [weak self] in
                self?.toggleFullscreen()
            })
        )
        hostingView.onHoverChanged = { [weak self] inside in
            self?.workspaceHoverChanged(inside)
        }
        hostingView.wantsLayer = true
        // DockPopover owns the contour so a shortcut can attach cleanly to the
        // screen edge while ordinary presentations remain fully rounded.
        hostingView.layer?.masksToBounds = false
        hostingView.sizingOptions = []
        workspaceHost = hostingView
        panel.contentView = hostingView
    }

    private func workspaceHoverChanged(_ inside: Bool) {
        pointerExitTask?.cancel()
        guard !inside, isWorkspaceVisible, !isFullscreen else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isWorkspaceVisible, !self.isFullscreen,
                  !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            // A sheet or popover belongs to the workspace, even outside its frame.
            guard self.panel.attachedSheet == nil, self.panel.childWindows?.isEmpty != false else {
                self.workspaceHoverChanged(false)
                return
            }
            self.hide()
        }
        pointerExitTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
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
        guard isWorkspaceVisible, !isFullscreen else { return }
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
        isWorkspaceVisible ? hide() : show()
    }

    func toggleFromShortcut() {
        if isWorkspaceVisible {
            hide()
        } else {
            show(fromShortcut: true)
            model.requestComposerFocus()
        }
    }

    func showFromNotification() {
        if !isWorkspaceVisible { show() }
    }

    func showQuota() {
        showFromNotification()
        panelPresentation.quotaRequest &+= 1
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
        pointerExitTask?.cancel()
        if !isWorkspaceVisible {
            // Read fresh: Settings and the fullscreen toggle both write this key.
            isFullscreen = UserDefaults.standard.object(forKey: CommandCenterPreferencesStore.opensFullscreenKey) as? Bool
                ?? preferences.launchesExpandedByDefault
        }
        onWillShow()
        isWorkspaceVisible = true
        panel.onCancel = { [weak self] in self?.hide() }
        panelPresentation.isEdgeAttached = true
        panelPresentation.edgeSide = placement()?.side ?? .right
        installPanelContentIfNeeded()
        if isFullscreen {
            enterFullscreen()
        } else {
            resizePanel(to: desiredWidth, animated: true)
        }
        // `swift run` leaves Terminal as the active app. A status-bar panel can
        // become key visually without receiving keyboard input until its agent
        // application is explicitly activated.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        EdgeDockMotion.reveal(workspaceHost, side: panelPresentation.edgeSide, fromShortcut: fromShortcut)
        model.markPopoverVisible()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            DebugLog.write("panel: shown (app active: \(NSApp.isActive), frontmost: \(frontmost), key: \(self.panel.isKeyWindow), responder: \(self.panel.responderDescription))")
        }
    }

    private func hide() {
        pointerExitTask?.cancel()
        guard isWorkspaceVisible else { return }
        EdgeDockMotion.cancel(workspaceHost)
        if isFullscreen {
            exitFullscreen()
        }
        isFullscreen = false
        isWorkspaceVisible = false
        model.markPopoverHidden()
        onHide()
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        UserDefaults.standard.set(isFullscreen, forKey: CommandCenterPreferencesStore.opensFullscreenKey)
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

        if isWorkspaceVisible {
            resizePanel(to: desiredWidth, animated: true)
        }
    }

    @discardableResult
    private func resizePanel(to width: CGFloat, animated: Bool = true) -> CGFloat {
        desiredWidth = width
        guard !isFullscreen, let placement = placement() else { return width }
        let horizontalInset = EdgeDockLayout.workspaceHorizontalInset
        let verticalInset = EdgeDockLayout.workspaceVerticalInset
        let availableWidth = max(0, placement.screenFrame.width - Metrics.screenInset - horizontalInset * 2)
        let fittedWidth = min(width, availableWidth)
        let height = min(Metrics.height, placement.visibleFrame.height)
        panelPresentation.edgeSide = placement.side
        panelPresentation.availableWidth = availableWidth
        panelPresentation.compactWidth = fittedWidth
        panelPresentation.compactHeight = max(0, height - verticalInset * 2)
        let frame = placement.frame(width: fittedWidth + horizontalInset * 2, height: height)

        // Session selection may re-evaluate the layout. Setting an identical
        // frame through the animator still visibly relayouts the host tree.
        guard !panel.frame.equalTo(frame) else { return fittedWidth }

        if animated, isWorkspaceVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = EdgeDockMotion.revealDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
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
        guard let placement = placement() else { return .greatestFiniteMagnitude }
        return max(0, placement.screenFrame.width - Metrics.screenInset - EdgeDockLayout.workspaceHorizontalInset * 2)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DebugLog.write("panel: became key (responder: \(panel.responderDescription))")
    }

    func windowDidResignKey(_ notification: Notification) {
        DebugLog.write("panel: resigned key")
    }
}

@MainActor
final class DockPanel: NSPanel {
    var acceptsWorkspaceFocus = true
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { acceptsWorkspaceFocus }
    override var canBecomeMain: Bool { acceptsWorkspaceFocus }
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
