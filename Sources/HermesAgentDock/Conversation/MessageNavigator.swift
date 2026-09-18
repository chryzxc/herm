import Foundation

/// Stable identity for a transcript location. The session component prevents a
/// delayed viewport or selection update from targeting a similarly identified
/// message after the user changes sessions.
struct MessageNavigatorTarget: Hashable, Identifiable {
    let sessionID: String
    let messageID: UUID

    var id: String { "\(sessionID):\(messageID.uuidString)" }
}

struct MessageNavigatorItem: Equatable, Identifiable {
    let target: MessageNavigatorTarget
    let ordinal: Int
    let roleLabel: String
    let preview: String
    let contentRevision: Int
    let hasImages: Bool

    var id: MessageNavigatorTarget { target }
    var messageID: UUID { target.messageID }
    var sessionID: String { target.sessionID }
}

enum MessageNavigator {
    static let defaultPreviewLimit = 160
    static let minimumPreviewLimit = 2

    static func items(
        messages: [ChatMessage],
        sessionID: String,
        previewLimit: Int = defaultPreviewLimit
    ) -> [MessageNavigatorItem] {
        let limit = max(minimumPreviewLimit, previewLimit)
        return messages.enumerated().map { index, message in
            MessageNavigatorItem(
                target: MessageNavigatorTarget(sessionID: sessionID, messageID: message.id),
                ordinal: index + 1,
                roleLabel: message.role == .user ? "You" : "Hermes",
                preview: boundedPreview(message.text, limit: limit),
                contentRevision: message.contentRevision,
                hasImages: !message.images.isEmpty
            )
        }
    }

    static func search(
        items: [MessageNavigatorItem],
        query: String
    ) -> [MessageNavigatorItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return items }
        let foldedQuery = normalizedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return items.filter { item in
            item.preview.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(foldedQuery)
                || item.roleLabel.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(foldedQuery)
        }
    }

    static func target(
        for messageID: UUID,
        sessionID: String,
        visibleIn visibleTargets: [MessageNavigatorTarget]? = nil
    ) -> MessageNavigatorTarget? {
        let target = MessageNavigatorTarget(sessionID: sessionID, messageID: messageID)
        guard let visibleTargets else { return target }
        return visibleTargets.contains(target) ? target : nil
    }

    /// Prefer the requested target, but reject stale targets from another
    /// session. Returning nil gives the caller an honest no-op for stale view
    /// geometry instead of scrolling a newly selected session.
    static func nearestVisibleTarget(
        to requestedTarget: MessageNavigatorTarget,
        visibleTargets: [MessageNavigatorTarget]
    ) -> MessageNavigatorTarget? {
        guard visibleTargets.contains(requestedTarget) else { return nil }
        return requestedTarget
    }

    static func boundedPreview(_ text: String, limit: Int = defaultPreviewLimit) -> String {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeLimit = max(minimumPreviewLimit, limit)
        guard normalized.count > safeLimit else { return normalized }
        return String(normalized.prefix(safeLimit - 1)) + "…"
    }
}
