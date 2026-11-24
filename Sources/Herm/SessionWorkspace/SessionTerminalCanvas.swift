import AppKit
import SwiftTerm
import SwiftUI

/// Each shell retains its screen and scrollback when switching tabs.
@MainActor
final class SessionTerminalEmulator: NSObject, @preconcurrency TerminalViewDelegate {
    let view: ContextTerminalView
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

    func reset() { view.receiveOutput(Array("\u{1b}c".utf8)[...]) }
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
    final class Coordinator {}

    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @Environment(\.dockHostVisible) private var hostVisible
    let session: LocalTerminalSession
    var onAttach: ((String, Int, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ContextTerminalView {
        let view = session.emulator.view
        view.presentationOwner = ObjectIdentifier(context.coordinator)
        view.requestsInitialFocus = true
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ContextTerminalView, context: Context) {
        let owner = ObjectIdentifier(context.coordinator)
        guard view.presentationOwner == owner else { return }
        view.onAttach = onAttach
        applyTheme(view)
        view.presentsOutput = hostVisible
        if hostVisible, view.requestsInitialFocus {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.presentationOwner == owner, view.requestsInitialFocus,
                    view.presentsOutput, let window = view.window
                else { return }
                view.requestsInitialFocus = false
                window.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ view: ContextTerminalView, coordinator: Coordinator) {
        // A retained emulator may already be mounted by a new representable.
        guard view.presentationOwner == ObjectIdentifier(coordinator) else { return }
        view.presentationOwner = nil
        view.presentsOutput = false
        view.onAttach = nil
        view.requestsInitialFocus = false
    }

    private func applyTheme(_ view: ContextTerminalView) {
        let font = NSFont.monospacedSystemFont(
            ofSize: DockTypography.size(.code, scale: workspaceScale), weight: .regular)
        if view.font != font { view.font = font }
        guard view.paletteRevision != DockThemeRuntime.revision else { return }
        view.paletteRevision = DockThemeRuntime.revision
        view.nativeBackgroundColor = NSColor(Color.dockCanvas)
        view.nativeForegroundColor = NSColor(Color.dockPrimaryText)
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
    var presentationOwner: ObjectIdentifier?
    var requestsInitialFocus = false
    private var hasPendingDisplay = false
    var presentsOutput = false {
        didSet {
            guard presentsOutput, !oldValue, hasPendingDisplay else { return }
            hasPendingDisplay = false
            super.bufferActivated(source: getTerminal())
            feed(byteArray: [])
        }
    }

    func receiveOutput(_ bytes: ArraySlice<UInt8>) {
        if presentsOutput {
            feed(byteArray: bytes)
        } else {
            // Keep the ANSI parser and scrollback live while deferring the AppKit refresh.
            getTerminal().feed(buffer: bytes)
            hasPendingDisplay = true
        }
    }

    override func scrolled(source: Terminal, yDisp: Int) {
        if presentsOutput { super.scrolled(source: source, yDisp: yDisp) }
    }

    override func bufferActivated(source: Terminal) {
        if presentsOutput { super.bufferActivated(source: source) }
    }

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
