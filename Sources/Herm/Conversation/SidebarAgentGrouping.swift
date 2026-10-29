import Foundation

/// How the chat sidebar lists conversations. A local display preference only.
enum SidebarGrouping: String, CaseIterable, Identifiable {
    /// One row per bot that expands into its running, unread, and recent chats.
    case agent
    /// Every bot's chats in one list, newest first.
    case session

    static let preferenceKey = "herm.chats.sidebarGrouping"

    var id: String { rawValue }
    var title: String { self == .agent ? "Agent" : "Session" }
}

/// Pure projection behind the multi-bot sidebar. Sessions from the selected
/// bot's scoped list are fresher (live `isWorking` and unread flags) than the
/// all-profile scan, so they replace the scan's copy of the same row. A
/// scoped row without a profile belongs to the selected scope.
enum SidebarAgentGrouping {
    struct Group: Equatable, Identifiable {
        let profileID: String
        /// Newest first.
        let sessions: [HermesSession]
        var id: String { profileID }
    }

    /// Recent chats shown under an expanded bot before "Show all".
    static let recentLimit = 3

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

    /// One group per bot, most recently active first. Bots without loaded
    /// chats keep roster order after them so refreshes do not reshuffle.
    static func groups(_ sessions: [HermesSession], botIDs: [String], scopeProfileID: String?) -> [Group] {
        let byProfile = Dictionary(grouping: sessions) { owner($0, scopeProfileID: scopeProfileID) ?? "" }
        return botIDs.enumerated()
            .map { offset, id in
                (offset, Group(profileID: id, sessions: (byProfile[id] ?? []).sorted(by: newestFirst)))
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.1.sessions.first?.lastUpdatedAt ?? .distantPast
                let rhsDate = rhs.1.sessions.first?.lastUpdatedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.0 < rhs.0
            }
            .map(\.1)
    }

    /// Sub-rows for an expanded bot: the newest few plus every chat that
    /// still needs attention, in recency order.
    static func visibleSessions(
        _ sessions: [HermesSession], showsAll: Bool, keeps: (HermesSession) -> Bool
    ) -> [HermesSession] {
        guard !showsAll else { return sessions }
        return sessions.enumerated()
            .filter { $0.offset < recentLimit || keeps($0.element) }
            .map(\.element)
    }

    static func newestFirst(_ lhs: HermesSession, _ rhs: HermesSession) -> Bool {
        let lhsDate = lhs.lastUpdatedAt ?? .distantPast
        let rhsDate = rhs.lastUpdatedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id < rhs.id
    }
}
