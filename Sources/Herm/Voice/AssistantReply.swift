import Foundation

/// A single spoken decision. Its continuation lives only for the active call.
struct AssistantReply {
    typealias FollowUp = @MainActor (String) async throws -> AssistantReply
    let text: String
    let requiresReadback: Bool
    let visual: String?
    var followUp: FollowUp?

    init(_ text: String, requiresReadback: Bool = false, visual: String? = nil, followUp: FollowUp? = nil) {
        self.text = text
        self.requiresReadback = requiresReadback
        self.visual = visual
        self.followUp = followUp
    }

    @MainActor static func confirm(
        _ question: String, phrase: String = "confirm", requiresReadback: Bool = false,
        action: @escaping @MainActor () async throws -> String
    ) -> Self {
        Self(question + " Say “\(phrase)” to proceed, or “cancel”.", requiresReadback: requiresReadback) { spoken in
            switch AssistantIntent.normalized(spoken).trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) {
            case "cancel", "no", "discard": return Self("Cancelled.")
            case phrase:
                try Task.checkCancellation()
                return Self(try await action())
            default: return confirm(question, phrase: phrase, requiresReadback: requiresReadback, action: action)
            }
        }
    }

    @MainActor static func choose<Value>(
        _ question: String, choices: [(String, Value)],
        selected: @escaping @MainActor (Value) async throws -> AssistantReply
    ) -> Self {
        let offered = Array(choices.prefix(6))
        let spokenChoices = offered.enumerated().map { "\($0.offset + 1). \($0.element.0)" }.joined(separator: ". ")
        return Self(question + " " + spokenChoices) { spoken in
            let term = AssistantIntent.normalized(spoken).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            if term == "cancel" || term == "no" { return Self("Cancelled.") }
            let number = AssistantIntent.number(term.replacingOccurrences(of: "option ", with: ""))
            if let number,
                let index = offered.indices.first(where: { number == Decimal($0 + 1) })
            {
                return try await selected(offered[index].1)
            }
            let matching = offered.filter { AssistantIntent.normalized($0.0) == term }
            if matching.count == 1 { return try await selected(matching[0].1) }
            return choose(question, choices: offered, selected: selected)
        }
    }
}
