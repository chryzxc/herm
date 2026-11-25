import AVFoundation
import SwiftUI

struct VoiceOutputSettings: View {
    private let compact: Bool

    @AppStorage(VoiceSpeechEngine.outputKey) private var output = VoiceSpeechEngine.current.rawValue
    @AppStorage(VoiceSpeechEngine.appleVoiceKey) private var appleVoice = ""
    @AppStorage(VoiceSpeechEngine.kokoroVoiceKey) private var kokoroVoice = KokoroVoice.presets[0].id
    @AppStorage(VoiceSpeechEngine.speedKey) private var speed = 1.0
    @ObservedObject private var setup = KokoroVoiceSetup.shared
    @Environment(\.openURL) private var openURL
    @State private var playback = LocalVoicePlayback()
    @State private var preview: Task<Void, Never>?
    @State private var previewFailed = false
    @State private var appleVoices: [(value: String, title: String)] = []

    init(compact: Bool = false) { self.compact = compact }

    private var engine: VoiceSpeechEngine { VoiceSpeechEngine(rawValue: output) ?? VoiceSpeechEngine.current }
    private var usesKokoro: Bool { engine == .kokoro && KokoroVoice.installed }
    static func engineChoices(includesKokoro: Bool, selected: VoiceSpeechEngine) -> [VoiceSpeechEngine] {
        VoiceSpeechEngine.allCases.filter { $0 != .kokoro || includesKokoro || selected == .kokoro }
    }

    var body: some View {
        if compact {
            quickMenu
        } else {
            settingsRows
        }
    }

    private var quickMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            quickRow("Conversation voice") { outputPicker }
            quickRow(voiceTitle) {
                voicePicker
                previewButton.fixedSize()
            }
            quickRow("Speaking speed") { speedControls }

            Divider().overlay(Color.dockBorderLight)
            VoiceRecognitionQuickStatus()

            if let quickNote {
                Text(quickNote)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dockPadding(12)
        .frame(width: 360)
    }

    private func quickRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title).dockFont(.body, weight: .semibold).foregroundStyle(Color.dockPrimaryText)
            Spacer(minLength: 4)
            control()
        }
        .frame(minHeight: 28)
    }

    private var quickNote: String? {
        if previewFailed { return "Preview couldn’t play. Check Settings → Voice." }
        if engine == .kokoro && !usesKokoro { return "Using Apple Speech until Kokoro is set up in Settings → Voice." }
        if engine == .hermes { return "Apple voice and speed apply to local answers and notices." }
        return nil
    }

    @ViewBuilder private var settingsRows: some View {
        SettingsPreferenceRow(
            title: "Conversation voice",
            detail: engine == .hermes
                ? "Hermes Agent speaks chat replies. Herm uses Apple Speech for local answers and notices."
                : "Herm speaks replies, local answers, and notices on this Mac."
        ) {
            outputPicker
        }

        if engine == .kokoro && (!usesKokoro || previewFailed) {
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(title: "Kokoro setup", detail: setupDescription) {
                if KokoroVoice.available {
                    if KokoroVoice.installer == nil {
                        Button("Get uv") {
                            openURL(URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
                        }
                        .buttonStyle(.dockSecondary)
                    } else {
                        Button(setup.installing ? "Installing…" : usesKokoro ? "Repair Kokoro" : "Install Kokoro") {
                            stopPreview()
                            setup.install()
                        }
                        .buttonStyle(.dockSecondary)
                        .disabled(setup.installing)
                    }
                }
            }
        }

        Divider().overlay(Color.dockBorderLight)
        SettingsPreferenceRow(title: voiceTitle, detail: voiceDescription) {
            voicePicker
            previewButton
        }

        Divider().overlay(Color.dockBorderLight)
        SettingsPreferenceRow(title: "Speaking speed", detail: "Applies to Apple Speech and Kokoro.") {
            speedControls
        }
    }

    private var voiceTitle: String { usesKokoro ? "Kokoro voice" : "Apple voice" }

    private var outputPicker: some View {
        let includesKokoro = compact ? KokoroVoice.installed : KokoroVoice.available
        let choices = Self.engineChoices(includesKokoro: includesKokoro, selected: engine).map {
            ($0.rawValue, $0.title)
        }
        return DockOptionPicker(placeholder: engine.title, selection: $output, options: choices)
            .accessibilityLabel("Conversation voice")
    }

    private var previewButton: some View {
        Button(preview == nil ? "Preview" : "Stop", action: togglePreview)
            .buttonStyle(.dockSecondary)
            .accessibilityLabel(preview == nil ? "Preview local voice" : "Stop voice preview")
    }

    private var speedControls: some View {
        HStack(spacing: 8) {
            DockSlider(
                value: Binding(get: { VoiceSpeechEngine.boundedSpeed(speed) }, set: { speed = $0 }),
                range: VoiceSpeechEngine.speedRange, step: 0.05
            )
            .frame(width: 100)
            .accessibilityLabel("Local speaking speed")
            Text(VoiceSpeechEngine.boundedSpeed(speed).formatted(.percent))
                .dockFont(.metadata)
                .monospacedDigit()
                .foregroundStyle(Color.dockSecondaryText)
        }
        .onAppear {
            refreshAppleVoices()
            if !compact { KokoroVoice.prewarmIfSelected() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAppleVoices()
        }
        .onChange(of: output) { _, _ in stopPreview() }
        .onChange(of: usesKokoro) { _, _ in
            stopPreview()
            if !compact { KokoroVoice.prewarmIfSelected() }
        }
        .onChange(of: appleVoice) { _, _ in stopPreview() }
        .onChange(of: kokoroVoice) { _, _ in stopPreview() }
        .onDisappear(perform: stopPreview)
    }

    private var setupDescription: String {
        if !KokoroVoice.available { return "Kokoro requires Apple silicon. Apple Speech is active." }
        if setup.installing { return "Downloading and checking Kokoro. Apple Speech is active until setup finishes." }
        if setup.failed { return "Kokoro couldn’t finish setup. Check uv and your connection, then try again." }
        if previewFailed && usesKokoro { return "Check the runtime and model files, then try the preview again." }
        if KokoroVoice.installer == nil {
            return "Install uv to download Kokoro. Apple Speech is active in the meantime."
        }
        return "Download the runtime and voice files once. Kokoro speaks offline after setup."
    }

    private var voiceDescription: String {
        if previewFailed { return "The preview couldn’t play. Check the voice installation and try again." }
        if usesKokoro { return "English voice presets. Apple Speech handles other languages and playback failures." }
        return "Choose an installed voice or let Herm match your Mac’s language."
    }

    @ViewBuilder private var voicePicker: some View {
        if usesKokoro {
            DockOptionPicker(
                placeholder: KokoroVoice.resolvedPreset(kokoroVoice).name, selection: $kokoroVoice,
                options: KokoroVoice.presets.map { ($0.id, $0.name) }, maxTitleWidth: compact ? 140 : nil
            )
            .accessibilityLabel("Kokoro voice")
        } else {
            DockOptionPicker(
                placeholder: "Automatic", selection: $appleVoice, options: appleVoices,
                maxTitleWidth: compact ? 140 : nil
            )
            .accessibilityLabel("Apple voice")
        }
    }

    private func refreshAppleVoices() {
        let local = Locale.current
        let voices = VoiceSpeechEngine.appleVoices.map { voice -> (String, String) in
            let language = local.localizedString(forIdentifier: voice.language) ?? voice.language
            return (voice.identifier, "\(voice.name) · \(language)")
        }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        appleVoices = [("", "Automatic")] + voices
    }

    private func togglePreview() {
        if preview != nil {
            stopPreview()
            return
        }
        previewFailed = false
        preview = Task {
            // Preview the actual installed preset. For an incomplete installation, preview the visible Apple voice.
            do {
                try await playback.speak(
                    "Your coffee timer has two minutes left. Your next meeting is at nine thirty.",
                    allowsFallback: !usesKokoro)
            } catch {
                guard !Task.isCancelled else { return }
                previewFailed = true
            }
            if !Task.isCancelled { preview = nil }
        }
    }

    private func stopPreview() {
        preview?.cancel()
        preview = nil
        playback.stop()
        previewFailed = false
    }
}
