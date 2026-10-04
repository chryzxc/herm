import Foundation

/// How voice mode reads approvals and clarify questions aloud, and how a
/// spoken reply maps back onto the answer Hermes expects.
enum VoicePrompts {
    static func approvalSpeech(title: String, detail: String, choices: [String]) -> String {
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenDetail = detail.count > 160 ? String(detail.prefix(160)) + "…" : detail
        let session = choices.contains(ApprovalChoice.session) ? " Say \"this session\" to allow it for the rest of the chat." : ""
        return "Approval needed. \(title). \(spokenDetail). Say yes to allow it, or no to deny it.\(session)"
    }

    static func clarificationSpeech(question: String, choices: [String], multiSelect: Bool, progress: String?) -> String {
        var parts = [progress.map { $0 + "." }, question].compactMap { $0 }
        if !choices.isEmpty {
            let options = choices.prefix(6).enumerated().map { "\($0.offset + 1): \($0.element)." }
            parts.append("Your options are " + options.joined(separator: " "))
            if multiSelect { parts.append("You can pick more than one.") }
        }
        return parts.joined(separator: " ")
    }

    static let approvalRetry = "Sorry, I didn't catch that. Say yes to allow it, or no to deny it."

    /// "always" is deliberately not voice-answerable: a misheard reply must not
    /// permanently allowlist a command. That choice stays on the card.
    static func approvalChoice(for spoken: String, choices: [String]) -> String? {
        let words = Set(tokens(spoken))
        let deny: Set = ["no", "nope", "nah", "deny", "don't", "don’t", "dont", "stop", "cancel", "reject", "decline", "never", "not"]
        let allow: Set = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "approve", "allow", "go", "proceed", "run", "fine", "continue", "do"]
        if !words.isDisjoint(with: deny) { return ApprovalChoice.deny }
        if words.contains("session"), choices.contains(ApprovalChoice.session) { return ApprovalChoice.session }
        if !words.isDisjoint(with: allow), choices.contains(ApprovalChoice.once) { return ApprovalChoice.once }
        return nil
    }

    /// Matches option text first, then "one"/"second"/"option 3"; anything else
    /// is a free-text answer, like typing into the clarify field.
    static func clarificationAnswer(for spoken: String, choices: [String], multiSelect: Bool) -> (answer: String, display: String) {
        let text = " " + tokens(spoken).joined(separator: " ") + " "
        var picked = choices.filter { choice in
            let normalized = tokens(choice).joined(separator: " ")
            return !normalized.isEmpty && text.contains(" \(normalized) ")
        }
        // Only short replies count numbers, so "I need two copies" stays free text.
        if (picked.isEmpty || multiSelect), tokens(spoken).count <= 4 {
            // "one" is usually a pronoun ("the second one") unless it's the only number.
            let words = tokens(spoken).filter { ordinals[$0] != nil }
            let counted = !multiSelect && words.contains { $0 != "one" } ? words.filter { $0 != "one" } : words
            let numbered = counted.compactMap { ordinals[$0] }.filter { $0 < choices.count }.map { choices[$0] }
            picked += numbered.filter { !picked.contains($0) }
        }
        if multiSelect {
            let selection = picked.isEmpty ? [spoken] : picked
            return (ClarifyQuestion.multiSelectAnswer(selection), selection.joined(separator: ", "))
        }
        // Several matches: the longest option is the most specific one heard.
        let answer = picked.max { $0.count < $1.count } ?? spoken
        return (answer, answer)
    }

    /// What follows "hey <name>" in a sleeping utterance: nil when the wake
    /// phrase was not said, empty when it was said on its own.
    static func afterWakePhrase(_ spoken: String, name: String) -> String? {
        let pattern = #"\b(hey|hi|hello|ok|okay)[\s,]+"# + NSRegularExpression.escapedPattern(for: name) + #"\b[\s,.!?]*"#
        guard let range = spoken.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(spoken[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether speech heard over a spoken reply is the user cutting in rather
    /// than the reply echoing back from the speakers.
    /// ponytail: word-overlap echo filter; use voice-processing AEC if speakers still trip it.
    static func isBargeIn(_ heard: String, over reply: String) -> Bool {
        let words = tokens(heard)
        let replyWords = Set(tokens(reply))
        let foreign = words.filter { !replyWords.contains($0) }
        let cutIns: Set = ["stop", "wait", "hold", "pause", "enough", "cancel", "quiet", "shut"]
        if foreign.contains(where: cutIns.contains) { return true }
        return words.count >= 3 && foreign.count * 2 > words.count
    }

    /// Mostly the reply's own words: the mic picked up the speakers.
    static func isEcho(_ heard: String, of reply: String) -> Bool {
        let words = tokens(heard)
        let replyWords = Set(tokens(reply))
        return !words.isEmpty && words.filter(replyWords.contains).count * 3 >= words.count * 2
    }

    private static let ordinals: [String: Int] = [
        "1": 0, "one": 0, "first": 0, "2": 1, "two": 1, "second": 1, "3": 2, "three": 2, "third": 2,
        "4": 3, "four": 3, "fourth": 3, "5": 4, "five": 4, "fifth": 4, "6": 5, "six": 5, "sixth": 5
    ]

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }
}
