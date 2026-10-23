import Foundation
import Testing

@testable import Herm

@MainActor
private final class VoiceAudioClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var continuation: CheckedContinuation<[String: Any], Never>?
    var path: String?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any]
    {
        self.path = path
        return await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
struct HermesVoicePlaybackTests {
    @Test func synthesisPinsAndEscapesTheOwningProfile() {
        #expect(HermesVoicePlayback.path(profileID: nil) == "/api/audio/speak?profile=default")
        let path = HermesVoicePlayback.path(profileID: "bot & other")
        #expect(
            URLComponents(string: path)?.queryItems == [
                URLQueryItem(name: "profile", value: "bot & other")
            ])
    }

    @Test func captionSegmentsUseTheExactPlainTextSentForSynthesis() {
        let segments = HermesVoicePlayback.cues(
            "- **Code:** build features and fix bugs.\n- Review changes.")
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { !$0.contains("**") && !$0.hasPrefix("- ") })
        #expect(segments.joined(separator: " ").contains("Code: build features and fix bugs."))
    }

    @Test func synthesisAcceptsOnlyNonemptyAudioData() throws {
        #expect(
            try HermesVoicePlayback.audioData([
                "ok": true, "data_url": "data:audio/wav;base64,AQID",
            ])
                == Data([1, 2, 3]))
        for url in [
            "https://example.com/audio", "data:text/plain;base64,AQID", "data:audio/wav;base64,",
            "data:audio/wav;base64,invalid",
        ] {
            #expect(throws: (any Error).self) {
                try HermesVoicePlayback.audioData(["ok": true, "data_url": url])
            }
        }
        #expect(throws: (any Error).self) {
            try HermesVoicePlayback.audioData([
                "ok": false, "data_url": "data:audio/wav;base64,AQID",
            ])
        }
    }

    @Test func cancelledSynthesisNeverReachesTheSpeakerWhenItsResponseArrivesLate() async throws {
        let client = VoiceAudioClient()
        let playback = HermesVoicePlayback()
        let task = Task {
            try await playback.speak(
                "Hello", profileID: "voice-bot", client: client, onCaption: { _ in })
        }
        for _ in 0..<100 where client.continuation == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.path == "/api/audio/speak?profile=voice-bot")
        task.cancel()
        // Invalid audio proves cancellation wins before decoding or opening a device.
        client.continuation?.resume(returning: [:])
        do {
            try await task.value
            Issue.record("Cancelled synthesis unexpectedly completed")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func cancelledPlaybackDoesNotStartSynthesis() async {
        let client = VoiceAudioClient()
        let playback = HermesVoicePlayback()
        let task = Task {
            try await playback.speak("Hello", profileID: nil, client: client, onCaption: { _ in })
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled playback unexpectedly completed")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(client.path == nil)
    }

    @Test func stoppingPlaybackRejectsAudioFromAnOutstandingSynthesis() async throws {
        let client = VoiceAudioClient()
        let playback = HermesVoicePlayback()
        var captions: [String] = []
        let task = Task {
            try await playback.speak("Hello", profileID: nil, client: client) { text in
                if let text { captions.append(text) }
            }
        }
        for _ in 0..<100 where client.continuation == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        playback.stop()
        client.continuation?.resume(returning: [
            "ok": true, "data_url": "data:audio/wav;base64,AQID",
        ])
        do {
            try await task.value
            Issue.record("Stopped playback unexpectedly completed")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(captions.isEmpty)
    }
}
