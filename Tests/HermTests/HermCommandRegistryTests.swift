import Testing

@testable import Herm

struct HermCommandRegistryTests {
    @Test func noCommandsShareAKeyEquivalentWithinAScope() {
        let assignments = HermCommand.all.map { command in
            guard let key = command.key else { return "missing:\(command.id)" }
            return "\(command.scope):\(key.character):\(command.modifiers)"
        }
        #expect(Set(assignments).count == assignments.count)
    }

    @Test func everyCommandAppearsInAMenuAndThePalette() {
        let menuIDs = HermCommand.Menu.allCases.flatMap { HermCommandRegistry.commands(in: $0).map(\.id) }
        let paletteIDs = HermCommandRegistry.paletteCommands.map(\.id)
        let commandIDs = HermCommand.all.map(\.id)
        #expect(menuIDs.count == commandIDs.count)
        #expect(Set(menuIDs) == Set(commandIDs))
        #expect(paletteIDs == commandIDs)
        #expect(HermCommand.Menu.allCases.map(\.rawValue) == ["File", "View", "Go", "Session", "Help"])
    }

    @Test @MainActor func handlersDispatchEachRegisteredAction() {
        var performed: [HermCommand.ID] = []
        let handlers = HermCommandHandlers(
            openSettings: { performed.append(.settings) },
            openCommandPalette: { performed.append(.commandPalette) },
            goBack: { performed.append(.back) },
            goForward: { performed.append(.forward) },
            newChat: { performed.append(.newChat) },
            stopGeneration: { performed.append(.stopGeneration) },
            closeSession: { performed.append(.closeSession) },
            toggleSidebar: { performed.append(.toggleSidebar) },
            toggleInspector: { performed.append(.toggleInspector) },
            showShortcutList: { performed.append(.showShortcutList) }
        )

        for command in HermCommand.all {
            handlers.perform(command.id)
        }

        #expect(performed == HermCommand.ID.allCases)
    }

    @Test @MainActor func commandPaletteHandlerRequestsSharedPalettePresentation() {
        let presentation = DockActionPalettePresentation()
        let handlers = HermCommandHandlers(
            openSettings: {},
            openCommandPalette: { presentation.present() },
            goBack: {},
            goForward: {},
            newChat: {},
            stopGeneration: {},
            closeSession: {},
            toggleSidebar: {},
            toggleInspector: {},
            showShortcutList: {}
        )

        handlers.perform(.commandPalette)

        #expect(presentation.isPresented)
    }

    @Test @MainActor func sidebarPaletteButtonUsesSharedPresentationRequest() {
        let presentation = DockActionPalettePresentation()

        presentation.present()

        #expect(presentation.isPresented)
    }

    @Test @MainActor func deferredPaletteActionRunsWhenSidebarHandlerMounts() {
        let presentation = DockActionPalettePresentation()
        var performed: [DockAction] = []
        presentation.pendingAction = .restartDock

        presentation.installActionHandler { performed.append($0) }

        #expect(performed == [.restartDock])
        #expect(presentation.pendingAction == nil)
    }

    @Test func approvalCardKeysRequireFocusAndAnIdleRequest() {
        #expect(ApprovalCardKeyAction.choice(for: .returnKey, isFocused: true, isPending: false) == ApprovalChoice.once)
        #expect(ApprovalCardKeyAction.choice(for: .deleteKey, isFocused: true, isPending: false) == ApprovalChoice.deny)
        #expect(ApprovalCardKeyAction.choice(for: .returnKey, isFocused: false, isPending: false) == nil)
        #expect(ApprovalCardKeyAction.choice(for: .deleteKey, isFocused: false, isPending: false) == nil)
        #expect(ApprovalCardKeyAction.choice(for: .returnKey, isFocused: true, isPending: true) == nil)
        #expect(ApprovalCardKeyAction.choice(for: .deleteKey, isFocused: true, isPending: true) == nil)
    }

    @Test func paletteLabelsUseTheRegisteredKeyEquivalents() {
        #expect(
            HermCommandRegistry.paletteCommands.map(\.keycap) == [
                "⌘,", "⌘K", "⌘[", "⌘]", "⌘N", "⌘.", "⌘W", "⌃⌘S", "⌥⌘I", "⌘/",
            ])
    }
}
