import AppKit
import SwiftTerm
import SwiftUI

/// Each shell retains its screen and scrollback when switching tabs.
@MainActor
final class SessionTerminalEmulator: NSObject, @preconcurrency TerminalViewDelegate {
    let view: TerminalView
    private weak var session: LocalTerminalSession?

    init(session: LocalTerminalSession) {
        self.session = session
        view = ContextTerminalView(
            frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(scrollback: LocalTerminalSession.maxOutputLines))
        super.init()
        view.terminalDelegate = self
        view.setAccessibilityLabel("Terminal. Type commands at the shell prompt.")
        view.setAccessibilityIdentifier(WorkflowAccessibilityIdentifier.terminalOutput)
    }

    func reset() { view.feed(text: "\u{1b}c") }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { session?.sendInput(data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(columns: newCols, rows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct SessionTerminalCanvas: NSViewRepresentable {
    let session: LocalTerminalSession
    var onAttach: ((String, Int, Int) -> Void)? = nil

    func makeNSView(context: Context) -> TerminalView {
        let view = session.emulator.view
        (view as? ContextTerminalView)?.onAttach = onAttach
        applyTheme(view)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        (view as? ContextTerminalView)?.onAttach = onAttach
        applyTheme(view)
    }

    private func applyTheme(_ view: TerminalView) {
        view.nativeBackgroundColor = NSColor(Color.dockCanvas)
        view.nativeForegroundColor = NSColor(Color.dockPrimaryText)
        guard let themed = view as? ContextTerminalView,
            themed.paletteRevision != DockThemeRuntime.revision
        else { return }
        themed.paletteRevision = DockThemeRuntime.revision
        view.caretColor = NSColor(Color.dockAccent)
        view.caretTextColor = NSColor(Color.dockOnAccentText)
        view.selectedTextBackgroundColor = NSColor(Color.dockAccentMuted)
        view.selectedTextForegroundColor = NSColor(Color.dockPrimaryText)
        // Keep ANSI meanings; explicit RGB output remains owned by the terminal program.
        let normal: [SwiftUI.Color] = [
            .dockSecondaryText, .dockDestructive, .dockSuccess,
            DockAccentColor.amber.color, .dockInfo, .dockMerged, DockAccentColor.cyan.color, .dockPrimaryText,
        ]
        let colors = (normal + normal).map { color -> SwiftTerm.Color in
            let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .gray
            return SwiftTerm.Color(
                red: UInt16(rgb.redComponent * 65535),
                green: UInt16(rgb.greenComponent * 65535), blue: UInt16(rgb.blueComponent * 65535))
        }
        view.installColors(colors)
    }
}

final class ContextTerminalView: TerminalView {
    var paletteRevision: Int?
    var onAttach: ((String, Int, Int) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Attach to chat", action: #selector(attachSelection), keyEquivalent: "")
        item.target = self
        item.isEnabled = !selection.getSelectedText().isEmpty && onAttach != nil
        menu.addItem(item)
        return menu
    }
    @objc private func attachSelection() {
        onAttach?(selection.getSelectedText(), selection.start.row + 1, selection.end.row + 1)
    }
}
