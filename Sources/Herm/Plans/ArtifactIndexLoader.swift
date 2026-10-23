import Foundation

/// Page-owned work: cancellation stops queued sessions and discards partial results.
enum ArtifactIndexLoader {
    struct SessionResult: Sendable {
        let sessionID: String
        let profileID: String?
        let records: [ArtifactRecord]
        let error: String?
    }

    struct CachedSession: Sendable {
        let session: HermesSession
        let records: [ArtifactRecord]

        func matches(_ current: HermesSession) -> Bool {
            session.scopedID == current.scopedID && current.lastUpdatedAt != nil
                && session.lastUpdatedAt == current.lastUpdatedAt && session.messageCount == current.messageCount
                && session.displayTitle == current.displayTitle
        }
    }

    @MainActor
    static func load(
        sessions: [HermesSession],
        cache: [ProfileScopedID: CachedSession] = [:],
        messages: @escaping @MainActor @Sendable (HermesSession, Int) async throws -> [String: Any]
    ) async -> [SessionResult] {
        await withTaskGroup(of: SessionResult.self) { group in
            var remaining = sessions.makeIterator()
            func add(_ session: HermesSession) {
                group.addTask { await loadSession(session, cached: cache[session.scopedID], messages: messages) }
            }
            for _ in 0..<4 {
                guard !Task.isCancelled, let session = remaining.next() else { break }
                add(session)
            }
            var results: [SessionResult] = []
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return []
                }
                results.append(result)
                if let session = remaining.next() { add(session) }
            }
            return results
        }
    }

    @MainActor
    private static func loadSession(
        _ session: HermesSession,
        cached: CachedSession?,
        messages: @MainActor @Sendable (HermesSession, Int) async throws -> [String: Any]
    ) async -> SessionResult {
        do {
            try Task.checkCancellation()
            if let cached, cached.matches(session) {
                return SessionResult(
                    sessionID: session.id, profileID: session.profileID, records: cached.records, error: nil)
            }
            var found: [String: ArtifactRecord] = [:]
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await messages(session, offset)
                let extracted = try await ArtifactService.extractPageInBackground(session: session, page: page)
                for record in extracted.records where found[record.id] == nil {
                    found[record.id] = record
                }
                guard extracted.hasMore else { break }
                offset += extracted.messageCount
            }
            return SessionResult(
                sessionID: session.id, profileID: session.profileID, records: Array(found.values), error: nil)
        } catch {
            return SessionResult(
                sessionID: session.id, profileID: session.profileID, records: [],
                error: HermesDiagnosticsService.safeSummary(error.localizedDescription))
        }
    }
}
