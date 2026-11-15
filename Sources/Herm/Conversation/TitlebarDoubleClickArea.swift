import AppKit
import SwiftUI

/// Transparent titlebar strip: double-click follows the system title-bar preference (zoom by default), single-click drags it.
struct TitlebarDoubleClickArea: NSViewRepresentable {
    final class Strip: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // Honor System Settings > Desktop & Dock > "Double-click a window's title bar to".
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.miniaturize(nil)
                case "None": break
                default: window?.zoom(nil)
                }
            } else {
                super.mouseDown(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> Strip { Strip() }
    func updateNSView(_ view: Strip, context: Context) {}
}
