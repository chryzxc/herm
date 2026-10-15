import AppKit
import SwiftUI

/// A regular, resizable window hosting the same workspace as the floating panel.
/// It exists for a secondary display: park it and it stays until closed, while
/// the notch keeps working on the main screen. The app only shows in the Dock
/// and Cmd-Tab while this window is open.
@MainActor
final class DockWindowController: NSObject, NSWindowDelegate {
    /// Reopen at launch if the window was open when the app last ran.
    static let wasOpenKey = "hermes.window.was-open"

    private let model: DockModel
    private let controlCenter: ControlCenterModel
    private let presentation = DockPanelPresentation()
    private var window: NSWindow?
    var onReturnToFloating: (() -> Void)?

    /// Window mode: true from `open()` until the user closes the window. Hiding
    /// via the shortcut or minimizing keeps it, so the floating panel stays away.
    private(set) var isOpen = false

    init(model: DockModel, controlCenter: ControlCenterModel) {
        self.model = model
        self.controlCenter = controlCenter
        presentation.isFullscreen = true // the window always uses the full Mission Control layout
    }

    func open() {
        let window = window ?? makeWindow()
        self.window = window
        isOpen = true
        NSApp.setActivationPolicy(.regular)
        // A global shortcut fires while another app is frontmost; cooperative
        // activation can be refused there, so take focus explicitly.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        model.markPopoverVisible()
        UserDefaults.standard.set(true, forKey: Self.wasOpenKey)
    }

    /// Shortcut: hide when frontmost, otherwise bring it on top of other apps.
    func toggle() {
        if let window, window.isKeyWindow, NSApp.isActive {
            window.orderOut(nil)
            model.markPopoverHidden()
        } else {
            open()
        }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        NSApp.setActivationPolicy(.accessory)
        model.markPopoverHidden()
        UserDefaults.standard.set(false, forKey: Self.wasOpenKey)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Herm"
        // Unified chrome: app background runs under the titlebar, like VS Code.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar gives the native 52pt title row with the
        // traffic lights centered in it; the sidebar header and chat title fill that row.
        window.toolbar = NSToolbar(identifier: "HermDockWindowToolbar")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 900, height: 600)
        window.delegate = self
        let host = NSHostingView(rootView: DockPopover(
            model: model, panelPresentation: presentation, controlCenter: controlCenter,
            onClose: { [weak window] in window?.performClose(nil) },
            onFullscreenToggle: { [weak window] in window?.toggleFullScreen(nil) },
            onOpenWindow: { [weak self, weak window] in
                window?.close()
                self?.onReturnToFloating?()
            },
            usesWindowChrome: true
        ))
        host.sizingOptions = []
        // Herm lays out its own 52pt title row. A titlebar safe area would let
        // split and scroll views stretch up behind it and cover page headers.
        host.safeAreaRegions = []
        window.contentView = host
        if !window.setFrameUsingName("HermDockWindow") {
            // First launch: prefer a secondary display, since that is the point.
            let screen = NSScreen.screens.first { $0 != NSScreen.main } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                window.setFrame(frame.insetBy(dx: frame.width * 0.06, dy: frame.height * 0.06), display: false)
            }
        }
        window.setFrameAutosaveName("HermDockWindow")
        return window
    }
}
