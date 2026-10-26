import Foundation
import Testing

@testable import Herm

struct VoiceReplyStreamTests {
    @Test func partialWordsAndSentencesWaitButCompleteProseStreams() {
        var stream = VoiceReplyStream()
        #expect(stream.append("The answer is") == nil)
        #expect(stream.append(" ready. Here is more") != nil)
        #expect(
            stream.finish("The answer is ready. Here is more detail.").trimmingCharacters(in: .whitespacesAndNewlines)
                == "Here is more detail.")
    }

    @Test func narrationCanStartAtAToolBoundaryWithoutWaitingForAnotherSentence() {
        var stream = VoiceReplyStream()
        _ = stream.append("Let me check that.")
        #expect(stream.flushSentence() == "Let me check that.")
        #expect(stream.flushSentence() == nil)
        #expect(stream.finish("Let me check that. It passed.") == " It passed.")
    }

    @Test func structuredOutputWaitsForTheCompletedRenderer() {
        var stream = VoiceReplyStream()
        #expect(stream.append("```herm-ui\n{\"text\":\"Done. Next\"") == nil)
        #expect(stream.emitted.isEmpty)
    }

    @Test func correctedFinalAnswerIsNotSilentlyDropped() {
        var stream = VoiceReplyStream()
        _ = stream.append("The result is ten. More")
        #expect(stream.finish("Correction: the result is twelve.") == "Correction: the result is twelve.")
    }
}
