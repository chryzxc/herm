import Foundation

/// Pure projection behind the multi-bot sidebar. Sessions from the selected
/// bot's scoped list are fresher (live `isWorking` and unread flags) than the
/// all-profile scan, so they replace the scan's copy of the same row. A
/// scoped row without a profile belongs to the selected scope.
enum SidebarAgentGrouping {
    static func owner(_ session: HermesSession, scopeProfileID: String?) -> String? {
        session.profileID ?? scopeProfileID
    }

    static func merged(all: [HermesSession], scoped: [HermesSession], scopeProfileID: String?) -> [HermesSession] {
        var byKey: [ProfileScopedID: HermesSession] = [:]
        for session in all {
            byKey[ProfileScopedID(profileID: session.profileID, resourceID: session.id)] = session
        }
        for session in scoped {
            byKey[ProfileScopedID(profileID: owner(session, scopeProfileID: scopeProfileID), resourceID: session.id)] =
                session
        }
        return byKey.values.sorted(by: newestFirst)
    }

    static func newestFirst(_ lhs: HermesSession, _ rhs: HermesSession) -> Bool {
        let lhsDate = lhs.lastUpdatedAt ?? .distantPast
        let rhsDate = rhs.lastUpdatedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id < rhs.id
    }
}
