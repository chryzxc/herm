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

    func allProfilePins() -> [HermesSession] {
        AllProfilesSessions.pinned(
            scopePinned: awaitingScopedPinsAfterSwitch ? [] : pinnedSessions,
            scanned: Array(knownProfilePins.values), scopeProfileID: profileScopeID,
            awaitingScopedPins: awaitingScopedPinsAfterSwitch)
    }

    /// The scoped REST page contains the entire owner's pin set, even while
    /// older conversation pages are still in flight.
    func recordScopedPins(_ pins: [HermesSession], scope: String?) {
        guard let owner = Self.normalizedProfileID(scope) else { return }
        supersededPinScanByProfile[owner] = allBotSessionsTask
        var updated = knownProfilePins.filter { $0.key.profileID != owner }
        for row in pins {
            let key = AllProfilesSessions.pinKey(row, scopeProfileID: owner)
            guard key.profileID == owner else { continue }
            updated[key] = row.withPinned(true, profileID: owner)
        }
        if updated != knownProfilePins {
            knownProfilePins = updated
            sidebarPinChanges.send()
        }
    }

    /// Older scans cannot undo a scoped read or a mutation. A bounded scan
    /// updates only rows it actually reports; omissions carry no pin evidence.
    func reconcileScannedPins(_ rows: [HermesSession], from task: Task<Void, Never>? = nil) {
        var updated = knownProfilePins
        for row in rows {
            let key = row.scopedID
            if let task,
                supersededPinScanBySession[key] == task
                    || key.profileID.flatMap({ supersededPinScanByProfile[$0] }) == task
            {
                continue
            }

            updated[key] = row.isPinned ? row : nil
        }
        if updated != knownProfilePins {
            knownProfilePins = updated
            sidebarPinChanges.send()
        }
    }

    /// Hermes deleted the session: drop it from its profile's retained copy
    /// and force a full walk on return.
    func forgetRetainedSession(_ sessionID: String, profileID: String?) {
        guard let key = Self.normalizedProfileID(profileID) else { return }
        setKnownPin(nil, key: ProfileScopedID(profileID: key, resourceID: sessionID))
        guard var retained = retainedProfileSessions[key] else { return }
        retained.sessions.removeAll { $0.id == sessionID }
        let pinCount = retained.pinnedSessions.count
        let pinKey = ProfileScopedID(profileID: key, resourceID: sessionID)
        retained.pinnedSessions.removeAll { AllProfilesSessions.pinKey($0, scopeProfileID: key) == pinKey }
        if retained.openSession?.id == sessionID { retained.openSession = nil }
        retained.historyLoadedAt = nil
        retainedProfileSessions[key] = retained
        if retained.pinnedSessions.count != pinCount { sidebarPinChanges.send() }
    }

    /// Mirrors an acknowledged pin into another profile's retained list.
    func applyRetainedPin(_ pinned: Bool, to session: HermesSession, profileID: String?) {
        guard let key = Self.normalizedProfileID(profileID) else { return }
        let pinKey = ProfileScopedID(profileID: key, resourceID: session.id)
        let row = pinned ? session.withPinned(true, profileID: key) : nil
        setKnownPin(row, key: pinKey)
        guard var retained = retainedProfileSessions[key] else { return }
        retained.pinnedSessions.removeAll { AllProfilesSessions.pinKey($0, scopeProfileID: key) == pinKey }
        if let row { retained.pinnedSessions.append(row) }
        retainedProfileSessions[key] = retained
    }

    private func setKnownPin(_ pin: HermesSession?, key: ProfileScopedID) {
        supersededPinScanBySession[key] = allBotSessionsTask
        guard knownProfilePins[key] != pin else { return }
        knownProfilePins[key] = pin
        sidebarPinChanges.send()
    }

    func renameKnownPin(_ session: HermesSession, title: String, profileID: String?) {
        let key = ProfileScopedID(profileID: profileID, resourceID: session.id)
        guard let pin = knownProfilePins[key] else { return }
        let renamed = HermesSession(
            id: pin.id, profileID: pin.profileID, title: title, preview: pin.preview, startedAt: pin.startedAt,
            updatedAt: pin.updatedAt, messageCount: pin.messageCount, source: pin.source, isHidden: pin.isHidden,
            isWorking: pin.isWorking, hasUnreadUpdate: pin.hasUnreadUpdate, isPinned: true, modelName: pin.modelName)
        setKnownPin(renamed, key: key)
    }

    func isAllProfileSessionPinned(_ session: HermesSession) -> Bool {
        let key = AllProfilesSessions.pinKey(session, scopeProfileID: profileScopeID)
        if key.profileID == Self.normalizedProfileID(profileScopeID), !awaitingScopedPinsAfterSwitch {
            return pinnedSessions.contains { AllProfilesSessions.pinKey($0, scopeProfileID: profileScopeID) == key }
        }
        return knownProfilePins[key] != nil
    }

    /// A retained history read stays valid until the session it changed is re-read.
    func invalidateRetainedHistory(profileID: String?) {
        guard let key = Self.normalizedProfileID(profileID) else { return }
        retainedProfileSessions[key]?.historyLoadedAt = nil
    }
}
