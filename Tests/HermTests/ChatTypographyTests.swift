import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct ChatTypographyTests {
    @Test func messagesShareTextSizeAndUpdateWithoutChangingContent() async throws {
        let source = "The same conversation text."
        let chunk = StreamingPresentationChunk(
            id: 0, text: source, revision: 0, isMutableTail: true, context: .markdown)
        func content(scale: CGFloat) -> some View {
            VStack {
                NativeMarkdownMessageView(markdown: source, hugsContent: true)
                MarkdownMessageView(markdown: source).equatable()
                NativeStreamingMarkdownView(chunks: [chunk], source: source, themeRevision: DockThemeRuntime.revision)
            }
            .environment(\.dockWorkspaceScale, scale)
            .frame(width: 600)
        }
        let host = NSHostingView(rootView: content(scale: 1))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for scale: CGFloat in [1, 1.1, 1.2, 1.3, 1] {
            host.rootView = content(scale: scale)
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let textViews = descendants(host).compactMap { $0 as? NativeMarkdownTextSectionView }
                .filter { $0.string == source }
            #expect(textViews.count == 3)
            for view in textViews {
                let storage = try #require(view.textStorage)
                let font = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                #expect(font.pointSize == DockTypography.size(.conversation, scale: scale))
                #expect(view.measuredHeight(forWidth: 600) > 0)
            }
        }
    }

    @Test func codeHighlightingAndDiffsRetainSelectedSize() async throws {
        let editor = CodeEditorContainerView(text: "let value = 1", filePath: "sample.swift")
        let diff = DiffCanvasContainer()
        diff.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let document = DiffDocument(path: "sample.swift", patch: "@@ -1 +1 @@\n-old\n+new")
        for scale: CGFloat in [1, 1.3, 1.1] {
            editor.setTextScale(scale)
            CodeSyntaxHighlighter.apply(to: editor.textView, tokens: [(NSRange(location: 0, length: 3), .keyword)])
            let expected = DockTypography.size(.code, scale: scale)
            #expect(editor.textView.font?.pointSize == expected)
            let typing = try #require(editor.textView.typingAttributes[.font] as? NSFont)
            #expect(typing.pointSize == expected)
            diff.update(
                document, split: true, wraps: true, wordDiffs: true, findRequest: 0, reveal: nil,
                viewport: nil, onNote: nil, onComment: nil, textScale: scale)
            try await Task.sleep(for: .milliseconds(50))
            diff.layoutSubtreeIfNeeded()
            let columns = descendants(diff).compactMap { $0 as? NSTextView }
            #expect(columns.count == 2)
            for column in columns { #expect(column.font?.pointSize == expected) }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
