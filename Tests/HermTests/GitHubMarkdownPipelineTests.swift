import AppKit
import Testing
@testable import Herm

@MainActor
struct GitHubMarkdownPipelineTests {
    @Test func legacyNativeHostUsesTheCanonicalAttributedDocument() {
        let source = "# Heading\n\n1. First **bold**\n2. Second [safe](https://example.com)\n\n> Quote\n\n| Name | Value |\n| --- | --- |\n| a | b |\n\n```swift\nlet answer = 42\n```"
        let canonical = NativeMarkdownAttributedTextBuilder.document(source, palette: NativeMarkdownPalette()).string
        let legacy = NativeMarkdownMessageView.Coordinator.attributedString(for: source)
        #expect(legacy.string == canonical.string)
        // NSTextBlock and dynamic-color instances have identity-based equality.
        // Compare their rendered attributes instead of allocation identity.
        func attributes(_ value: NSAttributedString) -> [String] {
            (0..<value.length).map { index in
                let row = value.attributes(at: index, effectiveRange: nil)
                let font = row[.font] as? NSFont
                let paragraph = row[.paragraphStyle] as? NSParagraphStyle
                let color = (row[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
                return "\(font?.fontName ?? ""):\(font?.pointSize ?? 0):\(row[.link] ?? ""):\(paragraph?.headIndent ?? 0):\(paragraph?.textBlocks.count ?? 0):\(color?.redComponent ?? 0):\(color?.greenComponent ?? 0):\(color?.blueComponent ?? 0)"
            }
        }
        #expect(attributes(legacy) == attributes(canonical))
        #expect(MarkdownMessageView.renderBlocks(for: source) == MarkdownRenderDocumentBuilder.renderBlocks(for: source))
    }
    @Test func presentationSizeChangesInvalidateAttributedOutput() {
        let first = NativeMarkdownTextSectionView()
        first.update(markdown: "Body **bold**", kind: .prose, bodySize: 12)
        #expect((first.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 12)
        first.update(markdown: "Body **bold**", kind: .prose, bodySize: 17, bodyWeight: .medium)
        #expect((first.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 17)
        let second = NativeMarkdownTextSectionView()
        second.update(markdown: "Body **bold**", kind: .prose, bodySize: 12)
        #expect((second.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 12)
    }
    @Test func tableTextMatchesReplySizeAcrossPresentationChanges() {
        let source = "| Name | Value |\n| --- | --- |\n| Job | Remote |"
        let view = NativeMarkdownTextSectionView()
        for size in [CGFloat(14), DockWorkspaceScale.points(14, scale: DockWorkspaceScale.window), 14] {
            view.update(markdown: source, kind: .table, bodySize: size)
            let text = view.textStorage!
            for word in ["Name", "Value", "Job", "Remote"] {
                let range = (text.string as NSString).range(of: word)
                #expect(range.location != NSNotFound)
                guard range.location != NSNotFound else { continue }
                #expect((text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?.pointSize == size)
            }
        }
    }
    @Test func headingsAndCodeFollowReplyPresentationSize() {
        for size in [CGFloat(14), CGFloat(16), CGFloat(14)] {
            let palette = NativeMarkdownPalette(bodySize: size)
            let heading = NativeMarkdownAttributedTextBuilder.document("# Heading", palette: palette).string
            let code = NativeMarkdownAttributedTextBuilder.code("let value = 1", palette: palette)
            #expect((heading.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == palette.fontSize(18))
            #expect((code.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == palette.fontSize(12.5))
        }
        let view = NativeMarkdownCodeView()
        for size in [CGFloat(14), CGFloat(16), CGFloat(14)] {
            view.update(code: "```swift\nlet value = 1\n```", language: "swift", bodySize: size)
            let text = view.subviews.flatMap { $0.subviews }.flatMap { $0.subviews }.compactMap { $0 as? NSTextView }.first
            #expect(text != nil)
            #expect((text?.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == NativeMarkdownPalette(bodySize: size).fontSize(12.5))
        }
    }
    @Test func documentCacheSeparatesSourceAndThemeRevisions() {
        let id = UUID()
        let first = MarkdownRenderDocumentCache.document(for: "old", key: .init(messageID: id, contentRevision: 1, themeRevision: 0))
        let updated = MarkdownRenderDocumentCache.document(for: "new", key: .init(messageID: id, contentRevision: 2, themeRevision: 0))
        let themed = MarkdownRenderDocumentCache.document(for: "new", key: .init(messageID: id, contentRevision: 2, themeRevision: 1))
        #expect(first.source == "old")
        #expect(updated.source == "new")
        #expect(themed.key.themeRevision == 1)
    }
}
