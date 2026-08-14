import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import UserNotifications

extension KeyboardShortcuts.Name {
    static let toggleHermesControl = Self(
        "toggleHermesControl",
        initial: .init(.space, modifiers: [.command, .option])
    )
}

@MainActor
final class HermesAgentDockDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = DockModel()
    private var dockPanel: DockPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockPanel = DockPanelController(model: model)
        if HermesAppRuntime.supportsUserNotifications {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        } else {
            DebugLog.write("model: UserNotifications unavailable outside an app bundle")
        }
        KeyboardShortcuts.onKeyUp(for: .toggleHermesControl) { [weak self] in
            self?.dockPanel?.toggleFromShortcut()
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
    private let statusItem: NSStatusItem
    private let unreadBadge = UnreadBadgeView(frame: .zero)
    private let panel: DockPanel
    private var cancellables = Set<AnyCancellable>()
    private var desiredWidth = Metrics.workspaceWidth

    init(model: DockModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.workspaceWidth, height: Metrics.height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureStatusItem()
        configurePanel()
        observeModel()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "Hermes")
        button.imagePosition = .imageOnly
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
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.hide() }
        let hostingView = NSHostingView(
            rootView: DockPopover(model: model, onWorkspaceWidthChange: { [weak self] width in
                self?.resizePanel(to: width) ?? width
            })
        )
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 22
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
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
    }

    private func updateStatusIcon(hasUnreadResponse: Bool) {
        let symbol = hasUnreadResponse
            ? "bubble.left.and.bubble.right.fill"
            : "bubble.left.and.bubble.right"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: hasUnreadResponse ? "Hermes, unread update" : "Hermes"
        )
        statusItem.button?.toolTip = hasUnreadResponse ? "Hermes — unread update" : "Hermes"
        unreadBadge.isHidden = !hasUnreadResponse
        DebugLog.write("status item: unread badge \(hasUnreadResponse ? "shown" : "hidden")")
    }

    @objc private func togglePanel() {
        panel.isVisible ? hide() : show()
    }

    func toggleFromShortcut() {
        if panel.isVisible {
            hide()
        } else {
            show()
            model.requestComposerFocus()
        }
    }

    func showFromNotification() {
        if !panel.isVisible { show() }
    }

    private func show() {
        resizePanel(to: desiredWidth, animated: false)
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

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.markPopoverHidden()
    }

    @discardableResult
    private func resizePanel(to width: CGFloat, animated: Bool = true) -> CGFloat {
        desiredWidth = width
        guard let button = statusItem.button else { return width }

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
    override var canBecomeMain: Bool { false }

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
