import AVFoundation
import SwiftUI

@MainActor
final class VoiceOutput: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var speakingMessageID: UUID?
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenMessageID: UUID?
    private var speechGeneration = 0

    func speak(messageID: UUID, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !(messageID == lastSpokenMessageID && isSpeaking) else { return }
        lastSpokenMessageID = messageID
        speechGeneration &+= 1
        let generation = speechGeneration
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true
        speakingMessageID = messageID
        let utterance = AVSpeechUtterance(string: cleaned(text))
        synthesizer.speak(utterance)
        observeCompletion(generation: generation)
    }

    func toggle(messageID: UUID, text: String) {
        if isSpeaking && speakingMessageID == messageID {
            stop()
        } else {
            speak(messageID: messageID, text: text)
        }
    }

    func stop() {
        speechGeneration &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakingMessageID = nil
        lastSpokenMessageID = nil
    }

    func preview(text: String) {
        let snippet = String(text.prefix(120))
        guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speechGeneration &+= 1
        let generation = speechGeneration
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true
        speakingMessageID = nil
        let utterance = AVSpeechUtterance(string: cleaned(snippet))
        utterance.rate = 0.5
        synthesizer.speak(utterance)
        observeCompletion(generation: generation)
    }

    private func observeCompletion(generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            while let self, self.speechGeneration == generation, self.synthesizer.isSpeaking {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if self?.speechGeneration == generation {
                self?.isSpeaking = false
                self?.speakingMessageID = nil
            }
        }
    }

    private func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
    }
}
