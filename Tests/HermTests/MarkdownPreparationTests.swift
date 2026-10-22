import AppKit
import Testing

@testable import Herm

@MainActor
struct MarkdownPreparationTests {
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
