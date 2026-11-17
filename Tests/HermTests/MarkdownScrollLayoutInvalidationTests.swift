import AppKit
import Testing

@testable import Herm

@MainActor
@Suite struct MarkdownScrollLayoutInvalidationTests {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private struct Fixture {
        let window: NSWindow
        let scroll: NSScrollView
        let container: NativeMarkdownDocumentContainerView
        let height: CGFloat
    }

    private func makeFixture() -> Fixture {
        let paragraphs = (0..<40).map { "Paragraph \($0) " + String(repeating: "scroll text ", count: 30) }
        let document = MarkdownRenderDocumentBuilder.build(
            source: paragraphs.joined(separator: "\n\n"),
            key: MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let container = NativeMarkdownDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 620, height: 10))
        container.apply(document: document)
        let height = container.measuredHeight(forWidth: 620)
        container.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        let documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 640, height: height))
        documentView.addSubview(container)
        scroll.documentView = documentView
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        return Fixture(window: window, scroll: scroll, container: container, height: height)
    }

    /// Every scroll tick posts a clip-view bounds change. A Markdown document
    /// whose mounted sections stay the same must not ask AppKit for another
    /// layout pass on each tick; that work lands in the display cycle per frame.
    @Test func scrollTickThatKeepsMountedSectionsDoesNotInvalidateLayout() throws {
        let fixture = makeFixture()
        #expect(fixture.height > 2_000)
        #expect(!fixture.container.needsLayout)
        let mounted = fixture.container.mountedSectionViews.count

        fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: 2))

        #expect(fixture.container.mountedSectionViews.count == mounted)
        #expect(!fixture.container.needsLayout)
    }

    /// Scrolling far enough to need other sections mounts them from the scroll
    /// notification itself, so no layout pass is spent on the new range.
    @Test func scrollingIntoOtherSectionsMountsWithoutLayoutRequest() throws {
        let fixture = makeFixture()
        let container = fixture.container
        #expect(fixture.height > 2_000)
        let visitsBefore = container.viewportSectionVisits
        let mountsBefore = container.viewportMountChanges
        let mountedBefore = Set(container.mountedSectionViews.map(ObjectIdentifier.init))

        fixture.scroll.contentView.scroll(to: NSPoint(x: 0, y: fixture.height / 2))

        #expect(container.viewportMountChanges > mountsBefore)
        #expect(container.viewportSectionVisits > visitsBefore)
        #expect(Set(container.mountedSectionViews.map(ObjectIdentifier.init)) != mountedBefore)
        #expect(!container.needsLayout)
    }
}
