import Foundation

/// Replaces the recognizer's changing hypothesis, without duplicating words
/// or overwriting a draft the user edited while capture was running.
struct ComposerDictation {
    private(set) var owner: String?
    private var prefix = ""
    private var rendered = ""

    mutating func begin(owner: String, text: String) {
        self.owner = owner
        prefix = text
        rendered = text
    }

    mutating func update(_ transcript: String, text: String, owner: String) -> String? {
        guard self.owner == owner, text == rendered else { return nil }
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator =
            prefix.isEmpty || prefix.last?.isWhitespace == true || spoken.isEmpty ? "" : " "
        rendered = prefix + separator + spoken
        return rendered
    }

    func owns(_ text: String) -> Bool { owner != nil && text == rendered }
}
