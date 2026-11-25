import AVFoundation
import Foundation

/// The conversation engine. Announcements and private readbacks use local speech.
enum VoiceSpeechEngine: String, CaseIterable {
    case hermes, apple, kokoro

    static let outputKey = "herm.voice.output"
    static let macVoiceKey = "herm.voice.macVoice"
    static let appleVoiceKey = "herm.voice.appleVoiceIdentifier"
    static let kokoroVoiceKey = "herm.voice.kokoroVoice"
    static let speedKey = "herm.voice.speakingSpeed"
    static let speedRange = 0.75...1.35

    var title: String {
        switch self {
        case .hermes: "Hermes Agent"
        case .apple: "Apple Speech"
        case .kokoro: "Kokoro"
        }
    }

    static var current: Self { selected(in: .standard) }

    static func selected(in defaults: UserDefaults) -> Self {
        if let raw = defaults.string(forKey: outputKey), let engine = Self(rawValue: raw) { return engine }
        return defaults.bool(forKey: macVoiceKey) ? .apple : .hermes
    }

    static func boundedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, speedRange.lowerBound), speedRange.upperBound)
    }

    static var speed: Double {
        boundedSpeed(UserDefaults.standard.object(forKey: speedKey) as? Double ?? 1)
    }

    static var appleVoices: [AVSpeechSynthesisVoice] {
        let personal = AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized
        return AVSpeechSynthesisVoice.speechVoices().filter { voice in
            if voice.voiceTraits.contains(.isPersonalVoice) { return personal }
            return !voice.voiceTraits.contains(.isNoveltyVoice)
        }
    }

    static func appleVoice(identifier: String) -> AVSpeechSynthesisVoice? {
        guard !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier),
            !voice.voiceTraits.contains(.isPersonalVoice)
                || AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized
        else { return nil }
        return voice
    }

    /// The best installed voice for the current language: a Personal Voice the
    /// user allowed, then Premium, then Enhanced, then the system default.
    static func bestVoice(language: String = AVSpeechSynthesisVoice.currentLanguageCode()) -> AVSpeechSynthesisVoice? {
        let personal = AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == language || $0.language.hasPrefix(prefix + "-")
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            if voice.voiceTraits.contains(.isPersonalVoice) { return personal ? 4 : -1 }
            if voice.voiceTraits.contains(.isNoveltyVoice) { return -1 }
            let exact = voice.language == language ? 1 : 0
            switch voice.quality {
            case .premium: return 3 * 2 + exact
            case .enhanced: return 2 * 2 + exact
            default: return exact
            }
        }
        let best = voices.filter { rank($0) >= 0 }.max { rank($0) < rank($1) }
        return best ?? AVSpeechSynthesisVoice(language: language)
    }
}

/// Routes each reply to the engine the user chose, read per reply so the
/// setting applies to the next sentence without restarting voice.
@MainActor
final class VoicePlayback: HermesVoicePlaybackProtocol {
    private let hermes = HermesVoicePlayback()
    private lazy var local = LocalVoicePlayback()

    func speak(
        _ text: String, profileID: String?, client: HermesRPCClientProtocol,
        onCaption: @escaping @MainActor (String?) -> Void
    ) async throws {
        if VoiceSpeechEngine.current == .hermes {
            try await hermes.speak(text, profileID: profileID, client: client, onCaption: onCaption)
        } else {
            try await local.speak(text, onCaption: onCaption)
        }
    }

    func speakLocally(_ text: String, onCaption: @escaping @MainActor (String?) -> Void) async throws {
        try await local.speak(text, onCaption: onCaption)
    }

    func stop() {
        hermes.stop()
        local.stop()
    }

    func prefetch(_ text: String, profileID: String?, client: HermesRPCClientProtocol) {
        if VoiceSpeechEngine.current == .hermes {
            hermes.prefetch(text, profileID: profileID, client: client)
        } else {
            local.prefetch(text)
        }
    }
}

/// Speaks with `AVSpeechSynthesizer`, one caption cue per utterance so captions
/// stay in step exactly as they do with Hermes audio.
@MainActor
final class MacVoicePlayback: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Bool, Never>?
    /// The utterance `finished` waits on; a late callback for a stopped one is ignored.
    private var speaking: ObjectIdentifier?
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ text: String, literal: Bool = false, onCaption: @escaping @MainActor (String?) -> Void
    ) async throws {
        let identifier = UserDefaults.standard.string(forKey: VoiceSpeechEngine.appleVoiceKey) ?? ""
        let voice = VoiceSpeechEngine.appleVoice(identifier: identifier) ?? VoiceSpeechEngine.bestVoice()
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(VoiceSpeechEngine.speed)
        try Task.checkCancellation()
        halt()
        let expected = generation
        let cues = HermesVoicePlayback.cues(text, literal: literal)
        guard !cues.isEmpty else {
            if literal { throw VoicePlaybackError.incomplete }
            return
        }
        for cue in cues {
            let utterance = AVSpeechUtterance(string: cue)
            utterance.voice = voice
            utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            onCaption(cue)
            let completed = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    finished = continuation
                    speaking = ObjectIdentifier(utterance)
                    synthesizer.speak(utterance)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, generation == expected else { return }
                    halt()
                }
            }
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            guard completed else { throw VoicePlaybackError.incomplete }
        }
    }

    func stop() { halt() }

    private func halt() {
        generation &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        resume(completed: false)
    }

    private func resume(completed: Bool) {
        let continuation = finished
        finished = nil
        speaking = nil
        continuation?.resume(returning: completed)
    }

    private func ended(_ utterance: ObjectIdentifier, completed: Bool) {
        if utterance == speaking { resume(completed: completed) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id, completed: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id, completed: false) }
    }
}
