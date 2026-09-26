import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechInput: ObservableObject {
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var isUnavailable = false
    @Published var transcript = ""
    @Published var errorMessage: String?
    @Published var completedTranscript: String?
    /// Smoothed microphone loudness in the 0...1 range for the voice orb.
    @Published private(set) var audioLevel: CGFloat = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStopping = false
    private var startGeneration = 0
    private var silenceTask: Task<Void, Never>?
    func toggle() {
        if isRecording {
            stop()
        } else {
            startListening()
        }
    }

    /// Begins one recognition turn. Call this again after Hermes has replied to
    /// continue a hands-free conversation.
    func startListening() {
        guard !isRecording, !isStarting else { return }
        startGeneration &+= 1
        // `stop()` cancels callbacks from its recognition turn. Clear that
        // marker before waiting on asynchronous permission callbacks for this
        // new turn, or every listen after the first completed turn exits at
        // the cancellation guard below. The generation still rejects stale
        // callbacks from the old turn.
        isStopping = false
        isUnavailable = false
        errorMessage = nil
        requestPermissionsAndStart(generation: startGeneration)
    }

    func stop() {
        startGeneration &+= 1
        isStopping = true
        silenceTask?.cancel()
        silenceTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isRecording = false
        isStarting = false
        audioLevel = 0
    }

    /// Submits the partial transcript now instead of waiting for silence.
    func finishUtterance() {
        guard isRecording else { return }
        completedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
    }

    func consumeCompletedTranscript() {
        completedTranscript = nil
    }

    /// Assistant playback must never share a recognition turn. Cancelling the
    /// request before TTS starts prevents the system recognizer from treating
    /// Hermes's speaker output as a new user message.
    func stopForAssistantSpeech() {
        completedTranscript = nil
        transcript = ""
        stop()
    }

    private func requestPermissionsAndStart(generation: Int) {
        isStarting = true
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            isStarting = false
            isUnavailable = true
            errorMessage = "Voice input requires the packaged Herm app."
            return
        }
        guard hasUsageDescription("NSSpeechRecognitionUsageDescription"),
              hasUsageDescription("NSMicrophoneUsageDescription") else {
            isStarting = false
            isUnavailable = true
            errorMessage = "This app build is missing voice permissions. Rebuild the Herm app bundle."
            return
        }
        Task { [weak self] in
            guard await Self.requestSpeechAuthorization() == .authorized else {
                guard let self, self.startGeneration == generation, !self.isStopping else { return }
                self.isStarting = false
                self.isUnavailable = true
                self.errorMessage = "Speech recognition permission is required."
                return
            }
            guard await Self.requestMicrophoneAuthorization() else {
                guard let self, self.startGeneration == generation, !self.isStopping else { return }
                self.isStarting = false
                self.isUnavailable = true
                self.errorMessage = "Microphone permission is required."
                return
            }
            guard let self, self.startGeneration == generation, !self.isStopping else { return }
            self.start(generation: generation)
        }
    }

    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated static func installAudioTap(
        on inputNode: AVAudioInputNode,
        request: SFSpeechAudioBufferRecognitionRequest,
        onAudioLevel: @escaping (CGFloat) -> Void
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
            request.append(buffer)
            onAudioLevel(normalizedAudioLevel(buffer))
        }
    }

    nonisolated static func normalizedAudioLevel(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        // Speech normally lives between roughly -55 dB (silence) and -10 dB.
        return CGFloat(min(1, max(0, (decibels + 55) / 45)))
    }

    private func start(generation: Int) {
        guard startGeneration == generation, !isStopping else { return }
        guard let recognizer, recognizer.isAvailable else {
            isStarting = false
            isUnavailable = true
            errorMessage = "Speech recognition is currently unavailable."
            return
        }

        transcript = ""
        isStopping = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            self.request = nil
            isStarting = false
            isUnavailable = true
            errorMessage = "No microphone input device is available."
            return
        }
        inputNode.removeTap(onBus: 0)
        Self.installAudioTap(on: inputNode, request: request) { [weak self] level in
            Task { @MainActor [weak self] in
                self?.updateAudioLevel(level)
            }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.request === request else { return }
                guard !isStopping else { return }
                if let result {
                    transcript = result.bestTranscription.formattedString
                    scheduleAutomaticSubmit(after: transcript)
                }
                if let error {
                    errorMessage = "Speech recognition stopped: \(error.localizedDescription)"
                    isUnavailable = true
                    stop()
                } else if result?.isFinal == true {
                    completedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    stop()
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            isStarting = false
        } catch {
            stop()
            isUnavailable = true
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
        }
    }

    private func hasUsageDescription(_ key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scheduleAutomaticSubmit(after transcript: String) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled,
                  let self,
                  self.isRecording,
                  self.transcript == transcript else { return }
            completedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            stop()
        }
    }

    private func updateAudioLevel(_ level: CGFloat) {
        // Fast attack keeps speech responsive; a slower release avoids a jittery orb.
        let smoothing: CGFloat = level > audioLevel ? 0.52 : 0.14
        audioLevel += (level - audioLevel) * smoothing
    }
}

/// Level-only microphone tap for the voice orb while Hermes' gateway owns
/// capture and transcription. CoreAudio shares input devices between
/// processes, so this never competes with Hermes' recorder.
@MainActor
final class MicLevelMeter: ObservableObject {
    @Published private(set) var level: CGFloat = 0
    private var engine: AVAudioEngine?
    private var generation = 0

    func start() {
        guard engine == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        generation &+= 1
        let expected = generation
        Task { [weak self] in
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            guard granted, let self, self.generation == expected, self.engine == nil else { return }
            self.startEngine()
        }
    }

    func stop() {
        generation &+= 1
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        level = 0
    }

    private func startEngine() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        Self.installTap(on: input) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let smoothing: CGFloat = value > self.level ? 0.5 : 0.12
                self.level += (value - self.level) * smoothing
            }
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    private nonisolated static func installTap(on input: AVAudioInputNode, onLevel: @escaping @Sendable (CGFloat) -> Void) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
            onLevel(SpeechInput.normalizedAudioLevel(buffer))
        }
    }
}
