import Foundation

/// Page-owned work: cancellation stops queued sessions and discards partial results.
enum ArtifactIndexLoader {
    struct SessionResult: Sendable {
        let sessionID: String
        let records: [ArtifactRecord]
        let error: String?
    }

    @MainActor
    static func load(
        sessions: [HermesSession],
        messages: @escaping @MainActor @Sendable (HermesSession) async throws -> [[String: Any]]
    ) async -> [SessionResult] {
        await withTaskGroup(of: SessionResult.self) { group in
            var remaining = sessions.makeIterator()
            func add(_ session: HermesSession) {
                group.addTask { await loadSession(session, messages: messages) }
            }
            for _ in 0..<4 {
                guard !Task.isCancelled, let session = remaining.next() else { break }
                add(session)
            }
            var results: [SessionResult] = []
            while let result = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return [] }
                results.append(result)
                if let session = remaining.next() { add(session) }
            }
            return results
        }
    }

    @MainActor
    private static func loadSession(
        _ session: HermesSession,
        messages: @MainActor @Sendable (HermesSession) async throws -> [[String: Any]]
    ) async -> SessionResult {
        do {
            try Task.checkCancellation()
            let raw = try await messages(session)
            try Task.checkCancellation()
            let records = await ArtifactService.extractInBackground(session: session, messages: raw)
            return SessionResult(sessionID: session.id, records: records, error: nil)
        } catch {
            return SessionResult(sessionID: session.id, records: [], error: error.localizedDescription)
        }
    }
}
