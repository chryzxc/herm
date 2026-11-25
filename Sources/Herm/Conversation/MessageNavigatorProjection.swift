import Foundation

/// The full map is disposable. Canonical chat history stays in DockModel.
struct MessageNavigatorProjection {
    struct Key: Equatable, Sendable {
        let owner: String?
        let sessionID: String
        let revision: UInt64
    }

    struct Result: Sendable {
        let key: Key
        let snapshot: MessageNavigatorSnapshot
        let messageCount: Int
        let messagesRevision: UInt64
        let timelineRevision: UInt64
        let storedPrompts: [MessageNavigatorItem]
        let loadedRows: [MessageNavigator.RowKey: MessageNavigatorItem]
    }

    let key: Key
    let messages: [ChatMessage]
    let messagesRevision: UInt64
    let timeline: [TranscriptTimelineEntry]
    let timelineRevision: UInt64
    let seenRowIDs: Set<Int>?
    let changes: Set<Int>?
    let prepend: TranscriptHistoryPrepend?
    let previous: Result?

    func build() -> Result {
        let storedPrompts =
            previous?.timelineRevision == timelineRevision
            ? previous?.storedPrompts ?? [] : MessageNavigator.earlierPromptItems(timeline, sessionID: key.sessionID)
        var loadedRows = previous?.loadedRows ?? [:]
        let snapshot: MessageNavigatorSnapshot
        if let previous, let changes,
            let updated = MessageNavigator.updating(
                previous.snapshot, oldMessageCount: previous.messageCount, messages: messages,
                changed: changes, sessionID: key.sessionID)
        {
            snapshot = updated
        } else {
            var earlierItems: [MessageNavigatorItem] = []
            if let seenRowIDs {
                earlierItems.reserveCapacity(storedPrompts.count)
                for var item in storedPrompts {
                    guard let rowID = item.storedRowID, !seenRowIDs.contains(rowID) else { continue }
                    item.ordinal = earlierItems.count + 1
                    earlierItems.append(item)
                }
            }
            let items: [MessageNavigatorItem]
            if let previous, let prepend,
                prepend.isInsertion(
                    after: previous.messagesRevision, previousCount: previous.messageCount,
                    revision: messagesRevision, count: messages.count)
            {
                items = MessageNavigator.items(
                    prepending: messages.prefix(prepend.count),
                    to: previous.snapshot.items.suffix(previous.messageCount),
                    earlierItems: earlierItems, sessionID: key.sessionID, reusing: &loadedRows)
            } else {
                items = MessageNavigator.items(
                    messages: messages, earlierItems: earlierItems, sessionID: key.sessionID, reusing: &loadedRows)
            }
            if let previous, previous.snapshot.items == items {
                snapshot = previous.snapshot
            } else {
                snapshot = MessageNavigatorSnapshot(items: items)
            }
        }
        return .init(
            key: key, snapshot: snapshot, messageCount: messages.count, messagesRevision: messagesRevision,
            timelineRevision: timelineRevision, storedPrompts: storedPrompts, loadedRows: loadedRows)
    }
}
