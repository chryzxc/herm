import Foundation

struct ComposerFollowUp {
    struct Request: Equatable {
        let owner: SessionComposerDraft.Key
        let prompt: String
    }

    let request: Request
    let text: String

    static func prompt(in messages: [ChatMessage]) -> String? {
        let recent = messages.suffix(16).filter {
            $0.systemEvent == nil && $0.kanbanNotice == nil
                && ($0.hasBodyText || $0.isError || $0.hasImages || !$0.attachmentURLs.isEmpty)
        }.suffix(4)
        guard let latest = recent.last, latest.role == .hermes, latest.hasBodyText, !latest.isError,
            recent.contains(where: { $0.role == .user && $0.hasBodyText })
        else { return nil }

        return recent.compactMap { message in
            guard message.hasBodyText, !message.isError else { return nil }
            let role = message.role == .user ? "User" : "Assistant"
            let prefix = message.text.prefix(601)
            let excerpt =
                prefix.count > 600
                ? "\(prefix.prefix(350)) … \(message.text.suffix(250))" : String(prefix)
            return "\(role): \(excerpt)"
        }.joined(separator: "\n\n")
    }
}
