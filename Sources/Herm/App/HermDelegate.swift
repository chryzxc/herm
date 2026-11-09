import AppKit
import Combine
import CoreSpotlight
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
    private let interruptions = HermInterruptionCoordinator(defaults: .standard)
    private let model: DockModel
    private let controlCenter: ControlCenterModel
    private var dockPanel: DockPanelController?
    private var edgeDock: EdgeDockController?
    private var dockWindow: DockWindowController?
    private let onboarding = DockOnboardingWindow()
    private var commandDoubleTapDetector = CommandDoubleTapDetector()
    private var optionDoubleTapDetector = CommandDoubleTapDetector()
    private var commandEventMonitors: [Any] = []
    private var keepAwake: NSObjectProtocol?
    private var keepAwakeObservers = Set<AnyCancellable>()
    private var dockTileStatus: DockTileStatus?
    private var actionErrorPresenter: DockActionErrorPresenter?
    private var quickCaptureHotKey: QuickCaptureHotKey?
    private var windowCaptureHotKey: QuickCaptureHotKey?
    private var spotlightIndex: SessionSpotlightIndex?
    static let keepAwakeKey = "herm.keepAwakeWhileWorking.v1"
    /// The running delegate, for App Intents, which have no other route to the models.
    static private(set) weak var current: HermDelegate?

    override init() {
        model = DockModel()
        controlCenter = ControlCenterModel()
        super.init()
        model.interruptionCoordinator = interruptions
        Self.current = self
    }

    func showSettings() {
        if let dockWindow, dockWindow.isOpen {
            dockWindow.showSettings()
        } else {
            dockPanel?.showSettings()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply the saved theme's appearance before any Dock window draws.
        _ = DockThemeStore.shared
        _ = NSScrollView.installDockScrollers
        actionErrorPresenter = DockActionErrorPresenter()
        Task {
            do { try await HermKeychain.restrictAccess(service: "io.github.chryzxc.Herm.gateway") } catch {
                DockActionErrorCenter.shared.report("Could not secure saved credentials", error: error)
            }
        }
        // AppKit's first tooltip waits ~1s; later ones are instant. Make the
        // first match so icon-only buttons explain themselves on hover.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        DispatchQueue.global(qos: .utility).async { AgentBrowser.reapOrphans() }
        let edge = EdgeDockController(
            model: model, controlCenter: controlCenter, interruptions: interruptions,
            openQuota: { [weak self] in
                self?.dockPanel?.showQuota()
            },
            openKanban: { [weak self] task in
                self?.dockPanel?.showKanban(task)
            },
            openDock: { [weak self] in
                self?.dockPanel?.showFromNotification()
            })
        edgeDock = edge
        dockPanel = DockPanelController(
            model: model, controlCenter: controlCenter, notchPanel: edge.panel,
            placement: { [weak edge] in edge?.placement },
            onWillShow: { [weak edge] in edge?.prepareForWorkspace() },
            onHide: { [weak edge] in edge?.restoreNotch() })
        dockPanel?.showIslandStatus(edge.state, openTask: { [weak edge] in edge?.openTask($0) })
        let window = DockWindowController(model: model, controlCenter: controlCenter)
        dockWindow = window
        dockPanel?.openWindow = { [weak window] in window?.open() }
        dockPanel?.isWindowOpen = { [weak window] in window?.isOpen == true }
        window.onReturnToFloating = { [weak self] in self?.dockPanel?.showFromNotification() }
        if UserDefaults.standard.bool(forKey: DockWindowController.wasOpenKey) { window.open() }
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
            UNUserNotificationCenter.current().setNotificationCategories(HermNotificationAction.categories)
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        } else {
            DebugLog.write("model: UserNotifications unavailable outside an app bundle")
        }
        NSApp.servicesProvider = self
        observeKeepAwake()
        dockTileStatus = DockTileStatus(model: model)
        installCommandDoubleTapShortcut()
        spotlightIndex = SessionSpotlightIndex(model: model)
        PullRequestWatchStore.shared.onNotice = { [weak model] reference, changes in
            model?.publishWorkflowNotice(
                HermNotice(
                    kind: .information, source: .repository, profileID: nil,
                    sourceID: reference.id, eventID: UUID().uuidString),
                body: "\(reference.id): " + changes.joined(separator: " · "), openURL: reference.url)
        }
        PullRequestWatchStore.shared.start()
        model.presentationDemand.$hasVisibleHost.removeDuplicates()
            .sink { PullRequestWatchStore.shared.setWorkspaceVisible($0) }
            .store(in: &keepAwakeObservers)
        _ = DesktopCaptureService.shared
        quickCaptureHotKey = QuickCaptureHotKey { [weak self] in self?.edgeDock?.toggleQuickCapture() }
        windowCaptureHotKey = QuickCaptureHotKey(
            identifier: 2, preference: { DesktopCaptureShortcut.stored },
            onPress: { [weak self] in self?.edgeDock?.captureWindow() })
        writeStatusItemDiagnosticIfRequested()
        HermAppUpdater.shared.isBusy = { [model] in model.isSending || model.status == .working }
        HermAppUpdater.shared.start()
        if !UserDefaults.standard.bool(forKey: DockOnboardingModel.completedKey),
            !ScrollPerformanceFixture.isRequested
        {
            showOnboarding()
        }
        if CommandLine.arguments.contains("--show-panel") {
            // The production app starts quietly in the menu bar. The debug
            // launcher passes this explicit argument so a manual run provides
            // immediate visible confirmation that the freshly built app is up —
            // a notch peek, not the full workspace.
            DispatchQueue.main.async { [weak self] in
                self?.edgeDock?.toggleQuickPreview()
            }
        }
    }

    func showOnboarding() {
        onboarding.open(client: model.controlRPCClient) { [weak self] in
            self?.dockPanel?.showFromNotification()
        }
    }

    /// Opt-in: blocks idle system sleep (the display may still sleep) while a turn is running.
    private func observeKeepAwake() {
        Publishers.CombineLatest(model.$status, model.$isSending)
            .map { status, sending in status == .working || sending }
            .removeDuplicates()
            .sink { [weak self] busy in self?.setKeepAwake(busy) }
            .store(in: &keepAwakeObservers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.setKeepAwake(self.model.status == .working || self.model.isSending)
            }
            .store(in: &keepAwakeObservers)
    }

    private func setKeepAwake(_ busy: Bool) {
        let enabled = UserDefaults.standard.bool(forKey: Self.keepAwakeKey)
        if busy, enabled, keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled, reason: "Herm is working")
        } else if !busy || !enabled, let activity = keepAwake {
            ProcessInfo.processInfo.endActivity(activity)
            keepAwake = nil
        }
    }

    /// Services menu entry "Send to Herm": drops the selected text into the composer and opens the panel.
    @objc func sendToHerm(
        _ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            error.pointee = "No text was selected."
            return
        }
        stageAndShow(text)
    }

    /// Puts outside text in the composer (when non-empty) and opens the panel.
    func stageAndShow(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { model.stageDraft(text) }
        dockPanel?.showFromNotification()
    }

    private func writeStatusItemDiagnosticIfRequested() {
        guard CommandLine.arguments.contains("--status-item-diagnostics") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let button = self.dockPanel?.statusItemDiagnostic
            let frame = button.flatMap { button in
                button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            }
            let detail =
                [
                    "title=\(button?.title ?? "")",
                    "visible=\(self.dockPanel?.statusItemIsVisible ?? false)",
                    "button_hidden=\(button?.isHidden ?? true)",
                    "button_frame=\(frame.map(NSStringFromRect) ?? "nil")",
                    "screen_count=\(NSScreen.screens.count)",
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
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged,
            handler: { [weak self] event in
                self?.handleCommandEvent(event)
            })
        {
            commandEventMonitors.append(globalMonitor)
        }
        // Two rapid Command shortcuts (⌘C then ⌘V) must not read as a
        // double-tap. Observing key activity between releases invalidates the
        // pair; events are inspected only for timing and never retained.
        if let localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler) {
            commandEventMonitors.append(localKeyMonitor)
        }
        if let globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: { [weak self] _ in
                self?.commandDoubleTapDetector.noteKeyActivity()
                self?.optionDoubleTapDetector.noteKeyActivity()
            })
        {
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
            if commandDoubleTapDetector.handle(
                isCommandDown: event.modifierFlags.contains(workspace.flag), at: event.timestamp)
            {
                if dockWindow?.isOpen == true {
                    dockWindow?.toggle()
                } else {
                    dockPanel?.toggleFromShortcut()
                }
            }
            return
        }
        let notch = DoubleTapShortcut.notch
        if notch.keyCodes.contains(event.keyCode),
            optionDoubleTapDetector.handle(isCommandDown: event.modifierFlags.contains(notch.flag), at: event.timestamp)
        {
            edgeDock?.toggleQuickPreview()
        }
    }

    /// A Spotlight result for a session opens the workspace on that session.
    func application(
        _ application: NSApplication, continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
            let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return false }
        let id = SessionSpotlightIndex.sessionID(from: identifier)
        dockPanel?.switchToWindow()
        if let session = model.sessions.first(where: { $0.id == id }) { model.resumeSession(session) }
        return true
    }

    /// Clicking the Dock icon (shown while the window is open) brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dockPanel?.switchToWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        edgeDock?.shutdown()
        PullRequestWatchStore.shared.stop()
        ReviewDraftStore.shared.flush()
        TerminalWorkspaceStore.shared.shutdown()
        QuickDraftStore.shared.flush()
        FilePreviewCenter.shared.flushSaves()
        // This is deliberately explicit: a menu-bar app can terminate without
        // releasing its delegate/model graph, so deinit is not a process-life
        // cycle hook for the local Hermes backend.
        model.shutdown()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard
            UserDefaults.standard.double(forKey: HermNotificationPreferences.snoozeKey)
                <= Date().timeIntervalSince1970
        else { return [] }
        return HermNotificationPreferences.enabled(
            HermNotificationPreferences.soundKey, defaults: .standard, fallback: true)
            ? [.banner, .list, .sound] : [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if response.actionIdentifier == HermNotificationAction.snooze {
            await MainActor.run {
                UserDefaults.standard.set(
                    Date().addingTimeInterval(30 * 60).timeIntervalSince1970,
                    forKey: HermNotificationPreferences.snoozeKey)
            }
            return
        }
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let choice = HermNotificationAction.choice(for: response.actionIdentifier)
        let requestID = response.notification.request.content.userInfo[HermNotificationAction.requestIDKey] as? String
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        let prURL = (response.notification.request.content.userInfo["herm.open-pr"] as? String).flatMap(
            URL.init(string:))
        await MainActor.run { [weak self] in
            if let choice, let requestID {
                self?.model.answerApproval(requestID: requestID, choice: choice)
            } else if let requestID, let reply {
                self?.model.answerClarification(requestID: requestID, text: reply)
            } else if let prURL, prURL.scheme == "https", prURL.host == "github.com" {
                self?.dockPanel?.showFromNotification()
                InAppBrowser.open(prURL)
            } else {
                self?.dockPanel?.showFromNotification()
            }
        }
    }
}

private final class UnreadBadgeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Color.dockDestructive).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
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
    private let preferences = CommandCenterPreferencesStore.shared
    private let statusItem: NSStatusItem
    private let unreadBadge = UnreadBadgeView(frame: .zero)
    private let panel = DockPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let notchPanel: NSWindow
    private let panelPresentation = DockPanelPresentation()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitors: [Any] = []
    private var desiredWidth = Metrics.workspaceWidth
    private var isFullscreen = false {
        didSet { panelPresentation.isFullscreen = isFullscreen }
    }
    private var workspaceHost: NSView?
    private var isWorkspaceVisible = false
    private var hideTask: DispatchWorkItem?
    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private let placement: () -> EdgeDockPlacement?
    private let onWillShow: () -> Void
    private let onHide: () -> Void
    var openWindow: (() -> Void)?
    var isWindowOpen: () -> Bool = { false }

    var statusItemDiagnostic: NSStatusBarButton? { statusItem.button }
    var statusItemIsVisible: Bool { statusItem.isVisible }

    init(
        model: DockModel, controlCenter: ControlCenterModel, notchPanel: NSWindow,
        placement: @escaping () -> EdgeDockPlacement?,
        onWillShow: @escaping () -> Void, onHide: @escaping () -> Void
    ) {
        self.model = model
        self.controlCenter = controlCenter
        self.notchPanel = notchPanel
        self.placement = placement
        self.onWillShow = onWillShow
        self.onHide = onHide
        // Temporarily keep the status item hidden: the movable notch is the launcher.
        // Retain its identity so restoring the menu-bar option later is reversible.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "io.github.chryzxc.Herm.statusItem"
        statusItem.isVisible = false
        super.init()

        configureStatusItem()
        configurePanel()
        installOutsideClickMonitors()
        observeModel()
        DockThemeStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.unreadBadge.needsDisplay = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isWorkspaceVisible else { return }
                self.resizePanel(to: self.desiredWidth)
            }.store(in: &cancellables)
        // A notch move (settings, rail menu or drag) re-docks an open workspace at
        // once. Hop a turn so the notch controller has applied the new side first.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .compactMap { _ in UserDefaults.standard.string(forKey: "hermes.notch.side") }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.isWorkspaceVisible, !self.isFullscreen,
                        let side = self.placement()?.side, side != self.panelPresentation.edgeSide
                    else { return }
                    self.resizePanel(to: self.desiredWidth)
                    EdgeDockMotion.reveal(self.workspaceHost, side: side, fromShortcut: false)
                }
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
        unreadBadge.layer?.cornerRadius = 3.5
        unreadBadge.isHidden = true
        unreadBadge.setAccessibilityElement(false)
        button.addSubview(unreadBadge)
        NSLayoutConstraint.activate([
            unreadBadge.widthAnchor.constraint(equalToConstant: 7),
            unreadBadge.heightAnchor.constraint(equalToConstant: 7),
            unreadBadge.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            unreadBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
        ])
    }

    private func configurePanel() {
        panel.delegate = self
        panel.isFloatingPanel = true
        // Hover (SwiftUI .onHover) needs mouse-moved events; only fullscreen set this before.
        panel.acceptsMouseMovedEvents = true
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
            rootView: DockPopover(
                model: model, panelPresentation: panelPresentation, controlCenter: controlCenter,
                availableWorkspaceWidth: { [weak self] in
                    self?.availableWorkspaceWidth() ?? .greatestFiniteMagnitude
                },
                onWorkspaceWidthChange: { [weak self] width in
                    // The split view changes pane count when the inspector toggles.
                    // Animating the window at the same time can leave an old
                    // divider drawn over the newly positioned conversation.
                    self?.resizePanel(to: width) ?? width
                },
                onClose: { [weak self] in
                    self?.hide()
                },
                onFullscreenToggle: { [weak self] in
                    self?.toggleFullscreen()
                },
                onOpenWindow: { [weak self] in
                    self?.switchToWindow()
                })
        )
        hostingView.wantsLayer = true
        // DockPopover owns the contour so a shortcut can attach cleanly to the
        // screen edge while ordinary presentations remain fully rounded.
        hostingView.layer?.masksToBounds = false
        hostingView.sizingOptions = []
        let container = hostingView.panelContainer()
        workspaceHost = container
        panel.contentView = container
    }

    private func observeModel() {
        model.$hasUnreadResponse
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hasUnreadResponse in
                self?.updateStatusIcon(hasUnreadResponse: hasUnreadResponse)
            }
            .store(in: &cancellables)

        model.$runtimeConfiguration.map { _ in () }
            .merge(with: model.$defaultBotName.map { _ in () })
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
        // A popover belongs to the workspace even where it overhangs the panel;
        // hiding here would tear it down before its row action runs.
        guard panel.attachedSheet == nil, !panel.dockHasInteractiveChildWindow else { return }
        hide()
    }

    private var statusItemFrame: NSRect {
        guard let button = statusItem.button,
            let window = button.window
        else { return .zero }
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
        statusItem.button?.image?.accessibilityDescription =
            unread ? "\(name) AI agent, unread update" : "\(name) AI agent"
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

    func showKanban(_ task: KanbanTaskSummary) {
        controlCenter.revealKanbanTask(task)
        showFromNotification()
        panelPresentation.kanbanRequest &+= 1
    }

    func showQuota() {
        showFromNotification()
        panelPresentation.quotaRequest &+= 1
    }

    func showSettings() {
        showFromNotification()
        panelPresentation.settingsRequest &+= 1
    }

    /// Only one workspace surface is shown at a time: the floating panel or the window.
    func switchToWindow() {
        hide()
        openWindow?()
    }

    private func show(fromShortcut: Bool = false) {
        // While the native window is open, every entry point focuses it instead.
        if isWindowOpen() {
            switchToWindow()
            return
        }
        if !isWorkspaceVisible {
            // Read fresh: Settings and the fullscreen toggle both write this key.
            isFullscreen = false  // the native window is the full-size surface
        }
        onWillShow()
        hideTask?.cancel()
        hideTask = nil
        let wasVisible = panel.isVisible
        isWorkspaceVisible = true
        panel.onCancel = { [weak self] in self?.hide() }
        panelPresentation.isEdgeAttached = true
        panelPresentation.edgeSide = placement()?.side ?? .right
        // A minimized panel would restore with its stale frame.
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        if let status = panelPresentation.islandStatus { panelPresentation.collapsedSize = status.collapsedSize }
        // Start from the collapsed notch shape; the morph below grows it.
        if !wasVisible { panelPresentation.isRevealed = false }
        installPanelContentIfNeeded()
        // Fullscreen leaves the host sized to the whole screen; resync it so the
        // compact panel sticks to the notch's edge instead of rendering offset.
        if let host = panel.contentView {
            host.autoresizingMask = [.width, .height]
            host.frame = NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size)
        }
        if isFullscreen {
            enterFullscreen()
        } else {
            resizePanel(to: desiredWidth)
        }
        // `swift run` leaves Terminal as the active app. A status-bar panel can
        // become key visually without receiving keyboard input until its agent
        // application is explicitly activated.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if !panelPresentation.isRevealed {
            // Also reverse an unfinished close when reopening the still-visible panel.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isWorkspaceVisible else { return }
                withAnimation(
                    self.reducesMotion
                        ? nil : EdgeDockMotion.panelMorph(side: self.panelPresentation.edgeSide, opening: true)
                ) {
                    self.panelPresentation.isRevealed = true
                }
            }
        }
        model.markPopoverVisible()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            DebugLog.write(
                "panel: shown (app active: \(NSApp.isActive), frontmost: \(frontmost), key: \(self.panel.isKeyWindow), responder: \(self.panel.responderDescription))"
            )
        }
    }

    private func hide() {
        guard isWorkspaceVisible else { return }
        EdgeDockMotion.cancel(workspaceHost)
        // Leave fullscreen state first so exitFullscreen's resize isn't skipped
        // (resizePanel bails while isFullscreen), which left the stale full-screen frame.
        let wasFullscreen = isFullscreen
        isFullscreen = false
        if wasFullscreen { exitFullscreen() }
        isWorkspaceVisible = false
        model.markPopoverHidden()
        onHide()
        guard !wasFullscreen, !reducesMotion else { return panel.orderOut(nil) }
        withAnimation(EdgeDockMotion.panelMorph(side: panelPresentation.edgeSide, opening: false)) {
            panelPresentation.isRevealed = false
        }
        let task = DispatchWorkItem { [weak self] in
            self?.hideTask = nil
            self?.panel.orderOut(nil)
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeDockMotion.morphSettle, execute: task)
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
        guard let screenFrame = placement()?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }

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
            hostingView.autoresizingMask = [.width, .height]
        }

        if isWorkspaceVisible {
            resizePanel(to: desiredWidth)
        }
    }

    func showIslandStatus(_ state: EdgeNotchState, openTask: @escaping (EdgeNotchTask) -> Void) {
        panelPresentation.islandStatus = state
        panelPresentation.openIslandTask = openTask
    }

    @discardableResult
    private func resizePanel(to width: CGFloat) -> CGFloat {
        desiredWidth = width
        guard !isFullscreen, let placement = placement() else { return width }
        let insets = placement.workspaceInsets
        let availableWidth = max(
            0, placement.screenFrame.width - Metrics.screenInset - insets.leading - insets.trailing)
        let fittedWidth = min(width, availableWidth)
        let height = min(Metrics.height, placement.visibleFrame.height)
        panelPresentation.edgeSide = placement.side
        panelPresentation.edgeInsets = insets
        panelPresentation.availableWidth = availableWidth
        panelPresentation.compactWidth = fittedWidth
        panelPresentation.compactHeight = max(0, height - insets.top - insets.bottom)
        let frame = placement.frame(width: fittedWidth + insets.leading + insets.trailing, height: height)
        // The notch clamps to the screen at its own height, so its rail can sit off the panel's center.
        let notchMidY =
            panelPresentation.islandStatus.map { $0.collapsedTop - $0.collapsedRailHeight / 2 }
            ?? placement.frame(width: 1, height: panelPresentation.collapsedSize.height).midY
        panelPresentation.collapsedOffsetY = placement.side == .top ? 0 : frame.midY - notchMidY

        // Session selection may re-evaluate layout without changing its size.
        guard !panel.frame.equalTo(frame) else { return fittedWidth }

        // SwiftUI owns the reveal; native frame animation races pane-count changes
        // and can finish at an obsolete size after another layout request.
        panel.setFrame(frame, display: true)
        return fittedWidth
    }

    /// Reads the capacity of the display hosting the menu-bar item without
    /// resizing the live panel. SwiftUI uses this only for layout decisions.
    private func availableWorkspaceWidth() -> CGFloat {
        guard let placement = placement() else { return .greatestFiniteMagnitude }
        let insets = placement.workspaceInsets
        return max(0, placement.screenFrame.width - Metrics.screenInset - insets.leading - insets.trailing)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DebugLog.write("panel: became key (responder: \(panel.responderDescription))")
    }

    func windowDidMiniaturize(_ notification: Notification) {
        hide()
    }

    func windowDidResignKey(_ notification: Notification) {
        DebugLog.write("panel: resigned key")
    }
}

@MainActor
final class DockPanel: NSPanel {
    static let hideFromScreenSharingKey = "herm.hideFromScreenSharing.v1"
    var acceptsWorkspaceFocus = true
    var onCancel: (() -> Void)?
    private var privacyObserver: NSObjectProtocol?

    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        applyScreenSharingPrivacy()
        privacyObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyScreenSharingPrivacy() }
        }
    }

    /// Keeps agent content out of screen shares and recordings; the stored flag is the only input.
    private func applyScreenSharingPrivacy() {
        sharingType = UserDefaults.standard.bool(forKey: Self.hideFromScreenSharingKey) ? .none : .readOnly
    }

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
            DebugLog.write(
                "panel: keyDown code=\(event.keyCode) repeat=\(event.isARepeat) responder=\(responderDescription)")
        }
        super.sendEvent(event)
    }
}
