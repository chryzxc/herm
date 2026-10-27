import EventKit
import Testing

@testable import Herm

@MainActor
struct SystemPermissionTests {
    @Test func calendarRespectsExistingPrivacyDecisions() {
        #expect(SystemCalendarService.shouldRequestAccess(.notDetermined))
        #expect(SystemCalendarService.shouldRequestAccess(.writeOnly))
        #expect(!SystemCalendarService.shouldRequestAccess(.fullAccess))
        #expect(!SystemCalendarService.shouldRequestAccess(.denied))
        #expect(!SystemCalendarService.shouldRequestAccess(.restricted))
    }

    @Test func unusedSpeechCleanupDoesNotCreateAnAudioEngine() {
        let speech = SpeechInput()
        #expect(speech.audioEngine == nil)
        speech.stop()
        speech.reset()
        speech.stopForAssistantSpeech()
        #expect(speech.audioEngine == nil)
        #expect(!speech.isRecording)
        #expect(!speech.isStarting)
    }
}
