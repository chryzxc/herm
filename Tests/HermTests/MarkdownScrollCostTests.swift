import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Work a transcript scroll tick must not repeat for every mounted Markdown
/// block: SwiftUI hosting updates, nested scroll view tiles, and link rect
/// layout. Each was a measured per-frame cost in long Markdown chats.
@MainActor
@Suite struct MarkdownScrollCostTests {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private struct Fixture {
        let window: NSWindow
        let scroll: NSScrollView
        let container: NativeMarkdownDocumentContainerView
        let height: CGFloat
    }

    private func makeFixture(_ source: String) -> Fixture {
        let document = MarkdownRenderDocumentBuilder.build(
            source: source, key: MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let container = NativeMarkdownDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 620, height: 10))
        container.apply(document: document)
        let height = container.measuredHeight(forWidth: 620)
        container.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        let documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 640, height: height + 2_000))
        documentView.addSubview(container)
        scroll.documentView = documentView
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return Fixture(window: window, scroll: scroll, container: container, height: height)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { child in [child as? T].compactMap { $0 } + descendants(of: child, as: type) }
    }

    private var codeSource: String {
        let code = (0..<12).map { "let value\($0) = compute(\($0)) // a long trailing comment that overflows" }
        return "Intro\n\n```swift\n" + code.joined(separator: "\n") + "\n```\n\nOutro."
    }

    @Test func preparedDocumentGeometryUsesTheMatchingWidth() throws {
        let document = MarkdownRenderDocumentBuilder.build(
            source: codeSource, key: .init(messageID: UUID(), contentRevision: 1, themeRevision: 1))
        let reference = NativeMarkdownDocumentContainerView()
        let controller = ConversationScrollController()
        reference.scrollController = controller
        reference.apply(document: document)
        let height = reference.measuredHeight(forWidth: 620)
        let context = try #require(controller.markdownMeasurementContext)
        var frames: [CGRect] = []
        for (index, section) in document.sections.enumerated() {
            let key = NativeMarkdownDocumentContainerView.measurementKey(for: section, context: context)
            let sectionHeight = try #require(NativeMarkdownCompletedHeightCache.height(for: key))
            let spacing =
                index == 0
                ? 0
                : NativeMarkdownDocumentContainerView.spacing(
                    after: document.sections[index - 1].source, before: section)
            frames.append(
                NativeMarkdownPreparedLayout.frame(
                    after: frames.last, width: context.width, height: sectionHeight, spacing: spacing))
        }
        controller.preparedPage = ConversationPreparedPage(
            documents: [document.key: document], measurements: [:],
            layouts: [document.key: .init(context: context, frames: frames)])
        let mounted = NativeMarkdownDocumentContainerView()
        mounted.scrollController = controller
        mounted.apply(document: document)
        let hits = NativeMarkdownCompletedHeightCache.hits
        #expect(mounted.measuredHeight(forWidth: 620) == height)
        #expect(NativeMarkdownCompletedHeightCache.hits == hits)
        #expect(mounted.sectionMeasurementCount == 0)
        #expect(mounted.measuredHeight(forWidth: 440) == reference.measuredHeight(forWidth: 440))
    }

    @Test func finishingStreamRetainsTheSelectedTextViewAcrossSectionIDChanges() throws {
        let source = "Paragraph to keep selected"
        let fixture = makeFixture(source)
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        let section = try #require(document.sections.first)
        fixture.container.applyStreaming(
            sections: [
                .init(
                    id: 99, sourceRange: section.sourceRange, source: section.source,
                    kind: section.kind, continuation: section.continuation)
            ],
            source: source)
        fixture.container.layoutSubtreeIfNeeded()
        let streamText = try #require(fixture.container.mountedSectionViews.first as? NSTextView)
        streamText.setSelectedRange(NSRange(location: 0, length: 9))
        let measurements = fixture.container.sectionMeasurementCount

        fixture.container.apply(document: document)
        fixture.container.layoutSubtreeIfNeeded()

        #expect(fixture.container.mountedSectionViews.first === streamText)
        #expect(streamText.selectedRange() == NSRange(location: 0, length: 9))
        #expect(fixture.container.sectionMeasurementCount == measurements)
    }

    /// A hosted SwiftUI view re-renders whenever its window position changes,
    /// so the code block chrome must stay pure AppKit.
    @Test func codeBlockChromeHostsNoSwiftUI() {
        let fixture = makeFixture(codeSource)
        #expect(descendants(of: fixture.container, as: NativeMarkdownCopyButton.self).count == 1)
        #expect(
            !descendants(of: fixture.container, as: NSView.self).contains {
                String(describing: type(of: $0)).contains("HostingView")
            })
    }

    /// Moving the transcript marks nested scroll views for layout. Re-tiling
    /// them when nothing they depend on changed was the largest scroll cost.
    @Test func outerScrollTickDoesNotRetileCodeScrollView() throws {
        let fixture = makeFixture(codeSource)
        let codeScroll = try #require(
            descendants(of: fixture.container, as: NativeMarkdownHorizontalScrollView.self).first)
        let tiles = codeScroll.tileCount

        for offset in stride(from: 4, through: 40, by: 4) {
            fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(offset)))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            fixture.window.displayIfNeeded()
        }

        #expect(codeScroll.tileCount == tiles)
    }

    /// A real size change must still tile, or the scrollers go stale.
    @Test func codeScrollViewStillTilesWhenResized() throws {
        let fixture = makeFixture(codeSource)
        let codeScroll = try #require(
            descendants(of: fixture.container, as: NativeMarkdownHorizontalScrollView.self).first)
        let tiles = codeScroll.tileCount

        codeScroll.setFrameSize(NSSize(width: codeScroll.frame.width - 40, height: codeScroll.frame.height))
        codeScroll.layoutSubtreeIfNeeded()

        #expect(codeScroll.tileCount > tiles)
    }

    @Test func copyButtonCopiesAndShowsConfirmationUntilCleared() {
        let button = NativeMarkdownCopyButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        var copies = 0
        button.onCopy = { copies += 1 }

        button.performClick(nil)

        #expect(copies == 1)
        #expect(button.isShowingConfirmation)
        #expect(button.toolTip == "Copied")

        button.setConfirmation(false)

        #expect(!button.isShowingConfirmation)
        #expect(button.toolTip == "Copy code")
    }

    /// Cursor rects reset on every scroll tick. Unchanged text and viewport
    /// reuse the measured link rects; changed text measures again.
    @Test func linkRectsAreReusedUntilTextChanges() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let text = NativeMarkdownTextSectionView()
        text.update(markdown: "Read [the docs](https://example.com) and [more](https://example.org).", kind: .prose)
        let height = text.measuredHeight(forWidth: 600)
        text.frame = NSRect(x: 0, y: 0, width: 600, height: height)
        window.contentView?.addSubview(text)

        text.resetCursorRects()
        let computed = text.linkRectComputationCount
        text.resetCursorRects()
        text.resetCursorRects()

        #expect(computed >= 1)
        #expect(text.linkRectComputationCount == computed)

        text.update(markdown: "Now [one link](https://example.net).", kind: .prose)
        text.resetCursorRects()

        #expect(text.linkRectComputationCount == computed + 1)

        text.update(markdown: "Plain text with no links.", kind: .prose)
        text.resetCursorRects()
        #expect(text.linkRectComputationCount == computed + 1)
    }

    /// Mounting a section lays out only what it draws, so a long section's
    /// layout must not be forced up front, while measurement stays complete.
    @Test func displayedTextUsesNonContiguousLayoutWithCompleteMeasurement() {
        let text = NativeMarkdownTextSectionView()
        let paragraph = String(repeating: "Long wrapped text for layout. ", count: 400)
        text.update(markdown: paragraph, kind: .prose)

        #expect(text.layoutManager?.allowsNonContiguousLayout == true)

        let height = text.measuredHeight(forWidth: 400)
        let contiguous = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        contiguous.textContainer?.lineFragmentPadding = 0
        contiguous.textContainerInset = .zero
        contiguous.textContainer?.size = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        contiguous.textStorage?.setAttributedString(text.attributedString())
        contiguous.layoutManager?.ensureLayout(for: contiguous.textContainer!)
        let expected = ceil(contiguous.layoutManager!.usedRect(for: contiguous.textContainer!).height)

        #expect(abs(height - expected) <= 1)
    }
}
