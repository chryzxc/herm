import CoreGraphics
import Foundation

struct ConversationMessageJumpPlan: Equatable {
    let messageID: UUID
    let windowRange: Range<Int>
}

struct ConversationMessageJumpEffect: Equatable {
    let messageID: UUID
    let windowRange: Range<Int>
    let isAtBottom: Bool
    let unseenMessageCount: Int
}

enum ConversationMessageScrollAnchor: Equatable {
    case center
}

/// Bounded presentation window for the canonical transcript. Hermes remains
/// the owner of every message; this policy only limits how many exact SwiftUI
/// rows are mounted at once.
///
/// The window is a plain clamped `Range<Int>` over the canonical messages. It
/// slides in bounded `pageSize` increments from either edge, so no interaction
/// sequence — a navigator jump or any number of load-more taps — can grow the
/// mounted transcript without bound. "Live tail" is derived, never stored:
/// `range.upperBound == totalCount`.
enum ConversationMessageWindow {
    // The active fallback renderer uses an exact SwiftUI stack, so keep its
    // default mounted page small. History is revealed in the same bounded
    // increment from either edge of the window.
    static let initialLimit = 12
    static let pageSize = 4
    /// Context mounted above and below a jump target.
    static let jumpContextAbove = 12
    static let jumpContextBelow = 12
    /// Hard backstop for the mounted row count under any reveal sequence.
    static let maxMountedRowCount = 36

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

    /// The newest `limit` messages. Session presentation always starts here.
    static func tailRange(totalCount: Int, limit: Int = initialLimit) -> Range<Int> {
        let safeTotal = max(0, totalCount)
        let start = max(0, safeTotal - max(1, limit))
        return start..<safeTotal
    }

    /// Clamps a stored window against the current transcript size. Every
    /// projection flows through this, so a momentarily stale range (a
    /// same-session refresh shrinking the transcript) can never index out of
    /// bounds. An empty stored range passes through untouched; callers treat
    /// it as "follow the tail".
    static func visibleRange(_ range: Range<Int>, totalCount: Int) -> Range<Int> {
        let safeTotal = max(0, totalCount)
        guard safeTotal > 0 else { return 0..<0 }
        guard !range.isEmpty else { return range }
        let lower = min(max(0, range.lowerBound), safeTotal - 1)
        let upper = min(max(range.upperBound, lower + 1), safeTotal)
        return lower..<upper
    }

    /// A bounded window centered on a jump target: up to `jumpContextAbove`
    /// rows above, the target, and up to `jumpContextBelow` rows below —
    /// regardless of how far the target sits from either transcript edge.
    static func jumpWindow(aroundIndex index: Int, totalCount: Int) -> Range<Int> {
        let safeTotal = max(0, totalCount)
        guard safeTotal > 0 else { return 0..<0 }
        let clampedIndex = min(max(0, index), safeTotal - 1)
        let lower = max(0, clampedIndex - jumpContextAbove)
        let upper = min(safeTotal, clampedIndex + 1 + jumpContextBelow)
        return lower..<max(upper, lower + 1)
    }

    /// Reveals one page of earlier history. The far edge retreats so repeated
    /// reveals slide the window instead of accumulating rows: one page beyond
    /// the last row the reader can see, never the visible rows themselves,
    /// and never past `maxMountedRowCount` unless protecting visibility
    /// demands more (a viewport wider than the backstop).
    static func revealEarlier(
        _ range: Range<Int>,
        totalCount: Int,
        visibleSpan: ClosedRange<Int>?
    ) -> Range<Int> {
        let bounds = visibleRange(range, totalCount: totalCount)
        guard bounds.lowerBound > 0 else { return bounds }
        let newLower = max(0, bounds.lowerBound - pageSize)
        let visibleFloor = visibleSpan.map { min($0.upperBound + 1, max(0, totalCount)) }
        if let visibleFloor {
            let marginUpper = max(visibleFloor + pageSize, newLower + 1)
            let backstop = max(newLower + maxMountedRowCount, visibleFloor)
            return newLower..<max(min(bounds.upperBound, marginUpper, backstop), newLower + 1)
        }
        let backstop = newLower + maxMountedRowCount
        return newLower..<max(min(bounds.upperBound, backstop), newLower + 1)
    }

    /// Reveals one page of later history with the symmetric sliding policy.
    /// The window is already open to the newest message when
    /// `upperBound == totalCount`, so this is a no-op there.
    static func revealLater(
        _ range: Range<Int>,
        totalCount: Int,
        visibleSpan: ClosedRange<Int>?
    ) -> Range<Int> {
        let bounds = visibleRange(range, totalCount: totalCount)
        let safeTotal = max(0, totalCount)
        guard !bounds.isEmpty, bounds.upperBound < safeTotal else { return bounds }
        let newUpper = min(bounds.upperBound + pageSize, safeTotal)
        let visibleCeiling = visibleSpan.map { max($0.lowerBound, 0) }
        var newLower = bounds.lowerBound
        if let visibleCeiling {
            newLower = max(newLower, min(max(visibleCeiling - pageSize, 0), newUpper - 1))
        }
        newLower = max(newLower, newUpper - maxMountedRowCount)
        if let visibleCeiling {
            newLower = min(newLower, visibleCeiling)
        }
        return max(newLower, 0)..<newUpper
    }

    /// True only when the window is open to the very newest message. Reading
    /// anywhere else is "not at bottom" even when the mounted window is
    /// shorter than the viewport — streaming-scroll guards, unread counting,
    /// and compaction all key off this.
    static func isLiveTail(_ range: Range<Int>, totalCount: Int) -> Bool {
        visibleRange(range, totalCount: totalCount).upperBound == max(0, totalCount)
    }

    /// Appended messages only shift indices upward at the tail. While the
    /// reader sits on the live tail, the window slides forward preserving its
    /// mounted count (today's same-limit suffix behavior). While they read
    /// above the bottom, the window freezes: new rows mount on return to the
    /// bottom, and the unread badge covers awareness in the meantime.
    static func rangeAfterCountChange(
        _ range: Range<Int>,
        oldCount: Int,
        newCount: Int,
        isAtBottom: Bool
    ) -> Range<Int> {
        let bounds = visibleRange(range, totalCount: oldCount)
        guard newCount > oldCount else { return bounds }
        guard isAtBottom, bounds.upperBound == oldCount else { return bounds }
        guard !bounds.isEmpty else { return tailRange(totalCount: newCount) }
        // A short transcript grows its window up to the initial limit, then
        // slides. Pinning the start at 0 here would mount every message of a
        // conversation that began short, however long it becomes.
        let start = max(0, newCount - max(bounds.count, initialLimit))
        return start..<newCount
    }

    /// Only a widened live tail compacts on repinning to the bottom. A
    /// non-tail window is history browsing; it never auto-compacts, because
    /// the geometry of a short window must not evict the jump target.
    static func shouldCompactAfterRepinning(
        wasAtBottom: Bool,
        isAtBottom: Bool,
        range: Range<Int>,
        totalCount: Int
    ) -> Bool {
        guard !wasAtBottom, isAtBottom else { return false }
        guard max(0, totalCount) > initialLimit else { return false }
        return isLiveTail(range, totalCount: totalCount)
            && visibleRange(range, totalCount: totalCount).count > initialLimit
    }

    static func compactedRange(totalCount: Int) -> Range<Int> {
        tailRange(totalCount: totalCount, limit: initialLimit)
    }

    /// A session owns no transcript presentation state. Never carry an
    /// expanded window from one session into another, where it would silently
    /// mount hundreds of rich rows before the reader requests them.
    static func rangeForSessionReplacement(totalCount: Int) -> Range<Int> {
        tailRange(totalCount: totalCount, limit: initialLimit)
    }

    static func jumpPlan(
        for item: MessageNavigatorItem,
        sessionID: String,
        messages: [ChatMessage]
    ) -> ConversationMessageJumpPlan? {
        guard item.sessionID == sessionID else { return nil }
        // Ordinals also count stored prompts that are not loaded, so locate
        // the message itself. A prompt that is still unloaded has no row.
        guard let index = messages.firstIndex(where: { $0.id == item.messageID }) else { return nil }
        return ConversationMessageJumpPlan(
            messageID: item.messageID,
            windowRange: jumpWindow(aroundIndex: index, totalCount: messages.count)
        )
    }

    static func jumpEffect(
        for item: MessageNavigatorItem,
        sessionID: String,
        messages: [ChatMessage]
    ) -> ConversationMessageJumpEffect? {
        guard let plan = jumpPlan(
            for: item,
            sessionID: sessionID,
            messages: messages
        ) else { return nil }
        return ConversationMessageJumpEffect(
            messageID: plan.messageID,
            windowRange: plan.windowRange,
            isAtBottom: false,
            unseenMessageCount: 0
        )
    }

    static func transcriptSelectionHandler(
        sessionID: String,
        messages: [ChatMessage],
        onEffect: @escaping (ConversationMessageJumpEffect) -> Void,
        onScroll: @escaping (UUID, ConversationMessageScrollAnchor) -> Void
    ) -> (MessageNavigatorItem) -> Void {
        { item in
            guard let effect = jumpEffect(
                for: item,
                sessionID: sessionID,
                messages: messages
            ) else { return }
            onEffect(effect)
            onScroll(effect.messageID, .center)
        }
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
}
