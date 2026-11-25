import Foundation

/// Only complete prose crosses the speech boundary; unfinished structured output
/// waits for the normal completed-reply renderer. This state is disposable per turn.
struct VoiceReplyStream {
    private(set) var emitted = ""
    private var pending = ""
    private var defersUntilComplete = false

    mutating func append(_ delta: String) -> String? {
        guard !defersUntilComplete else { return nil }
        pending += delta
        guard pending.utf8.count <= 4_096 else {
            defersUntilComplete = true
            pending = ""
            return nil
        }
        // Structured output (code, a link, a herm-ui block) waits for the completed
        // reply, but the finished prose before it is spoken now rather than held
        // back with it. Whatever begins at the marker starts a new sentence.
        if let marker = Self.firstMarker(in: pending) {
            defersUntilComplete = true
            let head = String(pending[..<marker])
            pending = ""
            guard let boundary = Self.lastSentenceEnd(in: head, includingTrailing: true) else { return nil }
            let text = String(head[..<boundary])
            emitted += text
            return text
        }
        guard let boundary = Self.lastSentenceEnd(in: pending, includingTrailing: false) else { return nil }
        let text = String(pending[..<boundary])
        emitted += text
        pending = String(pending[boundary...])
        return text
    }

    private static func firstMarker(in text: String) -> String.Index? {
        let symbol = text.firstIndex { "`<{[".contains($0) }
        let fence = text.range(of: "~~~")?.lowerBound
        let delivery = text.range(of: "MEDIA:")?.lowerBound
        return [symbol, fence, delivery].compactMap(\.self).min()
    }

    /// The end of the last complete sentence. A sentence counts as complete once
    /// the next one has started, or at the end when `includingTrailing` and it
    /// ends in terminal punctuation.
    private static func lastSentenceEnd(in text: String, includingTrailing: Bool) -> String.Index? {
        var boundary: String.Index?
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { _, range, _, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if includingTrailing || range.upperBound < text.endIndex,
                sentence.last.map({ ".!?。！？".contains($0) }) == true
            {
                boundary = range.upperBound
            }
        }
        return boundary
    }

    /// A tool boundary proves the model has finished its preceding narration,
    /// even when no next sentence arrived to delimit the final punctuation.
    mutating func flushSentence() -> String? {
        guard !defersUntilComplete,
            pending.trimmingCharacters(in: .whitespacesAndNewlines).last.map({ ".!?。！？".contains($0) }) == true
        else { return nil }
        let text = pending
        emitted += text
        pending = ""
        return text
    }

    mutating func finish(_ final: String) -> String {
        defer { self = Self() }
        // Hermes may replace the final answer. A corrected answer must remain
        // audible; an unchanged streamed prefix must never be spoken twice.
        if final.hasPrefix(emitted) { return String(final.dropFirst(emitted.count)) }
        // Hermes' completed text can differ from the streamed deltas only in
        // whitespace (a trimmed leading newline, joined segments); speaking
        // the whole answer again then repeats what was already said.
        if let end = Self.endOfSpokenPrefix(emitted, in: final) { return String(final[end...]) }
        return final
    }

    /// Where `spoken` ends inside `final`, comparing everything but whitespace.
    static func endOfSpokenPrefix(_ spoken: String, in final: String) -> String.Index? {
        var remaining = spoken.filter { !$0.isWhitespace }[...]
        guard !remaining.isEmpty else { return nil }
        var index = final.startIndex
        while index < final.endIndex, let next = remaining.first {
            let character = final[index]
            index = final.index(after: index)
            if character.isWhitespace { continue }
            guard character == next else { return nil }
            remaining = remaining.dropFirst()
        }
        return remaining.isEmpty ? index : nil
    }
}
