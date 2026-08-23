import AVFoundation
import SwiftUI

@MainActor
final class VoiceOutput: ObservableObject {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenMessageID: UUID?
    private var speechGeneration = 0

    func speak(messageID: UUID, text: String) {
        guard messageID != lastSpokenMessageID else { return }
        lastSpokenMessageID = messageID
        speechGeneration &+= 1
        let generation = speechGeneration
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true
        let utterance = AVSpeechUtterance(string: cleaned(text))
        synthesizer.speak(utterance)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            while let self, self.speechGeneration == generation, self.synthesizer.isSpeaking {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if self?.speechGeneration == generation {
                self?.isSpeaking = false
            }
        }
    }

    func stop() {
        speechGeneration &+= 1
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func preview(text: String) {
        let snippet = String(text.prefix(120))
        guard !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speechGeneration &+= 1
        let generation = speechGeneration
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = true
        let utterance = AVSpeechUtterance(string: cleaned(snippet))
        utterance.rate = 0.5
        synthesizer.speak(utterance)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            while let self, self.speechGeneration == generation, self.synthesizer.isSpeaking {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if self?.speechGeneration == generation {
                self?.isSpeaking = false
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
