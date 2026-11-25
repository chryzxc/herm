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

    @Test func proseBeforeStructuredOutputIsSpokenImmediately() {
        var stream = VoiceReplyStream()
        #expect(
            stream.append("Here is the chart. It covers March.\n\n```herm-ui\n{")?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "Here is the chart. It covers March.")
        #expect(stream.append(" \"version\": 1 } Done. Next") == nil)
        let final = "Here is the chart. It covers March.\n\n```herm-ui\n{ \"version\": 1 }\n```"
        #expect(
            stream.finish(final).trimmingCharacters(in: .whitespacesAndNewlines)
                == "```herm-ui\n{ \"version\": 1 }\n```")
    }

    @Test func mediaDeliveryIsNeverReadAloud() {
        let delivery = "MEDIA:/tmp/my photo.png"
        let final = "Here’s the photo.\n" + delivery + "\nI found it in the album."
        var stream = VoiceReplyStream()
        #expect(stream.append("Here’s the photo.\nMED") == "Here’s the photo.\n")
        #expect(stream.append("IA:/tmp/my photo.png\nI found it in the album.") == nil)
        #expect(VoiceSpeechText.prepare(stream.finish(final)) == "I found it in the album.")
        #expect(VoiceSpeechText.prepare(delivery).isEmpty)
    }

    @Test func unfinishedSentenceBeforeAMarkerWaitsForTheCompletedReply() {
        var stream = VoiceReplyStream()
        #expect(stream.append("Open [the docs](https://example.com) now.") == nil)
        #expect(
            stream.finish("Open [the docs](https://example.com) now.") == "Open [the docs](https://example.com) now.")

        var approximate = VoiceReplyStream()
        #expect(
            approximate.append("It takes ~5 minutes. Then")?.trimmingCharacters(in: .whitespaces)
                == "It takes ~5 minutes.")
    }

    @Test func correctedFinalAnswerIsNotSilentlyDropped() {
        var stream = VoiceReplyStream()
        _ = stream.append("The result is ten. More")
        #expect(stream.finish("Correction: the result is twelve.") == "Correction: the result is twelve.")
    }

    @Test func whitespaceOnlyDifferencesInTheFinalAnswerAreNotSpokenTwice() {
        var stream = VoiceReplyStream()
        _ = stream.append("\n\nThe answer is ready.  Here")
        #expect(stream.finish("The answer is ready. Here is more.") == " Here is more.")

        var narration = VoiceReplyStream()
        _ = narration.append("Let me check that.")
        _ = narration.flushSentence()
        #expect(narration.finish("Let me check that.\n\nIt passed.") == "\n\nIt passed.")
    }
}
