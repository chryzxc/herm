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

    @Test func nativeCaptureRearmsOnlyAfterTheResponseCompletes() {
        var lifecycle = NativeVoiceCaptureLifecycle()

        #expect(lifecycle.beginCapture() == true)
        lifecycle.captureStarted()
        lifecycle.receivedTranscript(hasText: true)
        #expect(lifecycle.receivedIdle() == false)
        #expect(lifecycle.beginCapture() == false)

        let drainGeneration = lifecycle.completedResponse()
        #expect(lifecycle.beginCapture() == false)
        #expect(lifecycle.playbackDrainCompleted(generation: drainGeneration) == true)
        #expect(lifecycle.beginCapture() == true)
    }

    @Test func emptyNativeCaptureCanRearmAfterIdle() {
        var lifecycle = NativeVoiceCaptureLifecycle()

        #expect(lifecycle.beginCapture() == true)
        lifecycle.receivedTranscript(hasText: false)

        #expect(lifecycle.receivedIdle() == true)
        #expect(lifecycle.beginCapture() == true)
    }

    @Test func resetInvalidatesAnInFlightNativeCapture() {
        var lifecycle = NativeVoiceCaptureLifecycle()
        let captureGeneration = lifecycle.generation

        lifecycle.reset()

        #expect(!lifecycle.isCurrent(generation: captureGeneration))
    }

    @Test func interruptionHoldsCaptureUntilHermesDeliversTheUtterance() {
        var lifecycle = NativeVoiceCaptureLifecycle()

        let initialCaptureStarted = lifecycle.beginCapture()
        #expect(initialCaptureStarted)
        let interruptionGeneration = lifecycle.beginInterruption()
        let competingCaptureStarted = lifecycle.beginCapture()
        let unrelatedTimeoutRecovered = lifecycle.interruptionTimedOut(generation: interruptionGeneration + 1)
        #expect(!competingCaptureStarted)
        #expect(!unrelatedTimeoutRecovered)

        lifecycle.receivedTranscript(hasText: true)
        let staleTimeoutRecovered = lifecycle.interruptionTimedOut(generation: interruptionGeneration)
        let captureStartedBeforeResponse = lifecycle.beginCapture()
        let drainGeneration = lifecycle.completedResponse()
        let captureStartedDuringPlaybackDrain = lifecycle.beginCapture()
        let playbackDrained = lifecycle.playbackDrainCompleted(generation: drainGeneration)
        let captureStartedAfterResponse = lifecycle.beginCapture()
        #expect(!staleTimeoutRecovered)
        #expect(!captureStartedBeforeResponse)
        #expect(!captureStartedDuringPlaybackDrain)
        #expect(playbackDrained)
        #expect(captureStartedAfterResponse)
    }

    @Test func interruptedCaptureRecoversWhenHermesCannotTranscribe() {
        var lifecycle = NativeVoiceCaptureLifecycle()
        let interruptionGeneration = lifecycle.beginInterruption()

        let timeoutRecovered = lifecycle.interruptionTimedOut(generation: interruptionGeneration)
        let captureStartedAfterTimeout = lifecycle.beginCapture()
        #expect(timeoutRecovered)
        #expect(captureStartedAfterTimeout)
    }

    @Test func bargeInInvalidatesAQueuedPlaybackDrain() {
        var lifecycle = NativeVoiceCaptureLifecycle()
        lifecycle.receivedTranscript(hasText: true)
        let drainGeneration = lifecycle.completedResponse()

        _ = lifecycle.beginInterruption()
        let staleDrainCompleted = lifecycle.playbackDrainCompleted(generation: drainGeneration)
        let competingCaptureStarted = lifecycle.beginCapture()

        #expect(!staleDrainCompleted)
        #expect(!competingCaptureStarted)
    }

    @Test func playbackDrainAccountsForSpeechAndSynthesisLatency() {
        let shortReply = NativeVoicePlaybackDrain.estimatedDuration(for: "Hello there.")
        let conversationalReply = NativeVoicePlaybackDrain.estimatedDuration(
            for: "Hello! I'm here and ready. What can I help you with?"
        )

        #expect(shortReply >= 2.5)
        #expect(conversationalReply >= 5.0)
        #expect(conversationalReply > shortReply)
    }
}
