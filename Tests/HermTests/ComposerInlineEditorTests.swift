import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ComposerInlineEditorTests {
    @Test func unchangedUpdatesAndSelectionReuseNativeWork() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 352, height: 100))
        let sync = ComposerEditorSynchronization()
        var heights: [CGFloat] = []
        func update(_ source: String) {
            sync.synchronize(text, markdown: source, contexts: [], inset: .zero)
            sync.updatePresentation(text) { heights.append($0) }
        }
        update("/help")
        let serializations = sync.serializationCount
        let highlights = sync.highlightCount
        let layouts = sync.layoutCount
        for caret in 0...5 {
            text.setSelectedRange(NSRange(location: caret, length: 0))
            #expect(sync.markdown(in: text) == "/help")
            update("/help")
        }
        #expect(sync.serializationCount == serializations)
        #expect(sync.highlightCount == highlights)
        #expect(sync.layoutCount == layouts)
        #expect(heights.count == 1)
        text.textStorage?.replaceCharacters(in: NSRange(location: 1, length: 4), with: "work")
        #expect(sync.markdown(in: text) == "/work")
        update("/work")
        #expect(sync.serializationCount == serializations + 1)
        #expect(sync.highlightCount == highlights + 1)
        #expect(sync.layoutCount == layouts + 1)
        update("/goal") // External same-length replacement must not reuse the old draft.
        #expect(sync.markdown(in: text) == "/goal")
        #expect(sync.highlightCount == highlights + 2)
        let beforeResize = sync.layoutCount
        text.setFrameSize(NSSize(width: 180, height: 100))
        update("/goal")
        #expect(sync.layoutCount == beforeResize + 1)
    }

    @Test func contextReplacementAndAttachmentEditsInvalidateSerialization() throws {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 352, height: 100))
        let sync = ComposerEditorSynchronization()
        var first = ChatContext(id: "first", title: "First", body: "one")
        first.inlineToken = "\u{E000}"
        sync.synchronize(text, markdown: "- \u{E000}", contexts: [first], inset: .zero)
        #expect(text.string.hasPrefix("• "))
        #expect(sync.markdown(in: text) == "- \u{E000}")
        var second = ChatContext(id: "second", title: "Second", body: "two")
        second.inlineToken = "\u{E001}"
        let replacement = InlineContextAttachment(context: second, token: "\u{E001}")
        text.textStorage?.addAttribute(.attachment, value: replacement, range: NSRange(location: 2, length: 1))
        #expect(sync.markdown(in: text) == "- \u{E001}")
        sync.synchronize(text, markdown: "- \u{E000}", contexts: [first], inset: .zero)
        #expect(sync.markdown(in: text) == "- \u{E000}")
        let old = try #require(text.textStorage?.attribute(.attachment, at: 2, effectiveRange: nil) as? InlineContextAttachment)
        first = ChatContext(id: "first", title: "Renamed", body: "one")
        first.inlineToken = "\u{E000}"
        sync.synchronize(text, markdown: "- \u{E000}", contexts: [first], inset: .zero)
        let new = try #require(text.textStorage?.attribute(.attachment, at: 2, effectiveRange: nil) as? InlineContextAttachment)
        #expect(old !== new)
        #expect(sync.markdown(in: text) == "- \u{E000}")
    }

    @Test func nativePlainTextEditorRetainsCopyableContextAttachments() async throws {
        _ = NSApplication.shared
        var context = ChatContext(id: "native-excerpt", title: "Selected lines", body: "Captured context")
        context.inlineToken = "\u{E000}"
        let source = "Before \u{E000} after"
        let editor = ComposerInputEditor(
            text: .constant(source), isFocused: false, onSubmit: {}, onCompletionKey: { _ in false },
            onFocusChanged: { _ in }, onCaretMoved: { _, _ in }, takePendingCaret: { nil }, onTextChanged: { _, _ in },
            onContentHeightChanged: { _ in }, contexts: [context])
        let host = NSHostingView(rootView: editor.frame(width: 352, height: 100))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 352, height: 100), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try #require(find(host))
        #expect(InlineContextCodec.serialize(text.attributedString()) == source)
        let storage = text.attributedString()
        #expect(storage.attribute(.attachment, at: 7, effectiveRange: nil) is InlineContextAttachment)
        text.setSelectedRange(NSRange(location: 0, length: storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.declareTypes([.string], owner: nil)
        #expect(text.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "Before [Selected lines] after")
        pasteboard.releaseGlobally()
    }
}
