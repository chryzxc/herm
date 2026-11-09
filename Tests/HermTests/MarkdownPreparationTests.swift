import AppKit
import Testing

@testable import Herm

@MainActor
struct MarkdownPreparationTests {
    @Test func backgroundMarkdownPreparationPreservesInlineSemantics() async {
        let source =
            "# Heading\n\nText **bold**, 👩‍💻 and [safe](https://example.invalid) "
            + "and [unsafe](file:///tmp/example).\n\n- item\n- second"
        let prepared = await Task.detached {
            MarkdownRenderDocumentBuilder.preparedBlocks(for: source)
        }.value
        MarkdownPreparedBlockCache.insert(prepared, for: source)
        let palette = NativeMarkdownPalette()
        let cached = NativeMarkdownAttributedTextBuilder.document(source, palette: palette).string
        let withoutCache = NativeMarkdownAttributedTextBuilder.document(source + "\n", palette: palette).string
        #expect(cached.string == withoutCache.string)
        let full = NSRange(location: 0, length: cached.length)
        var links: [URL] = []
        cached.enumerateAttribute(.link, in: full) { value, _, _ in
            if let link = value as? URL { links.append(link) }
        }
        #expect(links.allSatisfy { $0.scheme == "https" })
        #expect(!links.isEmpty)
    }

    @Test func largeCodePreparationKeepsExactDimensionsAcrossRemount() {
        let source = "```swift\n" + String(repeating: "let value = 42 // a complete line\n", count: 6_000) + "```"
        let reference = NativeMarkdownCodeView()
        reference.update(code: source, language: "swift")
        let incremental = NativeMarkdownCodeView()
        incremental.update(code: source, language: "swift", deferMeasurement: true)
        incremental.beginIncrementalLayout()
        var offset = 0
        var slices = 0
        while offset < incremental.incrementalTextLength {
            offset = incremental.advanceIncrementalLayout(from: offset)
            slices += 1
        }
        incremental.finishIncrementalLayout()
        #expect(slices > 1)
        #expect(incremental.contentSize == reference.contentSize)
        #expect(incremental.measuredHeight(forWidth: 640) == reference.measuredHeight(forWidth: 640))
        let remounted = NativeMarkdownCodeView()
        remounted.update(code: source, language: "swift", preparedSize: incremental.contentSize)
        #expect(remounted.contentSize == reference.contentSize)
    }

    @Test func incrementalTextLayoutMatchesFullTextKitMeasurement() {
        let source = String(
            repeating: "A **formatted** line with `code`, combining e\u{301}, and emoji 👩‍💻.\n", count: 1_000)
        let reference = NativeMarkdownTextSectionView()
        reference.update(markdown: source, kind: .prose)
        let expected = reference.measuredHeight(forWidth: 320)
        let incremental = NativeMarkdownTextSectionView()
        incremental.update(markdown: source, kind: .prose)
        incremental.beginIncrementalLayout(forWidth: 320)
        var offset = 0
        while offset < incremental.incrementalTextLength {
            offset = incremental.advanceIncrementalLayout(from: offset)
        }
        let measured = incremental.finishIncrementalLayout(forWidth: 320)
        #expect(measured.height == expected)
    }

    @Test func adjacentLargeCodeBecomesReadyWithExactCachedDimensions() async throws {
        _ = NSApplication.shared
        NativeMarkdownCompletedHeightCache.removeAll()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(scroll)
        window.orderFrontRegardless()
        let controller = ConversationScrollController()
        controller.allowsOccludedPreparationForTesting = true
        controller.clipView = scroll.contentView
        let context = NativeMarkdownDocumentContainerView.MeasurementContext(
            width: 620, bodySize: DockTypography.size(.conversation), bodyWeight: .regular,
            themeRevision: DockThemeRuntime.revision, mentionRevision: BotMentions.revision,
            themeID: DockThemeRuntime.current)
        controller.markdownMeasurementContext = context
        let source = "```swift\n" + String(repeating: "let value = 42 // complete line\n", count: 6_000) + "```"
        var messages = (0..<24).map { _ in ChatMessage(role: .user, text: "fixture") }
        messages[7] = ChatMessage(role: .hermes, text: source)
        let prefetch = ConversationMarkdownPrefetch()
        defer {
            prefetch.cancel()
            window.orderOut(nil)
        }
        prefetch.update(
            messages: messages, range: 8..<20, sessionID: "large-code", streamingID: nil, controller: controller,
            isCurrent: { _, _ in true })
        let deadline = Date().addingTimeInterval(20)
        while !prefetch.isReady(messageIDs: [messages[7].id], context: context), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(prefetch.isReady(messageIDs: [messages[7].id], context: context))
        let document = try #require(
            MarkdownRenderDocumentCache.cached(source: source, key: MarkdownMessageView.renderKey(for: source)))
        let section = try #require(document.sections.first)
        let key = NativeMarkdownDocumentContainerView.measurementKey(for: section, context: context)
        let measuredSize = try #require(NativeMarkdownCompletedHeightCache.codeSize(for: key))
        let reference = NativeMarkdownCodeView()
        reference.update(code: source, language: "swift")
        #expect(measuredSize == reference.contentSize)
        #expect(NativeMarkdownCompletedHeightCache.height(for: key) == reference.measuredHeight(forWidth: 620))
        controller.preparedPage = try #require(prefetch.preparedPage)
        NativeMarkdownCompletedHeightCache.removeAll()
        let mounted = NativeMarkdownDocumentContainerView()
        mounted.scrollController = controller
        mounted.apply(document: document)
        #expect(mounted.measuredHeight(forWidth: 620) == reference.measuredHeight(forWidth: 620))
        #expect(mounted.sectionMeasurementCount == 0)
    }

    @Test func completedCodeHeightIsReusedAtDifferentWidths() {
        NativeMarkdownCompletedHeightCache.removeAll()
        let source = "```swift\nlet value = \(UUID().uuidString)\n```"
        let key = MarkdownMessageView.renderKey(for: source)
        let container = NativeMarkdownDocumentContainerView()
        container.apply(document: MarkdownRenderDocumentBuilder.build(source: source, key: key))
        let height = container.measuredHeight(forWidth: 640)
        let count = container.sectionMeasurementCount
        #expect(container.measuredHeight(forWidth: 320) == height)
        #expect(container.sectionMeasurementCount == count)
    }
    @Test func idleMeasurementPopulatesTheExactCompletedHeightCache() throws {
        NativeMarkdownCompletedHeightCache.removeAll()
        let source = "Warm **section** \(UUID())"
        let key = MarkdownMessageView.renderKey(for: source)
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        let section = try #require(document.sections.first)
        let context = NativeMarkdownDocumentContainerView.MeasurementContext(
            width: 620, bodySize: DockTypography.size(.conversation), bodyWeight: .regular,
            themeRevision: DockThemeRuntime.revision, mentionRevision: BotMentions.revision,
            themeID: DockThemeRuntime.current)
        NativeMarkdownDocumentContainerView.warmHeight(
            for: section, context: context, textMeasurer: NativeMarkdownTextSectionView(),
            codeMeasurer: NativeMarkdownCodeView())
        let container = NativeMarkdownDocumentContainerView()
        container.apply(document: document)
        #expect(container.measuredHeight(forWidth: context.width) > 0)
        #expect(container.sectionMeasurementCount == 0)
    }

    @Test func requestedMeasurementProgressesDuringScrollingAndCancelsWithItsOwner() async throws {
        _ = NSApplication.shared
        NativeMarkdownCompletedHeightCache.removeAll()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(scroll)
        window.orderFrontRegardless()
        let controller = ConversationScrollController()
        controller.allowsOccludedPreparationForTesting = true
        controller.clipView = scroll.contentView
        controller.markdownMeasurementContext = .init(
            width: 620, bodySize: DockTypography.size(.conversation), bodyWeight: .regular,
            themeRevision: DockThemeRuntime.revision, mentionRevision: BotMentions.revision,
            themeID: DockThemeRuntime.current)
        controller.userScrollDidMove()
        let messages = (0..<24).map { ChatMessage(role: .hermes, text: "Unique \(UUID()) message \($0)") }
        let prefetch = ConversationMarkdownPrefetch()
        defer {
            prefetch.cancel()
            window.orderOut(nil)
        }
        prefetch.update(
            messages: messages, range: 8..<20, sessionID: "idle-warm", streamingID: nil, controller: controller,
            isCurrent: { _, _ in true })
        let deadline = Date().addingTimeInterval(5)
        while prefetch.committedDocuments < 12 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(prefetch.committedDocuments == 12)
        #expect(NativeMarkdownCompletedHeightCache.misses == 0)
        let context = try #require(controller.markdownMeasurementContext)
        let requestedID = messages[7].id
        while !prefetch.isReady(messageIDs: [requestedID], context: context) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(prefetch.isReady(messageIDs: [requestedID], context: context))
        #expect(controller.isUserScrolling)
        prefetch.cancelRequest()
        let missesWhileScrolling = NativeMarkdownCompletedHeightCache.misses
        try await Task.sleep(for: .milliseconds(100))
        #expect(NativeMarkdownCompletedHeightCache.misses == missesWhileScrolling)
        controller.userScrollDidSettle()
        while NativeMarkdownCompletedHeightCache.misses == missesWhileScrolling && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(NativeMarkdownCompletedHeightCache.misses > missesWhileScrolling)
        prefetch.cancel()
        let misses = NativeMarkdownCompletedHeightCache.misses
        try await Task.sleep(for: .milliseconds(100))
        #expect(NativeMarkdownCompletedHeightCache.misses == misses)
    }

    @Test func duplicateRequestedPageSurvivesMeasurementCacheEvictionWhileScrolling() async throws {
        _ = NSApplication.shared
        NativeMarkdownCompletedHeightCache.removeAll()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(scroll)
        window.orderFrontRegardless()
        let controller = ConversationScrollController()
        controller.clipView = scroll.contentView
        controller.allowsOccludedPreparationForTesting = true
        let context = NativeMarkdownDocumentContainerView.MeasurementContext(
            width: 620, bodySize: DockTypography.size(.conversation), bodyWeight: .regular,
            themeRevision: DockThemeRuntime.revision, mentionRevision: BotMentions.revision,
            themeID: DockThemeRuntime.current)
        controller.markdownMeasurementContext = context
        controller.userScrollDidMove()
        let text = "# \(UUID())\n\n" + (0..<30).map { "Paragraph \($0) **text**.\n\n" }.joined()
        var messages = (0..<24).map { _ in ChatMessage(role: .user, text: "fixture") }
        messages[7] = ChatMessage(role: .hermes, text: text)
        messages[20] = ChatMessage(role: .hermes, text: text)
        let prefetch = ConversationMarkdownPrefetch()
        defer {
            prefetch.cancel()
            window.orderOut(nil)
        }
        prefetch.update(
            messages: messages, range: 8..<20, sessionID: "duplicate", streamingID: nil,
            controller: controller, isCurrent: { _, _ in true })
        let deadline = Date().addingTimeInterval(10)
        while !prefetch.isReady(messageIDs: [messages[20].id], context: context), Date() < deadline {
            NativeMarkdownCompletedHeightCache.removeAll()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(prefetch.isReady(messageIDs: [messages[20].id], context: context))
        #expect(controller.isUserScrolling)
        #expect(prefetch.preparationSlices > 0)
        #expect(prefetch.maximumPreparationSliceNanoseconds > 0)
    }

    @Test func completedRemountReusesHeightsButStreamingNeverSharesMeasurements() {
        NativeMarkdownCompletedHeightCache.removeAll()
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: DockThemeRuntime.revision)
        let source =
            "# Measurement \(UUID())\n\n" + String(repeating: "A **paragraph** with inline `code`.\n\n", count: 30)
        let document = MarkdownRenderDocumentBuilder.build(source: source, key: key)
        let cold = NativeMarkdownDocumentContainerView()
        cold.apply(document: document)
        let height = cold.measuredHeight(forWidth: 620)
        #expect(cold.sectionMeasurementCount > 0)
        let warm = NativeMarkdownDocumentContainerView()
        warm.apply(document: document)
        #expect(warm.measuredHeight(forWidth: 620) == height)
        #expect(warm.sectionMeasurementCount == 0)
        #expect(NativeMarkdownCompletedHeightCache.hits >= document.sections.count)
        _ = warm.measuredHeight(forWidth: 300)
        #expect(warm.sectionMeasurementCount > 0)
        let hits = NativeMarkdownCompletedHeightCache.hits
        let streaming = NativeMarkdownDocumentContainerView()
        streaming.applyStreaming(sections: document.sections, source: source)
        #expect(streaming.measuredHeight(forWidth: 620) == height)
        #expect(streaming.sectionMeasurementCount > 0)
        #expect(NativeMarkdownCompletedHeightCache.hits == hits)
    }

    @Test func shortMutableStreamingTailBypassesBothCompletedCaches() {
        NativeMarkdownCompletedHeightCache.removeAll()
        let source = "Short mutable tail \(UUID())"
        let key = MarkdownMessageView.renderKey(for: source)
        let container = NativeMarkdownDocumentContainerView()
        let host = NativeMarkdownDocumentHost.Coordinator()
        host.update(container, source: source, key: key, sections: nil, cacheResult: false)
        let height = container.measuredHeight(forWidth: 400)
        #expect(MarkdownRenderDocumentCache.cached(source: source, key: key) == nil)
        #expect(NativeMarkdownCompletedHeightCache.hits == 0)
        #expect(NativeMarkdownCompletedHeightCache.misses == 0)
        host.update(container, source: source, key: key, sections: nil, cacheResult: true)
        #expect(container.measuredHeight(forWidth: 400) == height)
        #expect(MarkdownRenderDocumentCache.cached(source: source, key: key) != nil)
    }

    @Test func allMeasurementInputsParticipateInCacheIdentity() {
        NativeMarkdownCompletedHeightCache.removeAll()
        func key(
            source: String = "Text", kind: MarkdownRenderSectionKind = .prose, width: CGFloat = 620,
            size: CGFloat = 14, weight: CGFloat = 0, theme: Int = 1, mentions: Int = 1
        ) -> NativeMarkdownCompletedHeightCache.Key {
            .init(
                source: source, kind: kind, width: width, bodySize: size, bodyWeight: weight,
                themeRevision: theme, mentionRevision: mentions, themeID: DockThemeRuntime.current)
        }
        NativeMarkdownCompletedHeightCache.store(40, for: key())
        #expect(NativeMarkdownCompletedHeightCache.height(for: key()) == 40)
        for changed in [
            key(source: "Other"), key(kind: .quote), key(width: 620.25), key(size: 15),
            key(weight: 0.5), key(theme: 2), key(mentions: 2),
        ] {
            #expect(NativeMarkdownCompletedHeightCache.height(for: changed) == nil)
        }
    }

    nonisolated private static func parseOnWorker(source: String, key: MarkdownRenderKey) -> (
        MarkdownRenderDocument, Bool
    ) {
        (MarkdownRenderDocumentBuilder.build(source: source, key: key), Thread.isMainThread)
    }

    @Test func sectionParserRunsOutsideTheMainActorAndPreservesExactSource() async {
        let source = "# Header\n\n| a | b |\n| - | - |\n| x | y |\n\n```swift\nlet n = 1\n```\n"
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: 1)
        let (document, wasMainThread) = await Task.detached {
            Self.parseOnWorker(source: source, key: key)
        }.value
        #expect(!wasMainThread)
        #expect(document.source == source)
        #expect(document.sections.map(\.source).joined() == source)
        #expect(document.sections.contains { $0.kind == .table })
    }

    @Test func prefetchDiscardsCancelledAndObsoleteContent() async throws {
        let messages = (0..<30).map { ChatMessage(role: .hermes, text: "# Prefetch \(UUID())\n\nBody \($0)") }
        let prefetch = ConversationMarkdownPrefetch()
        prefetch.update(
            messages: messages, range: 10..<22, sessionID: "one", streamingID: nil, isCurrent: { _, _ in true })
        prefetch.cancel()
        try await Task.sleep(for: .milliseconds(80))
        #expect(prefetch.committedDocuments == 0)
        prefetch.update(
            messages: messages, range: 10..<22, sessionID: "two", streamingID: nil, isCurrent: { _, _ in false })
        try await Task.sleep(for: .milliseconds(80))
        #expect(prefetch.committedDocuments == 0)
        prefetch.cancel()
    }

    @Test func prefetchCoversBothAdjacentPagesWithoutPreparingMountedRows() async throws {
        let messages = (0..<40).map { ChatMessage(role: .hermes, text: "# Adjacent \(UUID())\n\nBody \($0)") }
        let prefetch = ConversationMarkdownPrefetch()
        defer { prefetch.cancel() }
        prefetch.update(
            messages: messages, range: 12..<24, sessionID: "adjacent", streamingID: nil,
            isCurrent: { _, _ in true })
        let deadline = Date().addingTimeInterval(5)
        while prefetch.committedDocuments < 16 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(prefetch.committedDocuments == 16)
        for index in messages.indices {
            let text = messages[index].text
            let cached = MarkdownRenderDocumentCache.cached(source: text, key: MarkdownMessageView.renderKey(for: text))
            #expect((cached != nil) == ((4..<12).contains(index) || (24..<32).contains(index)))
        }
    }
}

extension MarkdownPreparationTests {
    @Test func bodyStyleChangesRetainContentWhenTheHostKeyDoesNotChange() {
        let key = MarkdownRenderKey(messageID: UUID(), contentRevision: 1, themeRevision: DockThemeRuntime.revision)
        let source = String(repeating: "A wrapping paragraph that must survive font changes. ", count: 20)
        let container = NativeMarkdownDocumentContainerView()
        let host = NativeMarkdownDocumentHost.Coordinator()
        host.update(container, source: source, key: key, sections: nil)
        let original = container.measuredHeight(forWidth: 400)
        container.setBodyStyle(size: 20, weight: .semibold)
        host.update(container, source: source, key: key, sections: nil)
        #expect(container.measuredHeight(forWidth: 400) > original)
    }
}
