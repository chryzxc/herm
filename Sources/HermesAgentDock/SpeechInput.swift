import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechInput: ObservableObject {
    @Published var isRecording = false
    @Published var isStarting = false
    @Published var isUnavailable = false
    @Published var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isSimulated = false

    func toggle() {
        if isRecording {
            stop()
        } else {
            isUnavailable = false
            requestPermissionsAndStart()
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        isRecording = false
        isStarting = false
        isSimulated = false
    }

    private func requestPermissionsAndStart() {
        isStarting = true
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            isStarting = false
            isSimulated = true
            isRecording = true
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                Task { @MainActor [weak self] in
                    self?.isStarting = false
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else {
                    Task { @MainActor [weak self] in
                        self?.isStarting = false
                    }
                    return
                }
                Task { @MainActor [weak self] in
                    self?.start()
                }
            }
        }
    }

    private func start() {
        guard let recognizer, recognizer.isAvailable else { return }

        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
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
        }
    }
}
