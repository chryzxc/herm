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
        return sortedNewestFirst(byKey.values, tieBreakByID: true)
    }

    /// The bot that owns `session`: the bot whose profile it ran under. A row with no profile
    /// (and no selected scope) or the "default" profile belongs to the default bot.
    static func ownerBot(_ session: HermesSession, scopeProfileID: String?, bots: [BotSummary]) -> BotSummary? {
        ownerBot(profileID: session.profileID, scopeProfileID: scopeProfileID, bots: bots)
    }

    static func ownerBot(profileID: String?, scopeProfileID: String?, bots: [BotSummary]) -> BotSummary? {
        let owner = profileID ?? scopeProfileID
        if let owner, let bot = bots.first(where: { $0.id == owner }) { return bot }
        guard owner == nil || owner?.lowercased() == "default" else { return nil }
        return bots.first(where: \.isDefault)
    }

    /// Each bot's sessions, newest first, keyed by bot id; bots without a session are absent.
    static func sessionsByBot(_ sessions: [HermesSession], scopeProfileID: String?, bots: [BotSummary])
        -> [String: [HermesSession]]
    {
        let botIDs = Set(bots.map(\.id))
        let defaultID = bots.first(where: \.isDefault)?.id
        var byBot: [String: [HermesSession]] = [:]
        for session in sessions {
            let profile = owner(session, scopeProfileID: scopeProfileID)
            if let profile, botIDs.contains(profile) {
                byBot[profile, default: []].append(session)
            } else if let defaultID, profile == nil || profile?.lowercased() == "default" {
                byBot[defaultID, default: []].append(session)
            }
        }
        return byBot.mapValues { sortedNewestFirst($0, tieBreakByID: true) }
    }

    /// Orders sessions by `lastUpdatedAt`, newest first; ties go by id, or keep
    /// input order. Rail rebuilds sort hundreds of rows, often in scrambled
    /// dictionary order; sorting precomputed keys instead of the sessions
    /// keeps every comparison from copying an 11-field value.
    static func sortedNewestFirst<Rows: Sequence>(_ sessions: Rows, tieBreakByID: Bool) -> [HermesSession]
    where Rows.Element == HermesSession {
        let rows = Array(sessions)
        let dates = rows.map { $0.lastUpdatedAt ?? .distantPast }
        let ids = tieBreakByID ? rows.map(\.id) : []
        return rows.indices.sorted { lhs, rhs in
            if dates[lhs] != dates[rhs] { return dates[lhs] > dates[rhs] }
            if tieBreakByID, ids[lhs] != ids[rhs] { return ids[lhs] < ids[rhs] }
            return lhs < rhs
        }.map { rows[$0] }
    }

    static func newestFirst(_ lhs: HermesSession, _ rhs: HermesSession) -> Bool {
        let lhsDate = lhs.lastUpdatedAt ?? .distantPast
        let rhsDate = rhs.lastUpdatedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id < rhs.id
    }
}

/// Reuses the inspector's recent-session grouping across unrelated layout passes.
@MainActor
final class RecentSessionBotProjection {
    struct Inputs: Equatable {
        let scanned: [HermesSession]
        let scoped: [HermesSession]
        let scopeProfileID: String?
        let openSessionID: String?
        let roster: [BotSummary]
    }

    private var inputs: Inputs?
    private(set) var bots: [BotSummary] = []
    private(set) var sessionsByBot: [String: [HermesSession]] = [:]

    @discardableResult
    func update(_ next: Inputs) -> Bool {
        guard inputs != next else { return false }
        inputs = next
        let sessions = SidebarAgentGrouping.merged(
            all: next.scanned, scoped: next.scoped, scopeProfileID: next.scopeProfileID
        ).filter { !$0.isHidden && $0.id != next.openSessionID }
        let visibleBots = next.roster.filter { !$0.isHidden }
        sessionsByBot = SidebarAgentGrouping.sessionsByBot(
            sessions, scopeProfileID: next.scopeProfileID, bots: visibleBots)
        bots = visibleBots.filter { sessionsByBot[$0.id] != nil }
        return true
    }
}
