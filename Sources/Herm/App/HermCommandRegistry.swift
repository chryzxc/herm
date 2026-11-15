import AppKit
import SwiftUI

struct HermCommand: Identifiable {
    enum ID: String, CaseIterable, Hashable {
        case settings
        case commandPalette
        case back
        case forward
        case newChat
        case stopGeneration
        case closeSession
        case toggleSidebar
        case toggleInspector
        case showShortcutList
    }

    enum Scope: Hashable {
        case application
        case workspace
    }

    enum Menu: String, CaseIterable, Identifiable {
        case file = "File"
        case view = "View"
        case go = "Go"
        case session = "Session"
        case help = "Help"

        var id: String { rawValue }
    }

    let id: ID
    let title: String
    let key: KeyEquivalent?
    let modifiers: EventModifiers
    let scope: Scope
    let menu: Menu

    static let all: [HermCommand] = [
        HermCommand(id: .settings, title: "Settings…", key: ",", modifiers: .command, scope: .application, menu: .file),
        HermCommand(
            id: .commandPalette, title: "Command palette", key: "k", modifiers: .command, scope: .workspace, menu: .view
        ),
        HermCommand(id: .back, title: "Back", key: "[", modifiers: .command, scope: .workspace, menu: .go),
        HermCommand(id: .forward, title: "Forward", key: "]", modifiers: .command, scope: .workspace, menu: .go),
        HermCommand(id: .newChat, title: "New chat", key: "n", modifiers: .command, scope: .workspace, menu: .file),
        HermCommand(
            id: .stopGeneration, title: "Stop generation", key: ".", modifiers: .command, scope: .workspace,
            menu: .session),
        HermCommand(
            id: .closeSession, title: "Close current session", key: "w", modifiers: .command, scope: .workspace,
            menu: .session),
        HermCommand(
            id: .toggleSidebar, title: "Toggle sidebar", key: "s", modifiers: [.control, .command],
            scope: .workspace, menu: .view),
        HermCommand(
            id: .toggleInspector, title: "Toggle inspector", key: "i", modifiers: [.option, .command],
            scope: .workspace, menu: .view),
        HermCommand(
            id: .showShortcutList, title: "Keyboard shortcuts", key: "/", modifiers: .command,
            scope: .workspace, menu: .help),
    ]

    var shortcut: KeyboardShortcut? { key.map { KeyboardShortcut($0, modifiers: modifiers) } }
}

@MainActor
final class DockActionPalettePresentation: ObservableObject {
    @Published private(set) var isPresented = false
    var actionHandler: ((DockAction) -> Void)?
    var pendingAction: DockAction?

    func present() { isPresented = true }

    func dismiss() { isPresented = false }

    func installActionHandler(_ handler: @escaping (DockAction) -> Void) {
        actionHandler = handler
        guard let pendingAction else { return }
        self.pendingAction = nil
        handler(pendingAction)
    }
}

@MainActor
struct HermCommandHandlers {
    let openSettings: () -> Void
    let openCommandPalette: () -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let newChat: () -> Void
    let stopGeneration: () -> Void
    let closeSession: () -> Void
    let toggleSidebar: () -> Void
    let toggleInspector: () -> Void
    let showShortcutList: () -> Void

    func perform(_ command: HermCommand.ID) {
        switch command {
        case .settings: openSettings()
        case .commandPalette: openCommandPalette()
        case .back: goBack()
        case .forward: goForward()
        case .newChat: newChat()
        case .stopGeneration: stopGeneration()
        case .closeSession: closeSession()
        case .toggleSidebar: toggleSidebar()
        case .toggleInspector: toggleInspector()
        case .showShortcutList: showShortcutList()
        }
    }
}

/// Routes menu commands to the workspace in the key window.
///
/// Herm hosts its workspace in AppKit windows through `NSHostingView`, so SwiftUI focused
/// values set inside them never reach the app's `.commands`. Each workspace registers its
/// handlers for its window instead.
@MainActor
final class HermCommandRouter {
    static let shared = HermCommandRouter()

    private final class Entry {
        weak var owner: AnyObject?
        var handlers: HermCommandHandlers
        init(owner: AnyObject, handlers: HermCommandHandlers) {
            self.owner = owner
            self.handlers = handlers
        }
    }

    private var entries: [Entry] = []
    private let keyOwner: () -> AnyObject?

    init(keyOwner: @escaping () -> AnyObject? = { NSApp.keyWindow ?? NSApp.mainWindow }) {
        self.keyOwner = keyOwner
    }

    /// Registers or refreshes the handlers for one window. The newest registration is the
    /// fallback when the key window has none, such as while Settings is in front.
    func register(_ handlers: HermCommandHandlers, for owner: AnyObject) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
        entries.append(Entry(owner: owner, handlers: handlers))
    }

    func unregister(_ owner: AnyObject) {
        entries.removeAll { $0.owner == nil || $0.owner === owner }
    }

    @discardableResult
    func perform(_ command: HermCommand.ID) -> Bool {
        entries.removeAll { $0.owner == nil }
        let key = keyOwner()
        guard let entry = entries.last(where: { key != nil && $0.owner === key }) ?? entries.last else {
            return false
        }
        entry.handlers.perform(command)
        return true
    }
}

/// Registers a workspace's command handlers for the window that hosts it.
struct HermCommandRegistration: NSViewRepresentable {
    let handlers: HermCommandHandlers

    func makeNSView(context: Context) -> RegistrationView { RegistrationView() }

    func updateNSView(_ view: RegistrationView, context: Context) { view.handlers = handlers }

    static func dismantleNSView(_ view: RegistrationView, coordinator: ()) { view.unregister() }

    final class RegistrationView: NSView {
        var handlers: HermCommandHandlers? {
            didSet { register() }
        }
        private weak var registeredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let registeredWindow, registeredWindow !== window {
                HermCommandRouter.shared.unregister(registeredWindow)
            }
            register()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func unregister() {
            if let registeredWindow { HermCommandRouter.shared.unregister(registeredWindow) }
            registeredWindow = nil
        }

        private func register() {
            guard let window, let handlers else { return }
            HermCommandRouter.shared.register(handlers, for: window)
            registeredWindow = window
        }
    }
}

enum HermCommandRegistry {
    static func commands(in menu: HermCommand.Menu) -> [HermCommand] {
        HermCommand.all.filter { $0.menu == menu }
    }

    static var paletteCommands: [HermCommand] { HermCommand.all }

    static func command(_ id: HermCommand.ID) -> HermCommand {
        guard let command = HermCommand.all.first(where: { $0.id == id }) else {
            preconditionFailure("Missing Herm command: \(id.rawValue)")
        }
        return command
    }
}

struct HermCommandMenus: Commands {
    let openSettings: () -> Void

    var body: some Commands {
        CommandMenu(HermCommand.Menu.file.rawValue) {
            commandButtons(in: .file)
        }
        CommandMenu(HermCommand.Menu.view.rawValue) {
            commandButtons(in: .view)
        }
        CommandMenu(HermCommand.Menu.go.rawValue) {
            commandButtons(in: .go)
        }
        CommandMenu(HermCommand.Menu.session.rawValue) {
            commandButtons(in: .session)
        }
        CommandMenu(HermCommand.Menu.help.rawValue) {
            commandButtons(in: .help)
        }
    }

    @ViewBuilder
    private func commandButtons(in menu: HermCommand.Menu) -> some View {
        ForEach(HermCommandRegistry.commands(in: menu)) { command in
            commandButton(command) {
                if command.id == .settings { openSettings() } else { HermCommandRouter.shared.perform(command.id) }
            }
        }
    }

    @ViewBuilder
    private func commandButton(_ command: HermCommand, action: @escaping () -> Void) -> some View {
        if let shortcut = command.shortcut {
            Button(command.title, action: action).keyboardShortcut(shortcut)
        } else {
            Button(command.title, action: action)
        }
    }
}

extension HermCommand {
    var keycap: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.command) { symbols += "⌘" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        let keyText = key.map { $0 == "," ? "," : String($0.character).uppercased() } ?? ""
        return symbols + keyText
    }
}

struct HermShortcutList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts")
                .dockFont(.pageTitle, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(HermCommand.all) { command in
                        HStack {
                            Text(command.title)
                                .dockFont(.body)
                                .foregroundStyle(Color.dockPrimaryText)
                            Spacer()
                            Text(command.keycap)
                                .dockFont(.body, weight: .semibold, design: .monospaced)
                                .foregroundStyle(Color.dockSecondaryText)
                                .dockPill(compact: true)
                        }
                        .dockPadding(.vertical, 8)
                        if command.id != HermCommand.all.last?.id {
                            Divider().overlay(Color.dockBorder)
                        }
                    }
                }
            }
        }
        .dockPadding(20)
        .frame(width: 440, height: 520)
    }
}
