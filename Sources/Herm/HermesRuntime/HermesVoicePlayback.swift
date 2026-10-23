import AVFoundation
import Foundation

@MainActor
protocol HermesVoicePlaybackProtocol: AnyObject {
    func speak(
        _ text: String, profileID: String?, client: HermesRPCClientProtocol,
        onCaption: @escaping @MainActor (String?) -> Void) async throws
    func stop()
}

/// Synthesis belongs to Hermes; the selected conversation owns the speaker.
@MainActor
final class HermesVoicePlayback: HermesVoicePlaybackProtocol {
    private var player: AVAudioPlayer?
    private var generation = 0

    func speak(
        _ text: String, profileID: String?, client: HermesRPCClientProtocol,
        onCaption: @escaping @MainActor (String?) -> Void
    ) async throws {
        try Task.checkCancellation()
        stop()
        let expected = generation
        let cues = Self.cues(text)
        var nextAudio: Task<Data, Error>?
        defer { nextAudio?.cancel() }
        for (index, cue) in cues.enumerated() {
            onCaption(nil)
            let data: Data
            if let pending = nextAudio {
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
            guard audio.play() else { throw Self.unavailable("Could not play the voice reply.") }
            onCaption(cue)
            while audio.isPlaying {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard generation == expected else { throw CancellationError() }
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

    static func cues(_ text: String) -> [String] {
        let plain = GenerativeUIIntegration.plainText(text).components(separatedBy: .newlines).map {
            line in
            (try? AttributedString(markdown: line)).map { String($0.characters) } ?? line
        }.joined(separator: " ")
        return VoiceSubtitleTrack.cues(from: plain)
    }

    func stop() {
        generation &+= 1
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
