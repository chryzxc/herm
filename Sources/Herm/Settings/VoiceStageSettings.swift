import SwiftUI

/// How Herm is woken from any app: a system-wide chord, and an opt-in
/// on-device wake word.
enum VoiceWakeShortcut {
    static let key = "herm.shortcut.voice"
    static let wakeWordKey = "herm.voice.idleWakeWord"
    static let defaultChord = QuickCaptureChord.optionShiftSpace
    static var stored: QuickCaptureChord {
        UserDefaults.standard.string(forKey: key).flatMap(QuickCaptureChord.init(rawValue:)) ?? defaultChord
    }
    static var wakeWordEnabled: Bool { UserDefaults.standard.bool(forKey: wakeWordKey) }
    static let wakeNameKey = "herm.voice.wakeName"
    static let defaultWakeName = "Herm"
    static func wakeNames(
        _ configured: String? = UserDefaults.standard.string(forKey: wakeNameKey), botName: String? = nil
    ) -> [String] {
        if let name = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return [name]
        }
        if let name = botName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
            name.caseInsensitiveCompare(defaultWakeName) != .orderedSame
        {
            return [name, defaultWakeName]
        }
        return [defaultWakeName]
    }

    /// The notch mic's tooltip: every real way to start talking, as currently configured.
    static func talkHelp(chord: QuickCaptureChord, wakeName: String?) -> String {
        var lines = ["Start voice in the notch"]
        lines.append(
            chord == .off
                ? "Shortcut: off (set one in Settings → Keyboard shortcuts)"
                : "Shortcut: \(chord.title), from any app")
        if let wakeName { lines.append("Or say “Hey \(wakeName)”") }
        return lines.joined(separator: "\n")
    }

    /// The notch ear's tooltip: what the always-on wake word is doing now.
    static func wakeWordHelp(on: Bool, available: Bool, wakeName: String) -> String {
        if on && !available { return "Wake listening is unavailable\nClick to turn it off" }
        if on { return "Listening for “Hey \(wakeName)” on this Mac\nClick to stop listening" }
        let detail =
            available ? "Listening stays on this Mac" : "macOS may ask for Speech Recognition and Microphone access"
        return "Always listen for “Hey \(wakeName)”\n" + detail
    }
}

/// Both wake controls share one permission request and keep the switch off until it succeeds.
@MainActor
final class VoiceWakeActivation: ObservableObject {
    static let shared = VoiceWakeActivation()

    @Published private(set) var isRequesting = false
    @Published private(set) var error: String?

    func setEnabled(
        _ enabled: Bool, defaults: UserDefaults = .standard,
        requestSpeech: () async -> Void = MicLevelMeter.askForSpeechPermission,
        canDetect: () -> Bool = { MicLevelMeter.canDetectWakePhrase },
        requestMicrophone: () async -> Bool = SpeechInput.requestMicrophoneAuthorization
    ) async {
        guard !isRequesting else { return }
        error = nil
        if enabled {
            isRequesting = true
            defer { isRequesting = false }
            await requestSpeech()
            guard canDetect() else {
                error =
                    "Allow Speech Recognition in System Settings. Wake listening also needs on-device recognition for your language."
                return
            }
            guard await requestMicrophone() else {
                error = "Allow Microphone access for Herm in System Settings, then try again."
                return
            }
            defaults.set(true, forKey: VoiceWakeShortcut.wakeWordKey)
        } else {
            defaults.set(false, forKey: VoiceWakeShortcut.wakeWordKey)
        }
    }
}

/// Settings → Voice → Wake word: start talking hands-free from any app, like Siri.
struct VoiceWakeWordSettings: View {
    @ObservedObject var bots: BotModeModel
    @ObservedObject private var wakeActivation = VoiceWakeActivation.shared
    @AppStorage(VoiceWakeShortcut.wakeWordKey) private var listensForWakeWord = false
    @AppStorage(VoiceWakeShortcut.wakeNameKey) private var wakeName = ""
    @AppStorage(VoiceAnnouncer.announcesAloudKey) private var announcesAloud = false

    var body: some View {
        let botName = bots.voiceBot(profileID: "default")?.name
        let name = VoiceWakeShortcut.wakeNames(wakeName, botName: botName)[0]
        VStack(alignment: .leading, spacing: 0) {
            SettingsPreferenceRow(
                title: "Listen for “Hey \(name)”",
                detail: wakeActivation.error
                    ?? "Say it from any app to open voice in the notch. The first time you turn this on, macOS may ask for Speech Recognition and Microphone access. Listening stays on this Mac."
            ) {
                Toggle(
                    "Wake word",
                    isOn: Binding(
                        get: { listensForWakeWord },
                        set: { enabled in Task { await wakeActivation.setEnabled(enabled) } })
                )
                .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
                .disabled(wakeActivation.isRequesting)
            }
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(
                title: "Wake name",
                detail:
                    "The word after “Hey”. Leave blank to use the bot’s name. Short, distinct names are heard best."
            ) {
                DockTextField(botName ?? VoiceWakeShortcut.defaultWakeName, text: $wakeName).textFieldStyle(.dockGlass)
                    .frame(
                        width: 160)
            }
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(
                title: "Announce aloud",
                detail: listensForWakeWord
                    ? "With no call open, your local voice says when Herm needs your approval, has a question, couldn’t finish, or finished, and reads reminders you set. Only notices a banner would show are spoken, never message text. Follows Herm’s Quiet mode, not macOS Focus, and stays silent while the screen is locked."
                    : "Needs the wake word, so Herm only speaks up while it’s already listening for you."
            ) {
                Toggle("Announce aloud", isOn: $announcesAloud)
                    .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
                    .disabled(!listensForWakeWord && !announcesAloud)
            }
        }
    }
}

struct VoiceStageSettings: View {
    static let activityPillsKey = "herm.voice.activityPills"
    static let narratesStepsKey = "herm.voice.narrateStepsOnDevice"
    static var narratesSteps: Bool { UserDefaults.standard.object(forKey: narratesStepsKey) as? Bool ?? true }
    static let understandsCommandsKey = "herm.voice.commandsOnDevice"
    static var understandsCommands: Bool {
        UserDefaults.standard.object(forKey: understandsCommandsKey) as? Bool ?? true
    }
    @AppStorage(activityPillsKey) private var showsActivityPills = true
    @AppStorage(narratesStepsKey) private var narratesStepsOnDevice = true
    @AppStorage(understandsCommandsKey) private var understandsCommandsOnDevice = true
    @AppStorage(VoiceAcknowledgment.acknowledgesKey) private var acknowledges = VoiceAcknowledgment.enabledByDefault
    @State private var acknowledgmentPreview = LocalVoicePlayback()
    @AppStorage(VoiceScreenContext.seesFrontAppKey) private var seesFrontApp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPreferenceRow(
                title: "Acknowledge right away",
                detail:
                    "Hear a spoken acknowledgment in the reply voice. Apple Intelligence can tailor it to your request on this Mac. The sample uses your local voice."
            ) {
                Button("Play sample") {
                    Task {
                        try? await acknowledgmentPreview.speak(VoiceAcknowledgment.Kind.request.fallback(after: nil))
                    }
                }
                .buttonStyle(.dockSecondary)
                Toggle("Acknowledge right away", isOn: $acknowledges)
                    .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            }
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(
                title: "Let voice see the front app",
                detail:
                    "Requests like “summarize this page” share the front app’s window title and selected or visible text. A “Seeing …” chip shows what was shared. Text access needs Accessibility permission and skips secure fields and known password managers. To share an image, explicitly ask for a screenshot. That needs Screen Recording permission."
            ) {
                Toggle("Let voice see the front app", isOn: $seesFrontApp)
                    .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            }
            Divider().overlay(Color.dockBorderLight)
            VoiceOutputSettings()
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(
                title: "Activity cards",
                detail: "Show short-lived cards around the voice orb for tool steps, results, and errors."
            ) {
                Toggle("Activity cards", isOn: $showsActivityPills)
                    .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            }
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(
                title: "Describe steps with Apple Intelligence",
                detail: OnDeviceAssist.isAvailable
                    ? "While voice runs, each tool step's name, inputs and result go to Apple's on-device model, which describes it in plain words on the agent screen. Nothing is sent to Apple or Hermes. Generated text may be inaccurate."
                    : "Unavailable. Needs macOS 26 or later on a Mac with Apple Intelligence turned on in System Settings."
            ) {
                Toggle("Describe steps with Apple Intelligence", isOn: $narratesStepsOnDevice)
                    .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            }
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(
                title: "Understand commands with Apple Intelligence",
                detail: OnDeviceAssist.isAvailable
                    ? "Short requests to close the preview or show a tab, such as “get rid of that”, are recognized on this Mac instead of being sent to the agent. Anything else goes to the agent as you said it."
                    : "Unavailable. Needs macOS 26 or later on a Mac with Apple Intelligence turned on in System Settings."
            ) {
                Toggle("Understand commands with Apple Intelligence", isOn: $understandsCommandsOnDevice)
                    .labelsHidden().toggleStyle(.dockSwitch).controlSize(.small).tint(Color.dockAccent)
            }
            Divider().overlay(Color.dockBorderLight)
            AssistantShortcutSettings()
        }
        .onDisappear { acknowledgmentPreview.stop() }
        .onChange(of: seesFrontApp) { _, enabled in
            if enabled { _ = DesktopCaptureService.requestAppTextPermission() }
        }
    }
}
