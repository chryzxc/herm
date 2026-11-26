import Speech
import SwiftUI

struct VoiceRecognitionSettings: View {
    @ObservedObject var status: VoiceRecognitionStatus
    var compact = false
    @AppStorage(VoiceRecognitionPreference.engineKey) private var engine = "automatic"
    @AppStorage(VoiceRecognitionPreference.localeKey) private var localeID = ""
    @State private var locales: [Locale] = []
    @ObservedObject private var setup = VoiceRecognitionSetup.shared

    private var preference: VoiceRecognitionPreference {
        VoiceRecognitionPreference(engine: engine, localeID: localeID)
    }

    var body: some View {
        Group {
            if compact { quickRows } else { settingsRows }
        }
        .task {
            var choices = SFSpeechRecognizer.supportedLocales()
            choices.insert(.current)
            if #available(macOS 26, *) { choices.formUnion(await SpeechTranscriber.supportedLocales) }
            if !localeID.isEmpty { choices.insert(preference.locale) }
            var identifiers: Set<String> = []
            locales = choices.sorted { $0.identifier < $1.identifier }.filter {
                identifiers.insert($0.identifier.replacingOccurrences(of: "-", with: "_")).inserted
            }.sorted {
                VoiceRecognitionPreference.localeTitle($0).localizedStandardCompare(
                    VoiceRecognitionPreference.localeTitle($1)) == .orderedAscending
            }
            // A stored identifier retains its matching picker tag even on a differently configured Mac.
            if !localeID.isEmpty, !locales.contains(where: { $0.identifier == localeID }) {
                locales.append(Locale(identifier: localeID))
            }
        }
        .task(id: preference) {
            if preference.engine == .automatic { setup.prepareSelected() }
        }
    }

    private var settingsRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPreferenceRow(
                title: "Recognizer",
                detail: status.lastRoute.map { "Last used: \($0.label)." }
                    ?? "Automatic prefers Apple’s newer model when ready. Notch audio stays on this Mac."
            ) {
                Picker("Recognizer", selection: $engine) {
                    ForEach(VoiceRecognitionPreference.Engine.allCases, id: \.rawValue) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .labelsHidden()
            }
            Divider().overlay(Color.dockBorderLight)
            SettingsPreferenceRow(title: "Speech language", detail: languageDetail) {
                Picker("Speech language", selection: $localeID) {
                    Text("Match this Mac").tag("")
                    ForEach(locales, id: \.identifier) { locale in
                        Text(VoiceRecognitionPreference.localeTitle(locale)).tag(locale.identifier)
                    }
                }
                .labelsHidden()
                retryButton
            }
        }
    }

    private var quickRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            VoiceQuickRow(title: "Recognizer") {
                DockOptionPicker(
                    placeholder: preference.engine.title, selection: $engine,
                    options: VoiceRecognitionPreference.Engine.allCases.map { ($0.rawValue, $0.title) },
                    maxTitleWidth: 150
                )
                .accessibilityLabel("Recognizer")
            }
            VoiceQuickRow(title: "Speech language") {
                DockOptionPicker(
                    placeholder: localeID.isEmpty
                        ? "Match this Mac" : VoiceRecognitionPreference.localeTitle(preference.locale),
                    selection: $localeID,
                    options: [("", "Match this Mac")]
                        + locales.map { ($0.identifier, VoiceRecognitionPreference.localeTitle($0)) },
                    maxTitleWidth: 150
                )
                .accessibilityLabel("Speech language")
            }
            if preference.engine == .automatic {
                HStack(spacing: DockSpacing.control) {
                    Text(setup.state.detail)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    retryButton
                }
            }
        }
    }

    @ViewBuilder private var retryButton: some View {
        if preference.engine == .automatic, setup.state == .failed {
            Button("Retry") { setup.prepareSelected(retry: true) }
                .buttonStyle(.dockSecondary)
                .accessibilityLabel("Retry Apple speech model setup")
        }
    }

    private var languageDetail: String {
        if preference.engine == .classic {
            return "Classic uses this language when available. Changes apply on the next turn."
        }
        return setup.state.detail
    }
}
