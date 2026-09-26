import Foundation

/// Pure text rules for the composer’s Bot mention picker.
enum ComposerMentionPresentation {
    struct DirectBotRequest: Equatable {
        let profileID: String
        let text: String
    }

    /// A complete, single leading roster mention may be safely delivered as a
    /// direct user request to that Bot's canonical Bot Chat. This deliberately
    /// does not guess from roles, skills, prose, or partial/embedded mentions.
    static func directBotRequest(in text: String, profileIDs: [String]) -> DirectBotRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWhitespace = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let firstToken = String(trimmed[..<firstWhitespace])
        let requestText = String(trimmed[firstWhitespace...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstToken.hasPrefix("@"), !requestText.isEmpty else { return nil }

        let handle = String(firstToken.dropFirst())
        guard let profileID = profileIDs.first(where: { $0.caseInsensitiveCompare(handle) == .orderedSame }) else {
            return nil
        }

        let rosterHandles = Set(profileIDs.map { "@\($0.lowercased())" })
        let hasAdditionalRosterMention = requestText
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }
            .contains(where: rosterHandles.contains)
        guard !hasAdditionalRosterMention else { return nil }

        return DirectBotRequest(profileID: profileID, text: requestText)
    }

    /// Direct Bot relay currently accepts text only. Attachments must remain
    /// on the ordinary session submission path until Hermes exposes a Bot
    /// attachment contract.
    static func canDirectRouteBot(hasImages: Bool, hasPDF: Bool) -> Bool {
        !hasImages && !hasPDF
    }

    static func activeToken(in text: String) -> String? {
        guard let start = text.lastIndex(where: { $0.isWhitespace }) else {
            return text.hasPrefix("@") ? text : nil
        }
        let tokenStart = text.index(after: start)
        let token = String(text[tokenStart...])
        return token.hasPrefix("@") ? token : nil
    }

    static func replacingActiveToken(in text: String, with profileID: String) -> String {
        guard activeToken(in: text) != nil, let tokenStart = text.lastIndex(of: "@") else {
            return text
        }
        return String(text[..<tokenStart]) + "@\(profileID) "
    }
}

/// from DockModel so every keystroke re-renders only the composer view instead
/// of the whole popover (conversation, sidebar, and context panel observe
/// DockModel and would otherwise re-diff on each character).
@MainActor
final class ComposerText: ObservableObject {
    @Published var text = "" {
        didSet {
            guard !isUpdatingFromHistory else { return }
            historyIndex = nil
            restoreDraft = ""
        }
    }

    /// The `/`/`@` popover owns Up/Down while it is showing rows.
    var isCompletionOpen = false
    /// UTF-16 caret the editor applies after a completion rewrites the text.
    var pendingCaret: Int?
    private var historyIndex: Int?
    private var restoreDraft = ""
    private var isUpdatingFromHistory = false

    /// Clears draft-local state when the active conversation changes so
    /// history, text, and temporary image files cannot cross session boundaries.
    func reset() {
        isUpdatingFromHistory = true
        text = ""
        isUpdatingFromHistory = false
        historyIndex = nil
        restoreDraft = ""
    }

    /// Moves through the user prompts already present in the active session.
    /// Down past the newest prompt restores the draft that was present before
    /// history navigation began.
    func navigate(direction: Int, history: [String]) -> Bool {
        guard !history.isEmpty, direction != 0 else { return false }
        if let index = historyIndex, index >= history.count {
            historyIndex = nil
            restoreDraft = text
        }

        let nextIndex: Int?
        if direction < 0 {
            if let index = historyIndex {
                nextIndex = max(0, index - 1)
            } else {
                restoreDraft = text
                nextIndex = history.count - 1
            }
        } else {
            guard let index = historyIndex else { return false }
            if index + 1 < history.count {
                nextIndex = index + 1
            } else {
                setTextPreservingHistorySlot(restoreDraft)
                historyIndex = nil
                restoreDraft = ""
                return true
            }
        }

        guard let nextIndex else { return false }
        historyIndex = nextIndex
        setTextPreservingHistorySlot(history[nextIndex])
        return true
    }

    private func setTextPreservingHistorySlot(_ value: String) {
        isUpdatingFromHistory = true
        text = value
        isUpdatingFromHistory = false
    }
}
