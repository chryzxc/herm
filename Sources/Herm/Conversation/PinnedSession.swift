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
        hasRequestedSessionIndex: Bool = true,
        matchesProfile: Bool = false,
        scopeProfileID: String? = nil
    ) {
        switch projection {
        case .ready, .empty, .stale, .loading:
            if pinned.isEmpty {
                sessions = []
            } else {
                func key(_ session: HermesSession) -> ProfileScopedID {
                    matchesProfile
                        ? AllProfilesSessions.pinKey(session, scopeProfileID: scopeProfileID)
                        : ProfileScopedID(profileID: nil, resourceID: session.id)
                }
                let liveByKey = Dictionary(live.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
                sessions = pinned.map { pin in
                    let row = liveByKey[key(pin)] ?? pin
                    if matchesProfile, row.profileID == nil, let owner = key(pin).profileID {
                        return row.withPinned(row.isPinned, profileID: owner)
                    }
                    return row
                }.sorted {
                    ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast)
                }
            }
        case .unavailable, .failed:
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

    func selectedRow(_ selected: ProfileScopedID) -> HermesSession? {
        sessions.first { $0.scopedID == selected }
    }

    func withInitialRequestPending() -> Self {
        status == .empty ? Self(sessions: sessions, status: .loading) : self
    }

    private init(sessions: [HermesSession], status: PinnedSessionPresentationStatus) {
        self.sessions = sessions
        self.status = status
    }
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
