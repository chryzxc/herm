import Foundation

extension DockModel {
    static let allBotSessionsLimit = 100
    static let transcriptPreloadLimit = 8
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
        allBotSessionsTask = Task(priority: force ? .userInitiated : .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { allBotSessionsTask = nil }
            let startedAt = Date()
            if !force {
                guard await DockScrollActivity.waitForInputIdle() else { return }
            }
            do {
                let body = try await interruptRPC.allProfileSidebarSessions(limit: Self.allBotSessionsLimit)
                let response = UncheckedTranscriptValue(value: body)
                let loaded = try await Task.detached(priority: .utility) {
                    try Self.parseAllBotSessions(response.value)
                }.value
                guard !Task.isCancelled, !hasShutDown else { return }
                allBotSessionsLoadedAt = Date()
                let projection: HermesProjectionState<[HermesSession]> = loaded.isEmpty ? .empty : .ready(loaded)
                if projection != allBotSessionsState { allBotSessionsState = projection }
                DebugLog.writePerformance(
                    "sidebar all_bot_sessions rows=\(loaded.count) ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                )
                scheduleTranscriptPreload(scanned: loaded)
            } catch is CancellationError {
                return
            } catch {
                allBotSessionsState = Self.failedOrStale(
                    allBotSessionsState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
                DebugLog.write(
                    "model: all-bot sessions failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
                scheduleTranscriptPreload(scanned: [])
            }
        }
    }

    private func scheduleTranscriptPreload(scanned: [HermesSession]) {
        guard sessionTranscriptPreloadTask == nil, sessionTranscriptCache.hasPreloadCapacity else { return }
        let scope = profileScopeID
        let current = (pinnedSessions + sessions).map { ($0, $0.profileID ?? scope) }
        let remote = scanned.compactMap { session -> (HermesSession, String?)? in
            guard let profile = Self.normalizedProfileID(session.profileID) else { return nil }
            return (session, profile)
        }
        let candidates =
            current.filter { $0.0.isPinned } + remote.filter { $0.0.isPinned }
            + current.filter { !$0.0.isPinned } + remote.filter { !$0.0.isPinned }
        sessionTranscriptPreloadTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { sessionTranscriptPreloadTask = nil }
            await preloadSessionTranscripts(candidates, scope: scope)
        }
    }

    private func preloadSessionTranscripts(_ candidates: [(HermesSession, String?)], scope: String?) async {
        var seen = Set<String>()
        var attempted = 0
        for (session, profile) in candidates {
            guard !Task.isCancelled, !hasShutDown, profileScopeID == scope, sessionTranscriptCache.hasPreloadCapacity
            else { return }
            guard let profile = Self.normalizedProfileID(profile) else { continue }
            let key = WorkspaceIdentity.session(profileID: profile, sessionID: session.id)
            guard seen.insert(key).inserted, session.id != BotService.canonicalBotChatTitle,
                key != transcriptPresentationID, sessionTranscriptCache.value(for: key) == nil,
                let path = TranscriptHistoryPaging.pagePath(
                    sessionID: session.id, profileID: profile, limit: TranscriptHistoryPaging.pageRowLimit, offset: 0)
            else { continue }
            guard attempted < Self.transcriptPreloadLimit else { return }
            guard await DockScrollActivity.waitForInputIdle(), profileScopeID == scope else { return }
            attempted += 1
            do {
                let response = try await sessionRPCClient.fetchHTTP(path)
                guard let page = TranscriptHistoryPaging.page(from: response) else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                guard await DockScrollActivity.waitForInputIdle(), profileScopeID == scope else { return }
                let rows = await Self.projectStoredRowsOffMain(page.rows, priority: .utility)
                let (restored, references) = await Self.parseMessagesOffMain(
                    rows, defaultBotProfileID: nil, defaultBotDisplayName: nil, priority: .utility)
                guard !Task.isCancelled, !hasShutDown, profileScopeID == scope, key != transcriptPresentationID
                else { continue }
                sessionTranscriptCache.preload(restored, references: references, for: key)
            } catch is CancellationError {
                return
            } catch {
                DebugLog.write(
                    "model: transcript preload failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    /// Parses `/api/profiles/sessions/sidebar`. A failed scan omits
    /// `recents.sessions`, so that shape throws instead of reading as empty.
    nonisolated static func parseAllBotSessions(_ body: [String: Any]) throws -> [HermesSession] {
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
