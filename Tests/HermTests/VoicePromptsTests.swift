import Testing
@testable import Herm

struct VoicePromptsTests {
    @Test func spokenApprovalMapsToSafeChoices() {
        let choices = ApprovalChoice.all
        #expect(VoicePrompts.approvalChoice(for: "Yeah go ahead", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "No, don’t run that", choices: choices) == ApprovalChoice.deny)
        #expect(VoicePrompts.approvalChoice(for: "do not", choices: choices) == ApprovalChoice.deny)
        #expect(VoicePrompts.approvalChoice(for: "allow it for this session", choices: choices) == ApprovalChoice.session)
        #expect(VoicePrompts.approvalChoice(for: "always", choices: choices) == nil)
        #expect(VoicePrompts.approvalChoice(for: "hmm", choices: choices) == nil)
    }

    @Test func spokenClarifyAnswerMatchesOptions() {
        let choices = ["Postgres", "SQLite", "Use both"]
        #expect(VoicePrompts.clarificationAnswer(for: "let's go with sqlite", choices: choices, multiSelect: false).answer == "SQLite")
        #expect(VoicePrompts.clarificationAnswer(for: "the second one", choices: choices, multiSelect: false).answer == "SQLite")
        #expect(VoicePrompts.clarificationAnswer(for: "I need two separate databases please", choices: choices, multiSelect: false).answer
            == "I need two separate databases please")
        #expect(VoicePrompts.clarificationAnswer(for: "one and three", choices: choices, multiSelect: true).display == "Postgres, Use both")
    }

    @Test func wakePhraseWakesOnlyWhenAddressed() {
        #expect(VoicePrompts.afterWakePhrase("Hey Hermes", name: "Hermes") == "")
        #expect(VoicePrompts.afterWakePhrase("OK, hermes. What's the weather", name: "Hermes") == "What's the weather")
        #expect(VoicePrompts.afterWakePhrase("I told Hermes about it", name: "Hermes") == nil)
        #expect(VoicePrompts.afterWakePhrase("hey hermesis", name: "Hermes") == nil)
    }

    @Test func endpointGoesIdleOnlyWithoutSpeech() {
        var quiet = VoiceEndpointDetector()
        for t in stride(from: 0.0, through: 8.0, by: 0.1) { _ = quiet.ingest(level: 0.05, at: t) }
        #expect(quiet.heardNothing(for: 8, at: 8))

        var talking = VoiceEndpointDetector()
        for t in stride(from: 0.0, through: 1.0, by: 0.1) { _ = talking.ingest(level: 0.05, at: t) }
        for t in stride(from: 1.0, through: 8.0, by: 0.1) { _ = talking.ingest(level: 0.6, at: t) }
        #expect(!talking.heardNothing(for: 8, at: 8))
    }

    @Test func turnEndsFastWhenFinishedAndWaitsWhenTrailingOff() {
        // A finished thought ends quickly once the words stop.
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table for two", lastWordAt: 9, quietSince: 9, now: 10))
        #expect(VoiceEndpointDetector.shouldEndTurn("book a table for two", lastWordAt: 9, quietSince: 9, now: 10.3))
        // "...and" or "um": the speaker is still going.
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table and", lastWordAt: 9, quietSince: 9, now: 11.5))
        #expect(!VoiceEndpointDetector.shouldEndTurn("so I was thinking, um", lastWordAt: 9, quietSince: 9, now: 11.5))
        #expect(VoiceEndpointDetector.shouldEndTurn("book a table and", lastWordAt: 9, quietSince: 9, now: 12.1))
        // A soft voice the level detector missed waits a little longer.
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table", lastWordAt: 9, quietSince: nil, now: 10.3))
        #expect(VoiceEndpointDetector.shouldEndTurn("book a table", lastWordAt: 9, quietSince: nil, now: 10.7))
        // No words yet: give the recognizer time instead of dropping the turn.
        #expect(!VoiceEndpointDetector.shouldEndTurn("", lastWordAt: 0, quietSince: 9, now: 10))
        #expect(VoiceEndpointDetector.shouldEndTurn("", lastWordAt: 0, quietSince: 9, now: 12))
        #expect(!VoiceEndpointDetector.shouldEndTurn("", lastWordAt: 0, quietSince: nil, now: 12))
        #expect(VoiceEndpointDetector.shouldEndTurn(nil, lastWordAt: 0, quietSince: 9, now: 9))
        // The smart-turn model overrides the word guess both ways.
        #expect(VoiceEndpointDetector.shouldEndTurn("book a table and", lastWordAt: 9, quietSince: 9, now: 9.6, finished: true))
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table for two", lastWordAt: 9, quietSince: 9, now: 11.5, finished: false))
        #expect(VoiceEndpointDetector.shouldEndTurn("book a table for two", lastWordAt: 9, quietSince: 9, now: 12.1, finished: false))
    }

    @Test func quietRoomTimeoutsDoNotDisableOnDeviceRecognition() {
        #expect(!VoiceEndpointDetector.isRecognizerFailure(heardSpeech: false, failed: true, lived: 5))
        #expect(!VoiceEndpointDetector.isRecognizerFailure(heardSpeech: true, failed: true, lived: 0.2))
        #expect(VoiceEndpointDetector.isRecognizerFailure(heardSpeech: false, failed: true, lived: 0.2))
    }

    @Test func echoOfTheReplyIsNotTheUser() {
        let reply = "Sure. I booked a table for two at seven tonight."
        #expect(VoicePrompts.isEcho("I booked a table for two at seven", of: reply))
        #expect(!VoicePrompts.isEcho("thanks can you also order a taxi", of: reply))
        #expect(!VoicePrompts.isEcho("anything", of: ""))
    }

    @Test func bargeInIgnoresTheReplyEchoingBack() {
        let reply = "The forecast for today is sunny with a light breeze."
        #expect(!VoicePrompts.isBargeIn("the forecast for today", over: reply))
        #expect(VoicePrompts.isBargeIn("wait", over: reply))
        #expect(VoicePrompts.isBargeIn("actually tell me about tomorrow", over: reply))
        #expect(!VoicePrompts.isBargeIn("sunny", over: reply))
    }
}
