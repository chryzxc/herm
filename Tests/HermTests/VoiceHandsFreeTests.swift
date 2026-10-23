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

    @Test func pillQueueKeepsRestrictedSlotsDistinctDuringBursts() {
        var queue = VoicePillQueue()
        let now = Date()
        for index in 0..<10 {
            queue.push(key: "k\(index)", icon: .wrench, title: "Tool", detail: nil, slots: [1, 2], now: now)
            #expect(queue.pills.count <= 2)
            #expect(Set(queue.pills.map(\.slot)).count == queue.pills.count)
            #expect(queue.pills.allSatisfy { [1, 2].contains($0.slot) })
        }
        #expect(queue.pills.map(\.id) == ["k8", "k9"])
        let slot = queue.pills.last?.slot
        queue.push(key: "k9", icon: .checkCircle, title: "Done", detail: nil, slots: [1, 2], now: now)
        #expect(queue.pills.last?.slot == slot)
    }

    @Test func pillQueueMovesExistingCardsWhenHUDReservesLeftSide() {
        var queue = VoicePillQueue()
        let now = Date()
        for index in 0..<3 {
            queue.push(key: "k\(index)", icon: .wrench, title: "Tool", detail: nil, now: now)
        }
        queue.restrict(to: [1, 2])
        #expect(queue.pills.map(\.id) == ["k1", "k2"])
        #expect(Set(queue.pills.map(\.slot)) == Set([1, 2]))
        queue.restrict(to: [])
        #expect(queue.pills.isEmpty)
    }

    @Test func speechCuesPreserveTheTextInShortOrderedSegments() {
        #expect(VoiceSubtitleTrack.cues(from: "Hello there. The build finished cleanly.") == ["Hello there.", "The build finished cleanly."])
        let long = Array(repeating: "word", count: 60).joined(separator: " ") + "."
        let cues = VoiceSubtitleTrack.cues(from: long)
        #expect(cues.allSatisfy { $0.count <= VoiceSubtitleTrack.maxCueLength })
        #expect(cues.joined(separator: " ") == long)
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
