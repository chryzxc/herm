import AppKit
import SwiftUI

@MainActor
final class DockOnboardingWindow {
    private var window: NSWindow?

    func open(client: HermesRPCClientProtocol, finish: @escaping () -> Void) {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let setup = DockOnboardingModel(client: client)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Set up Herm"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 560)
        window.contentView = NSHostingView(
            rootView: DockOnboardingView(
                setup: setup, bots: setup.bots,
                close: { [weak window] in window?.close() },
                finish: { [weak window] in
                    window?.close()
                    finish()
                }))
        self.window = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
