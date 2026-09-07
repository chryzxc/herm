import Testing
@testable import HermesAgentDock

@MainActor
struct ComposerTextTests {
    @Test func markdownOrderedListsIncrementNumbers() {
        #expect(MarkdownMessageView.orderedListMarkers(in: "1. First\n2. Second\n3. Third") == ["1.", "2.", "3."])
    }

    @Test func markdownOrderedListsPreserveMarkersAcrossParagraphs() {
        #expect(MarkdownMessageView.orderedListMarkers(in: "1. First\n\nContext paragraph.\n\n4. Fourth\n\n5. Fifth") == ["1.", "4.", "5."])
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
