import AVFoundation
import AppKit
import Foundation
import Speech
import SwiftUI
import Testing

@testable import Herm

struct VoiceHandsFreeTests {
    @Test @MainActor func cumulativeRecognitionRevisesRatherThanRepeatingAPreviousPartial() async throws {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        defer { meter.stop() }
        meter.receiveRecognizedText("Find a map of Tacloban City", cumulative: true)
        try await Task.sleep(for: .milliseconds(550))
        meter.receiveRecognizedText("Show a map of Tacloban City", cumulative: true)
        #expect(meter.transcript == "Show a map of Tacloban City")
    }

    @Test @MainActor func revokedWordsDoNotGetSubmittedOrPauseRecognition() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        defer { meter.stop() }
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }

        meter.receiveRecognitionResult("Incorrect guess", ended: false, requestID: id, cumulative: true)
        meter.finishDetectedUtterance()
        meter.receiveRecognitionResult("", ended: true, requestID: id, cumulative: true)
        #expect(completions == [""])
        #expect(meter.transcript.isEmpty)
    }

    @Test @MainActor func onlyRepeatedRapidFailuresReportUnavailable() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        defer { meter.stop() }
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }

        for attempt in 1...3 {
            let request = SFSpeechAudioBufferRecognitionRequest()
            meter.setRecognitionRequestForTesting(request)
            meter.receiveRecognitionResult(
                nil, ended: true, requestID: ObjectIdentifier(request), error: NSError(domain: "test", code: 1))
            #expect(completions.count == (attempt == 3 ? 1 : 0))
        }
        #expect(completions == [nil])
    }

    @Test @MainActor func softWakeSpeechCanFinishWithoutARecognizerPartial() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false, wakeOnly: true)
        defer { meter.stop() }
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }

        meter.ingestAudioLevel(0.05, at: 0)
        meter.ingestAudioLevel(0.20, at: 1)
        meter.ingestAudioLevel(0.20, at: 1.2)
        meter.ingestAudioLevel(0.05, at: 1.3)
        meter.ingestAudioLevel(0.05, at: 2.6)
        meter.ingestAudioLevel(0.05, at: 5.7)
        #expect(completions.isEmpty)
        meter.receiveRecognitionResult("Hey Scout", ended: true, requestID: id)
        #expect(completions == ["Hey Scout"])
    }

    private struct MicrophoneScopeFixture: View {
        @State var meter: MicLevelMeter
        let workspaceDidRender: () -> Void
        let readCaption: (String) -> Void

        var body: some View {
            let _ = workspaceDidRender()
            VoiceMicrophoneContent(meter: meter) { meter in
                let _ = readCaption(meter.transcript)
                Text(meter.transcript)
            }
        }
    }

    @Test @MainActor func microphonePartialsUpdateTalkWithoutRefreshingTheWorkspace() async throws {
        _ = NSApplication.shared
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        defer { meter.stop() }
        var workspaceRenders = 0
        var captions: [String] = []
        let view = MicrophoneScopeFixture(
            meter: meter, workspaceDidRender: { workspaceRenders += 1 }, readCaption: { captions.append($0) })
        let bounds = NSRect(x: 0, y: 0, width: 240, height: 110)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let initialRenders = workspaceRenders
        #expect(initialRenders > 0)

        meter.receiveRecognizedText("First words")
        for _ in 0..<100 where captions.last != "First words" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(captions.last == "First words")
        #expect(workspaceRenders == initialRenders)
    }

    @Test func levelSamplingKeepsPeaksAndCapsDeliveryAtThirtyHertz() {
        var meter = VoiceLevelSampler()
        let samples = (0..<96).compactMap { frame in
            meter.sample(frame == 1 ? 0.9 : 0.1, at: Double(frame) / 96)
        }
        #expect(samples.count == 30)
        #expect(samples[1].level == 0.9)
    }

    @Test @MainActor func playbackChecksOnlyRunDuringActiveSpeech() {
        var probes = 0
        var playing = false
        let meter = MicLevelMeter(outputIsRunning: {
            probes += 1
            return playing
        })
        meter.listen(endpointing: true, watchingForBarge: false)
        meter.ingestAudioLevel(0.1, at: 0)
        #expect(probes == 0)
        meter.ingestAudioLevel(0.8, at: 1)
        meter.ingestAudioLevel(0.8, at: 1.05)
        #expect(probes == 1)
        playing = true
        meter.ingestAudioLevel(0.8, at: 1.11)
        #expect(probes == 2)
        #expect(meter.heardPlayback)

        meter.listen(endpointing: true, watchingForBarge: false, wakeOnly: true)
        meter.ingestAudioLevel(0.8, at: 2)
        #expect(probes == 2)
        #expect(meter.reading.level == 0)
        #expect(meter.isEndpointing)
    }

    @MainActor private func endAudioConfirmedTurn(_ meter: MicLevelMeter, playback: Bool = false) {
        meter.ingestAudioLevel(0.1, at: 0, outputPlaying: playback)
        meter.ingestAudioLevel(0.8, at: 1, outputPlaying: playback)
        meter.ingestAudioLevel(0.8, at: 1.4, outputPlaying: playback)
        meter.ingestAudioLevel(0.1, at: 1.5, outputPlaying: playback)
        meter.ingestAudioLevel(0.1, at: 2.8, outputPlaying: playback)
        meter.ingestAudioLevel(0.1, at: 5.9, outputPlaying: playback)
    }

    @Test @MainActor func finalOnlyRecognitionSurvivesAudioEndpoint() throws {
        var ends = 0
        var cancels = 0
        let feed = RecognitionFeed { request in
            ends += 1
            request.endAudio()
        }
        let meter = MicLevelMeter(
            feed: feed,
            cancelRecognition: { task in
                cancels += 1
                task?.cancel()
            })
        meter.listen(endpointing: true, watchingForBarge: false)
        cancels = 0
        let request = SFSpeechAudioBufferRecognitionRequest()
        meter.setRecognitionRequestForTesting(request)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        #expect(feed.append(buffer))
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }
        endAudioConfirmedTurn(meter)
        #expect(ends == 1)
        #expect(cancels == 0)
        #expect(!feed.append(buffer))
        #expect(completions.isEmpty)
        meter.receiveRecognitionResult("original words", ended: true, requestID: ObjectIdentifier(request))
        meter.receiveRecognitionResult("original words", ended: true, requestID: ObjectIdentifier(request))
        #expect(completions.count == 1)
        #expect(completions.first == "original words")
    }

    @Test @MainActor func exhaustedDrainRecoversOnceAndStaleResultsAreIgnored() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }
        endAudioConfirmedTurn(meter)
        meter.finishRecognitionDrain(requestID: id)
        meter.finishRecognitionDrain(requestID: id)
        meter.receiveRecognitionResult("late", ended: true, requestID: id)
        #expect(completions.count == 1)
        #expect(completions[0] == "")
        #expect(meter.transcript.isEmpty)
    }

    @Test @MainActor func stoppingInvalidatesPendingFinal() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }
        endAudioConfirmedTurn(meter)
        meter.stop()
        meter.receiveRecognitionResult("late", ended: true, requestID: id)
        meter.finishRecognitionDrain(requestID: id)
        #expect(completions.isEmpty)
        #expect(meter.transcript.isEmpty)
    }

    @Test @MainActor func playbackFlagSurvivesDelayedFinal() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        let request = SFSpeechAudioBufferRecognitionRequest()
        meter.setRecognitionRequestForTesting(request)
        var playbackAtCompletion = false
        meter.onUtteranceEnd = { _ in playbackAtCompletion = meter.heardPlayback }
        endAudioConfirmedTurn(meter, playback: true)
        meter.receiveRecognitionResult("echo", ended: true, requestID: ObjectIdentifier(request))
        #expect(playbackAtCompletion)
    }

    @Test @MainActor func drainSuppressesQuietAnnouncementsUntilFinal() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        let request = SFSpeechAudioBufferRecognitionRequest()
        meter.setRecognitionRequestForTesting(request)
        var quiet = 0
        var completions: [String?] = []
        meter.onQuiet = { quiet += 1 }
        meter.onUtteranceEnd = { completions.append($0) }
        endAudioConfirmedTurn(meter)
        let beforeDrain = quiet
        meter.ingestAudioLevel(0.1, at: 8, outputPlaying: false)
        meter.ingestAudioLevel(0.1, at: 40, outputPlaying: false)
        #expect(quiet == beforeDrain)
        meter.receiveRecognitionResult("original words", ended: true, requestID: ObjectIdentifier(request))
        #expect(completions.count == 1)
        #expect(completions.first == "original words")
    }

    @Test @MainActor func drainErrorDoesNotSubmitAnUnfinalizedRequest() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }
        endAudioConfirmedTurn(meter)
        var retry = 0
        meter.onUnfinishedUtterance = { retry += 1 }
        meter.receiveRecognitionResult("partial", ended: false, requestID: id)
        meter.receiveRecognitionResult(nil, ended: true, requestID: id, error: NSError(domain: "test", code: 1))
        #expect(completions == [""])
        #expect(retry == 1)
        #expect(meter.isEndpointing)
    }

    @Test @MainActor func rescoredFinalReplacesThePartialInsteadOfRepeatingIt() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }
        meter.receiveRecognitionResult("call our mom", ended: false, requestID: id)
        meter.finishDetectedUtterance()
        #expect(completions.isEmpty)
        meter.receiveRecognitionResult("Call Herm", ended: true, requestID: id)
        #expect(completions == ["Call Herm"])
    }

    @Test @MainActor func resumingAfterAThinkingPauseKeepsTheSameRecognitionRequest() {
        var drains = 0
        let feed = RecognitionFeed { request in
            drains += 1
            request.endAudio()
        }
        let meter = MicLevelMeter(feed: feed)
        meter.listen(endpointing: true, watchingForBarge: false)
        defer { meter.stop() }
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        let start = ProcessInfo.processInfo.systemUptime
        meter.ingestAudioLevel(0.08, at: start, outputPlaying: false)
        meter.ingestAudioLevel(0.7, at: start + 0.1, outputPlaying: false)
        meter.ingestAudioLevel(0.7, at: start + 0.45, outputPlaying: false)
        meter.receiveRecognitionResult("Play a song", ended: false, requestID: id, cumulative: true)
        meter.ingestAudioLevel(0.08, at: start + 0.46, outputPlaying: false)

        // The earlier endpoint threshold would have closed the recognizer here.
        meter.ingestAudioLevel(0.08, at: start + 1.96, outputPlaying: false)
        meter.ingestAudioLevel(0.7, at: start + 2.01, outputPlaying: false)
        meter.ingestAudioLevel(0.7, at: start + 2.35, outputPlaying: false)
        meter.ingestAudioLevel(0.08, at: start + 2.36, outputPlaying: false)
        #expect(drains == 0)
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }
        meter.receiveRecognitionResult("Play a song in Spotify", ended: false, requestID: id, cumulative: true)
        meter.ingestAudioLevel(0.08, at: start + 4.5, outputPlaying: false)
        #expect(drains == 1)
        meter.receiveRecognitionResult("Play a song in Spotify", ended: true, requestID: id, cumulative: true)
        #expect(completions == ["Play a song in Spotify"])
    }

    @Test @MainActor func theEndOfASameBreathWakeRequestCanArriveAfterTheOldDeadline() async throws {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false, wakeOnly: true)
        defer { meter.stop() }
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }
        meter.receiveRecognitionResult("Hey Herm show me a map of", ended: false, requestID: id, cumulative: true)
        meter.finishDetectedUtterance()
        try await Task.sleep(for: .milliseconds(1_000))
        #expect(completions.isEmpty)
        meter.receiveRecognitionResult(
            "Hey Herm show me a map of Tacloban City", ended: true, requestID: id, cumulative: true)
        #expect(completions == ["Hey Herm show me a map of Tacloban City"])
    }

    @Test @MainActor func timeoutAsksForARepeatAndIgnoresTheLateResult() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        defer { meter.stop() }
        let request = SFSpeechAudioBufferRecognitionRequest()
        let id = ObjectIdentifier(request)
        meter.setRecognitionRequestForTesting(request)
        var completions: [String?] = []
        var retries = 0
        meter.onUtteranceEnd = { completions.append($0) }
        meter.onUnfinishedUtterance = { retries += 1 }
        meter.receiveRecognitionResult("Yes", ended: false, requestID: id, cumulative: true)
        meter.finishDetectedUtterance()
        meter.finishRecognitionDrain(requestID: id, finalized: false)
        meter.receiveRecognitionResult("Yes, don't run that", ended: true, requestID: id, cumulative: true)
        #expect(completions == [""])
        #expect(retries == 1)
        #expect(meter.transcript.isEmpty)
    }

    @Test @MainActor func drainDeadlineTriggersRecovery() async throws {
        let meter = MicLevelMeter()
        meter.listen(endpointing: true, watchingForBarge: false)
        meter.setRecognitionRequestForTesting(SFSpeechAudioBufferRecognitionRequest())
        var completions: [String?] = []
        meter.onUtteranceEnd = { completions.append($0) }
        endAudioConfirmedTurn(meter)
        try await Task.sleep(for: .seconds(8))
        #expect(completions.count == 1)
        #expect(completions.first == .some(""))
    }

    @Test func feedRejectsAudioAfterEndingAndRetainsRequest() throws {
        let feed = RecognitionFeed()
        let request = SFSpeechAudioBufferRecognitionRequest()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        feed.request = request
        #expect(feed.append(buffer))
        feed.endAudio()
        feed.endAudio()
        #expect(feed.request === request)
        #expect(!feed.append(buffer))
    }

    @Test func staleMicrophoneInputCannotReachTheNewRecognitionRequest() throws {
        let feed = RecognitionFeed()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        feed.acceptAudio(from: 1)
        feed.request = SFSpeechAudioBufferRecognitionRequest()
        #expect(feed.append(buffer, generation: 1))

        feed.acceptAudio(from: 2)
        feed.request = SFSpeechAudioBufferRecognitionRequest()
        #expect(!feed.append(buffer, generation: 1))
        #expect(feed.append(buffer, generation: 2))
    }

    @Test(arguments: [false, true]) @MainActor
    func bargeInPreservesPartialAcrossSynchronousModeChange(preservingPlayback: Bool) {
        let meter = MicLevelMeter()
        defer { meter.stop() }
        meter.listen(endpointing: false, watchingForBarge: true, requiresOnDevice: true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        meter.setRecognitionRequestForTesting(request)
        meter.onBargeSpeech = { [weak meter] _ in
            meter?.listen(
                endpointing: true, watchingForBarge: false, requiresOnDevice: true,
                preservingPlaybackOnBargeIn: preservingPlayback)
            return true
        }
        meter.receiveRecognizedText("Read the")
        #expect(meter.isEndpointing)
        #expect(meter.heardPlayback == preservingPlayback)
        #expect(meter.transcript == "Read the")
        meter.receiveRecognitionResult("Read the second option", ended: false, requestID: ObjectIdentifier(request))
        #expect(meter.transcript == "Read the second option")
        // The old reply can finish while the cut-in is still in progress.
        meter.listen(
            endpointing: true, watchingForBarge: false, requiresOnDevice: true, preservingUtterance: true)
        #expect(meter.transcript == "Read the second option")
    }

    @Test @MainActor func interruptionKeepsTheWordsThatStoppedPlayback() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: false, watchingForBarge: true)
        meter.onBargeSpeech = { _ in true }
        meter.receiveRecognizedText("Actually tell me")
        meter.listen(endpointing: true, watchingForBarge: false)
        #expect(meter.transcript == "Actually tell me")
        #expect(meter.isEndpointing)
        meter.receiveRecognizedText("Actually tell me about tomorrow")
        #expect(meter.utteranceTranscript == "Actually tell me about tomorrow")
        // Sending manually enters thinking with the same endpointing mode,
        // but must start a fresh transcript for steering.
        meter.listen(endpointing: true, watchingForBarge: false)
        #expect(meter.transcript.isEmpty)
        meter.stop()
        meter.receiveRecognizedText("Late callback")
        #expect(meter.transcript.isEmpty)
        #expect(!meter.isRunning)
    }

    @Test @MainActor func finishingPlaybackDiscardsUnacceptedEcho() {
        let meter = MicLevelMeter()
        meter.listen(endpointing: false, watchingForBarge: true)
        meter.onBargeSpeech = { _ in false }
        meter.receiveRecognizedText("The forecast is sunny")
        meter.listen(endpointing: true, watchingForBarge: false)
        #expect(meter.transcript.isEmpty)
        meter.stop()
    }

    /// Feeds `level` at ~43 buffers/s (1024 frames @ 44.1 kHz) for `seconds`.
    private func feed(_ detector: inout VoiceEndpointDetector, level: Double, seconds: Double, from start: inout Double)
        -> Bool
    {
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
        #expect(
            VoiceSubtitleTrack.cues(from: "Hello there. The build finished cleanly.") == [
                "Hello there.", "The build finished cleanly.",
            ])
        let long = Array(repeating: "word", count: 60).joined(separator: " ") + "."
        let cues = VoiceSubtitleTrack.cues(from: long)
        #expect(cues.allSatisfy { $0.count <= VoiceSubtitleTrack.maxCueLength })
        #expect(cues.joined(separator: " ") == long)
    }

    @Test func pillTargetsPreferWebLinksThenExistingFiles() {
        #expect(
            VoicePillQueue.target(in: #"{"path": "/etc/hosts", "url": "https://example.com/a"}"#)
                == "https://example.com/a")
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

    @Test func recognizerRestartAfterAPauseKeepsTheEarlierWords() {
        // The recognizer dropped "turn on the lights" and restarted at "and".
        #expect(VoiceEndpointDetector.startsNewSegment(previous: "Turn on the lights", next: "And", pause: 1.2))
        // Growing or revising the same phrase is not a new segment.
        #expect(
            !VoiceEndpointDetector.startsNewSegment(previous: "Turn on", next: "Turn on the lights", pause: 1.2))
        #expect(!VoiceEndpointDetector.startsNewSegment(previous: "I scream", next: "Ice cream", pause: 0.1))
        #expect(!VoiceEndpointDetector.startsNewSegment(previous: "", next: "Hello", pause: 2))
    }

    @Test func runningActivityCardsStayUntilTheirWorkEnds() {
        var queue = VoicePillQueue()
        let now = Date(timeIntervalSince1970: 1000)
        queue.push(
            key: "tool", icon: .terminalWindow, title: "Running a command", detail: nil, isRunning: true, now: now)
        queue.expire(now: now.addingTimeInterval(VoicePillQueue.lifetime * 3))
        #expect(queue.pills.map(\.id) == ["tool"])

        let ended = now.addingTimeInterval(VoicePillQueue.lifetime * 3)
        queue.settleRunning(now: ended)
        #expect(queue.pills.first?.isRunning == false)
        queue.expire(now: ended.addingTimeInterval(VoicePillQueue.lifetime + 1))
        #expect(queue.pills.isEmpty)
    }
}
