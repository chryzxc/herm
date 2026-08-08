import Foundation
import Testing
@testable import HermesAgentDock

struct VoiceTurnTelemetryTests {
    @Test func reportsFirstResponseAndCompletionFromSubmission() {
        let submitted = Date(timeIntervalSince1970: 100)
        var telemetry = VoiceTurnTelemetry()

        telemetry.beginListening(at: submitted.addingTimeInterval(-2))
        telemetry.receivedTranscript(at: submitted.addingTimeInterval(-1))
        telemetry.submittedRequest(at: submitted)
        telemetry.receivedResponse(at: submitted.addingTimeInterval(0.84))
        telemetry.completedResponse(at: submitted.addingTimeInterval(2.11))

        #expect(telemetry.summary == "FIRST 0.8s · DONE 2.1s")
    }

    @Test func interruptionTakesPrecedenceOverEarlierTimings() {
        var telemetry = VoiceTurnTelemetry()
        telemetry.submittedRequest(at: Date(timeIntervalSince1970: 100))
        telemetry.receivedResponse(at: Date(timeIntervalSince1970: 101))
        telemetry.markInterrupted()

        #expect(telemetry.summary == "INTERRUPTED")
    }
}
