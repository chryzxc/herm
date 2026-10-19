import AppKit
import SwiftUI

/// Presentation state for actions that belong to one completed assistant message.
/// IDs, rather than row positions or text, keep refresh/TTS state isolated when
/// the transcript changes.
@MainActor
final class ConversationMessageActionState: ObservableObject {
    @Published private(set) var pendingActions: [UUID: ConversationMessageActionKind] = [:]
    @Published private(set) var copiedMessageID: UUID?

    func pendingAction(for messageID: UUID) -> ConversationMessageActionKind? {
        pendingActions[messageID]
    }

    func copy(_ message: ChatMessage) {
        let text = Self.readableText(GenerativeUIIntegration.readableText(message))
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }
        copiedMessageID = message.id
    }

    func run(
        _ messageID: UUID,
        action: ConversationMessageActionKind,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard pendingActions[messageID] == nil else { return }
        pendingActions[messageID] = action
        Task { @MainActor [weak self] in
            await operation()
            self?.pendingActions.removeValue(forKey: messageID)
        }
    }

    static func readableText(_ markdown: String) -> String {
        var result = markdown
        var codeSpans: [String] = []
        if let codeRegex = try? NSRegularExpression(pattern: #"(?s)`{1,3}(.*?)`{1,3}"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in codeRegex.matches(in: result, range: range).reversed() {
                guard let codeRange = Range(match.range(at: 1), in: result),
                      let fullRange = Range(match.range, in: result) else { continue }
                codeSpans.append(String(result[codeRange]))
                result.replaceSubrange(fullRange, with: "\u{001E}\(codeSpans.count - 1)\u{001F}")
            }
        }
        result = result.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: #"\*([^*\n]+)\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"_([^_\n]+)_"#, with: "$1", options: .regularExpression)
        for (index, code) in codeSpans.enumerated() {
            result = result.replacingOccurrences(of: "\u{001E}\(index)\u{001F}", with: code)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
