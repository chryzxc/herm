import Foundation

/// Movie-style captions for a spoken reply: the reply is cut into short cues
/// that are shown one at a time at roughly speaking pace, and only ever move
/// forward. A reference type held in `@State`, advanced from a timeline, so
/// ticking it never invalidates the view.
final class VoiceSubtitleTrack {
    static let maxCueLength = 110

    private var messageID: UUID?
    private var index = 0
    private var shownAt: TimeInterval = 0

    /// The cue to show for `text` at `now`. A new `messageID` restarts at the
    /// first cue; otherwise the track moves on once the current cue is
    /// complete and has been on screen long enough to be spoken.
    func cue(messageID: UUID, text: String, now: TimeInterval) -> String? {
        if messageID != self.messageID {
            self.messageID = messageID
            index = 0
            shownAt = now
        }
        let cues = Self.cues(from: text)
        guard !cues.isEmpty else { return nil }
        index = min(index, cues.count - 1)
        if index + 1 < cues.count, now - shownAt >= Self.duration(of: cues[index]) {
            index += 1
            shownAt = now
        }
        return cues[index]
    }

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

    /// Matches the speaking rate `NativeVoicePlaybackDrain` assumes.
    static func duration(of cue: String) -> TimeInterval {
        max(1.2, Double(cue.split(separator: " ").count) / 2.25 + 0.3)
    }
}
