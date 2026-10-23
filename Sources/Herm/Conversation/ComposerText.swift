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
        let hasAdditionalRosterMention =
            requestText
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }
            .contains(where: rosterHandles.contains)
        guard !hasAdditionalRosterMention else { return nil }

        return DirectBotRequest(profileID: profileID, text: requestText)
    }

    /// The composer's relay route: a leading mention sends the rest of the
    /// text; otherwise a message naming exactly one roster Bot anywhere goes
    /// to that Bot whole, so its reply lands in this session. Several Bots
    /// stay with the session agent.
    static func botRelayRequest(in text: String, profileIDs: [String]) -> DirectBotRequest? {
        if let leading = directBotRequest(in: text, profileIDs: profileIDs) { return leading }
        let mentioned = mentionedProfiles(in: text, profileIDs: profileIDs)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mentioned.count == 1,
            trimmed.split(whereSeparator: \.isWhitespace).contains(where: { !$0.hasPrefix("@") })
        else { return nil }
        return DirectBotRequest(profileID: mentioned[0], text: trimmed)
    }

    /// Why a Bot picked into `draft` would not be reached, shown in the `@`
    /// popover. Herm's relay is text-only and takes one Bot; anything else
    /// goes to the session agent, which has `message_agent` only in a Bot Chat.
    static func relayNotice(
        draft: String, profileIDs: [String], hasAttachments: Bool,
        isQueued: Bool, inBotChat: Bool
    ) -> String? {
        guard !inBotChat else { return nil }
        if hasAttachments {
            return "Bots get text only. Remove attachments and context to send this to a Bot."
        }
        if isQueued {
            return "A queued prompt is pending. Send to a Bot once it finishes."
        }
        let typed = activeToken(in: draft).map { String(draft.dropLast($0.count)) } ?? draft
        if !mentionedProfiles(in: typed, profileIDs: profileIDs).isEmpty {
            return "One Bot per message. Mentioning two only works in a Bot Chat."
        }
        return nil
    }

    /// Roster profiles mentioned in `text`, in first-mention order.
    static func mentionedProfiles(in text: String, profileIDs: [String]) -> [String] {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"(?:^|\s)@([a-z0-9][a-z0-9_-]*)(?![a-z0-9_@/:-])"#, options: .caseInsensitive)
        else { return [] }
        let source = text as NSString
        var resolved: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let handle = source.substring(with: match.range(at: 1))
            guard let profile = profileIDs.first(where: { $0.caseInsensitiveCompare(handle) == .orderedSame }),
                !resolved.contains(profile)
            else { continue }
            resolved.append(profile)
        }
        return resolved
    }

    /// Direct Bot relay currently accepts text only. Attachments must remain
    /// on the ordinary session submission path until Hermes exposes a Bot
    /// attachment contract.
    static func canDirectRouteBot(hasImages: Bool, hasPDF: Bool) -> Bool {
        !hasImages && !hasPDF
    }

    /// Mirrors Hermes Desktop's identification-only mention middleware.
    /// Delivery belongs to the session agent's message_agent tool.
    static func annotatedPrompt(_ text: String, profileIDs: [String]) -> String {
        let resolved = mentionedProfiles(in: text, profileIDs: profileIDs)
        guard !resolved.isEmpty else { return text }
        let identities = resolved.map {
            "@\($0) = agent profile \"\($0)\" (message_agent target: \"\($0 == "default" ? "hermes" : $0)\")"
        }.joined(separator: "; ")
        return text + "\n\n[@mentions resolved from the Bot Mode roster — the user is referring to: " + identities
            + ". If they want one of these agents contacted, compose your own message and send it with your message_agent tool; never forward the user's text verbatim. If this session has no message_agent tool, agent messaging is unavailable here — say so.]"
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
    /// True while the text is an unedited recalled prompt.
    var isBrowsingHistory: Bool { historyIndex != nil }
    private var restoreDraft = ""
    private var isUpdatingFromHistory = false

    /// Replaces a conversation's editor state with one final text publication.
    func reset(to text: String = "") {
        isUpdatingFromHistory = true
        if self.text != text { self.text = text }
        isUpdatingFromHistory = false
        historyIndex = nil
        restoreDraft = ""
        pendingCaret = nil
        isCompletionOpen = false
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
