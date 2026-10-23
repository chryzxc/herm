import Foundation
import SwiftUI

struct VoiceReplyCaption: View {
    let text: String
    var immersive = false

    var body: some View {
        Text(text)
            .dockFont(size: immersive ? 17 : 14, weight: .medium)
            .foregroundStyle(Color.dockPrimaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .lineLimit(4)
    }
}

/// Short speech segments. Each caption is shown by its audio player's start,
/// rather than an estimated reading-speed timer.
enum VoiceSubtitleTrack {
    static let maxCueLength = 110

    /// Sentences, with long ones split on word boundaries. The last cue may
    /// still be growing while the reply streams.
    static func cues(from text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        return sentences.flatMap(split)
    }

    private static func split(_ sentence: String) -> [String] {
        guard sentence.count > maxCueLength else { return [sentence] }
        var cues: [String] = []
        var line = ""
        for word in sentence.split(separator: " ") {
            if !line.isEmpty, line.count + word.count + 1 > maxCueLength {
                cues.append(line)
                line = ""
            }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { cues.append(line) }
        return cues
    }

}
