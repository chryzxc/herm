import AppKit
import SwiftUI

/// Presentation state for actions that belong to one completed assistant message.
/// IDs, rather than row positions or text, keep refresh/TTS state isolated when
/// the transcript changes.
@MainActor
final class ConversationMessageActionState: ObservableObject {
    @Published private(set) var pendingMessageIDs: Set<UUID> = []
    @Published private(set) var copiedMessageID: UUID?

    func isPending(_ messageID: UUID) -> Bool { pendingMessageIDs.contains(messageID) }

    func copy(_ message: ChatMessage) {
        let text = Self.readableText(message.text)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        copiedMessageID = message.id
    }

    func run(_ messageID: UUID, operation: @escaping @MainActor () async -> Void) {
        guard pendingMessageIDs.insert(messageID).inserted else { return }
        Task { @MainActor [weak self] in
            await operation()
            self?.pendingMessageIDs.remove(messageID)
        }
    }

    static func readableText(_ markdown: String) -> String {
        var result = markdown
        result = result.replacingOccurrences(of: "```", with: "")
        result = result.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: #"(?m)(?<![A-Za-z0-9])_|_(?![A-Za-z0-9])"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
