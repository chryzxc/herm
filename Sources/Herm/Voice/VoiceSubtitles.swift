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

/// Keeps the chat's Markdown intact while preparing only its prose for the speaker.
enum VoiceSpeechText {
    static func prepare(_ text: String) -> String {
        let source = GenerativeUIIntegration.displayUserText(text)
        // Most streamed sentences are already plain speech.
        guard source.contains("MEDIA:") || source.utf8.contains(where: { "*>_~`#[]<|+{-\n\r\\".utf8.contains($0) })
        else { return source }

        var fence: MarkdownFence?
        var prose: [String] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.replacing(/^\s*(?:>\s*)+/, with: "")
            if let open = fence {
                if open.isClosed(by: line) { fence = nil }
                continue
            }
            if let opening = MarkdownFence(opening: line) {
                fence = opening
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("::preview{"),
                !trimmed.drop(while: { "`\"'".contains($0) }).hasPrefix("MEDIA:")
            else { continue }

            // Markdown tables are read as short rows, never as pipes or separator dashes.
            let tableRow = trimmed.first == "|" && trimmed.last == "|"
            let content: String
            if tableRow {
                let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard cells.contains(where: { cell in cell.contains(where: { $0.isLetter || $0.isNumber }) })
                else { continue }
                content = cells.filter { !$0.isEmpty }.joined(separator: ", ")
            } else {
                content = trimmed
            }
            let markdown =
                content
                .replacing(/<\/?[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*)?\s*\/?>/, with: "")
                .replacing(/(\d)\s*\*\s*(?=\d)/) { "\($0.1) times " }
            let plain = (try? AttributedString(markdown: markdown)).map { String($0.characters) } ?? markdown
            // A stream can end inside emphasis, and escaped punctuation is literal to Markdown.
            let cleaned =
                plain.replacing(/[\*`]+|~{2,}|\b_+\b/, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let standalone = tableRow || trimmed.contains(/^(?:#{1,6}|[-+*]|\d+[.)])\s/)
            let needsPause = standalone && cleaned.last.map { $0.isLetter || $0.isNumber } == true
            prose.append(needsPause ? cleaned + "." : cleaned)
        }
        return prose.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
