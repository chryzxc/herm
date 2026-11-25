import Foundation
import Testing

@testable import Herm

struct VoiceTalkHelpTests {
    @Test func tooltipListsTheConfiguredWaysToStartTalking() {
        #expect(
            VoiceWakeShortcut.talkHelp(chord: .optionShiftSpace, wakeName: "Scout")
                == "Start voice in the notch\nShortcut: ⌥⇧ Space, from any app\nOr say “Hey Scout”")
        #expect(
            VoiceWakeShortcut.talkHelp(chord: .off, wakeName: nil)
                == "Start voice in the notch\nShortcut: off (set one in Settings → Keyboard shortcuts)")
    }

    @Test func wakeWordTooltipFollowsTheToggleAndAvailability() {
        #expect(
            VoiceWakeShortcut.wakeWordHelp(on: true, available: true, wakeName: "Scout")
                == "Listening for “Hey Scout” on this Mac\nClick to stop listening")
        #expect(
            VoiceWakeShortcut.wakeWordHelp(on: false, available: true, wakeName: "Scout")
                == "Always listen for “Hey Scout”\nListening stays on this Mac")
        #expect(
            VoiceWakeShortcut.wakeWordHelp(on: false, available: false, wakeName: "Scout").contains(
                "may ask for Speech Recognition"))
        #expect(
            VoiceWakeShortcut.wakeWordHelp(on: true, available: false, wakeName: "Scout").contains("unavailable"))
    }

    @Test(arguments: [true, false], [true, false])
    @MainActor func firstTimeWakeActivationWaitsForBothPermissions(speech: Bool, microphone: Bool) async throws {
        let suite = "VoiceWakeActivation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let activation = VoiceWakeActivation()
        var calls: [String] = []
        await activation.setEnabled(
            true, defaults: defaults,
            requestSpeech: {
                calls.append("speech")
                #expect(activation.isRequesting)
                #expect(!defaults.bool(forKey: VoiceWakeShortcut.wakeWordKey))
            },
            canDetect: { speech },
            requestMicrophone: {
                calls.append("microphone")
                #expect(!defaults.bool(forKey: VoiceWakeShortcut.wakeWordKey))
                return microphone
            })
        #expect(calls == (speech ? ["speech", "microphone"] : ["speech"]))
        #expect(defaults.bool(forKey: VoiceWakeShortcut.wakeWordKey) == (speech && microphone))
        #expect((activation.error == nil) == (speech && microphone))
        #expect(!activation.isRequesting)
        await activation.setEnabled(false, defaults: defaults)
        #expect(!defaults.bool(forKey: VoiceWakeShortcut.wakeWordKey))
    }
}
