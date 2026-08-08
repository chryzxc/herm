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

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStopping = false
    private var silenceTask: Task<Void, Never>?
    func toggle() {
        if isRecording {
            stop()
        } else {
            isUnavailable = false
            errorMessage = nil
            requestPermissionsAndStart()
        }
    }

    func stop() {
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
    }

    func consumeCompletedTranscript() {
        completedTranscript = nil
    }

    private func requestPermissionsAndStart() {
        isStarting = true
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            isStarting = false
            isUnavailable = true
            errorMessage = "Voice input requires the packaged Hermes Agent Dock app."
            return
        }
        guard hasUsageDescription("NSSpeechRecognitionUsageDescription"),
              hasUsageDescription("NSMicrophoneUsageDescription") else {
            isStarting = false
            isUnavailable = true
            errorMessage = "This app build is missing voice permissions. Rebuild the Hermes Agent Dock app bundle."
            return
        }
        Task { [weak self] in
            guard await Self.requestSpeechAuthorization() == .authorized else {
                self?.isStarting = false
                self?.isUnavailable = true
                self?.errorMessage = "Speech recognition permission is required."
                return
            }
            guard await Self.requestMicrophoneAuthorization() else {
                self?.isStarting = false
                self?.isUnavailable = true
                self?.errorMessage = "Microphone permission is required."
                return
            }
            self?.start()
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
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { buffer, _ in
            request.append(buffer)
        }
    }

    private func start() {
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
        Self.installAudioTap(on: inputNode, request: request)

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
}
