import Combine
import Foundation

struct VoiceRecognitionPreference: Equatable {
    enum Engine: String, CaseIterable {
        case automatic, classic

        var title: String {
            self == .automatic ? "Automatic" : "Classic Apple Speech"
        }
    }

    static let engineKey = "herm.voice.recognitionEngine"
    static let localeKey = "herm.voice.recognitionLocale"

    let engine: Engine
    let locale: Locale

    init(engine: String, localeID: String, systemLocale: Locale = .current) {
        self.engine = Engine(rawValue: engine) ?? .automatic
        locale = localeID.isEmpty ? systemLocale : Locale(identifier: localeID)
    }

    static func read(in defaults: UserDefaults = .standard) -> Self {
        Self(
            engine: defaults.string(forKey: engineKey) ?? "",
            localeID: defaults.string(forKey: localeKey) ?? "")
    }

    static func localeTitle(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

@MainActor
final class VoiceRecognitionStatus: ObservableObject {
    struct Route: Equatable {
        enum Engine: String {
            case modern = "Apple SpeechTranscriber"
            case classic = "Classic Apple Speech"
        }

        let engine: Engine
        let locale: Locale

        var label: String { "\(engine.rawValue) · \(VoiceRecognitionPreference.localeTitle(locale))" }
    }

    // Observable independently from audio levels and live transcript revisions.
    @Published private(set) var lastRoute: Route?

    func started(_ engine: Route.Engine, locale: Locale) {
        let route = Route(engine: engine, locale: locale)
        if route != lastRoute { lastRoute = route }
    }
}

/// Full and quick settings observe the same background model setup.
@MainActor
final class VoiceRecognitionSetup: ObservableObject {
    static let shared = VoiceRecognitionSetup()

    enum State: Equatable {
        case checking, installing
        case ready(Locale)
        case unavailable, failed

        var detail: String {
            switch self {
            case .checking: "Checking Apple’s on-device model."
            case .installing: "Installing Apple’s newer model. You can keep using voice."
            case .ready(let locale):
                "Apple’s newer model is ready · \(VoiceRecognitionPreference.localeTitle(locale))"
            case .unavailable:
                "The newer Apple model is unavailable. Herm can use Classic Apple Speech where supported."
            case .failed: "Couldn’t prepare the newer model. Herm can use Classic Apple Speech while you retry."
            }
        }
    }

    @Published private(set) var state: State = .checking
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func prepareSelected(retry: Bool = false) {
        let preference = VoiceRecognitionPreference.read(in: defaults)
        guard preference.engine == .automatic else { return }
        if #available(macOS 26, *) {
            VoiceTranscriber.shared.prepare(locale: preference.locale, retry: retry)
        } else {
            report(.unavailable, for: preference.locale)
        }
    }

    func report(_ next: State, for locale: Locale) {
        let selected = VoiceRecognitionPreference.read(in: defaults)
        guard selected.engine == .automatic, selected.locale == locale, state != next else { return }
        state = next
    }
}
