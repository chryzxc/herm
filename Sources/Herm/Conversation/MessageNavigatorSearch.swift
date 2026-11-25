import Foundation

struct NavigatorHistorySearchKey: Equatable {
    let generation: Int
    let storageSessionID: String
    let resolvedSessionID: String?
    let offset: Int

    init(generation: Int, cursor: TranscriptHistoryCursor) {
        self.generation = generation
        storageSessionID = cursor.storageSessionID
        resolvedSessionID = cursor.readOnlyResolvedSessionID
        offset = cursor.nextOffset
    }
}

struct NavigatorStoredSearchIndex: Sendable {
    let pages: [MessageNavigator.StoredSearchProjection]
    let tail: TranscriptHistoryCursor
}

struct MessageNavigatorSearchRequest: Equatable, Sendable {
    let snapshot: MessageNavigatorSnapshot
    let sessionID: String
    let query: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot === rhs.snapshot && lhs.sessionID == rhs.sessionID && lhs.query == rhs.query
    }
}

/// Results and queued Return belong to the exact query and immutable history projection.
struct MessageNavigatorSearchState {
    private var completed: MessageNavigatorSearchRequest?
    private var partial: MessageNavigatorSearchRequest?
    private var matches: [MessageNavigatorItem] = []
    private var pendingSelection: MessageNavigatorSearchRequest?

    func isComplete(for request: MessageNavigatorSearchRequest?) -> Bool {
        request != nil && completed == request
    }

    func results(for request: MessageNavigatorSearchRequest?) -> [MessageNavigatorItem] {
        request != nil && (completed == request || partial == request) ? matches : []
    }

    mutating func showLoaded(
        _ results: [MessageNavigatorItem], for request: MessageNavigatorSearchRequest,
        current: MessageNavigatorSearchRequest?
    ) {
        guard current == request, !isComplete(for: request) else { return }
        completed = nil
        partial = request
        matches = results
    }

    mutating func submit(_ request: MessageNavigatorSearchRequest) -> MessageNavigatorItem? {
        guard !isComplete(for: request) else { return matches.first }
        pendingSelection = request
        return nil
    }

    mutating func invalidateSelection(for request: MessageNavigatorSearchRequest?) {
        if pendingSelection != request { pendingSelection = nil }
    }

    mutating func complete(
        _ results: [MessageNavigatorItem], for request: MessageNavigatorSearchRequest,
        current: MessageNavigatorSearchRequest?
    ) -> MessageNavigatorItem? {
        guard current == request else { return nil }
        completed = request
        partial = nil
        matches = results
        guard pendingSelection == request else { return nil }
        pendingSelection = nil
        return results.first
    }
}
