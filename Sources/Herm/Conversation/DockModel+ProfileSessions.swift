import Foundation

/// One profile's conversation list as Herm last showed it. Rows came from
/// Hermes for that profile; they are shown on return only until the quiet
/// re-read that follows replaces them.
struct RetainedProfileSessions: Equatable {
    var sessions: [HermesSession]
    var pinnedSessions: [HermesSession]
    /// When the full history walk behind `sessions` finished, so a return
    /// inside the reuse window reads only the first page again.
    var historyLoadedAt: Date?
    /// The chat that was open when the profile was left, if any.
    var openSession: HermesSession?
}

extension DockModel {
    /// Keeps the outgoing profile's list and open chat. Only a list Hermes
    /// returned is kept; a loading or failed projection keeps nothing new.
    func retainCurrentProfileSessions() {
        guard !profileScopeUnavailable, let scope = Self.normalizedProfileID(profileScopeID) else { return }
        switch sessionProjectionState {
        case .ready, .empty, .stale: break
        case .loading, .unavailable, .failed: return
        }
        let historyLoadedAt = sessionHistoryLoadedAt.flatMap {
            Self.normalizedProfileID($0.profileID) == scope ? $0.date : nil
        }
        retainedProfileSessions[scope] = RetainedProfileSessions(
            sessions: sessions, pinnedSessions: pinnedSessions, historyLoadedAt: historyLoadedAt,
            openSession: openSessionToRetain(scope: scope))
    }

    /// The chat to reopen on return. Canonical Bot Chats resolve by title and
    /// other profiles' chats are owned elsewhere, so neither is kept.
    private func openSessionToRetain(scope: String) -> HermesSession? {
        guard activeBotProfileID == nil, let id = Self.normalizedProfileID(navigationSessionID),
            Self.normalizedProfileID(sessionProfileID ?? profileScopeID) == scope
        else { return nil }
        if let listed = (sessions + pinnedSessions).first(where: { $0.id == id }) { return listed }
        return HermesSession(
            id: id, profileID: scope, title: currentSessionTitle ?? "", preview: "", startedAt: nil,
            messageCount: 0, source: HermesFeatureIDs.sessionSource)
    }

    /// What to show the moment `profileID` becomes the scope: its retained
    /// list, else its rows from the all-profile scan that already loaded in
    /// the background. A profile absent from both loads normally.
    func profileSessionsToShow(for profileID: String) -> RetainedProfileSessions? {
        if let retained = retainedProfileSessions[profileID] { return retained }
        let scanned: [HermesSession]
        switch allBotSessionsState {
        case .ready(let rows), .stale(let rows, _): scanned = rows
        case .loading, .empty, .unavailable, .failed: return nil
        }
        let owned = Self.preloadedSessions(scanned, profileID: profileID)
        guard !owned.isEmpty else { return nil }
        return RetainedProfileSessions(
            sessions: owned, pinnedSessions: owned.filter(\.isPinned), historyLoadedAt: nil, openSession: nil)
    }

    static func preloadedSessions(_ scanned: [HermesSession], profileID: String) -> [HermesSession] {
        scanned.filter { normalizedProfileID($0.profileID) == profileID }
            .sorted(by: SidebarAgentGrouping.newestFirst)
    }

    /// Hermes deleted the session: drop it from its profile's retained copy
    /// and force a full walk on return.
    func forgetRetainedSession(_ sessionID: String, profileID: String?) {
        guard let key = Self.normalizedProfileID(profileID), var retained = retainedProfileSessions[key] else { return }
        retained.sessions.removeAll { $0.id == sessionID }
        retained.pinnedSessions.removeAll { $0.id == sessionID }
        if retained.openSession?.id == sessionID { retained.openSession = nil }
        retained.historyLoadedAt = nil
        retainedProfileSessions[key] = retained
    }

    /// Mirrors an acknowledged pin into another profile's retained list.
    func applyRetainedPin(_ pinned: Bool, to session: HermesSession, profileID: String?) {
        guard let key = Self.normalizedProfileID(profileID), var retained = retainedProfileSessions[key] else { return }
        retained.pinnedSessions.removeAll { $0.id == session.id }
        if pinned { retained.pinnedSessions.append(session.withPinned(true, profileID: key)) }
        retainedProfileSessions[key] = retained
    }

    /// A retained history read stays valid until the session it changed is re-read.
    func invalidateRetainedHistory(profileID: String?) {
        guard let key = Self.normalizedProfileID(profileID) else { return }
        retainedProfileSessions[key]?.historyLoadedAt = nil
    }
}
