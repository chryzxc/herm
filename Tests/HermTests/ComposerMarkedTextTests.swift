import AppKit
import Testing

@testable import Herm

/// While an input method is composing (Japanese, Chinese, Korean), Return and the
/// arrow keys belong to the input method: Return commits the conversion and the
/// arrows move through candidates. They must not send the message or drive the
/// completion menu.
@MainActor
struct ComposerMarkedTextTests {
    private final class Spy {
        var submits = 0
        var completionKeys: [ComposerCompletionKey] = []
    }

    private func makeComposer() -> (ComposerInputTextView, NSWindow, Spy) {
        _ = NSApplication.shared
        let spy = Spy()
        let text = ComposerInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        text.onSubmit = { spy.submits += 1 }
        // No completion menu is open, so the menu declines every key.
        text.onCompletionKey = { key in
            spy.completionKeys.append(key)
            return false
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = text
        window.makeFirstResponder(text)
        return (text, window, spy)
    }

    private func key(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private func compose(_ text: ComposerInputTextView) {
        text.setMarkedText(
            "にほんご", selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func returnWhileComposingDoesNotSend(keyCode: UInt16) throws {
        let (text, window, spy) = makeComposer()
        compose(text)
        try #require(text.hasMarkedText())

        text.keyDown(with: try key(keyCode, "\r", in: window))

        #expect(spy.submits == 0)
        #expect(spy.completionKeys.isEmpty)
    }

    @Test func arrowsWhileComposingDoNotDriveCompletion() throws {
        let (text, window, spy) = makeComposer()
        compose(text)

        text.keyDown(with: try key(125, "\u{f701}", in: window))
        text.keyDown(with: try key(126, "\u{f700}", in: window))

        #expect(spy.completionKeys.isEmpty)
    }

    @Test func returnAfterTheConversionIsCommittedSends() throws {
        let (text, window, spy) = makeComposer()
        compose(text)
        text.unmarkText()
        try #require(!text.hasMarkedText())

        text.keyDown(with: try key(36, "\r", in: window))

        #expect(spy.submits == 1)
    }
}
