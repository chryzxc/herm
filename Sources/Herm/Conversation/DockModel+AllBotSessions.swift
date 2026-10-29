import Foundation

extension DockModel {
    static let allBotSessionsLimit = 100
    /// Matches Hermes' sidebar cache TTL: a burst of completed turns costs one scan.
    static let allBotSessionsRefreshInterval: TimeInterval = 5

    /// Loads every bot's recent sessions in one request. One read runs at a
    /// time, and reads closer together than the refresh interval are skipped
    /// unless forced.
    func loadAllBotSessions(force: Bool = false) {
        guard allBotSessionsTask == nil else { return }
        if !force, let loadedAt = allBotSessionsLoadedAt,
            Date().timeIntervalSince(loadedAt) < Self.allBotSessionsRefreshInterval
        {
            return
        }
        allBotSessionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { allBotSessionsTask = nil }
            let startedAt = Date()
            do {
                let body = try await interruptRPC.allProfileSidebarSessions(limit: Self.allBotSessionsLimit)
                let loaded = try Self.parseAllBotSessions(body)
                allBotSessionsLoadedAt = Date()
                let projection: HermesProjectionState<[HermesSession]> = loaded.isEmpty ? .empty : .ready(loaded)
                if projection != allBotSessionsState { allBotSessionsState = projection }
                DebugLog.writePerformance(
                    "sidebar all_bot_sessions rows=\(loaded.count) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                )
            } catch is CancellationError {
                return
            } catch {
                allBotSessionsState = Self.failedOrStale(
                    allBotSessionsState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
                DebugLog.write(
                    "model: all-bot sessions failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    /// Parses `/api/profiles/sessions/sidebar`. A failed scan omits
    /// `recents.sessions`, so that shape throws instead of reading as empty.
    static func parseAllBotSessions(_ body: [String: Any]) throws -> [HermesSession] {
        guard let recents = body["recents"] as? [String: Any],
            let rows = recents["sessions"] as? [[String: Any]]
        else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        var seen = Set<ProfileScopedID>()
        return rows.compactMap { row in
            guard !isModellessFeed(row),
                let session = parseSession(row, profileID: normalizedProfileID(row["profile"] as? String)),
                seen.insert(session.scopedID).inserted
            else { return nil }
            return session
        }
    }
}
