import Testing
@testable import HermesAgentDock

@MainActor
struct ComposerTextTests {
    @Test func markdownMessagesUseTheirSourceAsTheRenderEqualityBoundary() {
        #expect(MarkdownMessageView(markdown: "- One") == MarkdownMessageView(markdown: "- One"))
        #expect(MarkdownMessageView(markdown: "- One") != MarkdownMessageView(markdown: "- Two"))
    }

    @Test func markdownOrderedListsIncrementNumbers() {
        #expect(MarkdownMessageView.orderedListMarkers(in: "1. First\n2. Second\n3. Third") == ["1.", "2.", "3."])
    }

    @Test func markdownOrderedListsPreserveMarkersAcrossParagraphs() {
        #expect(MarkdownMessageView.orderedListMarkers(in: "1. First\n\nContext paragraph.\n\n4. Fourth\n\n5. Fifth") == ["1.", "4.", "5."])
    }

    @Test func markdownRendersEmbeddedRuntimeJSONAsACodeBlock() {
        let message = """
        Worker completed.

        {"verdict":"REQUEST_CHANGES","findings":["retry required"]}
        """

        #expect(MarkdownMessageView.codeBlockLanguages(in: message) == ["json"])
    }

    @Test func multiLineJSONObjectWithinBudgetStillBecomesACodeBlock() {
        let payload = (0..<50).map { index in
            "\"key\(index)\":\"value \(index)\""
        }.joined(separator: ",\n")
        let message = "Result:\n\n{\(payload)\n}"

        #expect(MarkdownMessageView.codeBlockLanguages(in: message) == ["json"])
    }

    @Test func unterminatedJSONObjectBeyondLineBudgetStopsScanning() {
        let opening = "{\n\"started\": true"
        let filler = (0..<5_000).map { index in
            "\"pending\(index)\": [1, 2, 3"
        }.joined(separator: "\n")
        let message = opening + "\n" + filler

        #expect(MarkdownMessageView.codeBlockLanguages(in: message).isEmpty)
    }

    @Test func jsonObjectBeyondByteBudgetIsNotDetected() {
        let filler = String(repeating: "a", count: MarkdownJSONScanPolicy.maxScanBytes + 1)
        let message = "{\"payload\": \"\(filler)\"}"

        #expect(MarkdownMessageView.codeBlockLanguages(in: message).isEmpty)
    }

    private let history = ["first prompt", "second prompt", "third prompt"]

    @Test func upArrowEntersHistoryAtNewestPrompt() {
        let composer = ComposerText()
        composer.text = "fresh draft"

        #expect(composer.navigate(direction: -1, history: Array(history)))
        #expect(composer.text == "third prompt")
        #expect(composer.navigate(direction: -1, history: Array(history)))
        #expect(composer.text == "second prompt")
    }

    @Test func downArrowPastNewestRestoresTheDraftBeingComposed() {
        let composer = ComposerText()
        composer.text = "work in progress"
        composer.navigate(direction: -1, history: Array(history))

        #expect(composer.navigate(direction: 1, history: Array(history)))
        #expect(composer.text == "work in progress")
        #expect(composer.navigate(direction: 1, history: Array(history)) == false)
    }

    @Test func typingAfterHistoryNavigationExitsHistoryMode() {
        let composer = ComposerText()
        composer.text = "start"
        composer.navigate(direction: -1, history: Array(history))

        composer.text += " more"

        #expect(composer.text == "third prompt more")
        #expect(composer.navigate(direction: 1, history: Array(history)) == false)
    }

    @Test func staleHistoryIndexIsRecoveredWhenHistoryShrinks() {
        let composer = ComposerText()
        composer.text = "draft"
        composer.navigate(direction: -1, history: Array(history))

        #expect(composer.navigate(direction: -1, history: ["replacement"]))
        #expect(composer.text == "replacement")
    }

    @Test func resetClearsDraftAndHistoryNavigation() {
        let composer = ComposerText()
        composer.text = "draft"
        composer.navigate(direction: -1, history: Array(history))

        composer.reset()

        #expect(composer.text.isEmpty)
        #expect(composer.navigate(direction: 1, history: Array(history)) == false)
    }

    @Test func navigationRequiresHistoryAndDirection() {
        let composer = ComposerText()

        #expect(composer.navigate(direction: -1, history: []) == false)
        #expect(composer.navigate(direction: 0, history: Array(history)) == false)
        #expect(composer.navigate(direction: 1, history: Array(history)) == false)
    }
}
