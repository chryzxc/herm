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
