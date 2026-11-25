import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ComposerFollowUpTests {
    @Test func contextUsesOnlyRecentConversationText() throws {
        let longReply = "The first detail. " + String(repeating: "x", count: 700) + " The final detail."
        let messages: [ChatMessage] = [
            .init(role: .user, text: "Old question"),
            .init(role: .hermes, text: "Old answer"),
            .init(role: .user, text: "Earlier question"),
            .init(role: .hermes, text: "Earlier answer"),
            .init(role: .user, text: "What changed?"),
            .init(role: .hermes, text: longReply),
            .init(role: .hermes, text: "Internal detail", systemEvent: .init(label: "Model switch")),
        ]
        let prompt = try #require(ComposerFollowUp.prompt(in: messages))
        #expect(prompt.hasPrefix("User: Earlier question"))
        #expect(prompt.contains("User: What changed?\n\nAssistant: The first detail."))
        #expect(prompt.hasSuffix("The final detail."))
        #expect(!prompt.contains("Old question"))
        #expect(!prompt.contains("Internal detail"))
        #expect(prompt.count < 720)
        #expect(ComposerFollowUp.prompt(in: [.init(role: .hermes, text: "Welcome")]) == nil)
        #expect(ComposerFollowUp.prompt(in: messages + [.init(role: .user, text: "Still waiting")]) == nil)
        #expect(ComposerFollowUp.prompt(in: messages + [.init(role: .hermes, text: "Error", isError: true)]) == nil)
    }

    @Test func outputMustBeAShortPlainDraft() {
        #expect(OnDeviceAssist.cleanFollowUp("\nCould you show what changed? ") == "Could you show what changed?")
        for invalid in ["", "NO_SUGGESTION", "One\nTwo", "/help", "@bot", String(repeating: "x", count: 141)] {
            #expect(OnDeviceAssist.cleanFollowUp(invalid) == nil)
        }
    }

    @Test func focusedComposerInsertsSuggestionAndAppliesSettingImmediately() async throws {
        _ = NSApplication.shared
        let suite = "ComposerFollowUpTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = DockModel(
            sessionAgentStateFileURL: path.appendingPathComponent("agents.json"), defaults: defaults,
            initialSessionID: "follow-up-fixture", botActivityFileURL: path.appendingPathComponent("bots.json"))
        defer { model.shutdown() }
        model.messages = [
            .init(role: .user, text: "Review the layout."), .init(role: .hermes, text: "The gutter moved."),
        ]
        let suggestion = "Can you show me where the gutter moved?"
        let composer = ChatComposerView(
            model: model, composer: model.composer, speechInput: SpeechInput(), botMode: BotModeModel(), onStop: {},
            generateFollowUp: { _ in suggestion })
        let host = NSHostingView(rootView: composer.defaultAppStorage(defaults).dockThemedRoot())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 180), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        let editor = try #require(findEditor(in: host))
        try #require(window.makeFirstResponder(editor))
        try await wait(in: host) { editor.onFollowUpSuggestion?() == suggestion }
        #expect(model.draft.isEmpty)
        #expect(editor.accessibilityHelp()?.contains(suggestion) == true)

        let tab = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        editor.keyDown(with: tab)
        #expect(editor.string == suggestion)
        #expect(model.draft == suggestion)
        #expect(model.messages.count == 2)
        #expect(editor.selectedRange().location == suggestion.utf16.count)
        #expect(editor.onFollowUpSuggestion?() == nil)

        model.draft = ""
        try await wait(in: host) { editor.string.isEmpty && editor.onFollowUpSuggestion?() == suggestion }
        defaults.set(false, forKey: ComposerTypingSettings.followUpSuggestionsKey)
        try await wait(in: host) { editor.accessibilityHelp()?.contains(suggestion) != true }
        #expect(editor.onFollowUpSuggestion?() == nil)
        #expect(model.draft.isEmpty)
    }

    private func findEditor(in view: NSView) -> ComposerInputTextView? {
        if let editor = view as? ComposerInputTextView { return editor }
        return view.subviews.lazy.compactMap(findEditor(in:)).first
    }

    private func wait(in host: NSView, until ready: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready())
    }
}
