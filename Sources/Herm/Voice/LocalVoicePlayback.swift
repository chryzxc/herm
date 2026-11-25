import AVFoundation
import Foundation
import NaturalLanguage

/// The local voice is shared by conversation replies, private actions, notices and the preview.
@MainActor
final class LocalVoicePlayback {
    private lazy var apple = MacVoicePlayback()
    private var player: AVAudioPlayer?
    private var pending: Task<Data, Error>?
    private var prefetched: [(key: Clip, audio: Task<Data, Error>)] = []
    private var generation = 0

    private struct Clip: Equatable {
        let cue: String
        let voice: String
        let speed: Double
    }

    func speak(
        _ text: String, literal: Bool = false, allowsFallback: Bool = true,
        onCaption: @escaping @MainActor (String?) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        beginPlayback()
        guard VoiceSpeechEngine.current == .kokoro else {
            try await apple.speak(text, literal: literal, onCaption: onCaption)
            return
        }
        guard KokoroVoice.installed, Self.supportsKokoro(text) else {
            guard allowsFallback else { throw KokoroVoice.Failure.unavailable }
            try await apple.speak(text, literal: literal, onCaption: onCaption)
            return
        }
        let expected = generation
        let voice = Self.selectedPreset
        let speed = VoiceSpeechEngine.speed
        let cues = HermesVoicePlayback.cues(text, literal: literal)
        guard !cues.isEmpty else {
            if literal { throw VoicePlaybackError.incomplete }
            return
        }
        defer {
            if generation == expected { stopAudio() }
        }
        if let first = cues.first { pending = audio(for: Clip(cue: first, voice: voice, speed: speed)) }
        for (index, cue) in cues.enumerated() {
            do {
                guard let pending else { throw KokoroVoice.Failure.unavailable }
                let data = try await withTaskCancellationHandler {
                    try await pending.value
                } onCancel: {
                    pending.cancel()
                }
                try Task.checkCancellation()
                guard generation == expected else { throw CancellationError() }
                self.pending =
                    index + 1 < cues.count ? audio(for: Clip(cue: cues[index + 1], voice: voice, speed: speed)) : nil
                try await play(data) { onCaption(cue) }
                guard generation == expected else { throw CancellationError() }
            } catch {
                try Task.checkCancellation()
                guard generation == expected else { throw CancellationError() }
                guard allowsFallback else { throw error }
                stopAudio()
                try await apple.speak(cues[index...].joined(separator: " "), literal: true, onCaption: onCaption)
                return
            }
        }
    }

    func prefetch(_ text: String) {
        guard VoiceSpeechEngine.current == .kokoro, KokoroVoice.installed, Self.supportsKokoro(text),
            let cue = HermesVoicePlayback.cues(text).first
        else { return }
        let clip = Clip(cue: cue, voice: Self.selectedPreset, speed: VoiceSpeechEngine.speed)
        guard !prefetched.contains(where: { $0.key == clip }) else { return }
        if prefetched.count == 2 { prefetched.removeFirst().audio.cancel() }
        prefetched.append((clip, generate(clip)))
    }

    func stop() {
        beginPlayback()
        for entry in prefetched { entry.audio.cancel() }
        prefetched.removeAll()
    }

    private func beginPlayback() {
        generation &+= 1
        stopAudio()
        apple.stop()
    }

    private func stopAudio() {
        pending?.cancel()
        pending = nil
        (player?.delegate as? PlaybackFinish)?.end()
        player?.stop()
        player = nil
    }

    private static var selectedPreset: String {
        UserDefaults.standard.string(forKey: VoiceSpeechEngine.kokoroVoiceKey) ?? ""
    }

    private func audio(for clip: Clip) -> Task<Data, Error> {
        if let index = prefetched.firstIndex(where: { $0.key == clip }) {
            return prefetched.remove(at: index).audio
        }
        return generate(clip)
    }

    private func generate(_ clip: Clip) -> Task<Data, Error> {
        Task { try await KokoroVoice.synthesize(clip.cue, voice: clip.voice, speed: clip.speed) }
    }

    private func play(_ data: Data, onStart: () -> Void) async throws {
        let audio = try AVAudioPlayer(data: data)
        let finish = PlaybackFinish()
        audio.delegate = finish
        player = audio
        defer {
            audio.stop()
            if player === audio { player = nil }
        }
        guard audio.play() else { throw KokoroVoice.Failure.unavailable }
        onStart()
        let completed = await withTaskCancellationHandler {
            await finish.wait()
        } onCancel: {
            Task { @MainActor in finish.end() }
        }
        try Task.checkCancellation()
        guard completed else { throw VoicePlaybackError.incomplete }
    }

    static func supportsKokoro(_ text: String) -> Bool {
        guard text.split(whereSeparator: \.isWhitespace).count >= 5 else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(512)))
        guard let match = recognizer.languageHypotheses(withMaximum: 1).first, match.value >= 0.85 else { return true }
        return match.key == .english
    }
}
