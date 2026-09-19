import CoreGraphics
import Foundation

struct ConversationMessageJumpPlan: Equatable {
    let messageID: UUID
    let renderedLimit: Int
}

struct ConversationMessageJumpEffect: Equatable {
    let messageID: UUID
    let renderedLimit: Int
    let isAtBottom: Bool
    let unseenMessageCount: Int
}

enum ConversationMessageScrollAnchor: Equatable {
    case center
}

/// Bounded presentation window for the canonical transcript. Hermes remains
/// the owner of every message; this policy only limits how many exact SwiftUI
/// rows are mounted at once.
enum ConversationMessageWindow {
    // The active fallback renderer uses an exact SwiftUI stack, so keep its
    // default mounted page small. Older history is revealed in the same
    // bounded increment so a single tap cannot remount a huge transcript.
    static let initialLimit = 12
    static let pageSize = 12
    static let topLoadThreshold: CGFloat = 24
    static let topRearmDistance: CGFloat = 80

    /// Builds navigation metadata from the same canonical messages and
    /// session identity used by the mounted transcript window. Keeping this
    /// hook here prevents a navigator from accidentally indexing a different
    /// projection or retaining state across session replacement.
    static func navigatorItems(
        messages: [ChatMessage],
        sessionID: String,
        previewLimit: Int = MessageNavigator.defaultPreviewLimit
    ) -> [MessageNavigatorItem] {
        MessageNavigator.items(
            messages: messages,
            sessionID: sessionID,
            previewLimit: previewLimit
        )
    }

    static func visibleMessages<Element>(_ messages: [Element], limit: Int) -> ArraySlice<Element> {
        messages.suffix(max(initialLimit, limit))
    }

    static func revealedLimit(currentLimit: Int, totalCount: Int) -> Int {
        min(totalCount, max(initialLimit, currentLimit) + pageSize)
    }

    static func limitToReveal(messageOrdinal: Int, totalCount: Int, currentLimit: Int) -> Int {
        let safeTotal = max(0, totalCount)
        let safeOrdinal = max(0, messageOrdinal)
        // The mounted window is a suffix. An oldest-first ordinal therefore
        // needs the number of rows from that ordinal through the newest row.
        let requiredSuffixLimit = safeOrdinal > safeTotal
            ? safeTotal
            : safeTotal - safeOrdinal + 1
        return min(safeTotal, max(initialLimit, currentLimit, requiredSuffixLimit))
    }

    static func jumpPlan(
        for item: MessageNavigatorItem,
        sessionID: String,
        totalCount: Int,
        currentLimit: Int
    ) -> ConversationMessageJumpPlan? {
        guard item.sessionID == sessionID else { return nil }
        return ConversationMessageJumpPlan(
            messageID: item.messageID,
            renderedLimit: limitToReveal(
                messageOrdinal: item.ordinal,
                totalCount: totalCount,
                currentLimit: currentLimit
            )
        )
    }

    static func jumpEffect(
        for item: MessageNavigatorItem,
        sessionID: String,
        messages: [ChatMessage],
        currentLimit: Int
    ) -> ConversationMessageJumpEffect? {
        guard let plan = jumpPlan(
            for: item,
            sessionID: sessionID,
            totalCount: messages.count,
            currentLimit: currentLimit
        ) else { return nil }
        return ConversationMessageJumpEffect(
            messageID: plan.messageID,
            renderedLimit: plan.renderedLimit,
            isAtBottom: false,
            unseenMessageCount: 0
        )
    }

    static func transcriptSelectionHandler(
        sessionID: String,
        messages: [ChatMessage],
        currentLimit: @escaping () -> Int,
        onEffect: @escaping (ConversationMessageJumpEffect) -> Void,
        onScroll: @escaping (UUID, ConversationMessageScrollAnchor) -> Void
    ) -> (MessageNavigatorItem) -> Void {
        { item in
            guard let effect = jumpEffect(
                for: item,
                sessionID: sessionID,
                messages: messages,
                currentLimit: currentLimit()
            ) else { return }
            onEffect(effect)
            onScroll(effect.messageID, .center)
        }
    }

    /// A session owns no transcript presentation state. Never carry an
    /// expanded page from one session into another, where it would silently
    /// mount hundreds of rich rows before the reader requests them.
    static func limitForSessionReplacement() -> Int { initialLimit }

    static func shouldCompactAfterRepinning(
        wasAtBottom: Bool,
        isAtBottom: Bool,
        currentLimit: Int,
        totalCount: Int
    ) -> Bool {
        !wasAtBottom
            && isAtBottom
            && totalCount > initialLimit
            && currentLimit > initialLimit
    }

    static func compactedLimit(totalCount: Int) -> Int {
        min(totalCount, initialLimit)
    }

    static func limitAfterCountChange(
        currentLimit: Int,
        oldCount: Int,
        newCount: Int,
        isAtBottom: Bool
    ) -> Int {
        let normalizedLimit = max(initialLimit, currentLimit)
        guard newCount > oldCount, !isAtBottom else { return normalizedLimit }
        // Preserve the visible start index while the user reads above the
        // bottom; appended messages extend the window instead of evicting a
        // row from the top of their viewport.
        return normalizedLimit + (newCount - oldCount)
    }

    static func shouldLoadEarlier(
        topMinY: CGFloat,
        hiddenCount: Int,
        isArmed: Bool
    ) -> Bool {
        isArmed && hiddenCount > 0 && topMinY >= -topLoadThreshold
    }

    static func shouldRearmTopTrigger(topMinY: CGFloat) -> Bool {
        topMinY < -topRearmDistance
    }
}

/// The unread badge represents message presentations the reader can actually
/// see, never transport-only assistant placeholders or activity events.
enum ConversationUnreadMessagePolicy {
    static func rendersMessageBubble(_ message: ChatMessage, streamingID: UUID?) -> Bool {
        if message.id == streamingID { return true }
        if message.isSteering { return true }
        if !message.images.isEmpty { return true }
        return message.hasBodyText
    }

    static func renderedMessageCount(_ messages: [ChatMessage], streamingID: UUID?) -> Int {
        messages.count { rendersMessageBubble($0, streamingID: streamingID) }
    }
}

/// Live text gets progressively more expensive to line-wrap as it grows. Keep
/// early responses immediate, then lower the presentation cadence before a
/// long response can monopolize the main actor. This policy affects only the
/// disposable live tail; completed messages retain their full content.
enum ConversationStreamingPresentationPolicy {
    static func flushIntervalMilliseconds(textLength: Int) -> Int {
        switch textLength {
        case ..<2_048: 80
        case ..<8_192: 120
        case ..<24_576: 180
        default: 250
        }
    }

    /// Native/SwiftUI scrolling is substantially more expensive than changing
    /// the live text. A bounded cadence lets several flushes share one footer
    /// movement without visibly falling behind a streaming response.
    static let tailAdjustmentIntervalMilliseconds = 120
}
