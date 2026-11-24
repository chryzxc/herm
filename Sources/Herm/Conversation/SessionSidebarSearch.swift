import Foundation

enum SessionSidebarSearch {
    struct Scope: Equatable, Sendable {
        let mainChatIDs: Set<String>
        let showsAllProfiles: Bool
        let selectedBotID: String?
        let visibleBots: [BotSummary]
        var profileScopeID: String? = nil

        func includes(_ session: HermesSession) -> Bool {
            guard !mainChatIDs.contains(session.id) else { return false }
            if showsAllProfiles || session.source != "hermes-bot" { return true }
            let bot =
                visibleBots.first { $0.id == session.profileID }
                ?? visibleBots.first { $0.name == session.title }
            return bot?.id == selectedBotID
        }
    }

    struct Request: Equatable, Sendable {
        let query: String
        let conversations: [HermesSession]
        let pinned: [HermesSession]
        let projects: [String: String]
        let scope: Scope

        func resolve() -> Results {
            Results(query: query, scope: scope, sessions: matches())
        }

        func matches() -> [HermesSession] {
            SessionSidebarSearch.sessions(
                matching: query, in: (conversations + pinned).filter(scope.includes), projects: projects)
        }
    }

    struct Results: Sendable {
        let query: String
        let scope: Scope
        let sessions: [HermesSession]

        func sessions(for request: Request?) -> [HermesSession]? {
            guard let request, query == request.query, scope == request.scope else { return nil }
            return sessions
        }
    }

    static func sessions(
        matching query: String, in sessions: [HermesSession], projects: [String: String]
    ) -> [HermesSession] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return sessions.filter { session in
            guard !Task.isCancelled, seen.insert(session.id).inserted else { return false }
            return query.isEmpty
                || session.displayTitle.localizedCaseInsensitiveContains(query)
                || session.displayPreview?.localizedCaseInsensitiveContains(query) == true
                || projects[session.id]?.localizedCaseInsensitiveContains(query) == true
        }.sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
    }
}
