import Foundation
import Testing

@testable import Herm

struct VoicePromptsTests {
    @Test func spokenApprovalMapsToSafeChoices() {
        let choices = ApprovalChoice.all
        #expect(VoicePrompts.approvalChoice(for: "Yes.", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "Uh, yes yes.", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "Yes, you may.", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "I allow it", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "Yes, I allow it.", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "Yeah, I allow it.", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "I approve it", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "Yes", choices: [ApprovalChoice.session, ApprovalChoice.deny]) == nil)
        #expect(VoicePrompts.approvalChoice(for: "Yeah go ahead", choices: choices) == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "No, don’t run that", choices: choices) == ApprovalChoice.deny)
        #expect(VoicePrompts.approvalChoice(for: "do not", choices: choices) == ApprovalChoice.deny)
        #expect(
            VoicePrompts.approvalChoice(for: "allow it for this session", choices: choices) == ApprovalChoice.session)
        #expect(VoicePrompts.approvalChoice(for: "always", choices: choices) == nil)
        #expect(VoicePrompts.approvalChoice(for: "hmm", choices: choices) == nil)
    }

    @Test(arguments: [
        "do you need access", "can you run it", "what does allow mean", "yes but wait", "what is this session",
        "always allow", "yes always allow", "yes if the file is safe", "maybe yes", "she said yes",
        "I don’t want to click it myself", "no, ask me again", "what if I say no", "yes, not the other one",
    ])
    func questionsAndAmbiguousRepliesCannotApprove(_ text: String) {
        #expect(VoicePrompts.approvalChoice(for: text, choices: ApprovalChoice.all) == nil)
    }

    @Test func onlyClearlySeparateRequestsQueueBehindAnApproval() {
        for request in ["Show the weather tomorrow", "Play a song in Spotify", "Could you check the build?"] {
            #expect(VoicePrompts.isSeparateRequestDuringApproval(request))
        }
        for decision in [
            "Can you run it?", "Yes if it's safe", "What does allow mean?", "I don't want to click it myself",
            "Run that again", "Can you do that later?", "Please run the command", "What happens if I say yes?",
        ] {
            #expect(!VoicePrompts.isSeparateRequestDuringApproval(decision))
        }
    }

    @Test func screenClickApprovalNeverReadsCoordinatesOrOffersBroaderScopeAloud() {
        let approval = ApprovalPresentation.from(payload: ["command": "computer_use: click at (728, 859)"])
        #expect(VoicePrompts.approvalSpeech(approval) == "I need to click on the screen. May I continue?")
        #expect(approval.detail == "computer_use: click at (728, 859)")
        #expect(approval.choices.contains(ApprovalChoice.session))

        let compound = ApprovalPresentation.from(payload: ["command": approval.detail + " and type a message"])
        #expect(VoicePrompts.knownApprovalDescription(compound) == nil)
        #expect(VoicePrompts.approvalSpeech(compound).contains("Check the details in chat"))
    }

    @Test func narrationCanExplainScopeButCannotReadCommandsOrSuggestConsent() {
        let approval = ApprovalPresentation.from(payload: ["command": "git status"])
        #expect(
            VoicePrompts.approvalSpeech(approval, explanation: "I need to check for uncommitted changes.")
                == "I need to check for uncommitted changes. May I continue?")
        for candidate in ["UNKNOWN", "Run git status.", "Click at (728, 859).", "Say yes.", "rm -rf private"] {
            #expect(
                VoicePrompts.approvalSpeech(approval, explanation: candidate) == VoicePrompts.approvalSpeech(approval))
        }
        var blocked = approval
        blocked.smartDenied = true
        #expect(
            VoicePrompts.approvalSpeech(blocked, explanation: "I need to check for uncommitted changes.")
                == "A safety check blocked this action. Review the details in chat before deciding.")
    }

    @Test func approvalPlaybackDiscardsTheReadoutWithoutDiscardingAClearAnswer() throws {
        let readout = VoicePrompts.approvalSpeech(.from(payload: ["command": "git status"]))
        #expect(VoicePrompts.approvalAnswer("May I continue?", readout: readout) == nil)
        #expect(VoicePrompts.approvalAnswer("May I continue? Yes.", readout: readout) == "yes")
        #expect(VoicePrompts.approvalAnswer("Yes. May I continue?", readout: readout) == "yes")
        #expect(
            VoicePrompts.approvalAnswer("May I continue? Yes.", readout: "Check yes.txt. " + readout)
                == nil)
        #expect(
            VoicePrompts.approvalAnswer(
                readout + " Yes, I allow it.", readout: readout) == "yes i allow it")
        let conditional = try #require(
            VoicePrompts.approvalAnswer("May I continue? Yes if it is safe.", readout: readout))
        #expect(VoicePrompts.approvalChoice(for: conditional, choices: ApprovalChoice.all) == nil)

        let sharesCondition = "I need to check a file. If it is safe. May I continue?"
        for answer in ["Yes, if it is safe.", "If it is safe, yes."] {
            #expect(VoicePrompts.approvalAnswer(answer, readout: sharesCondition) == answer)
        }
    }

    @Test func aDecisionIsNotEchoSimplyBecauseTheReadoutSharesTwoOfItsWords() {
        let readout = "I need to click it. May I continue?"
        #expect(VoicePrompts.approvalAnswer("I allow it", readout: readout) == "I allow it")
        #expect(VoicePrompts.approvalAnswer("I continue. Yes.", readout: readout) == "yes")
        #expect(VoicePrompts.approvalAnswer("need to click it", readout: readout) == nil)
        #expect(
            VoicePrompts.approvalChoice(for: "Yes, I allow it. I allow it.", choices: ApprovalChoice.all)
                == ApprovalChoice.once)
        #expect(VoicePrompts.approvalChoice(for: "Yes, no, I allow it", choices: ApprovalChoice.all) == nil)
        #expect(VoicePrompts.approvalChoice(for: "I allow it only if it's safe", choices: ApprovalChoice.all) == nil)
    }

    @Test func voiceContextIsCompactAndRemovedFromDisplayedHistory() {
        let prompt = VoicePrompts.conversationPrompt("Check the build")
        #expect(GenerativeUIIntegration.displayUserText(prompt) == "Check the build")
        #expect(prompt.count < 700)
        #expect(prompt.contains("approval requirements"))
        // Talk's screen asks for a visual and tabs only where the plugin serves them.
        let visual = VoicePrompts.conversationPrompt("Check the build", visuals: true)
        #expect(GenerativeUIIntegration.displayUserText(visual) == "Check the build")
        #expect(visual.contains("herm-ui") && visual.contains("herm_inspector") && visual.count < 1_100)
        #expect(!VoicePrompts.conversationPrompt("Check the build", visuals: false).contains("herm_inspector"))
    }

    @Test func voiceCanAskForATableWithoutTheAgentUIPlugin() {
        let request = "Compare these two laptops"
        let preview = VoicePrompts.conversationPrompt(request, visuals: false, previews: true)
        #expect(preview.contains("short Markdown table of confirmed data"))
        #expect(!preview.contains("herm_inspector"))
        #expect(!VoicePrompts.conversationPrompt(request, visuals: false, previews: false).contains("Markdown table"))

        let plain = VoicePrompts.conversationPrompt("Follow up", visuals: false, previews: true)
        let queued = "Follow up\n\n[Herm rendering context v1]\nShow a preview.\n[/Herm rendering context]"
        #expect(VoicePrompts.conversationPrompt(queued, visuals: false, previews: true) == plain)
    }

    @Test func voiceCanAskForADiagramWithoutTheAgentUIPlugin() {
        let request = "Draw a diagram of the workflow."
        let preview = VoicePrompts.conversationPrompt(request, visuals: false, previews: true)
        #expect(preview.contains("compact Mermaid diagram"))
        #expect(!preview.contains("herm_inspector"))
    }

    @Test func spokenClarifyAnswerMatchesOptions() {
        let choices = ["Postgres", "SQLite", "Use both"]
        #expect(
            VoicePrompts.clarificationAnswer(for: "let's go with sqlite", choices: choices, multiSelect: false)?.answer
                == "SQLite")
        #expect(
            VoicePrompts.clarificationAnswer(for: "the second one", choices: choices, multiSelect: false)?.answer
                == "SQLite")
        #expect(
            VoicePrompts.clarificationAnswer(
                for: "I need two separate databases please", choices: choices, multiSelect: false
            )?.answer
                == "I need two separate databases please")
        #expect(
            VoicePrompts.clarificationAnswer(for: "one and three", choices: choices, multiSelect: true)?.display
                == "Postgres, Use both")
    }

    @Test func clarificationKeepsAmbiguousAndOutOfRangeSelectionsOpen() {
        let choices = ["Work", "Personal", "Family"]
        #expect(
            VoicePrompts.clarificationAnswer(
                for: "Use Safari", choices: ["Open Chrome", "Use Safari"], multiSelect: false)?.answer == "Use Safari")
        for answer in ["not Work", "Work or Personal", "option eight", "the fourth one", "pick Work and strangers"] {
            #expect(VoicePrompts.clarificationAnswer(for: answer, choices: choices, multiSelect: false) == nil)
        }
        #expect(
            VoicePrompts.clarificationAnswer(for: "option to", choices: choices, multiSelect: false)?.answer
                == "Personal")
        #expect(
            VoicePrompts.clarificationAnswer(for: "number two please", choices: choices, multiSelect: false)?.answer
                == "Personal")
        #expect(
            VoicePrompts.clarificationAnswer(for: "Work and option three", choices: choices, multiSelect: true)?.answer
                == #"["Work","Family"]"#)
        #expect(
            VoicePrompts.clarificationAnswer(
                for: "my answer is Tomorrow", choices: choices, multiSelect: false)?.answer == "Tomorrow")
    }

    @Test func clarificationDoesNotPickAnOptionFromItsOwnReadout() {
        let readout = VoicePrompts.clarificationSpeech(
            question: "Which list?", choices: ["Work", "Family"], multiSelect: false, progress: nil)
        #expect(VoicePrompts.clarificationUtterance(readout, readout: readout, overPlayback: false) == nil)
        #expect(VoicePrompts.clarificationUtterance("Two. Family.", readout: readout, overPlayback: false) == nil)
        #expect(VoicePrompts.clarificationUtterance("Family", readout: readout, overPlayback: true) == nil)
        #expect(VoicePrompts.clarificationUtterance("Family", readout: readout, overPlayback: false) == "Family")
        #expect(
            VoicePrompts.clarificationUtterance("Two. Family. Option two.", readout: readout, overPlayback: true)
                == "option two")
    }

    @Test func wakePhraseWakesOnlyWhenAddressed() {
        #expect(VoicePrompts.afterWakePhrase("Hey Hermes", name: "Hermes") == "")
        #expect(VoicePrompts.afterWakePhrase("OK, hermes. What's the weather", name: "Hermes") == "What's the weather")
        #expect(VoicePrompts.afterWakePhrase("I told Hermes about it", name: "Hermes") == nil)
        #expect(VoicePrompts.afterWakePhrase("I told them to say hey Hermes first", name: "Hermes") == nil)
        #expect(VoicePrompts.afterWakePhrase("hey hermesis", name: "Hermes") == nil)
    }

    @Test func activeVoiceStripsTheAddressAndKeepsTheRequest() {
        let names = ["Herm", "Assistant"]
        #expect(VoicePrompts.removingVoiceAddress(" Hey Assistant! ", names: names).isEmpty)
        #expect(VoicePrompts.removingVoiceAddress("Hey Herm…", names: names).isEmpty)
        #expect(VoicePrompts.removingVoiceAddress("Hey Herm: set a timer", names: names) == "set a timer")
        #expect(
            VoicePrompts.removingVoiceAddress("Ask Assistant for the notes", names: names)
                == "Ask Assistant for the notes")
    }

    @Test func displayedLaterChoicesCanBeSpokenByNumber() {
        let choices = (1...12).map { "Report \($0)" }
        #expect(
            VoicePrompts.clarificationAnswer(for: "option seven", choices: choices, multiSelect: false)?.answer
                == choices[6])
        #expect(
            VoicePrompts.clarificationAnswer(for: "number twelve", choices: choices, multiSelect: false)?.answer
                == choices[11])
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
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table for two", lastWordAt: 9, quietSince: 9, now: 9.7))
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table for two", lastWordAt: 9, quietSince: 9, now: 10.7))
        #expect(VoiceEndpointDetector.shouldEndTurn("book a table for two", lastWordAt: 9, quietSince: 9, now: 11))
        // "...and" or "um": the speaker is still going.
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table and", lastWordAt: 9, quietSince: 9, now: 11.5))
        #expect(!VoiceEndpointDetector.shouldEndTurn("so I was thinking, um", lastWordAt: 9, quietSince: 9, now: 11.5))
        #expect(VoiceEndpointDetector.shouldEndTurn("book a table and", lastWordAt: 9, quietSince: 9, now: 12.1))
        // A soft voice the level detector missed waits a little longer.
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table", lastWordAt: 9, quietSince: nil, now: 10.1))
        #expect(!VoiceEndpointDetector.shouldEndTurn("book a table", lastWordAt: 9, quietSince: nil, now: 11.2))
        #expect(VoiceEndpointDetector.shouldEndTurn("book a table", lastWordAt: 9, quietSince: nil, now: 11.5))
        #expect(
            VoiceEndpointDetector.shouldEndTurn(
                "Hey Herm", lastWordAt: 9, quietSince: 9, now: 10.3, wakeOnly: true))
        // No words yet: give the recognizer time instead of dropping the turn.
        #expect(!VoiceEndpointDetector.shouldEndTurn("", lastWordAt: 0, quietSince: 9, now: 10))
        #expect(VoiceEndpointDetector.shouldEndTurn("", lastWordAt: 0, quietSince: 9, now: 12))
        #expect(!VoiceEndpointDetector.shouldEndTurn("", lastWordAt: 0, quietSince: nil, now: 12))
        #expect(VoiceEndpointDetector.shouldEndTurn(nil, lastWordAt: 0, quietSince: 9, now: 9))
        // Even the smart-turn model must allow a brief pause or a hanging sentence.
        #expect(
            !VoiceEndpointDetector.shouldEndTurn(
                "book a table", lastWordAt: 9, quietSince: 9, now: 10.7, finished: true))
        #expect(
            VoiceEndpointDetector.shouldEndTurn(
                "book a table", lastWordAt: 9, quietSince: 9, now: 10.9, finished: true))
        #expect(
            !VoiceEndpointDetector.shouldEndTurn(
                "book a table and", lastWordAt: 9, quietSince: 9, now: 10.4, finished: true))
        #expect(
            !VoiceEndpointDetector.shouldEndTurn(
                "book a table for two", lastWordAt: 9, quietSince: 9, now: 11.5, finished: false))
        #expect(
            VoiceEndpointDetector.shouldEndTurn(
                "book a table for two", lastWordAt: 9, quietSince: 9, now: 12.1, finished: false))
    }

    @Test func resumedAudioExtendsATurnEvenBeforeTheNewWordsArrive() {
        let partial = "Play a song"
        #expect(
            !VoiceEndpointDetector.shouldEndTurn(
                partial, lastWordAt: 10, quietSince: 10.5, now: 11.55, finished: true, lastLoudAt: 11.3))
        #expect(
            VoiceEndpointDetector.shouldEndTurn(
                partial, lastWordAt: 10, quietSince: 10.5, now: 13.2, finished: true, lastLoudAt: 11.3))
    }

    @Test func quietRoomTimeoutsDoNotDisableOnDeviceRecognition() {
        #expect(!VoiceEndpointDetector.isRecognizerFailure(heardSpeech: false, failed: true, lived: 5))
        #expect(!VoiceEndpointDetector.isRecognizerFailure(heardSpeech: true, failed: true, lived: 0.2))
        #expect(VoiceEndpointDetector.isRecognizerFailure(heardSpeech: false, failed: true, lived: 0.2))
    }

    @Test func backgroundNoiseCannotHoldARecognizedRequestForever() {
        #expect(
            !VoiceEndpointDetector.shouldEndTurn(
                "Hello", lastWordAt: 10, quietSince: nil,
                now: 13.9, isHearingSpeech: true))
        #expect(
            VoiceEndpointDetector.shouldEndTurn(
                "Hello", lastWordAt: 10, quietSince: nil,
                now: 14, isHearingSpeech: true))
        #expect(
            !VoiceEndpointDetector.shouldEndTurn(
                "Hello there", lastWordAt: 13, quietSince: nil,
                now: 14, isHearingSpeech: true))
        #expect(
            !VoiceEndpointDetector.shouldEndTurn(
                "", lastWordAt: 0, quietSince: nil,
                now: 100, isHearingSpeech: true))
    }

    @Test func recognizedWordsSurviveAnErrorAtTheEndOfCapture() {
        #expect(VoiceRecognitionCompletion.resolve("  Hello  ", isFinal: false, hasError: true) == .finished("Hello"))
        #expect(VoiceRecognitionCompletion.resolve("Hello", isFinal: true, hasError: false) == .finished("Hello"))
        #expect(VoiceRecognitionCompletion.resolve("Hello", isFinal: false, hasError: false) == .listening)
        #expect(VoiceRecognitionCompletion.resolve("  ", isFinal: false, hasError: true) == .failed)
    }

    @Test @MainActor func speechWarningCanBeDismissedWithoutStartingAnotherCapture() {
        let speech = SpeechInput()
        speech.errorMessage = "Speech recognition couldn’t continue. Try again."
        speech.isUnavailable = true
        speech.dismissError()
        #expect(speech.errorMessage == nil)
        #expect(!speech.isUnavailable)
        #expect(!speech.isRecording)
        #expect(!speech.isStarting)
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
        #expect(VoicePrompts.isBargeIn("actually tell", over: reply))
        #expect(VoicePrompts.isBargeIn("no", over: reply))
    }

    @Test func aRequestToSeeSomethingRequiresAVisual() {
        #expect(VoicePrompts.asksToSee("Show me my calendar for today"))
        #expect(VoicePrompts.asksToSee("compare these two laptops"))
        #expect(!VoicePrompts.asksToSee("what time is it"))
        #expect(VoicePrompts.conversationPrompt("list my repos", visuals: true).contains("include the visual"))
        #expect(!VoicePrompts.conversationPrompt("what time is it", visuals: true).contains("include the visual"))
        let media = VoicePrompts.conversationPrompt("Show me a photo", visuals: true, previews: true)
        #expect(media.contains("own MEDIA: line outside code fences"))
        #expect(media.contains("An image or video delivery counts as the visual."))
    }

    @Test func wakePhraseUsesTheBotAndKeepsHermAsADefaultAlias() {
        let names = VoiceWakeShortcut.wakeNames("  ", botName: "Data Scout")
        #expect(names == ["Data Scout", "Herm"])
        #expect(VoicePrompts.afterWakePhrase("Hey Data Scout, open the browser", names: names) == "open the browser")
        #expect(VoicePrompts.afterWakePhrase("Hey Herm", names: names) == "")
        #expect(VoiceWakeShortcut.wakeNames(nil) == ["Herm"])
    }

    @Test func aCustomWakeNameOverridesTheBotAndDefaultAlias() {
        let names = VoiceWakeShortcut.wakeNames("Jarvis", botName: "Data Scout")
        #expect(names == ["Jarvis"])
        #expect(VoicePrompts.afterWakePhrase("Hey Jarvis, open the browser", names: names) == "open the browser")
        #expect(VoicePrompts.afterWakePhrase("Hey Herm", names: names) == nil)
        #expect(VoicePrompts.afterWakePhrase("Hey Data Scout", names: names) == nil)
    }

    @Test func switchToABotFindsItEvenWhenTheNameIsMisheard() {
        let names = ["Juniper", "Cypher", "Data Scout"]
        #expect(VoicePrompts.botSwitchTarget("switch to Cypher", among: names) == 1)
        #expect(VoicePrompts.botSwitchTarget("Switch to cipher.", among: names) == 1)
        #expect(VoicePrompts.botSwitchTarget("let me talk to the Data Scout bot", among: names) == 2)
        #expect(VoicePrompts.botSwitchTarget("switch to dark mode", among: names) == nil)
        #expect(VoicePrompts.botSwitchTarget("tell Cypher to switch to Juniper later", among: names) == nil)
        #expect(VoicePrompts.botSwitchTarget("get the weather", among: names) == nil)
    }
}

struct VoiceBotSwitchRequestTests {
    @Test func switchPhrasingsNameTheBotAndOnlyClearOnesAreExplicit() {
        #expect(VoicePrompts.botSwitchRequest("Switch to Cypher.")?.name == "cypher")
        #expect(VoicePrompts.botSwitchRequest("please talk to the Data Scout bot")?.name == "data scout")
        #expect(VoicePrompts.botSwitchRequest("switch to Cypher")?.explicit == true)
        #expect(VoicePrompts.botSwitchRequest("get the weather")?.explicit == false)
        #expect(VoicePrompts.botSwitchRequest("what's the weather tomorrow") == nil)
        #expect(VoicePrompts.botSwitchRequest("switch to the browser tab and search for flights") == nil)
    }
}
