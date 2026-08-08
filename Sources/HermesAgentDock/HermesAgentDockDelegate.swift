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
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        KeyboardShortcuts.onKeyUp(for: .toggleHermesControl) { [weak self] in
            self?.dockPanel?.toggleFromShortcut()
        }
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

@MainActor
private final class DockPanelController: NSObject, NSWindowDelegate {
    private enum Metrics {
        static let compactWidth: CGFloat = 420
        // Keep the chat compact while giving the right Control workspace
        // enough room to reach the screen edge on wide displays.
        static let workspaceWidth: CGFloat = 960
        static let height: CGFloat = 640
        static let screenInset: CGFloat = 12
        static let menuGap: CGFloat = 8
    }

    private let model: DockModel
    private let statusItem: NSStatusItem
    private let panel: DockPanel
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var desiredWidth = Metrics.compactWidth

    init(model: DockModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = DockPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.compactWidth, height: Metrics.height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureStatusItem()
        configurePanel()
        observeModel()
        observeOutsideClicks()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "Hermes")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp])
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
        panel.contentView = NSHostingView(
            rootView: DockPopover(model: model, onWorkspaceWidthChange: { [weak self] width in
                self?.resizePanel(to: width)
            })
        )
    }

    private func observeModel() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
    }

    private func observeOutsideClicks() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hide()
            }
        }
    }

    private func updateStatusIcon() {
        let symbol = model.hasUnreadResponse
            ? "bubble.left.and.bubble.right.fill"
            : "bubble.left.and.bubble.right"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Hermes")
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

    private func resizePanel(to width: CGFloat, animated: Bool = true) {
        desiredWidth = width
        guard let button = statusItem.button else { return }

        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? button.window?.screen
            ?? NSScreen.main
        guard let screen else { return }

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
