import AVFoundation
import Foundation

@MainActor
protocol HermesVoicePlaybackProtocol: AnyObject {
    func speak(
        _ text: String, profileID: String?, client: HermesRPCClientProtocol,
        onCaption: @escaping @MainActor (String?) -> Void) async throws
    func speakLocally(_ text: String, onCaption: @escaping @MainActor (String?) -> Void) async throws
    func stop()
    /// Starts synthesizing a queued reply's first sentence while the current one plays.
    func prefetch(_ text: String, profileID: String?, client: HermesRPCClientProtocol)
}

extension HermesVoicePlaybackProtocol {
    func prefetch(_ text: String, profileID: String?, client: HermesRPCClientProtocol) {}
}

/// Synthesis belongs to Hermes; the selected conversation owns the speaker.
@MainActor
final class HermesVoicePlayback {
    private var player: AVAudioPlayer?
    private var generation = 0
    private var prefetched: [(cue: String, profileID: String?, audio: Task<Data, Error>)] = []

    func speak(
        _ text: String, profileID: String?, client: HermesRPCClientProtocol,
        onCaption: @escaping @MainActor (String?) -> Void
    ) async throws {
        try Task.checkCancellation()
        halt()
        let expected = generation
        let cues = Self.cues(text)
        var nextAudio: Task<Data, Error>?
        defer { nextAudio?.cancel() }
        for (index, cue) in cues.enumerated() {
            onCaption(nil)
            let data: Data
            if let pending = nextAudio ?? takePrefetched(cue, profileID: profileID) {
                data = try await pending.value
            } else {
                data = try await synthesize(cue, profileID: profileID, client: client)
            }
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            // Prepare the next segment while this one plays, so caption sync
            // does not add a synthesis round-trip between every sentence.
            nextAudio =
                index + 1 < cues.count
                ? Task {
                    try await synthesize(cues[index + 1], profileID: profileID, client: client)
                } : nil
            let audio = try AVAudioPlayer(data: data)
            player = audio
            defer {
                audio.stop()
                if player === audio { player = nil }
            }
            let finish = PlaybackFinish()
            audio.delegate = finish
            guard audio.play() else { throw Self.unavailable("Could not play the voice reply.") }
            onCaption(cue)
            // Wakes the moment the sentence ends, so the next one follows without a polling gap.
            let completed = await withTaskCancellationHandler {
                await finish.wait()
            } onCancel: {
                Task { @MainActor in finish.end() }
            }
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            guard completed else { throw VoicePlaybackError.incomplete }
        }
    }

    private func synthesize(_ cue: String, profileID: String?, client: HermesRPCClientProtocol)
        async throws -> Data
    {
        try Task.checkCancellation()
        let response = try await client.sendHTTP(
            "POST", path: Self.path(profileID: profileID), body: ["text": cue], timeout: 30)
        try Task.checkCancellation()
        return try Self.audioData(response)
    }

    static func cues(_ text: String, literal: Bool = false) -> [String] {
        VoiceSubtitleTrack.cues(from: literal ? text : VoiceSpeechText.prepare(text))
    }

    func prefetch(_ text: String, profileID: String?, client: HermesRPCClientProtocol) {
        // Streamed replies arrive a sentence at a time; without this, each one waits
        // a full synthesis round-trip after the previous sentence finishes playing.
        guard let cue = Self.cues(text).first,
            !prefetched.contains(where: { $0.cue == cue && $0.profileID == profileID })
        else { return }
        prefetched.append(
            (cue, profileID, Task { try await synthesize(cue, profileID: profileID, client: client) }))
    }

    private func takePrefetched(_ cue: String, profileID: String?) -> Task<Data, Error>? {
        guard let index = prefetched.firstIndex(where: { $0.cue == cue && $0.profileID == profileID })
        else { return nil }
        return prefetched.remove(at: index).audio
    }

    func stop() {
        halt()
        for item in prefetched { item.audio.cancel() }
        prefetched.removeAll()
    }

    /// Ends the current segment but keeps audio prepared for the queued sentences.
    private func halt() {
        generation &+= 1
        (player?.delegate as? PlaybackFinish)?.end()
        player?.stop()
        player = nil
    }

    static func path(profileID: String?) -> String {
        var url = URLComponents()
        url.path = "/api/audio/speak"
        // An absent profile must resolve to the default, never a later UI selection.
        url.queryItems = [URLQueryItem(name: "profile", value: profileID ?? "default")]
        return url.string!
    }

    static func audioData(_ response: [String: Any]) throws -> Data {
        guard response["ok"] as? Bool == true,
            let url = response["data_url"] as? String,
            let separator = url.firstIndex(of: ","),
            url.hasPrefix("data:audio/"), url[..<separator].hasSuffix(";base64"),
            url.utf8.count <= 32 * 1_024 * 1_024,
            let data = Data(base64Encoded: String(url[url.index(after: separator)...])),
            !data.isEmpty
        else {
            throw unavailable("Hermes did not return playable voice audio.")
        }
        return data
    }

    private static func unavailable(_ message: String) -> NSError {
        NSError(domain: "HermVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum VoicePlaybackError: LocalizedError {
    case incomplete

    var errorDescription: String? { "The voice reply did not finish playing." }
}

/// Resumes one waiting sentence when its player finishes, is stopped, or the
/// task is cancelled; later signals are ignored.
@MainActor
final class PlaybackFinish: NSObject, AVAudioPlayerDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }

    func end(completed: Bool = false) {
        guard result == nil else { return }
        result = completed
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: completed)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in end(completed: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in end() }
    }
}
