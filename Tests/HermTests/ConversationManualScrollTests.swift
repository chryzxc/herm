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

        init(source: String = ConversationManualScrollTests.source, keepsAllSections: Bool = true) {
            _ = NSApplication.shared
            let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 0, themeRevision: 0)
            document.apply(document: MarkdownRenderDocumentBuilder.build(source: source, key: key))
            document.keepsAccessibilitySectionsMounted = keepsAllSections
            document.frame = NSRect(x: 0, y: 0, width: 640, height: document.measuredHeight(forWidth: 640))
            scroll.documentView = document
            window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = scroll
            scroll.layoutSubtreeIfNeeded()
            document.layoutSubtreeIfNeeded()
            sections = document.subviews
        }

        func scroll(to y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            document.layoutSubtreeIfNeeded()
        }
    }

    @Test func coldDocumentsCreateDisplayViewsOnlyForTheViewport() {
        let source = String(repeating: "A unique **allocation check** with `inline code`.\n\n", count: 512)
        let fixture = NativeFixture(source: source, keepsAllSections: false)
        defer { fixture.window.orderOut(nil) }
        if !NSApp.isFullKeyboardAccessEnabled {
            #expect(fixture.document.instantiatedSectionCount < 50)
        }
        let height = fixture.document.intrinsicContentSize.height
        fixture.scroll(to: height - fixture.scroll.contentView.bounds.height)
        #expect(!fixture.document.subviews.isEmpty)
        #expect(fixture.document.intrinsicContentSize.height == height)
        fixture.document.keepsAccessibilitySectionsMounted = true
        fixture.document.layoutSubtreeIfNeeded()
        #expect(fixture.document.instantiatedSectionCount == 512)
    }

    @Test func codeCopyIncludesContinuationsThatHaveNeverBeenMounted() throws {
        let body = String(repeating: "let copiedValue = 42\n", count: 2_000)
        let source = "```swift\n" + body + "```\n"
        let streaming = StreamingText()
        streaming.appendPresentation(source)
        let fixture = NativeFixture(source: source, keepsAllSections: false)
        defer { fixture.window.orderOut(nil) }
        let opening = try #require(streaming.chunks.first)
        let fencedOpening = StreamingPresentationChunk(
            id: opening.id, text: opening.text, revision: opening.revision, isMutableTail: opening.isMutableTail,
            context: .fencedCode(marker: "`", length: 3, language: "swift")
        )
        let sections = MarkdownRenderDocumentBuilder.sections(for: [fencedOpening] + streaming.chunks.dropFirst())
        fixture.document.applyStreaming(sections: sections, source: source)
        fixture.document.setFrameSize(NSSize(width: 640, height: fixture.document.measuredHeight(forWidth: 640)))
        fixture.document.layoutSubtreeIfNeeded()
        let first = try #require(fixture.document.subviews.compactMap { $0 as? NativeMarkdownCodeView }.first)
        #expect(sections.count > 2)
        if !NSApp.isFullKeyboardAccessEnabled {
            #expect(fixture.document.instantiatedSectionCount < sections.count)
        }
        let copied = fixture.document.codeBlockText(startingAt: first)
        let isExact = copied == body.trimmingCharacters(in: .newlines)
        #expect(isExact, "Copy must preserve all lines, including a chunk boundary in the middle of a line")
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

    @Test func historyCorrectionPreservesMovementDuringPageLayout() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 640, height: 8_000))
        scroll.documentView = document
        let controller = ConversationScrollController()
        controller.clipView = scroll.contentView
        controller.shiftVisibleTop(by: 1_000)
        var anchor = ConversationScrollAnchor(messageID: UUID(), offset: -100)
        // The trackpad keeps moving while SwiftUI measures the incoming page.
        controller.shiftVisibleTop(by: -75)
        anchor.recordUserScroll(delta: -75)
        document.setFrameSize(NSSize(width: 640, height: 10_000))
        controller.shiftVisibleTop(by: anchor.correction(rowMinY: 2_900, visibleTop: try #require(controller.geometry).visibleTop))
        #expect(try #require(controller.geometry).visibleTop == 2_925)
        // Evicting earlier rows preserves movement in the other direction too.
        var laterAnchor = ConversationScrollAnchor(messageID: anchor.messageID, offset: -25)
        controller.shiftVisibleTop(by: 50)
        laterAnchor.recordUserScroll(delta: 50)
        // AppKit may clamp the origin before the new row frames arrive.
        document.setFrameSize(NSSize(width: 640, height: 2_000))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_600))
        controller.shiftVisibleTop(by: laterAnchor.correction(
            rowMinY: 900, visibleTop: try #require(controller.geometry).visibleTop
        ))
        #expect(try #require(controller.geometry).visibleTop == 975)
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
        var longMarkdown: String? = nil
        var streaming: StreamingText? = nil
        var defersStreaming = true
        var indices = 0..<12
        var messageIDs = (0..<12).map { _ in UUID() }
        var rowSource: ((Int) -> String)? = nil

        var body: some View {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(indices), id: \.self) { index in
                        ConversationMessageRow(
                            message: ChatMessage(
                                id: messageIDs[index], role: .hermes,
                                text: index == 11 && streaming != nil ? ""
                                    : rowSource?(index) ?? (index == 11 ? longMarkdown : nil) ?? (source + "\nResponse \(index)")
                            ),
                            isStreamingMessage: index == 11 && streaming != nil,
                            streamingText: streaming, activeBotProfileID: nil,
                            botsByID: [:], avatarImages: [:], botRosterRevision: 0,
                            onImagePreview: { _ in }
                        )
                            .equatable()
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
            .environment(\.conversationScrollController, defersStreaming ? controller : nil)
        }
    }

    @Test func longCompletedChatRowUsesViewportSections() async throws {
        let source = ScrollPerformanceFixture.standard.idleLongMarkdown
        let controller = ConversationScrollController()
        let metrics = Metrics()
        let host = NSHostingView(rootView: Transcript(
            controller: controller, metrics: metrics, longMarkdown: source,
            indices: 11..<12
        ))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        func documents(in view: NSView) -> [NativeMarkdownDocumentContainerView] {
            if let document = view as? NativeMarkdownDocumentContainerView { return [document] }
            return view.subviews.flatMap { documents(in: $0) }
        }
        let document = try #require(documents(in: host).first,
                                    "A real long assistant row must use the viewport-aware renderer")
        let height = document.intrinsicContentSize.height
        #expect(height > 10_000)
        if !NSApp.isFullKeyboardAccessEnabled {
            #expect(document.instantiatedSectionCount < 50)
        }
        controller.shiftVisibleTop(by: height / 2)
        host.layoutSubtreeIfNeeded()
        #expect(document.intrinsicContentSize.height == height)
        #expect(!document.subviews.isEmpty)
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_SCROLL_PROFILE"] == "1"))
    func measureLongMarkdownScrollWork() async throws {
        let fixture = ScrollPerformanceFixture.standard
        try await profile(keepsAllSections: false, longMarkdown: fixture.idleLongMarkdown)
        let code = "# Large code response\n\n```swift\n" + String(repeating: "let value = 42 // A complete source line.\n", count: 6_000) + "```\n"
        try await profile(keepsAllSections: false, longMarkdown: code, scenario: "large-fence")
        for defersStreaming in [false, true, true, false] {
            try await profile(keepsAllSections: false, longMarkdown: fixture.idleLongMarkdown, streams: true, defersStreaming: defersStreaming)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_SCROLL_PROFILE"] == "1"))
    func pagingRichMarkdownHistoryPreservesTheVisibleMessage() async throws {
        try await ConversationTranscriptIntegrationTests().checkProductionPaging(
            source: String(ScrollPerformanceFixture.standard.idleLongMarkdown.prefix(32_768))
        )
    }

    private func profile(keepsAllSections: Bool, longMarkdown: String? = nil, streams: Bool = false, defersStreaming: Bool = true, scenario: String = "rich") async throws {
        let streaming = streams ? StreamingText() : nil
        let deltas = longMarkdown.map { value in
            stride(from: 0, to: value.count, by: 4_096).map { String(value.dropFirst($0).prefix(4_096)) }
        } ?? []
        let half = deltas.count / 2
        streaming?.appendPresentation(deltas.prefix(half).joined())
        let setupStarted = DispatchTime.now().uptimeNanoseconds
        let controller = ConversationScrollController()
        let metrics = Metrics()
        let host = NSHostingView(rootView: Transcript(controller: controller, metrics: metrics, longMarkdown: longMarkdown, streaming: streaming, defersStreaming: defersStreaming))
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
        let top = longMarkdown == nil ? min(5_000, initial.documentHeight / 2)
            : try #require(metrics.viewports.first { $0.index == 11 }).minY + 2_000
        controller.shiftVisibleTop(by: top)
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
        let setupMS = Double(DispatchTime.now().uptimeNanoseconds - setupStarted) / 1_000_000
        let readsBefore = metrics.geometryReads
        let started = clock()
        var stepMS: [Double] = []
        var nextDelta = half
        let clip = try #require(controller.clipView)
        let document = try #require(clip.documentView)
        for step in 0..<120 {
            let stepStarted = DispatchTime.now().uptimeNanoseconds
            if streams, step.isMultiple(of: 4), nextDelta < deltas.count {
                streaming?.appendPresentation(deltas[nextDelta])
                nextDelta += 1
            }
            let delta: CGFloat = step < 60 ? 24 : -24
            let sign: CGFloat = document.isFlipped ? 1 : -1
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + sign * delta))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(8))
            stepMS.append(Double(DispatchTime.now().uptimeNanoseconds - stepStarted) / 1_000_000)
        }
        let cpuMS = Double(clock() - started) / Double(CLOCKS_PER_SEC) * 1_000
        if !streams { #expect(controller.geometry?.documentHeight == initial.documentHeight) }
        if streams { #expect(streaming?.text == longMarkdown) }
        if keepsAllSections {
            #expect(containers.allSatisfy { $0.keepsAccessibilitySectionsMounted })
            #expect(containers.reduce(0) { $0 + $1.subviews.count } == mounted)
        }
        let sortedSteps = stepMS.sorted()
        let mode = longMarkdown == nil ? (keepsAllSections ? "all-sections" : "viewport-sections") : (streams ? (defersStreaming ? "rich-streaming-deferred" : "rich-streaming-live") : "\(scenario)-completed")
        print("manual_scroll_latency mode=\(mode) source_bytes=\(longMarkdown?.utf8.count ?? Self.source.utf8.count) setup_ms=\(String(format: "%.1f", setupMS)) p95_step_ms=\(String(format: "%.1f", sortedSteps[Int(Double(sortedSteps.count - 1) * 0.95)])) max_step_ms=\(String(format: "%.1f", sortedSteps.last ?? 0))")
        print("manual_scroll_fixture mode=\(mode) steps=120 cpu_ms=\(String(format: "%.1f", cpuMS)) mounted_sections=\(mounted) row_geometry_reads=\(metrics.geometryReads - readsBefore)")
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(!controller.isUserScrolling)
        #expect(abs((controller.geometry?.visibleTop ?? 0) - top) < 1,
                "Applying deferred text must preserve the reader's position above the bottom")
        if let streaming {
            let expected = NativeMarkdownDocumentContainerView()
            NativeStreamingMarkdownView.Coordinator().update(expected, chunks: streaming.chunks, source: streaming.text, themeRevision: DockThemeRuntime.revision)
            let live = try #require(containers.max { $0.frame.height < $1.frame.height })
            #expect(abs(live.measuredHeight(forWidth: live.bounds.width) - expected.measuredHeight(forWidth: live.bounds.width)) < 1,
                    "Settling must render every chunk received during the gesture")
        }
    }
}
