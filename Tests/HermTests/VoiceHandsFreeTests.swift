import Foundation
import Testing
@testable import Herm

struct VoiceHandsFreeTests {
    /// Feeds `level` at ~43 buffers/s (1024 frames @ 44.1 kHz) for `seconds`.
    private func feed(_ detector: inout VoiceEndpointDetector, level: Double, seconds: Double, from start: inout Double) -> Bool {
        var ended = false
        let step = 1024.0 / 44_100
        for _ in 0..<Int(seconds / step) {
            start += step
            if detector.ingest(level: level, at: start) { ended = true }
        }
        return ended
    }

    @Test func endsTurnAfterSpeechThenQuietEvenOverSteadyRoomNoise() {
        var detector = VoiceEndpointDetector()
        var t = 0.0
        // A fan sits at 0.35 — far above Hermes' fixed threshold equivalent.
        #expect(!feed(&detector, level: 0.35, seconds: 3, from: &t))
        #expect(!feed(&detector, level: 0.75, seconds: 1.5, from: &t))
        #expect(!feed(&detector, level: 0.35, seconds: 1, from: &t), "a pause mid-sentence keeps the turn open")
        #expect(!feed(&detector, level: 0.75, seconds: 1, from: &t))
        #expect(feed(&detector, level: 0.35, seconds: 1.5, from: &t))
    }

    @Test func clicksAndBeepsDoNotCountAsSpeech() {
        var detector = VoiceEndpointDetector()
        var t = 0.0
        _ = feed(&detector, level: 0.1, seconds: 1, from: &t)
        #expect(!feed(&detector, level: 0.8, seconds: 0.15, from: &t))
        #expect(!feed(&detector, level: 0.1, seconds: 3, from: &t))
    }

    private func drained(_ gate: inout NativeVoicePlaybackGate, _ running: Bool, _ time: Double) -> Bool {
        gate.isDrained(outputRunning: running, at: time)
    }

    @Test func playbackGateResumesSoonAfterSpeakersGoQuiet() {
        var gate = NativeVoicePlaybackGate(startedAt: 0, cap: 30)
        #expect(!drained(&gate, true, 0.1))
        #expect(!drained(&gate, false, 4.0), "gap between sentences")
        #expect(!drained(&gate, true, 4.5))
        #expect(!drained(&gate, false, 8.0))
        #expect(drained(&gate, false, 9.0), "1s quiet ends the hold, not the 30s estimate")
    }

    @Test func playbackGateWaitsForLateSynthesisAndCapsBusyOutput() {
        var late = NativeVoicePlaybackGate(startedAt: 0, cap: 30)
        #expect(!drained(&late, false, 0.1))
        #expect(!drained(&late, false, 1.5), "TTS may not have started yet")
        #expect(drained(&late, false, 3.0))

        var music = NativeVoicePlaybackGate(startedAt: 0, cap: 6)
        #expect(!drained(&music, true, 5.9))
        #expect(drained(&music, true, 6.0))
    }

    @Test func pillQueueCapsReplacesOldestAndUpdatesInPlace() {
        var queue = VoicePillQueue()
        let now = Date()
        for index in 0..<4 {
            queue.push(key: "k\(index)", icon: .wrench, title: "t\(index)", detail: nil, now: now)
        }
        #expect(queue.pills.map(\.id) == ["k1", "k2", "k3"])
        #expect(Set(queue.pills.map(\.slot)).count == 3, "live pills never share a slot")

        queue.push(key: "k2", icon: .checkCircle, title: "done", detail: nil, now: now.addingTimeInterval(5))
        #expect(queue.pills.count == 3)
        queue.expire(now: now.addingTimeInterval(VoicePillQueue.lifetime + 1))
        #expect(queue.pills.map(\.id) == ["k2"])
    }

    @Test func subtitlesStartAtTheBeginningAndOnlyMoveForward() {
        let track = VoiceSubtitleTrack()
        let id = UUID()
        #expect(track.cue(messageID: id, text: "Hello there.", now: 0) == "Hello there.")
        // More text streams in before the first cue has been spoken.
        #expect(track.cue(messageID: id, text: "Hello there. The build finished cleanly.", now: 0.5) == "Hello there.")
        #expect(track.cue(messageID: id, text: "Hello there. The build finished cleanly.", now: 1.3) == "The build finished cleanly.")
        #expect(track.cue(messageID: id, text: "Hello there. The build finished cleanly.", now: 60) == "The build finished cleanly.", "stays on the last cue")
        #expect(track.cue(messageID: UUID(), text: "Next reply.", now: 61) == "Next reply.")

        let long = Array(repeating: "word", count: 60).joined(separator: " ") + "."
        #expect(VoiceSubtitleTrack.cues(from: long).allSatisfy { $0.count <= VoiceSubtitleTrack.maxCueLength })
    }

    @Test func pillTargetsPreferWebLinksThenExistingFiles() {
        #expect(VoicePillQueue.target(in: #"{"path": "/etc/hosts", "url": "https://example.com/a"}"#) == "https://example.com/a")
        #expect(VoicePillQueue.target(in: #"{"path": "/etc/hosts"}"#) == "/etc/hosts")
        #expect(VoicePillQueue.target(in: "wrote /definitely/not/here.txt") == nil)
        #expect(VoicePillQueue.target(in: "javascript:alert(1)") == nil)
        #expect(VoicePillQueue.label(for: "https://example.com/a") == "example.com")
        #expect(VoicePillQueue.label(for: "/etc/hosts") == "hosts")

        var queue = VoicePillQueue()
        let now = Date()
        queue.push(key: "link", icon: .link, title: "Open", detail: nil, target: "/etc/hosts", now: now)
        queue.expire(now: now.addingTimeInterval(VoicePillQueue.lifetime + 1))
        #expect(queue.pills.count == 1, "clickable cards outlive plain ones")
    }

    @Test func diffStatsCountChangedLinesButNotFileHeaders() {
        var call = ActiveToolCall(id: "1", name: "patch", input: "", context: "", startedAt: .now, isComplete: true)
        #expect(call.diffStats == nil)
        call.diffPreview = "--- a/x.swift\n+++ b/x.swift\n@@ -1,2 +1,3 @@\n-old\n+new\n+more\n same"
        #expect(call.diffStats?.added == 2)
        #expect(call.diffStats?.removed == 1)
    }

    @Test @MainActor func recentTranscriptKeepsTheLastSpokenExchanges() {
        var messages = (0..<10).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .hermes, text: "m\($0)") }
        messages.append(ChatMessage(role: .hermes, text: "boom", isError: true))
        messages.append(ChatMessage(role: .hermes, text: "  "))
        #expect(VoiceRecentTranscript.recent(messages).map(\.text) == ["m4", "m5", "m6", "m7", "m8", "m9"])
    }
}
