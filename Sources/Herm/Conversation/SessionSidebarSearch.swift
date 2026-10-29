import Foundation

enum SessionSidebarSearch {
    static func sessions(
        matching query: String, in sessions: [HermesSession], projects: [String: String]
    ) -> [HermesSession] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        return sessions.filter { session in
            guard seen.insert(session.id).inserted else { return false }
            return query.isEmpty
                || [session.displayTitle, session.displayPreview ?? "", projects[session.id] ?? ""]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
    }
}
