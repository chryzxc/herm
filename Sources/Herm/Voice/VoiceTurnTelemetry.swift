import CoreAudio
import Foundation

/// Timing markers for a single native Hermes voice turn. Keeping this as a
/// value type makes the UI independent from the gateway and easy to test.
struct VoiceTurnTelemetry: Equatable {
    private(set) var listeningStartedAt: Date?
    private(set) var transcriptReceivedAt: Date?
    private(set) var requestSubmittedAt: Date?
    private(set) var firstResponseAt: Date?
    private(set) var completedAt: Date?
    private(set) var wasInterrupted = false

    mutating func beginListening(at date: Date = .now) {
        listeningStartedAt = date
        transcriptReceivedAt = nil
        requestSubmittedAt = nil
        firstResponseAt = nil
        completedAt = nil
        wasInterrupted = false
    }

    mutating func receivedTranscript(at date: Date = .now) {
        transcriptReceivedAt = date
    }

    mutating func submittedRequest(at date: Date = .now) {
        requestSubmittedAt = date
    }

    mutating func receivedResponse(at date: Date = .now) {
        if firstResponseAt == nil {
            firstResponseAt = date
        }
    }

    mutating func completedResponse(at date: Date = .now) {
        completedAt = date
    }

    mutating func markInterrupted() {
        wasInterrupted = true
    }

    var summary: String? {
        if wasInterrupted { return "INTERRUPTED" }
        guard let requestSubmittedAt else { return nil }
        var parts: [String] = []
        if let firstResponseAt {
            parts.append("FIRST \(duration(firstResponseAt.timeIntervalSince(requestSubmittedAt)))")
        }
        if let completedAt {
            parts.append("DONE \(duration(completedAt.timeIntervalSince(requestSubmittedAt)))")
        }
        return parts.isEmpty ? "REQUEST SENT" : parts.joined(separator: " · ")
    }

    private func duration(_ value: TimeInterval) -> String {
        String(format: "%.1fs", max(0, value))
    }
}

/// The gateway records one VAD-bounded native capture at a time. This small
/// state machine owns the re-arm decision so a completed response cannot leave
/// the UI claiming to listen while no `voice.record` capture is active.
struct NativeVoiceCaptureLifecycle: Equatable {
    private(set) var captureArmed = false
    private(set) var hasPendingTranscript = false
    private(set) var isAwaitingPlaybackDrain = false
    private(set) var startFailures = 0
    private(set) var generation = 0

    func isCurrent(generation: Int) -> Bool {
        self.generation == generation
    }

    mutating func beginCapture() -> Bool {
        guard !captureArmed, !hasPendingTranscript, !isAwaitingPlaybackDrain else { return false }
        captureArmed = true
        return true
    }

    mutating func captureStarted() {
        startFailures = 0
    }

    mutating func captureStartFailed() -> Bool {
        captureArmed = false
        startFailures += 1
        return startFailures <= 3
    }

    mutating func receivedTranscript(hasText: Bool) {
        // A transcript resolves any prior capture or barge-in recovery timer.
        // Incrementing the generation makes delayed start/timeout callbacks
        // harmless instead of allowing them to claim the microphone again.
        generation &+= 1
        captureArmed = false
        hasPendingTranscript = hasText
        isAwaitingPlaybackDrain = false
    }

    mutating func receivedIdle() -> Bool {
        captureArmed = false
        return !hasPendingTranscript
    }

    /// `message.complete` closes model generation, not speaker playback. Hold
    /// the normal recorder while Hermes flushes its streamed TTS queue; its
    /// full-duplex listener remains responsible for real user barge-in.
    @discardableResult
    mutating func completedResponse() -> Int {
        generation &+= 1
        hasPendingTranscript = false
        captureArmed = false
        isAwaitingPlaybackDrain = true
        startFailures = 0
        return generation
    }

    mutating func playbackDrainCompleted(generation: Int) -> Bool {
        guard self.generation == generation, isAwaitingPlaybackDrain else { return false }
        isAwaitingPlaybackDrain = false
        return !captureArmed && !hasPendingTranscript
    }

    /// Hermes owns the microphone while it captures a spoken interruption.
    /// Do not start a competing `voice.record` capture until its transcript
    /// arrives, or a bounded recovery timeout proves it did not arrive.
    @discardableResult
    mutating func beginInterruption() -> Int {
        generation &+= 1
        captureArmed = false
        hasPendingTranscript = true
        isAwaitingPlaybackDrain = false
        startFailures = 0
        return generation
    }

    mutating func interruptionTimedOut(generation: Int) -> Bool {
        guard self.generation == generation, hasPendingTranscript else { return false }
        hasPendingTranscript = false
        return !captureArmed
    }

    mutating func reset() {
        generation &+= 1
        captureArmed = false
        hasPendingTranscript = false
        isAwaitingPlaybackDrain = false
        startFailures = 0
    }
}

/// Hermes currently has no gateway event for "the final speaker sample has
/// played". Streaming TTS can finish several seconds after `message.complete`,
/// so reopening the ordinary recorder at that event feeds Hermes its own
/// voice. This conservative estimate keeps barge-in on Hermes' dedicated
/// full-duplex listener while delaying only the next quiet listening turn.
enum NativeVoicePlaybackDrain {
    static func estimatedDuration(for text: String) -> TimeInterval {
        // Hermes' speech path caps a reply at 4,000 characters.
        let spokenText = String(text.prefix(4_000))
        let words = spokenText.split(whereSeparator: { $0.isWhitespace }).count
        let sentenceEnds = spokenText.reduce(into: 0) { count, character in
            if character == "." || character == "!" || character == "?" {
                count += 1
            }
        }
        let sentences = max(1, min(sentenceEnds, 12))

        // About 135 spoken words/minute, plus synthesis startup per sentence
        // and an acoustic tail so CoreAudio has released the output device.
        return max(2.5, (Double(words) / 2.25) + (Double(sentences) * 0.65) + 0.8)
    }
}

/// Ends the post-reply microphone hold when the speakers actually go quiet,
/// instead of always waiting out the word-count estimate (which is kept as the
/// cap for when other audio, like music, keeps the output device busy).
struct NativeVoicePlaybackGate {
    let startedAt: TimeInterval
    let cap: TimeInterval
    /// Longer than Hermes' gap between two streamed TTS sentences (~0.5s).
    var quietHold: TimeInterval = 1.0
    /// Before any playback is heard, synthesis may still be starting.
    var startupGrace: TimeInterval = 3.0
    private var sawPlayback = false
    private var quietSince: TimeInterval?

    init(startedAt: TimeInterval, cap: TimeInterval) {
        self.startedAt = startedAt
        self.cap = cap
    }

    mutating func isDrained(outputRunning: Bool, at now: TimeInterval) -> Bool {
        let elapsed = now - startedAt
        if elapsed >= cap { return true }
        if outputRunning {
            sawPlayback = true
            quietSince = nil
            return false
        }
        let since = quietSince ?? now
        quietSince = since
        return now - since >= quietHold && (sawPlayback || elapsed >= startupGrace)
    }

    /// Whether any process is playing through the default output device.
    /// Hermes plays each TTS sentence with `afplay`; nil if CoreAudio fails.
    static func isOutputRunning() -> Bool? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }
}
