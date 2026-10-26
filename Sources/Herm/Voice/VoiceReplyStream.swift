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
        guard pending.utf8.count <= 4_096,
            !pending.contains("`"), !pending.contains("<"), !pending.contains("{"),
            !pending.contains("~~~"), !pending.contains("[")
        else {
            defersUntilComplete = true
            pending = ""
            return nil
        }
        let buffered = pending
        var boundary: String.Index?
        buffered.enumerateSubstrings(in: buffered.startIndex..., options: .bySentences) { _, range, _, _ in
            let sentence = buffered[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if range.upperBound < buffered.endIndex,
                sentence.last.map({ ".!?。！？".contains($0) }) == true
            {
                boundary = range.upperBound
            }
        }
        guard let boundary else { return nil }
        let text = String(pending[..<boundary])
        emitted += text
        pending = String(pending[boundary...])
        return text
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
        return final
    }
}
