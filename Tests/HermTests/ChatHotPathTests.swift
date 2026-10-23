import AppKit
import Testing

@testable import Herm

@MainActor
struct ChatHotPathTests {
    @Test func nativeStreamingPreparesOnlyChangedChunks() {
        let streaming = StreamingText()
        streaming.appendPresentation(String(repeating: "A stable **Markdown** paragraph.\n\n", count: 2_000))
        let view = NativeMarkdownDocumentContainerView()
        let coordinator = NativeStreamingMarkdownView.Coordinator()
        coordinator.update(
            view, chunks: streaming.chunks, source: streaming.text, themeRevision: DockThemeRuntime.revision)
        let initial = coordinator.sectionPreparationCount
        #expect(initial > 5)
        for _ in 0..<10 {
            streaming.appendPresentation("more text ")
            coordinator.update(
                view, chunks: streaming.chunks, source: streaming.text, themeRevision: DockThemeRuntime.revision)
        }
        #expect(coordinator.sectionPreparationCount == initial + 10)
        let beforeTheme = coordinator.sectionPreparationCount
        coordinator.update(
            view, chunks: streaming.chunks, source: streaming.text, themeRevision: DockThemeRuntime.revision + 1)
        #expect(coordinator.sectionPreparationCount == beforeTheme)
    }

    @Test func incrementalSectionsMatchPureParserThroughFencesReplacementAndClear() {
        let streaming = StreamingText()
        let view = NativeMarkdownDocumentContainerView()
        let coordinator = NativeStreamingMarkdownView.Coordinator()
        func check() {
            coordinator.update(
                view, chunks: streaming.chunks, source: streaming.text, themeRevision: DockThemeRuntime.revision)
            #expect(coordinator.preparedSections == MarkdownRenderDocumentBuilder.sections(for: streaming.chunks))
            #expect(coordinator.preparedSections.map(\.source).joined() == streaming.text)
        }
        for text in [
            "# Title\n\n", "````swift\n", String(repeating: "let café = 1 // 🙂\n\n", count: 1_500),
            "````\n\n", "> Quote\n\n- Item\n", "| A | B |\n| --- | --- |\n| 1 | 2 |",
        ] {
            streaming.appendPresentation(text)
            check()
        }
        streaming.retainCompletionPresentation()
        let completed = streaming.text
        #expect(streaming.completionChunks(matching: completed) == streaming.chunks)
        streaming.replacePresentation(with: "Replacement **reply**")
        check()
        streaming.clearPresentation()
        check()
        // Another stream can reuse chunk id/revision; its source and context still invalidate sections.
        let other = StreamingText()
        other.appendPresentation("Different reply")
        coordinator.update(view, chunks: other.chunks, source: other.text, themeRevision: DockThemeRuntime.revision)
        #expect(coordinator.preparedSections == MarkdownRenderDocumentBuilder.sections(for: other.chunks))
        let another = StreamingText()
        another.appendPresentation("# A new stream with the same chunk identity")
        #expect(another.chunks == other.chunks)
        coordinator.update(view, chunks: another.chunks, source: another.text, themeRevision: DockThemeRuntime.revision)
        #expect(coordinator.preparedSections == MarkdownRenderDocumentBuilder.sections(for: another.chunks))
    }

    @Test func tailUpdatesReuseStableMeasurementsAndKeepExactHeight() {
        let streaming = StreamingText()
        streaming.appendPresentation(String(repeating: "Stable paragraph with **bold** text.\n\n", count: 500))
        let view = NativeMarkdownDocumentContainerView()
        let coordinator = NativeStreamingMarkdownView.Coordinator()
        coordinator.update(
            view, chunks: streaming.chunks, source: streaming.text, themeRevision: DockThemeRuntime.revision)
        _ = view.measuredHeight(forWidth: 500)
        let before = view.sectionMeasurementCount
        streaming.appendPresentation("Changed tail")
        coordinator.update(
            view, chunks: streaming.chunks, source: streaming.text, themeRevision: DockThemeRuntime.revision)
        let height = view.measuredHeight(forWidth: 500)
        #expect(view.sectionMeasurementCount == before + 1)
        let reference = NativeMarkdownDocumentContainerView()
        reference.applyStreaming(
            sections: MarkdownRenderDocumentBuilder.sections(for: streaming.chunks), source: streaming.text)
        #expect(height == reference.measuredHeight(forWidth: 500))
    }
}
