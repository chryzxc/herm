import Foundation

enum PinnedSessionPresentationStatus: Equatable {
    case ready
    case empty
    case loading
    case stale(String)
    case unavailable(String)
    case failed(String)
}

/// The sidebar's Pinned section. Pins are Hermes' `sessions.pinned` flag; this
/// only prefers the live index row (working/unread state) when one exists.
struct PinnedSessionPresentation: Equatable {
    let sessions: [HermesSession]
    let status: PinnedSessionPresentationStatus

    init(
        pinned: [HermesSession],
        live: [HermesSession],
        projection: HermesProjectionState<[HermesSession]>,
        hasRequestedSessionIndex: Bool = true
    ) {
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        switch projection {
        case .ready, .empty, .stale:
            sessions = pinned.map { liveByID[$0.id] ?? $0 }
                .sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
        case .loading, .unavailable, .failed:
            sessions = []
        }
        switch projection {
        case .ready: status = .ready
        case .empty: status = !hasRequestedSessionIndex ? .loading : .empty
        case .loading: status = .loading
        case .stale(_, let message): status = .stale(message)
        case .unavailable(let message): status = .unavailable(message)
        case .failed(let message): status = .failed(message)
        }
    }

    var count: Int { sessions.count }
}

struct PinnedSessionRowControls {
    let select: () -> Void
    let togglePin: () -> Void
}

enum PinnedSessionRowInteraction {
    static func select(
        _ sessionID: String,
        selectedSessionID: inout String?
    ) {
        selectedSessionID = sessionID
    }
}
