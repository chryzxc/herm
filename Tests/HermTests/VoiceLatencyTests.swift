import Foundation
import Testing

@testable import Herm

struct VoiceLatencyTests {
    @Test func timingsCoverEachStageWithoutTheWordsSpoken() {
        var telemetry = VoiceTurnTelemetry()
        let start = Date(timeIntervalSince1970: 0)
        telemetry.beginListening(at: start)
        telemetry.startedSpeaking(at: start)  // Before a request: not this turn's reply.
        telemetry.receivedTranscript(at: start.addingTimeInterval(2))
        telemetry.submittedRequest(at: start.addingTimeInterval(2.1))
        telemetry.receivedResponse(at: start.addingTimeInterval(3.1))
        telemetry.startedSpeaking(at: start.addingTimeInterval(3.6))
        telemetry.startedSpeaking(at: start.addingTimeInterval(5))
        telemetry.completedResponse(at: start.addingTimeInterval(4))
        #expect(
            telemetry.timings
                == "voice turn: listen 2.0s · submit 0.1s · first token 1.0s · first audio 1.5s · done 1.9s")
        telemetry.beginListening(at: start)
        #expect(telemetry.firstAudioAt == nil)
        #expect(telemetry.timings == nil)
    }

    @Test func recognizerVocabularyIsTrimmedDistinctAndBounded() {
        let names = ["  Herm ", "herm", "", "Hermes", String(repeating: "x", count: 61)]
        #expect(MicLevelMeter.recognizerVocabulary(names) == ["Herm", "Hermes"])
        #expect(MicLevelMeter.recognizerVocabulary((0..<150).map { "name\($0)" }).count == 100)
    }

    @Test func finalResultWaitIsShortOnlyWhenWordsWereHeard() {
        #expect(MicLevelMeter.finalResultWait(hasPartial: true) == 1.8)
        #expect(MicLevelMeter.finalResultWait(hasPartial: false) >= 3)
    }

    @Test func onlyShortPanelOrHidePhrasesAskTheOnDeviceModel() {
        #expect(VoicePrompts.mayBeLocalCommand("get rid of that preview"))
        #expect(VoicePrompts.mayBeLocalCommand("pull up the browser"))
        #expect(!VoicePrompts.mayBeLocalCommand("what's the weather tomorrow"))
        #expect(
            !VoicePrompts.mayBeLocalCommand("open the browser and search for flights to Tokyo next week please"))
        #expect(
            OnDeviceAssist.voiceCommands.allSatisfy { $0 == "close" || SessionInspector.Section(agentTab: $0) != nil })
    }
}

struct VoiceTranscriptTests {
    @Test func transcriptSegmentsKeepWordBoundariesAndAttachPunctuation() {
        #expect(VoiceTranscriptText.join("Show a map of", "Tacloban City") == "Show a map of Tacloban City")
        #expect(VoiceTranscriptText.join("Tacloban", ", Philippines") == "Tacloban, Philippines")
        #expect(VoiceTranscriptText.join("Hello", "  ") == "Hello")
    }

    @Test func wakeAlternativesRequireTheWholeAddressAndLeaveTheCommandAlone() {
        let names = ["Scout"]
        #expect(
            VoiceTranscriptText.wakeAlternative(
                ["I asked Scout", "Hey Scout open Calendar", "Hey Scout open Maps"],
                matching: "Hey Shout open Calendar.", names: names) == "Hey Scout open Calendar.")
        #expect(
            VoiceTranscriptText.wakeAlternative(
                ["Hey Scout"], matching: "Scout", names: names, after: "Please tell them") == nil)
        #expect(
            VoiceTranscriptText.wakeAlternative(
                ["Shout", "Scout open Calendar"], matching: "Shout open Calendar", names: names, after: "Hey")
                == "Scout open Calendar")
    }

    @Test func conflictingWakeAlternativeCanWakeButCannotSupplyANewAction() {
        let names = ["Scout"]
        #expect(
            VoiceTranscriptText.wakeAlternative(
                ["Hey Scout open Calendar"], matching: "Hey Shout open Maps", names: names) == "Hey Scout")
        #expect(
            VoiceTranscriptText.wakeAlternative(
                ["Hey Scout open Maps"], matching: "Hey Shout don't open Maps", names: names) == "Hey Scout")
        #expect(
            VoiceTranscriptText.wakeAlternative(
                ["Hey shout", "Scout"], matching: "Hey Shout", names: names) == nil)
    }
}

struct VoiceRecognitionPreferenceTests {
    @Test func automaticUsesTheMacsLocaleAndExplicitChoicesKeepTheRegion() {
        let philippines = Locale(identifier: "en_PH")
        let automatic = VoiceRecognitionPreference(engine: "", localeID: "", systemLocale: philippines)
        #expect(automatic.engine == .automatic)
        #expect(automatic.locale == philippines)

        let classic = VoiceRecognitionPreference(
            engine: "classic", localeID: "en_PH", systemLocale: .init(identifier: "en_US"))
        #expect(classic.engine == .classic)
        #expect(classic.locale == philippines)
        #expect(classic != automatic)
    }

    @MainActor @Test func aLateModelDownloadCannotOverwriteTheStatusOfTheSelectedLocale() throws {
        let name = "VoiceRecognitionSetupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let setup = VoiceRecognitionSetup(defaults: defaults)
        let english = Locale(identifier: "en_US")
        let french = Locale(identifier: "fr_FR")
        defaults.set("en_US", forKey: VoiceRecognitionPreference.localeKey)
        setup.report(.installing, for: english)
        #expect(setup.state == .installing)

        defaults.set("fr_FR", forKey: VoiceRecognitionPreference.localeKey)
        setup.report(.checking, for: french)
        setup.report(.ready(english), for: english)
        #expect(setup.state == .checking)
        setup.report(.ready(french), for: french)
        #expect(setup.state == .ready(french))

        defaults.set("classic", forKey: VoiceRecognitionPreference.engineKey)
        setup.report(.failed, for: french)
        #expect(setup.state == .ready(french))
    }

    @MainActor @Test func recordsActualRecognizerAndResolvedLocaleRatherThanThePreference() {
        let status = VoiceRecognitionStatus()
        #expect(status.lastRoute == nil)
        status.started(.classic, locale: Locale(identifier: "en_PH"))
        #expect(status.lastRoute?.engine == .classic)
        #expect(status.lastRoute?.locale.identifier == "en_PH")
        status.started(.modern, locale: Locale(identifier: "en_US"))
        #expect(status.lastRoute?.engine == .modern)
        #expect(status.lastRoute?.locale.identifier == "en_US")
    }
}
