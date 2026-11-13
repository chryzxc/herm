import Testing

@testable import Herm

struct ComposerDictationTests {
    @Test func cancelRestoresOnlyTheOwnedDraft() {
        var dictation = ComposerDictation()
        dictation.begin(owner: "chat-a", text: "Draft")
        #expect(dictation.update("hello", text: "Draft", owner: "chat-a") == "Draft hello")
        #expect(dictation.cancel(text: "Draft hello", owner: "chat-a") == "Draft")
        #expect(dictation.cancel(text: "Edited draft", owner: "chat-a") == nil)
        #expect(dictation.cancel(text: "Draft hello", owner: "chat-b") == nil)
    }

    @Test func partialWordsAppearImmediatelyAndCorrectionsReplaceThePreviousHypothesis() {
        var dictation = ComposerDictation()
        dictation.begin(owner: "chat-a", text: "Please")
        #expect(dictation.update("book", text: "Please", owner: "chat-a") == "Please book")
        #expect(
            dictation.update("book a table", text: "Please book", owner: "chat-a")
                == "Please book a table")
        #expect(
            dictation.update("book a taxi", text: "Please book a table", owner: "chat-a")
                == "Please book a taxi")
        #expect(
            dictation.update("book a taxi", text: "Please book a taxi", owner: "chat-a")
                == "Please book a taxi")
    }

    @Test func userEditsAndSessionChangesNeverGetOverwrittenByLateRecognition() {
        var dictation = ComposerDictation()
        dictation.begin(owner: "chat-a", text: "Draft")
        #expect(dictation.update("hello", text: "Draft", owner: "chat-a") == "Draft hello")
        #expect(dictation.update("hello there", text: "Edited draft", owner: "chat-a") == nil)
        #expect(dictation.update("hello there", text: "Draft hello", owner: "chat-b") == nil)
        #expect(!dictation.owns("Edited draft"))
    }

    @Test func emptyTranscriptsAndWhitespaceKeepTheExistingDraftIntact() {
        var dictation = ComposerDictation()
        dictation.begin(owner: "chat-a", text: "Draft\n")
        #expect(dictation.update(" ", text: "Draft\n", owner: "chat-a") == "Draft\n")
        #expect(dictation.update("  hello  ", text: "Draft\n", owner: "chat-a") == "Draft\nhello")
        dictation.begin(owner: "chat-a", text: "")
        #expect(dictation.update("Hello", text: "", owner: "chat-a") == "Hello")
    }
}
