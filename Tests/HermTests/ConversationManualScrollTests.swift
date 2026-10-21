import AppKit
import Darwin
import SwiftUI
import Testing
@testable import Herm

@MainActor
struct ConversationManualScrollTests {
    private static let source = "# Response\n\n" + String(
        repeating: "A paragraph with **strong text** and `inline code` that wraps naturally.\n\n",
        count: 32
    ) + "```swift\nlet value = 42\n```\n"

    @MainActor
    private final class NativeFixture {
        let document = NativeMarkdownDocumentContainerView()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window: NSWindow
        let sections: [NSView]

        init() {
            _ = NSApplication.shared
            let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 0, themeRevision: 0)
            document.apply(document: MarkdownRenderDocumentBuilder.build(source: source, key: key))
            document.keepsAccessibilitySectionsMounted = true
            document.frame = NSRect(x: 0, y: 0, width: 640, height: document.measuredHeight(forWidth: 640))
            scroll.documentView = document
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            document.layoutSubtreeIfNeeded()
            sections = document.subviews
        }

        func scroll(to y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            document.layoutSubtreeIfNeeded()
        }
    }

    @Test func offscreenSectionsRemountWithoutChangingHeightOrOrder() throws {
        let fixture = NativeFixture()
        defer { fixture.window.orderOut(nil) }
        let height = fixture.document.intrinsicContentSize.height
        #expect(fixture.sections.count > 20)
        fixture.document.keepsAccessibilitySectionsMounted = false
        fixture.document.layoutSubtreeIfNeeded()
        if !NSApp.isFullKeyboardAccessEnabled {
            #expect(fixture.document.subviews.count < fixture.sections.count)
        }
        let first = try #require(fixture.sections.first)
        let last = try #require(fixture.sections.last)
        fixture.scroll(to: height - fixture.scroll.contentView.bounds.height)
        #expect(last.superview === fixture.document)
        if !NSApp.isFullKeyboardAccessEnabled { #expect(first.superview == nil) }
        #expect(fixture.document.intrinsicContentSize.height == height)
        fixture.scroll(to: 0)
        #expect(first.superview === fixture.document)
        #expect(fixture.document.intrinsicContentSize.height == height)

        fixture.document.keepsAccessibilitySectionsMounted = true
        fixture.document.layoutSubtreeIfNeeded()
        #expect(fixture.document.subviews == fixture.sections)
        #expect(fixture.document.intrinsicContentSize.height == height)
    }

    @Test func scrollingKeepsFocusedTextAndSelectionMounted() throws {
        let fixture = NativeFixture()
        defer { fixture.window.orderOut(nil) }
        fixture.document.keepsAccessibilitySectionsMounted = false
        fixture.document.layoutSubtreeIfNeeded()
        let text = try #require(fixture.document.subviews.compactMap { $0 as? NativeMarkdownTextSectionView }.first)
        #expect(fixture.window.makeFirstResponder(text))
        let range = NSRange(location: 0, length: 5)
        text.setSelectedRange(range)
        fixture.scroll(to: fixture.document.frame.height - fixture.scroll.contentView.bounds.height)
        #expect(text.superview === fixture.document)
        #expect(fixture.window.firstResponder === text)
        #expect(text.selectedRange() == range)
    }

    @Test func viewportResizeMountsNewlyVisibleSections() {
        let fixture = NativeFixture()
        defer { fixture.window.orderOut(nil) }
        fixture.document.keepsAccessibilitySectionsMounted = false
        fixture.document.layoutSubtreeIfNeeded()
        let before = Set(fixture.document.subviews.map(ObjectIdentifier.init))
        fixture.scroll.contentView.setFrameSize(NSSize(width: 640, height: 1_000))
        fixture.document.layoutSubtreeIfNeeded()
        let after = Set(fixture.document.subviews.map(ObjectIdentifier.init))
        #expect(before.isSubset(of: after))
        if !NSApp.isFullKeyboardAccessEnabled { #expect(after.count > before.count) }
    }

    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    @Test(arguments: [false, true])
    func movingAMessageIntoViewRemountsItsSections(moveAncestor: Bool) {
        let fixture = NativeFixture()
        defer { fixture.window.orderOut(nil) }
        let content = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 640, height: 3_000))
        let row = FlippedDocument(frame: content.bounds)
        fixture.scroll.documentView = content
        content.addSubview(row)
        row.addSubview(fixture.document)
        let movingView = moveAncestor ? row : fixture.document
        movingView.setFrameOrigin(NSPoint(x: 0, y: 2_000))
        fixture.document.keepsAccessibilitySectionsMounted = false
        fixture.scroll(to: 0)
        if !NSApp.isFullKeyboardAccessEnabled { #expect(fixture.document.subviews.isEmpty) }
        movingView.setFrameOrigin(.zero)
        content.layoutSubtreeIfNeeded()
        #expect(!fixture.document.subviews.isEmpty)
    }

    @Test func streamedAppendPreservesReadingPositionAndRetainedSections() throws {
        let fixture = NativeFixture()
        defer { fixture.window.orderOut(nil) }
        fixture.document.keepsAccessibilitySectionsMounted = false
        fixture.scroll(to: 300)
        let before = fixture.scroll.contentView.bounds.origin
        let first = try #require(fixture.sections.first)
        let oldHeight = fixture.document.frame.height
        let source = Self.source + "\n\n# Appended section\n\nMore streamed text.\n"
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 0)
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        fixture.document.applyStreaming(sections: document.sections, source: source)
        fixture.document.setFrameSize(NSSize(width: 640, height: fixture.document.measuredHeight(forWidth: 640)))
        fixture.document.layoutSubtreeIfNeeded()
        #expect(fixture.document.frame.height > oldHeight)
        #expect(fixture.scroll.contentView.bounds.origin == before)
        #expect(first.superview === fixture.document)
        fixture.scroll(to: fixture.document.frame.height - fixture.scroll.contentView.bounds.height)
        #expect(fixture.document.subviews.compactMap { $0 as? NativeMarkdownTextSectionView }.contains {
            $0.string.contains("More streamed text.")
        })
    }

    private final class Metrics {
        var geometryReads = 0
        var viewports: [MessageNavigatorViewport] = []
        var bounds = ConversationContentBounds(topMinY: 0, bottomMaxY: 0)
    }

    private struct Transcript: View {
        let controller: ConversationScrollController
        let metrics: Metrics
        private let messageIDs = (0..<12).map { _ in UUID() }

        var body: some View {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(0..<12, id: \.self) { index in
                        MarkdownMessageView(markdown: source + "\nResponse \(index)")
                            .background {
                                GeometryReader { geometry in
                                    let _ = { metrics.geometryReads += 1 }()
                                    Color.clear.preference(
                                        key: MessageNavigatorViewportPreferenceKey.self,
                                        value: [MessageNavigatorViewport(
                                            target: MessageNavigatorTarget(sessionID: "fixture", messageID: messageIDs[index]),
                                            index: index,
                                            minY: geometry.frame(in: .named("document")).minY,
                                            maxY: geometry.frame(in: .named("document")).maxY
                                        )]
                                    )
                                }
                            }
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ConversationContentBoundsPreferenceKey.self,
                            value: ConversationContentBounds(
                                topMinY: geometry.frame(in: .named("document")).minY,
                                bottomMaxY: geometry.frame(in: .named("document")).maxY
                            )
                        )
                    }
                }
                .background {
                    ConversationScrollEventObserver(
                        controller: controller, onScroll: { _, _ in }, onScrollSettled: { _ in }
                    )
                }
                .coordinateSpace(name: "document")
                .onPreferenceChange(MessageNavigatorViewportPreferenceKey.self) { metrics.viewports = $0 }
                .onPreferenceChange(ConversationContentBoundsPreferenceKey.self) { metrics.bounds = $0 }
            }
            .frame(width: 640, height: 600)
        }
    }

    /// Opt-in process CPU comparison; it never starts Hermes or reads a user's transcript.
    /// The accessibility mounting flag keeps the control's entire view tree mounted;
    /// this does not enable the system screen reader. Run both orders to reduce cache bias.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_SCROLL_PROFILE"] == "1"))
    func measureManualScrollWork() async throws {
        for keepsAll in [true, false, false, true] {
            try await profile(keepsAllSections: keepsAll)
        }
    }

    private func profile(keepsAllSections: Bool) async throws {
        let controller = ConversationScrollController()
        let metrics = Metrics()
        let host = NSHostingView(rootView: Transcript(controller: controller, metrics: metrics))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        let initial = try #require(controller.geometry)
        #expect(initial.documentHeight > initial.visibleHeight)
        controller.shiftVisibleTop(by: min(5_000, initial.documentHeight / 2))
        host.layoutSubtreeIfNeeded()
        func documents(in view: NSView) -> [NativeMarkdownDocumentContainerView] {
            if let document = view as? NativeMarkdownDocumentContainerView { return [document] }
            return view.subviews.flatMap { documents(in: $0) }
        }
        let containers = documents(in: host)
        for container in containers { container.keepsAccessibilitySectionsMounted = keepsAllSections }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        let mounted = containers.reduce(0) { $0 + $1.subviews.count }
        #expect(containers.count == 12)
        let readsBefore = metrics.geometryReads
        let started = clock()
        for step in 0..<120 {
            controller.shiftVisibleTop(by: step < 60 ? 24 : -24)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(8))
        }
        let cpuMS = Double(clock() - started) / Double(CLOCKS_PER_SEC) * 1_000
        #expect(controller.geometry?.documentHeight == initial.documentHeight)
        if keepsAllSections {
            #expect(containers.allSatisfy { $0.keepsAccessibilitySectionsMounted })
            #expect(containers.reduce(0) { $0 + $1.subviews.count } == mounted)
        }
        print("manual_scroll_fixture mode=\(keepsAllSections ? "all-sections" : "viewport-sections") steps=120 cpu_ms=\(String(format: "%.1f", cpuMS)) mounted_sections=\(mounted) row_geometry_reads=\(metrics.geometryReads - readsBefore)")
    }
}
