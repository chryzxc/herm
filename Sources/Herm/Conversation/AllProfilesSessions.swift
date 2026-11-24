import Foundation

/// Pure projection behind the sidebar's "All profiles" scope. Recents come
/// from `SidebarAgentGrouping.merged`; this merges every profile's pins.
///
/// The selected profile's pins are authoritative (`DockModel.pinnedSessions`
/// is refreshed after every pin mutation), so its rows in the all-profile
/// scan are ignored once that list has been read. Other profiles' pins come
/// from the scan's `pinned` flag, backfilled with pins Herm already showed for
/// a profile the bounded scan no longer lists.
enum AllProfilesSessions {
    static let storageKey = "herm.sessions.showsAllProfiles"

    static func pinned(
        scopePinned: [HermesSession], scanned: [HermesSession], scopeProfileID: String?,
        retainedPins: [HermesSession] = [], awaitingScopedPins: Bool = false
    ) -> [HermesSession] {
        let scope = ProfileScopedID(profileID: scopeProfileID, resourceID: "").profileID
        var seen = Set<ProfileScopedID>()
        var rows: [HermesSession] = []
        let scannedKeys = Set(scanned.map(\.scopedID))
        for session in scopePinned {
            let key = ProfileScopedID(
                profileID: SidebarAgentGrouping.owner(session, scopeProfileID: scope), resourceID: session.id)
            if seen.insert(key).inserted { rows.append(session) }
        }
        for session in scanned where session.isPinned {
            let key = ProfileScopedID(profileID: session.profileID, resourceID: session.id)
            // The selected profile's own scan rows are only a preview until its read lands.
            guard awaitingScopedPins || key.profileID != scope, seen.insert(key).inserted else { continue }
            rows.append(session)
        }
        for session in retainedPins {
            let key = ProfileScopedID(
                profileID: SidebarAgentGrouping.owner(session, scopeProfileID: scope), resourceID: session.id)
            // An omission keeps the pin; a scan row settles it either way.
            guard key.profileID != scope, !scannedKeys.contains(key), seen.insert(key).inserted else { continue }
            rows.append(session)
        }
        return SidebarAgentGrouping.sortedNewestFirst(rows, tieBreakByID: true)
    }

    static func pinKey(_ session: HermesSession, scopeProfileID: String?) -> ProfileScopedID {
        ProfileScopedID(
            profileID: SidebarAgentGrouping.owner(session, scopeProfileID: scopeProfileID), resourceID: session.id)
    }

    /// Per-row pin state without rebuilding the merged list: the selected
    /// profile answers from its own pins, other profiles' rows are scan rows
    /// (see `SidebarAgentGrouping.merged`) carrying Hermes' `pinned` flag.
    static func isPinned(
        _ session: HermesSession, scopePinned: [HermesSession], scopeProfileID: String?
    ) -> Bool {
        let scope = ProfileScopedID(profileID: scopeProfileID, resourceID: "").profileID
        let owner = ProfileScopedID(
            profileID: SidebarAgentGrouping.owner(session, scopeProfileID: scope), resourceID: session.id)
        guard owner.profileID == scope else { return session.isPinned }
        return scopePinned.contains { $0.id == session.id }
    }

    /// The bot that owns a row in the combined list, for its profile pill.
    static func ownerBot(
        _ session: HermesSession, bots: [BotSummary], scopeProfileID: String?
    ) -> BotSummary? {
        guard let owner = SidebarAgentGrouping.owner(session, scopeProfileID: scopeProfileID) else { return nil }
        return bots.first { $0.id == owner }
    }
}
