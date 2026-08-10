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
    private(set) var startFailures = 0
    private(set) var generation = 0

    func isCurrent(generation: Int) -> Bool {
        self.generation == generation
    }

    mutating func beginCapture() -> Bool {
        guard !captureArmed, !hasPendingTranscript else { return false }
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
    }

    mutating func receivedIdle() -> Bool {
        captureArmed = false
        return !hasPendingTranscript
    }

    mutating func completedResponse() -> Bool {
        hasPendingTranscript = false
        startFailures = 0
        return !captureArmed
    }

    /// Hermes owns the microphone while it captures a spoken interruption.
    /// Do not start a competing `voice.record` capture until its transcript
    /// arrives, or a bounded recovery timeout proves it did not arrive.
    @discardableResult
    mutating func beginInterruption() -> Int {
        generation &+= 1
        captureArmed = false
        hasPendingTranscript = true
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
        startFailures = 0
    }
}
