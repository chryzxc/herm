import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ComposerInlineEditorTests {
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
