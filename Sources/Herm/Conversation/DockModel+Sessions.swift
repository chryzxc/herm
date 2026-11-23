import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func toggleSessions() {
        isShowingSessions.toggle()
        if isShowingSessions { loadSessions() }
    }

    /// Re-home the foreground session surface and profile-owned conversation
    /// index. The outgoing list is retained under its own profile and replaced
    /// by the target's retained (or preloaded) list, else cleared; the target
    /// is then re-read, quietly when something is already shown. Late
    /// responses are rejected by the generation guard in `loadSessions`.
    /// Returns the chat that was open when the target profile was last left.
    @discardableResult
    func setProfileScope(_ profileID: String?) -> HermesSession? {
        let normalized = profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = normalized?.isEmpty == false ? normalized : nil
        let nextUnavailable = next == nil
        guard profileScopeID != next || profileScopeUnavailable != nextUnavailable else {
            if sessionProfileID == nil { sessionProfileID = next }
            return nil
        }
        retainCurrentProfileSessions()
        profileScopeID = next
        profileScopeUnavailable = nextUnavailable
        if let next {
            defaults.set(next, forKey: profileScopeKey)
        } else {
            defaults.removeObject(forKey: profileScopeKey)
        }
        let shown = next.flatMap(profileSessionsToShow(for:))
        sessionHistoryLoadedAt = shown?.historyLoadedAt.map { (next, $0) }
        pendingSessionIndexRefresh = false
        sessionIndexRefreshTask?.cancel()
        sessionIndexRefreshTask = nil
        sessionLoadGeneration &+= 1
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        isLoadingSessions = false
        isPollingSessions = false
        sessions = shown?.sessions ?? []
        pinnedSessions = shown?.pinnedSessions ?? []
        if let shown {
            sessionProjectionState = shown.sessions.isEmpty ? .empty : .ready(shown.sessions)
        } else {
            sessionProjectionState = .loading
        }
        // Keep the outgoing session profile until its draft has been saved.
        newChat()
        loadSessions(quiet: shown != nil)
        return shown?.openSession
    }

    func artifactSessions(onPage: @MainActor ([HermesSession]) async -> Void) async throws -> Bool {
        var seen = Set<ProfileScopedID>()
        return try await interruptRPC.artifactSessions { rows in
            let raw = UncheckedTranscriptValue(value: rows)
            let parsed = await Task.detached(priority: .utility) {
                raw.value.compactMap { Self.parseSession($0, profileID: $0["profile"] as? String) }
            }.value
            guard !Task.isCancelled else { return }
            let sessions = parsed.filter { seen.insert($0.scopedID).inserted }
            if !sessions.isEmpty { await onPage(sessions) }
        }
    }

    func artifactMessages(for session: HermesSession, offset: Int) async throws -> [String: Any] {
        // Show recent output early, then page back through the pre-compaction history.
        do {
            return try await interruptRPC.sessionMessages(
                sessionID: session.id, profileID: session.profileID, latest: true,
                limit: 100, offset: offset, includeCompacted: true)
        } catch HermesGateway.GatewayError.httpError(404) {
            return ["data": []]  // pruned since the session list was read
        }
    }

    func resultPeek(for session: HermesSession) async throws -> EdgeResultContent? {
        let started = Date()
        defer { DebugLog.write("workflow: result.read_ms=\(Int(Date().timeIntervalSince(started) * 1000))") }
        let result = try await interruptRPC.sessionMessages(
            sessionID: session.id, profileID: session.profileID, latest: true)
        return try EdgeResultContent.parse(result, session: session)
    }

    func markQuickResultReviewed(_ snapshot: HermesSession) {
        guard let live = sessions.first(where: { $0.id == snapshot.id && $0.profileID == snapshot.profileID }),
            !live.isWorking, live.lastUpdatedAt == snapshot.lastUpdatedAt
        else { return }
        updateSessionActivity(sessionID: live.id, unread: false)
        if currentSessionIDs.contains(live.id), status == .idle { hasUnreadResponse = false }
    }

    func updateCurrentSessionTitle(_ title: String) {
        guard sessionID != nil else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        guard !trimmed.isEmpty,
            normalized != "untitled",
            normalized != "untitled chat",
            normalized != "untitled session",
            normalized != "hermes session", currentSessionTitle != trimmed
        else { return }
        currentSessionTitle = trimmed
    }

    func loadInitialWorkspaceSessions() {
        guard workspaceStartup.phase == .resolvingProfile else { return }
        if !sessions.isEmpty || !pinnedSessions.isEmpty {
            workspaceStartup.phase = .finished
            return
        }
        workspaceStartup.phase = .loadingSessions
        if sessionLoadTask == nil, loadSessions() == nil {
            workspaceStartup.phase = .finished
        }
    }

    @discardableResult
    func loadSessions(profileID: String? = nil, quiet: Bool = false, reconcileHistory: Bool = false)
        -> Task<Void, Never>?
    {
        guard !hasShutDown else { return nil }
        let scope = profileID ?? profileScopeID
        if profileScopeUnavailable, scope == nil {
            sessions = []
            sessionProjectionState = .empty
            if workspaceStartup.phase == .loadingSessions { workspaceStartup.phase = .finished }
            return nil
        }
        guard !isLoadingSessions, !(quiet && isPollingSessions) else { return sessionLoadTask }
        sessionLoadTask?.cancel()
        if quiet { isPollingSessions = true } else { isLoadingSessions = true }
        sessionLoadGeneration &+= 1
        let generation = sessionLoadGeneration
        let previousProjectionState = sessionProjectionState
        if !quiet { sessionProjectionState = Self.refreshingProjectionState(sessionProjectionState) }
        let task = Task(priority: quiet ? .utility : .userInitiated) { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = ProcessInfo.processInfo.systemUptime
            defer {
                if self.sessionLoadGeneration == generation {
                    lastSessionIndexReadAt = Date()
                    if isLoadingSessions { isLoadingSessions = false }
                    isPollingSessions = false
                    sessionLoadTask = nil
                    if workspaceStartup.phase == .loadingSessions { workspaceStartup.phase = .finished }
                    if pendingSessionIndexRefresh && !hasShutDown {
                        pendingSessionIndexRefresh = false
                        refreshSessionIndexAfterActivity()
                    }
                }
            }
            do {
                if quiet {
                    guard await DockScrollActivity.waitForInputIdle() else { return }
                }
                try await sessionRPCClient.connect()
                var params: [String: Any] = ["limit": 50]
                if let scope, !scope.isEmpty { params["profile"] = scope }
                let result = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.sessionList.rawValue, params: params)
                guard !self.hasShutDown, self.sessionLoadGeneration == generation, self.profileScopeID == scope else {
                    return
                }
                guard let rawSessions = result["sessions"] as? [[String: Any]] else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                await migrateLegacyLocalPins()
                let reuseStoredHistory = Self.canReuseSessionHistory(
                    loadedAt: sessionHistoryLoadedAt, scope: scope, now: Date(), reconcile: reconcileHistory)
                let activityGeneration = sessionActivityGeneration
                let firstPage = try? await sessionRPCClient.fetchHTTP(Self.sessionIndexPath(profileID: scope))
                guard !self.hasShutDown, self.sessionLoadGeneration == generation, self.profileScopeID == scope else {
                    return
                }
                let recentRows = firstPage?["sessions"] as? [[String: Any]]
                if recentRows == nil, sessionHistoryLoadedAt != nil {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let indexRows = UncheckedTranscriptValue(value: (recentRows, rawSessions))
                let (recent, live) = await Task.detached(priority: quiet ? .utility : .userInitiated) {
                    let recent = indexRows.value.0.map { SessionIndexPage(rows: $0, profileID: scope) }
                    let live = indexRows.value.1.compactMap { Self.parseSession($0, profileID: scope) }
                    return (recent, live)
                }.value
                guard !Task.isCancelled, !hasShutDown, sessionLoadGeneration == generation, profileScopeID == scope
                else { return }
                let total = (firstPage?["total"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
                let storedRecent = reuseStoredHistory || total != nil ? recent?.conversations ?? [] : []
                if sessions.isEmpty, let recent, !live.isEmpty || !storedRecent.isEmpty || !recent.pinned.isEmpty {
                    // The first REST page includes every pin and authoritative recency.
                    // Keep the projection loading until older history has arrived.
                    if sessionProjectionState != .loading { sessionProjectionState = .loading }
                    guard
                        await publishSessionIndex(
                            live: live, stored: storedRecent, recent: recent, working: nil,
                            activityGeneration: activityGeneration, loadGeneration: generation, scope: scope,
                            quiet: quiet)
                    else { return }
                    DebugLog.writePerformance(
                        "session_index stage=recent rows=\(sessions.count) ms=\(Self.elapsedMilliseconds(since: startedAt))"
                    )
                }
                let activeRead = recent.map { _ in
                    Task { @MainActor [sessionRPCClient] in
                        let response = try? await sessionRPCClient.request(
                            HermesFeatureIDs.ID.sessionActiveList.rawValue, params: [:])
                        return (response?["sessions"] as? [[String: Any]]).map(Self.liveWorkingSessions)
                    }
                }
                defer { activeRead?.cancel() }
                var older: [HermesSession] = []
                if !reuseStoredHistory, let recentRows, let total {
                    older = try await Self.fetchOlderSessions(
                        client: sessionRPCClient, profileID: scope, offset: min(100, recentRows.count), total: total)
                }
                let active = await activeRead?.value
                if quiet {
                    guard await DockScrollActivity.waitForInputIdle() else { return }
                }
                guard !self.hasShutDown, self.sessionLoadGeneration == generation, self.profileScopeID == scope else {
                    return
                }
                let stored = storedRecent + older
                guard
                    await publishSessionIndex(
                        live: live, stored: stored, recent: recent, working: recent?.working(with: active),
                        activityGeneration: activityGeneration, loadGeneration: generation, scope: scope, quiet: quiet,
                        retainingHistory: reuseStoredHistory)
                else { return }
                if !reuseStoredHistory, !stored.isEmpty { sessionHistoryLoadedAt = (scope, Date()) }
                // Hermes names a session after its first turn; the header follows the list.
                if let current = sessions.first(where: { currentSessionIDs.contains($0.id) }) {
                    updateCurrentSessionTitle(current.title)
                }
                let projection: HermesProjectionState<[HermesSession]> = sessions.isEmpty ? .empty : .ready(sessions)
                if projection != sessionProjectionState { sessionProjectionState = projection }
                DebugLog.writePerformance(
                    "session_index stage=complete rows=\(sessions.count) ms=\(Self.elapsedMilliseconds(since: startedAt))"
                )
                loadAllBotSessions()
            } catch {
                guard !self.hasShutDown, self.sessionLoadGeneration == generation, self.profileScopeID == scope else {
                    return
                }
                sessionProjectionState = Self.failedOrStale(
                    sessions.isEmpty ? previousProjectionState : .ready(sessions),
                    safeMessage: "Hermes session data is unavailable. Try refreshing.")
                DebugLog.write("model: session list failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
        sessionLoadTask = task
        return task
    }

    private static func elapsedMilliseconds(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    @discardableResult
    func deleteSession(_ session: HermesSession) async -> Bool {
        guard session.id != sessionID, session.id != sessionStorageID else {
            sessionDeletionError = "The active session cannot be deleted."
            return false
        }
        guard deletingSessionID == nil else { return false }
        sessionDeletionError = nil
        deletingSessionID = session.id
        defer { deletingSessionID = nil }
        do {
            try await sessionRPCClient.connect()
            // Hermes refuses to delete a session still loaded in the gateway, even one
            // we aren't viewing. Close idle live copies first; busy ones still fail loudly.
            let live = try? await sessionRPCClient.request(HermesFeatureIDs.ID.sessionActiveList.rawValue, params: [:])
            for row in (live?["sessions"] as? [[String: Any]]) ?? []
            where row["session_key"] as? String == session.id && (row["status"] as? String ?? "idle") == "idle" {
                if let liveID = row["session_id"] as? String {
                    _ = try? await sessionRPCClient.request(
                        HermesFeatureIDs.ID.sessionClose.rawValue, params: ["session_id": liveID])
                }
            }
            var params: [String: Any] = ["session_id": session.id]
            if let profileID = session.profileID ?? profileScopeID { params["profile"] = profileID }
            _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionDelete.rawValue, params: params)
            sessionTranscriptCache.remove(
                WorkspaceIdentity.session(
                    profileID: Self.normalizedProfileID(session.profileID ?? profileScopeID), sessionID: session.id))
            discardComposerDraft(
                for: SessionComposerDraft.Key(
                    profileID: Self.normalizedProfileID(session.profileID ?? profileScopeID), sessionID: session.id
                ))
            let owner = SessionComposerDraft.Key(
                profileID: Self.normalizedProfileID(session.profileID ?? profileScopeID), sessionID: session.id)
            for pending in pendingSessionSends where pending.owner == owner {
                cleanupImageAttachments(pending.snapshot.images)
            }
            pendingSessionSends.removeAll { $0.owner == owner }
            sessionStopAttempts[owner] = nil
            SessionBrowserStore.shared.delete(
                SessionBrowserKey(profileID: session.profileID ?? profileScopeID, sessionID: session.id))
            sessions.removeAll { $0.id == session.id }
            forgetRetainedSession(session.id, profileID: session.profileID ?? profileScopeID)
            DebugLog.write("model: deleted saved session \(session.id)")
            return true
        } catch {
            sessionDeletionError =
                "Could not delete the session: \(Self.safeUserDiagnostic(error.localizedDescription))"
            actionErrors.report("Could not delete session", error: error)
            DebugLog.write("model: session delete failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    @discardableResult
    func setSessionHidden(_ session: HermesSession, hidden: Bool) async -> Bool {
        guard updatingSessionVisibilityID == nil else { return false }
        sessionVisibilityError = nil
        updatingSessionVisibilityID = session.id
        defer { updatingSessionVisibilityID = nil }
        do {
            try await sessionRPCClient.connect()
            var params: [String: Any] = ["session_id": session.id, "hidden": hidden]
            if let profileID = session.profileID ?? profileScopeID { params["profile"] = profileID }
            _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionSetHidden.rawValue, params: params)
            invalidateRetainedHistory(profileID: session.profileID ?? profileScopeID)
            loadSessions()
            return true
        } catch {
            sessionVisibilityError = Self.safeUserDiagnostic(error.localizedDescription)
            actionErrors.report("Could not update session visibility", error: error)
            return false
        }
    }

    func isSessionPinned(_ sessionID: String) -> Bool {
        pinnedSessions.contains { $0.id == sessionID }
    }

    /// Toggles Hermes' pin flag through the same `PATCH /api/sessions/{id}`
    /// Hermes Desktop uses, so a pin made here shows up there and in the CLI.
    /// `isPinned` is the caller's merged view for a chat outside the selected
    /// profile, whose pin lives in the all-profile scan instead of `pinnedSessions`.
    @discardableResult
    func toggleSessionPinned(_ session: HermesSession, isPinned currentlyPinned: Bool? = nil) async -> Bool {
        guard pinningSessionID == nil else { return false }
        let pinned = !(currentlyPinned ?? isSessionPinned(session.id))
        let scope = profileScopeID
        let profileID = session.profileID ?? scope
        let ownedByScope = Self.normalizedProfileID(profileID) == Self.normalizedProfileID(scope)
        pinningSessionID = session.id
        defer { pinningSessionID = nil }
        do {
            try await sessionPinService.setPinned(
                pinned, sessionID: session.id, profileID: profileID, client: sessionRPCClient)
            applyAllProfilePin(pinned, to: session, profileID: profileID)
            applyRetainedPin(pinned, to: session, profileID: profileID)
            guard ownedByScope, profileScopeID == scope else { return true }
            // Reject list snapshots that predate the acknowledged mutation.
            sessionLoadGeneration &+= 1
            sessionLoadTask?.cancel()
            sessionLoadTask = nil
            isLoadingSessions = false
            isPollingSessions = false
            pinnedSessions.removeAll { $0.id == session.id }
            if pinned { pinnedSessions.append(session) }
            await loadSessions(quiet: true)?.value
            return true
        } catch {
            actionErrors.report(pinned ? "Could not pin session" : "Could not unpin session", error: error)
            DebugLog.write("model: session pin failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    /// Reflects an acknowledged pin in the all-profile scan at once, then
    /// re-reads it; the scan is otherwise throttled.
    func applyAllProfilePin(_ pinned: Bool, to session: HermesSession, profileID: String?) {
        let key = ProfileScopedID(profileID: profileID, resourceID: session.id)
        func patched(_ rows: [HermesSession]) -> [HermesSession] {
            var rows = rows.filter { $0.scopedID != key }
            rows.append(session.withPinned(pinned, profileID: key.profileID))
            return rows.sorted(by: SidebarAgentGrouping.newestFirst)
        }
        switch allBotSessionsState {
        case .ready(let rows): allBotSessionsState = .ready(patched(rows))
        case .stale(let rows, let message): allBotSessionsState = .stale(patched(rows), safeMessage: message)
        case .empty where pinned: allBotSessionsState = .ready(patched([]))
        case .empty, .loading, .unavailable, .failed: break
        }
        loadAllBotSessions(force: true)
    }

    /// `/api/sessions` back-fills every pinned row past `limit`, so the recent
    /// page plus the pins is the full pinned set. Its rows also carry
    /// `last_active`, which session.list omits.
    /// Rows that hold messages yet never called a model: plugin feeds and
    /// delivery logs, not conversations. They show inside the chat they
    /// report on, so the session list leaves them out.
    nonisolated static func isModellessFeed(_ row: [String: Any]) -> Bool {
        let messages = (row["message_count"] as? NSNumber)?.intValue ?? 0
        guard messages > 0, let calls = (row["api_call_count"] as? NSNumber)?.intValue, calls == 0 else { return false }
        return ((row["model"] as? String) ?? "").isEmpty
    }

    private static func sessionIndexPath(profileID: String?, offset: Int = 0) -> String {
        var path = "/api/sessions?limit=100&order=recent"
        if offset > 0 { path += "&offset=\(offset)" }
        if let profileID, !profileID.isEmpty,
            let encoded = profileID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        {
            path += "&profile=\(encoded)"
        }
        return path
    }

    private static func fetchOlderSessions(
        client: HermesRPCClientProtocol, profileID: String?, offset: Int, total: Int
    ) async throws -> [HermesSession] {
        var rows: [HermesSession] = []
        var offset = offset
        var total = total
        while offset < total {
            try Task.checkCancellation()
            guard offset > 0 else { throw HermesGateway.GatewayError.malformedResponse }
            let page = try await client.fetchHTTP(sessionIndexPath(profileID: profileID, offset: offset))
            guard let sessions = page["sessions"] as? [[String: Any]], !sessions.isEmpty,
                let pageTotal = page["total"] as? Int, pageTotal >= 0
            else { throw HermesGateway.GatewayError.malformedResponse }
            let raw = UncheckedTranscriptValue(value: sessions)
            let parsed = await Task.detached(priority: Task.currentPriority) {
                Array(
                    raw.value.lazy.filter { !isModellessFeed($0) }.compactMap { parseSession($0, profileID: profileID) }
                )
            }.value
            try Task.checkCancellation()
            rows.append(contentsOf: parsed)
            offset += min(100, sessions.count)  // Pinned rows can be appended beyond the page.
            total = pageTotal
        }
        return rows
    }

    /// External deletions in older pages can linger until the next full read.
    static let sessionHistoryReuseWindow: TimeInterval = 300

    static func canReuseSessionHistory(
        loadedAt: (profileID: String?, date: Date)?, scope: String?, now: Date, reconcile: Bool
    ) -> Bool {
        guard !reconcile, let loadedAt, loadedAt.profileID == scope else { return false }
        return now.timeIntervalSince(loadedAt.date) < sessionHistoryReuseWindow
    }

    /// True when an index read finished within `interval`, so a timer poll adds nothing.
    func sessionIndexReadRecently(within interval: TimeInterval, now: Date = Date()) -> Bool {
        lastSessionIndexReadAt.map { now.timeIntervalSince($0) < interval } ?? false
    }

    private struct SessionIndexPage: Sendable {
        let conversations: [HermesSession]
        let pinned: [HermesSession]
        let lastActive: [String: Date]
        let feedIDs: Set<String>
        let recentlyWrittenIDs: Set<String>

        init(rows: [[String: Any]], profileID: String?) {
            let parsed = rows.compactMap { DockModel.parseSession($0, profileID: profileID) }
            let feeds = Set(rows.filter(DockModel.isModellessFeed).compactMap { $0["id"] as? String })
            feedIDs = feeds
            conversations = parsed.filter { !feeds.contains($0.id) }
            pinned = parsed.filter(\.isPinned)
            lastActive = Dictionary(
                parsed.compactMap { session in session.updatedAt.map { (session.id, $0) } },
                uniquingKeysWith: max)
            recentlyWrittenIDs = Set(
                rows.compactMap { row in
                    row["is_active"] as? Bool == true ? row["id"] as? String : nil
                })
        }

        func working(with live: (known: Set<String>, working: Set<String>)?) -> Set<String>? {
            // Other Hermes processes do not report into the workspace gateway.
            live.map { $0.working.union(recentlyWrittenIDs.subtracting($0.known)) }
        }
    }

    private static func liveWorkingSessions(_ rows: [[String: Any]]) -> (known: Set<String>, working: Set<String>) {
        let known = Set(rows.compactMap { $0["session_key"] as? String })
        let working = Set(
            rows.compactMap { row -> String? in
                guard let status = row["status"] as? String,
                    ["starting", "working", "streaming", "waiting"].contains(status)
                else { return nil }
                return row["session_key"] as? String
            })
        return (known, working)
    }

    private func publishSessionIndex(
        live: [HermesSession], stored: [HermesSession], recent: SessionIndexPage?, working: Set<String>?,
        activityGeneration: UInt64, loadGeneration: UInt64, scope: String?, quiet: Bool, retainingHistory: Bool = false
    ) async -> Bool {
        while !Task.isCancelled, !hasShutDown, sessionLoadGeneration == loadGeneration, profileScopeID == scope {
            if quiet {
                guard await DockScrollActivity.waitForInputIdle() else { return false }
            }
            let revision = sessionIndexRevision
            let currentActivity = sessionActivityGeneration
            let openSession = navigationSessionID
            let previous = sessions
            let previousPins = pinnedSessions
            let unread = Set(defaults.stringArray(forKey: unreadSessionIDsKey) ?? [])
            // Gateway events newer than the network read win over its working-session snapshot.
            let currentWorking = activityGeneration == currentActivity ? working : nil
            let projection = Task.detached(priority: quiet ? .utility : .userInitiated) {
                Self.mergedSessionIndex(
                    live: live, stored: stored, recent: recent, working: currentWorking,
                    retainingHistory: retainingHistory,
                    previous: previous, previousPins: previousPins, openSession: openSession, unread: unread)
            }
            let (updated, pins) = await withTaskCancellationHandler {
                await projection.value
            } onCancel: {
                projection.cancel()
            }
            if quiet {
                guard await DockScrollActivity.waitForInputIdle() else { return false }
            }
            guard !Task.isCancelled, !hasShutDown, sessionLoadGeneration == loadGeneration, profileScopeID == scope
            else { return false }
            guard revision == sessionIndexRevision, openSession == navigationSessionID,
                currentWorking == nil || currentActivity == sessionActivityGeneration,
                unread == Set(defaults.stringArray(forKey: unreadSessionIDsKey) ?? [])
            else { continue }
            if let pins { pinnedSessions = pins }
            if let updated { sessions = updated }
            if workspaceStartup.phase == .loadingSessions, !sessions.isEmpty || !pinnedSessions.isEmpty {
                workspaceStartup.phase = .finished
            }
            return true
        }
        return false
    }

    private nonisolated static func mergedSessionIndex(
        live: [HermesSession], stored: [HermesSession], recent: SessionIndexPage?, working: Set<String>?,
        retainingHistory: Bool, previous: [HermesSession], previousPins: [HermesSession], openSession: String?,
        unread: Set<String>
    ) -> ([HermesSession]?, [HermesSession]?) {
        let retained = retainingHistory ? previous : []
        let storedModels = Dictionary(
            (stored + retained).compactMap { row in row.modelName.map { (row.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let loaded = (live + stored + retained)
            .filter { seen.insert($0.id).inserted }
            .filter { recent?.feedIDs.contains($0.id) != true || $0.id == openSession }
            .map { row in
                let session = row.modelName == nil ? row.withModelName(storedModels[row.id]) : row
                return Self.withRecency(session, from: recent?.lastActive ?? [:])
            }
        let pinned = recent.map { mergingSessionIndex($0.pinned, with: previous + previousPins, working: working) }
        let merged = applyingUnreadIDs(
            unread, to: mergingSessionIndex(loaded, with: previous, keeping: openSession, working: working))
        return (merged == previous ? nil : merged, pinned == previousPins ? nil : pinned)
    }

    nonisolated static func withRecency(_ session: HermesSession, from lastActive: [String: Date]) -> HermesSession {
        guard let date = lastActive[session.id], date > (session.lastUpdatedAt ?? .distantPast) else { return session }
        return HermesSession(
            id: session.id,
            profileID: session.profileID,
            title: session.title,
            preview: session.preview,
            startedAt: session.startedAt,
            updatedAt: date,
            messageCount: session.messageCount,
            source: session.source,
            isHidden: session.isHidden,
            isWorking: session.isWorking,
            hasUnreadUpdate: session.hasUnreadUpdate, isPinned: session.isPinned, modelName: session.modelName
        )
    }

    /// One-time move of pins older Herm builds kept in UserDefaults into Hermes.
    /// Pins that fail to write (other than a deleted session) stay for the next load.
    func migrateLegacyLocalPins() async {
        let key = "hermes.dock.pinned-sessions.v1"
        guard let data = defaults.data(forKey: key),
            let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let references = saved["references"] as? [[String: String]]
        else { return }
        var remaining: [[String: String]] = []
        for reference in references {
            guard let sessionID = reference["sessionID"] else { continue }
            do {
                try await sessionPinService.setPinned(
                    true, sessionID: sessionID, profileID: reference["profileID"], client: sessionRPCClient)
            } catch HermesSessionPinService.Failure.sessionNotFound {
                continue
            } catch {
                remaining.append(reference)
            }
        }
        if remaining.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONSerialization.data(withJSONObject: ["references": remaining]) {
            defaults.set(data, forKey: key)
        }
    }

    @discardableResult
    func renameSession(_ session: HermesSession, title: String) async -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, renamingSessionID == nil else { return false }
        renamingSessionID = session.id
        defer { renamingSessionID = nil }
        do {
            try await sessionRPCClient.connect()
            if session.id == navigationSessionID, let sessionID {
                _ = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.sessionTitle.rawValue, params: ["session_id": sessionID, "title": cleanTitle])
                currentSessionTitle = cleanTitle
            } else {
                try await HermesCLIAdapter(rpc: HermesControlRPC(client: sessionRPCClient)).renameSavedSession(
                    sessionID: session.id, title: cleanTitle, profileID: session.profileID ?? profileScopeID)
            }
            invalidateRetainedHistory(profileID: session.profileID ?? profileScopeID)
            loadSessions()
            return true
        } catch {
            actionErrors.report("Could not rename session", error: error)
            DebugLog.write("model: session rename failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    func clearSessionVisibilityError() {
        sessionVisibilityError = nil
    }

    func clearSessionDeletionError() {
        sessionDeletionError = nil
    }

    @discardableResult
    func restoreLatestSessionIfNeeded() -> Task<Void, Never>? {
        guard !didRestoreLatestSession else { return nil }
        didRestoreLatestSession = true
        guard sessionID == nil, sessionResumeTask == nil else { return nil }
        guard !profileScopeUnavailable else {
            isRestoringSession = false
            sessionProjectionState = .empty
            return nil
        }
        restoreGeneration &+= 1
        let generation = restoreGeneration
        isRestoringSession = true
        let scope = profileScopeID
        return Task {
            defer { if isRestoringSession { isRestoringSession = false } }
            do {
                try await sessionRPCClient.connect()
                guard generation == restoreGeneration else { return }
                let scopedLastSessionKey = lastSessionIDKey(for: scope)
                if let savedSessionID = defaults.string(forKey: scopedLastSessionKey),
                    !savedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    await resumeSession(
                        HermesSession(
                            id: savedSessionID, title: "", preview: "", startedAt: nil, messageCount: 0, source: ""),
                        reportFailure: false)
                {
                    return
                }
                guard generation == restoreGeneration else { return }
                // Restoration selects from the shared index; a one-row lookup
                // must never replace the sidebar's complete snapshot.
                let indexLoad = isPollingSessions ? sessionLoadTask : loadSessions()
                await indexLoad?.value
                guard generation == restoreGeneration else { return }
                if case .empty = sessionProjectionState {
                    defaults.removeObject(forKey: scopedLastSessionKey)
                    DebugLog.write("model: no saved session to restore")
                    return
                }
                guard case .ready(let loaded) = sessionProjectionState, let latest = loaded.first else { return }
                _ = await resumeSession(latest, reportFailure: true)
            } catch {
                guard generation == restoreGeneration else { return }
                sessionProjectionState = Self.failedOrStale(
                    sessionProjectionState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
                DebugLog.write(
                    "model: latest session restore failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func resumeSession(_ session: HermesSession, profileID: String? = nil) {
        if focusDetachedSession?(session.id) == true { return }
        if focusProjectedSession?(session, profileID ?? session.profileID ?? profileScopeID) == true { return }
        restoreGeneration &+= 1
        if isRestoringSession { isRestoringSession = false }
        startSessionResume(session, reportFailure: true, profileID: profileID)
    }

    /// Reloads the selected transcript from Hermes rather than patching the
    /// local array. Hermes remains authoritative for completed responses.
    func refreshCurrentSession() async {
        guard let sessionID, !sessionID.isEmpty else { return }
        _ = await resumeSession(
            HermesSession(
                id: sessionID,
                profileID: sessionProfileID ?? profileScopeID,
                title: currentSessionTitle ?? "",
                preview: "",
                startedAt: nil,
                messageCount: messages.count,
                source: HermesFeatureIDs.sessionSource
            ),
            reportFailure: true, reviewUnread: false
        )
    }

    /// Creates a bounded Hermes branch from one completed message. The
    /// source message ID is sent to Hermes so the source conversation remains
    /// unchanged and the returned branch is the only conversation selected.
    func branchConversation(from message: ChatMessage) async {
        guard sessionActionsReady, let sessionID, !sessionID.isEmpty,
            message.role == .hermes,
            message.hasBodyText
        else { return }
        // Hermes has no message anchor: it keeps the first `count` visible
        // rows. Count them locally, with older paged history loaded first.
        await loadTranscriptHistory(through: nil)
        // Count only what Hermes counts: persisted user/assistant rows. Local
        // error cards, feed lines and system-role rows are never copied, and
        // one kanban wake row expands into several local notices.
        var rowCount = 0
        var position: Int?
        var previousWasKanban = false
        for candidate in messages
        where (candidate.role == .user || candidate.role == .hermes)
            && (candidate.hasBodyText || !candidate.images.isEmpty) && !candidate.isError
        {
            if let event = candidate.systemEvent, event.isFeed || event.label == "System" { continue }
            let continuesKanbanRow = candidate.kanbanNotice != nil && previousWasKanban
            previousWasKanban = candidate.kanbanNotice != nil
            if !continuesKanbanRow { rowCount += 1 }
            if candidate.id == message.id {
                position = rowCount - 1
                break
            }
        }
        guard let position else { return }
        let count = await storedBranchCount(through: message) ?? position + 1
        do {
            var params: [String: Any] = [
                "session_id": sessionID,
                "count": count,
            ]
            if let profileID = sessionProfileID ?? profileScopeID, !profileID.isEmpty {
                params["profile"] = profileID
            }
            let result = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.sessionBranch.rawValue,
                params: params
            )
            // `session_id` is a live runtime handle; resume needs the stored key.
            let branchID =
                Self.stableSessionID(from: result)
                ?? (result["session_id"] as? String)
                ?? (result["branch_session_id"] as? String)
                ?? (result["id"] as? String)
            guard let branchID, !branchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = await resumeSession(
                HermesSession(
                    id: branchID,
                    profileID: sessionProfileID ?? profileScopeID,
                    title: "",
                    preview: "",
                    startedAt: nil,
                    messageCount: 0,
                    source: HermesFeatureIDs.sessionSource
                ), reportFailure: true)
        } catch {
            actionErrors.report("Could not branch conversation", error: error)
            DebugLog.write("model: message branch failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
        }
    }

    /// Hermes' `session.branch` keeps the first `count` stored user/assistant
    /// rows with text, including rows the transcript hides (scaffolding,
    /// compaction summaries), so the displayed position undercounts. Count the
    /// stored rows instead; nil falls back to the displayed position.
    func storedBranchCount(through message: ChatMessage) async -> Int? {
        guard let target = storedMessageReferences[message.id]?.rowID, let storageID = sessionStorageID else {
            return nil
        }
        var cursor = TranscriptHistoryCursor(storageSessionID: storageID, profileID: sessionProfileID ?? profileScopeID)
        var rows: [[String: Any]] = []
        do {
            while cursor.hasMore {
                guard
                    let path = TranscriptHistoryPaging.pagePath(
                        sessionID: storageID, profileID: cursor.profileID,
                        limit: TranscriptHistoryPaging.maximumPageRowLimit, offset: cursor.nextOffset
                    ), let page = TranscriptHistoryPaging.page(from: try await sessionRPCClient.fetchHTTP(path))
                else { return nil }
                rows =
                    TranscriptHistoryPaging.advance(
                        &cursor, with: page, limit: TranscriptHistoryPaging.maximumPageRowLimit) + rows
            }
        } catch { return nil }
        var count = 0
        for row in rows {
            guard let role = row["role"] as? String, role == "user" || role == "assistant" else { continue }
            let content = row["content"]
            let text =
                (content as? String)
                ?? ((content as? [[String: Any]])?.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }
                    .joined() ?? "")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            count += 1
            if TranscriptHistoryPaging.rowID(row) == target { return count }
        }
        return nil
    }

    @discardableResult
    func resumeSession(
        _ session: HermesSession, reportFailure: Bool, profileID: String? = nil, reviewUnread: Bool = true
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let task = startSessionResume(
            session, reportFailure: reportFailure, profileID: profileID, reviewUnread: reviewUnread)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Select the identity and its cached transcript together before scheduling Hermes I/O.
    @discardableResult
    func startSessionResume(
        _ session: HermesSession, reportFailure: Bool, profileID: String? = nil, reviewUnread: Bool = true,
        onComplete: ((Bool) -> Void)? = nil
    ) -> Task<Bool, Never> {
        let selectedAt = DispatchTime.now().uptimeNanoseconds
        sessionResumeTask?.cancel()
        let owningProfileID = Self.normalizedProfileID(profileID ?? session.profileID ?? profileScopeID)
        // The session queue uses Hermes' durable storage identity, whereas a
        // resume can expose a different runtime identity. Both identify the
        // same active conversation and must retain its unsent composer text.
        let isRefreshingActiveSession =
            (session.id == sessionID || session.id == sessionStorageID)
            && owningProfileID == Self.normalizedProfileID(sessionProfileID)
        let seenStore = SidebarSessionSeenStore.shared
        let seenAt = seenStore.seenAt(profileID: owningProfileID, sessionID: session.id)
        let reviewCutoff = Date()
        let needsUnreadReview =
            reviewUnread
            && (seenAt != nil || seenStore.isBaselined(profileID: owningProfileID))
        if !isRefreshingActiveSession || needsUnreadReview { unreadDividerMessageID = nil }
        if !isRefreshingActiveSession {
            sessionWorkspace = nil
            pendingWorktreeDirectory = nil
        }
        prepareLeavingTranscript()
        cacheLeavingTranscript()
        if let sessionStorageID {
            cacheAgentState(for: sessionStorageID)
        }
        // Reopening the selected session refreshes its transcript, but is not
        // a session change. Its composer belongs to that active conversation
        // and must survive navigation through a Control page or a repeated
        // click in the session queue.
        if !isRefreshingActiveSession {
            stopVoiceConversation()
            saveComposerDraft()
            restoreComposerDraft(for: SessionComposerDraft.Key(profileID: owningProfileID, sessionID: session.id))

            detachInFlightBotActivities(as: .canceled, keepingSubmitted: true)
        }
        invalidateRuntimeModelOptionsRefresh(keepingCatalog: isRefreshingActiveSession)
        // A refresh re-reads at least as much history as the reader already
        // paged in, so refreshing never collapses the transcript they scrolled.
        let refreshedTranscriptRowCount = isRefreshingActiveSession ? (transcriptHistoryCursor?.nextOffset ?? 0) : 0
        sessionResumeGeneration &+= 1
        transcriptTimelineTask?.cancel()
        transcriptTimelineTask = nil
        resetEffortTransition(keepingSessionReasoning: isRefreshingActiveSession)
        interruptGeneration &+= 1
        let resumeGeneration = sessionResumeGeneration
        sessionPreviewImageTask?.cancel()
        sessionTranscriptImageTask?.cancel()
        sessionSwitchStartedAt = selectedAt
        sessionSwitchToken = UUID().uuidString
        sessionSwitchCachedLayoutRecorded = false
        sessionSwitchFreshLayoutRecorded = false
        let requestedStorageID = isRefreshingActiveSession ? (sessionStorageID ?? session.id) : session.id
        let previewKey = WorkspaceIdentity.session(profileID: owningProfileID, sessionID: requestedStorageID)
        if !isRefreshingActiveSession {
            let isUnprovenAlias =
                session.id == BotService.canonicalBotChatTitle
                || storageIDsByRuntimeID[session.id].map { $0 != session.id } == true
            sessionTranscriptPreview =
                isUnprovenAlias ? nil : openingPreview(for: previewKey, storageID: requestedStorageID)
        }
        positionsAtUnreadOnResume =
            needsUnreadReview && (!isRefreshingActiveSession || messages.isEmpty)
            && sessionTranscriptPreview?.isPreloaded != false
        sessionTranscriptLoadState = sessionTranscriptPreview == nil ? .loading : .refreshing
        recordSessionSwitch(
            "selection", startedAt: selectedAt,
            extra: "cache_hit=\(sessionTranscriptPreview == nil ? 0 : 1)")
        loadPreviewImages()
        let openingRowIDs =
            sessionTranscriptPreview?.rowIDs ?? (isRefreshingActiveSession ? transcriptMessageIDsByRowID : [:])
        transcriptHistoryCursor = nil
        isLoadingEarlierTranscript = false
        isLoadingTranscriptHistory = false
        earlierTranscriptRetryAfter = nil
        transcriptTimeline = []
        transcriptMessageIDsByRowID = [:]
        clearMessagePins()
        sessionID = session.id
        sessionProfileID = owningProfileID
        kanbanAttributionSessionID = session.id
        activeBotProfileID = profileID
        activeBotDisplayName = profileID == nil ? nil : session.displayTitle
        // The old transcript belongs exclusively to the session that was just
        // left. Clear the visible projection before awaiting the new session's
        // resume response; otherwise the old conversation is rendered under
        // the new session ID during that request's loading window.
        if !isRefreshingActiveSession {
            messages = []
            todoPlan = nil
        }
        streamingText.clearPresentation()
        newSessionCreationAuthorized = false
        showClarification(nil)
        presentedClarificationRequestIDs = []
        valuePrompt = nil
        valuePromptError = nil
        clarificationResponseError = nil
        approvalTitle = nil
        approvalText = nil
        approvalDetails = nil
        isRespondingToApproval = false
        isRespondingToClarification = false
        if !isRefreshingActiveSession {
            sessionModelOptionID = nil
            sessionModelValue = session.modelName
        } else if sessionModelValue == nil {
            sessionModelValue = session.modelName
        }
        sessionStorageID = requestedStorageID
        let workspaceKey = WorkspaceIdentity.session(profileID: owningProfileID, sessionID: session.id)
        pendingWorktreeDirectory = pendingWorktreeDirectories[workspaceKey]
        if !isRefreshingActiveSession { restorePendingSendIfPossible(for: composerDraftKey) }
        _ = restoreAgentState(for: session.id)
        isShowingSessions = false
        isSending = false
        status = .working
        interruptState = .idle
        isDiscardingStoppedTurn = false
        sendQueuedPromptAfterInterrupt = false
        reasoningState = nil
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        streamingReasoningBuffer = ""
        streamingMessageID = nil
        streamingMessageSessionID = nil
        streamingMessageIsVisionNotice = false
        // nil, not the "Untitled chat" placeholder, so later titles and auto-naming still apply.
        let resumedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSessionTitle = resumedTitle.isEmpty ? nil : resumedTitle
        restorePendingApproval(for: [session.id])
        let context = SessionResumeContext(
            generation: resumeGeneration, startedAt: selectedAt, token: sessionSwitchToken,
            owningProfileID: owningProfileID, storageID: requestedStorageID, previewKey: previewKey,
            openingRowIDs: openingRowIDs, isRefresh: isRefreshingActiveSession, rowCount: refreshedTranscriptRowCount,
            reviewCutoff: needsUnreadReview ? reviewCutoff : nil, seenAt: seenAt)
        let task = Task { [weak self] in
            guard let self, context.generation == sessionResumeGeneration else { return false }
            let loaded = await finishSessionResume(
                session, reportFailure: reportFailure, profileID: profileID, context: context)
            if context.generation == sessionResumeGeneration {
                sessionResumeTask = nil
                if !Task.isCancelled { onComplete?(loaded) }
            }
            return loaded
        }
        sessionResumeTask = task
        return task
    }

    private struct SessionResumeContext {
        let generation: Int
        let startedAt: UInt64
        let token: String
        let owningProfileID: String?
        let storageID: String
        let previewKey: String
        let openingRowIDs: [Int: UUID]
        let isRefresh: Bool
        let rowCount: Int
        let reviewCutoff: Date?
        let seenAt: Date?
    }

    private func finishSessionResume(
        _ session: HermesSession, reportFailure: Bool, profileID: String?, context: SessionResumeContext
    ) async -> Bool {
        let resumeGeneration = context.generation
        let switchToken = context.token
        let owningProfileID = context.owningProfileID
        let isRefreshingActiveSession = context.isRefresh
        do {
            try Task.checkCancellation()
            let connectionStartedAt = DispatchTime.now().uptimeNanoseconds
            try await sessionRPCClient.connect()
            recordSessionSwitch(
                "connect", startedAt: connectionStartedAt, generation: resumeGeneration, token: switchToken)
            try Task.checkCancellation()
            guard resumeGeneration == sessionResumeGeneration else { return false }
            var resumeParams: [String: Any] = [
                "session_id": session.id,
                "source": HermesFeatureIDs.sessionSource,
                // Page the transcript over REST instead of shipping it whole in
                // this response: long sessions produced multi-megabyte frames
                // and parsed thousands of rows nobody had scrolled to. Hermes
                // hydrates the model history in the background either way.
                "defer_history": true,
                "omit_messages": true,
            ]
            if let owningProfileID, !owningProfileID.isEmpty { resumeParams["profile"] = owningProfileID }
            let resumeStartedAt = DispatchTime.now().uptimeNanoseconds
            let workspaceRevision = sessionWorkspaceRevision
            let reasoningRevision = sessionReasoningRevision
            let result = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.sessionResume.rawValue, params: resumeParams)
            recordSessionSwitch("resume", startedAt: resumeStartedAt, generation: resumeGeneration, token: switchToken)
            try Task.checkCancellation()
            guard resumeGeneration == sessionResumeGeneration, sessionID == session.id else { return false }
            let reportedSessionID = (result["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSessionID = (reportedSessionID?.isEmpty == false) ? reportedSessionID! : session.id
            // The response must prove it belongs to the conversation the user
            // opened. While another session is responding, the gateway can
            // resolve `session.resume` to that active session; adopting its
            // identity and transcript here would project one session's
            // conversation into another, so fail closed instead.
            guard
                Self.resumeResponseProvesSessionOwnership(
                    requestedSessionID: session.id,
                    resolvedSessionID: resolvedSessionID,
                    result: result
                )
            else {
                guard resumeGeneration == sessionResumeGeneration, sessionID == session.id else { return false }
                let safeMessage = "Hermes returned a different session than the one requested. Try opening it again."
                sessionTranscriptLoadState = .failed(safeMessage)
                sessionProjectionState = Self.failedOrStale(sessionProjectionState, safeMessage: safeMessage)
                if reportFailure { status = .offline }
                if reportFailure, sessionTranscriptPreview == nil {
                    status = .offline
                    messages = [
                        ChatMessage(
                            role: .hermes, text: "I couldn't load that conversation: \(safeMessage)",
                            modelName: currentModelName)
                    ]
                    scrollToLatestMessageRequest &+= 1
                }
                DebugLog.write("model: session resume mismatch: requested \(session.id), resolved \(resolvedSessionID)")
                return false
            }
            sessionID = resolvedSessionID
            kanbanAttributionSessionID = Self.kanbanAttributionAfterResume(
                requestedSessionID: session.id,
                resolvedSessionID: resolvedSessionID
            )
            sessionStorageID = Self.stableSessionID(from: result) ?? context.storageID
            storageIDsByRuntimeID[resolvedSessionID] = sessionStorageID
            if workspaceRevision == sessionWorkspaceRevision {
                applySessionWorkspace(result, owner: resolvedSessionID)
            }
            restorePendingApproval(for: [session.id, resolvedSessionID, sessionStorageID])
            persistActiveSessionID(sessionID)
            let model = [result["model"] as? String, result["model_name"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            if let model {
                currentModelName = model
                if let id = sessionModelOptionID {
                    let routedModel =
                        runtimeModelOptions.first(where: { $0.id == id })?.model
                        ?? id.firstIndex(of: "|").map { String(id[id.index(after: $0)...]) }
                    if routedModel != model {
                        sessionModelOptionID = nil
                    }
                }
                sessionModelValue = model
            }
            guard result["messages"] is [[String: Any]] else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            let info = result["info"] as? [String: Any] ?? result
            if reasoningRevision == sessionReasoningRevision, !applyReportedSessionReasoning(info) {
                refreshSessionReasoningVariant(afterConfirmedResume: true)
            }
            refreshRuntimeModelOptions(sessionID: resolvedSessionID, afterConfirmedResume: true)
            var transcriptRows = result["messages"]
            if TranscriptHistoryPaging.resumeResponseDefersTranscript(result),
                let storageID = sessionStorageID
            {
                let tail = try await loadTranscriptTail(
                    storageSessionID: storageID,
                    profileID: owningProfileID,
                    minimumRowCount: context.rowCount,
                    fallbackResumeParams: resumeParams
                )
                guard resumeGeneration == sessionResumeGeneration else { return false }
                transcriptRows = tail.rows
                transcriptHistoryCursor = tail.cursor
            }
            let parseStartedAt = DispatchTime.now().uptimeNanoseconds
            let (parsed, references) = await Self.parseMessagesOffMain(
                transcriptRows,
                defaultBotProfileID: profileID,
                defaultBotDisplayName: profileID == nil ? nil : session.displayTitle
            )
            recordSessionSwitch("parse", startedAt: parseStartedAt, generation: resumeGeneration, token: switchToken)
            try Task.checkCancellation()
            guard resumeGeneration == sessionResumeGeneration else { return false }
            let stable = Self.keepingMessageIDs(
                parsed, previous: context.openingRowIDs,
                previousMessages: sessionTranscriptPreview?.messages ?? (isRefreshingActiveSession ? messages : []))
            let renamed = Dictionary(
                parsed.rowIDs.compactMap { row, id in stable.rowIDs[row].map { (id, $0) } },
                uniquingKeysWith: { first, _ in first })
            let restored = RestoredTranscript(
                messages: stable.messages,
                pendingImages: parsed.pendingImages.map {
                    .init(messageID: renamed[$0.messageID] ?? $0.messageID, fileURLs: $0.fileURLs)
                },
                rowIDs: stable.rowIDs,
                trailingActivity: parsed.trailingActivity)
            transcriptMessageIDsByRowID = restored.rowIDs
            storedMessageReferences = Dictionary(
                references.map { (renamed[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            let resolvedKey = WorkspaceIdentity.session(profileID: owningProfileID, sessionID: sessionStorageID)
            if sessionStorageID != BotService.canonicalBotChatTitle {
                sessionTranscriptCache.store(restored, references: storedMessageReferences, for: resolvedKey)
            }
            let previewImages = Dictionary(
                (sessionTranscriptPreview?.messages ?? []).filter { !$0.images.isEmpty }.map { ($0.id, $0.images) },
                uniquingKeysWith: { first, _ in first })
            let previewPaths = Dictionary(
                (sessionTranscriptPreview?.pendingImages ?? []).map { ($0.messageID, $0.fileURLs) },
                uniquingKeysWith: { first, _ in first })
            let restoredPaths = Dictionary(
                restored.pendingImages.map { ($0.messageID, $0.fileURLs) }, uniquingKeysWith: { first, _ in first })
            let freshMessages = restored.messages.map { message in
                guard let images = previewImages[message.id], let paths = previewPaths[message.id],
                    restoredPaths[message.id] == paths
                else { return message }
                return message.attachingImages(images)
            }
            // A turn that went live while the transcript loaded keeps its row.
            let liveRow = streamingMessageID.flatMap { id in messages.first { $0.id == id } }
            // Mid-turn messages Hermes has not stored yet stay until it does.
            let pendingUserMessages =
                sessionStorageID
                .flatMap { unconfirmedUserMessagesBySessionID.removeValue(forKey: $0) }
                .map { Self.missingUserMessages($0, from: restored.messages) } ?? []
            messages = freshMessages + [liveRow].compactMap { $0 }
            let pendingSends = reconcilePendingSends(
                for: composerDraftKey, restored: restored.messages, rowIDs: restored.rowIDs, replacingTranscript: true)
            messages.append(contentsOf: pendingSends.unmatchedMessages)
            if let stop = sessionStopAttempts[composerDraftKey] {
                if stop.outcome == .accepted, stop.tailPending {
                    isDiscardingStoppedTurn = true
                }
                if stop.outcome == .failed {
                    interruptState = .failed("Hermes could not be interrupted. Try again.")
                } else if stop.outcome == .accepted, result["running"] as? Bool == true {
                    interruptState = .failed("Hermes still reports work in progress after Stop. Try Stop again.")
                }
            }
            let stashedTurnActivity = sessionStorageID.flatMap {
                inFlightTurnActivityBySessionID.removeValue(forKey: $0)
            }
            if liveRow == nil, (result["running"] as? Bool) == true {
                adoptRunningTurn(
                    inflight: result["inflight"] as? [String: Any],
                    activity: stashedTurnActivity ?? restored.trailingActivity)
            } else if liveRow == nil, !restored.trailingActivity.isEmpty {
                showExternalTurn(restored.trailingActivity, generation: resumeGeneration)
            }
            // Only a turn still running can apply them; otherwise Hermes dropped them.
            if streamingMessageID != nil, !pendingUserMessages.isEmpty {
                let index = messages.firstIndex { $0.id == streamingMessageID } ?? messages.endIndex
                messages.insert(contentsOf: Self.missingUserMessages(pendingUserMessages, from: messages), at: index)
            }
            sessionTranscriptImageTask = rehydratePendingTranscriptImages(
                restored.pendingImages,
                requestedSessionID: resolvedSessionID
            )
            if transcriptHistoryCursor?.hasMore == true {
                loadTranscriptTimeline(generation: resumeGeneration)
            }
            if let reviewCutoff = context.reviewCutoff {
                let seenStore = SidebarSessionSeenStore.shared
                let seenAt = context.seenAt
                do {
                    let unread = try await sessionUnreadReplies.project(
                        session: session, profileID: owningProfileID,
                        after: seenAt ?? .distantPast, through: reviewCutoff)
                    guard resumeGeneration == sessionResumeGeneration, !Task.isCancelled else { return false }
                    if unread.count > 0, unread.firstRowID == nil {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    if let rowID = unread.firstRowID {
                        let target = await loadTranscriptHistory(through: rowID)
                        guard resumeGeneration == sessionResumeGeneration, !Task.isCancelled else { return false }
                        guard let target else { throw HermesGateway.GatewayError.malformedResponse }
                        unreadDividerMessageID = target
                    }
                    if seenStore.seenAt(profileID: owningProfileID, sessionID: session.id) == seenAt {
                        seenStore.markSeen(profileID: owningProfileID, sessionID: session.id, at: reviewCutoff)
                        if sessions.first(where: { $0.id == session.id })?.lastUpdatedAt.map({ $0 <= reviewCutoff })
                            ?? true
                        {
                            updateSessionActivity(sessionID: session.id, unread: false)
                        }
                    }
                } catch is CancellationError {
                    return false
                } catch {
                    DebugLog.write(
                        "model: unread history unavailable: \(Self.safeUserDiagnostic(error.localizedDescription))")
                }
            }
            // Questions still waiting on this session (Herm was detached when Hermes asked).
            for request in result["open_requests"] as? [[String: Any]] ?? [] {
                if let event = HermesGateway.event(forServerRequest: request) {
                    receiveGatewayEvent(event.type, params: event.params)
                }
            }
            // Open requests captured above land in the pending map but are not
            // presented by the session-filtered handler; project them now.
            restorePendingClarification(for: [session.id, resolvedSessionID, sessionStorageID])
            restorePendingApproval(for: [session.id, resolvedSessionID, sessionStorageID])
            mergePersistedBotActivities(for: [session.id, sessionStorageID, kanbanAttributionSessionID])
            projectBotMessagesIntoActivity()
            restoreBotDispatches(
                calls: restored.messages.flatMap(\.activity) + restored.trailingActivity,
                rows: transcriptRows as? [[String: Any]] ?? [])
            // Hermes' authoritative plan; todo events missed while detached never replay.
            if let state = result["todo_state"] as? [String: Any], let todos = state["todos"] as? [[String: Any]] {
                // Dated by its last write in the loaded tail; one older than the tail predates every prompt in it.
                let written = (restored.messages.flatMap(\.activity) + restored.trailingActivity)
                    .filter { ["todo_list", "todo"].contains($0.name) }.map(\.startedAt).max()
                applyTodos(
                    todos, sessionID: resolvedSessionID, revision: state["revision"] as? Int ?? 0,
                    updatedAt: written ?? .distantPast)
            }
            sessionTranscriptPreview = nil
            sessionPreviewImageTask?.cancel()
            sessionTranscriptLoadState = .ready
            recordSessionSwitch(
                "fresh_publication", startedAt: context.startedAt, generation: resumeGeneration, token: switchToken)
            refreshSessionFast()
            cacheCurrentAgentState()
            refreshDelegationStatus()
            startDelegationMonitoring()
            if approvalText == nil, clarificationQuestion == nil, streamingMessageID == nil {
                status = .idle
            }
            drainQueuedPromptIfIdle()
            DebugLog.write(
                "model: resumed session \(session.id) (\(messages.count) messages, \(activeSubagents.count) rehydrated agents)"
            )
            Task { await refreshMessagePins() }
            return true
        } catch is CancellationError {
            recordSessionSwitch(
                "cancelled", startedAt: context.startedAt, generation: resumeGeneration, token: switchToken)
            if resumeGeneration == sessionResumeGeneration {
                sessionTranscriptLoadState = .failed("Conversation loading was canceled. Try again.")
                status = .offline
            }
            return false
        } catch {
            guard resumeGeneration == sessionResumeGeneration else { return false }
            let rpcError = error as NSError
            let notFound =
                (rpcError.domain == "Hermes" && (rpcError.userInfo["HermesRPCCode"] as? Int) == 4007)
                || (error as? HermesGateway.GatewayError).map {
                    if case .httpError(404) = $0 { return true }
                    return false
                } == true
            if notFound {
                sessionTranscriptCache.remove(context.previewKey)
                sessionTranscriptPreview = nil
            }
            sessionTranscriptLoadState = .failed("Hermes session data is unavailable. Try refreshing.")
            if effortCatalog == nil, !isLoadingRuntimeModelOptions {
                runtimeModelOptionsError = "Hermes could not load its model catalog."
            }
            sessionProjectionState = Self.failedOrStale(
                sessionProjectionState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
            if reportFailure, !isRefreshingActiveSession, sessionTranscriptPreview == nil {
                status = .offline
                messages = [
                    ChatMessage(
                        role: .hermes,
                        text:
                            "I couldn't load that conversation: \(Self.safeUserDiagnostic(error.localizedDescription))",
                        modelName: currentModelName)
                ]
                scrollToLatestMessageRequest &+= 1
            } else if reportFailure {
                status = .offline
            }
            DebugLog.write("model: session resume failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    /// Sets the project the not-yet-created chat will start in (the new-chat project picker).
    func chooseNewChatProject(_ path: String) {
        guard sessionID == nil, newSessionCreationAuthorized, !isCreatingSession else { return }
        // A worktree chat expects its own folder back from Hermes; a picked project replaces it.
        pendingWorktreeDirectory = nil
        newSessionProjectPath = path
        newSessionProjectWasPicked = true
        objectWillChange.send()
    }

    private func prepareLeavingTranscript() {
        if let sessionStorageID, streamingMessageID != nil {
            inFlightTurnActivityBySessionID[sessionStorageID] = streamingTurnActivity
            unconfirmedUserMessagesBySessionID[sessionStorageID] = Self.unconfirmedUserMessages(
                messages, storedIDs: Set(transcriptMessageIDsByRowID.values))
        }
        commitStreamingMessage()
    }

    /// Keeps the transcript as the reader left it so returning shows it before the fresh resume lands.
    func cacheLeavingTranscript() {
        guard sessionTranscriptLoadState == .ready, sessionTranscriptPreview == nil,
            let id = sessionStorageID, id != BotService.canonicalBotChatTitle
        else { return }
        sessionTranscriptCache.refresh(
            RestoredTranscript(messages: messages, pendingImages: [], rowIDs: transcriptMessageIDsByRowID),
            references: storedMessageReferences,
            for: WorkspaceIdentity.session(profileID: sessionProfileID, sessionID: id))
    }

    func newChat(projectPath: String? = nil) {
        commitStreamingMessage()
        cacheLeavingTranscript()
        sessionWorkspace = nil
        pendingWorktreeDirectory = nil
        sessionResumeTask?.cancel()
        sessionResumeTask = nil
        transcriptTimelineTask?.cancel()
        transcriptTimelineTask = nil
        sessionPreviewImageTask?.cancel()
        sessionPreviewImageTask = nil
        sessionTranscriptImageTask?.cancel()
        sessionTranscriptImageTask = nil
        sessionTranscriptPreview = nil
        sessionTranscriptLoadState = .ready
        detachInFlightBotActivities(as: .canceled, keepingSubmitted: true)
        commitStreamingMessage()
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        streamingMessageGeneration &+= 1
        if let sessionStorageID {
            cacheAgentState(for: sessionStorageID)
        }
        stopVoiceConversation()
        saveComposerDraft()
        sessionResumeGeneration &+= 1
        // A new chat has no session catalog; reload the global one or effort stays unavailable.
        refreshRuntimeModelOptions()
        resetEffortTransition()
        restoreGeneration &+= 1
        interruptGeneration &+= 1
        delegationMonitoringTask?.cancel()
        delegationMonitoringTask = nil
        sessionID = nil
        unreadDividerMessageID = nil
        activeBotProfileID = nil
        activeBotDisplayName = nil
        sessionProfileID = profileScopeID
        sessionStorageID = nil
        transcriptMessageIDsByRowID = [:]
        clearMessagePins()
        newSessionCreationAuthorized = true
        newSessionProjectPath = projectPath
        newSessionProjectWasPicked = false
        restoreComposerDraft(for: composerDraftKey)
        showClarification(nil)
        presentedClarificationRequestIDs = []
        valuePrompt = nil
        valuePromptError = nil
        clarificationResponseError = nil
        approvalTitle = nil
        approvalText = nil
        approvalDetails = nil
        isRespondingToApproval = false
        isRespondingToClarification = false
        defaults.removeObject(forKey: lastSessionIDKey(for: sessionProfileID ?? profileScopeID))
        currentSessionTitle = nil
        currentModelName = nil
        sessionModelOptionID = nil
        sessionModelValue = nil
        messages = []
        activeToolCalls = []
        reasoningState = nil
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        streamingReasoningBuffer = ""
        recentEvents = []
        streamingMessageID = nil
        streamingMessageSessionID = nil
        streamingResponseStartedAt = nil
        streamingMessageBuffer = ""
        streamingMessagePendingPresentationDelta = ""
        streamingMessagePublishedSuffix = ""
        conversationActivityPhase = .idle
        streamingMessageIsVisionNotice = false
        isSending = false
        status = .idle
        interruptState = .idle
        isDiscardingStoppedTurn = false
        sendQueuedPromptAfterInterrupt = false
        isShowingSessions = false
        activeSubagents = []
        sessionAgents = []
        agentActivities = []
        synthesizedSubagentIDs = []
    }

    /// Creates the project-scoped session immediately after a directory is
    /// selected, so the Projects action has an observable result before the
    /// first prompt is typed.
    func startNewChat(in projectPath: String) async {
        newChat(projectPath: projectPath)
        sessionProjectionState = .loading
        do {
            try await sessionRPCClient.connect()
            _ = try await createAuthorizedSession(source: HermesFeatureIDs.sessionSource)
        } catch {
            sessionProjectionState = .failed(safeMessage: "Hermes could not start a new session. Try again.")
            DebugLog.write(
                "model: project chat creation failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
        }
    }

    static func failedOrStale<Value: Equatable & Sendable>(_ state: HermesProjectionState<Value>, safeMessage: String)
        -> HermesProjectionState<Value>
    {
        switch state {
        case .ready(let value), .stale(let value, _): return .stale(value, safeMessage: safeMessage)
        default: return .failed(safeMessage: safeMessage)
        }
    }

    /// Background session refreshes keep the last authoritative list visible.
    /// Only a projection without a successful value may enter the loading state.
    static func refreshingProjectionState<Value: Equatable & Sendable>(_ state: HermesProjectionState<Value>)
        -> HermesProjectionState<Value>
    {
        switch state {
        case .ready(let value), .stale(let value, _):
            return .stale(value, safeMessage: "Refreshing conversations…")
        default:
            return .loading
        }
    }

    func cacheAgentState(for sessionID: String) {
        guard !sessionID.isEmpty else { return }
        agentStateBySessionID[sessionID] = SessionAgentState(
            activeToolCalls: activeToolCalls,
            recentEvents: recentEvents,
            sessionAgents: sessionAgents,
            activeSubagents: activeSubagents,
            agentActivities: agentActivities,
            synthesizedSubagentIDs: synthesizedSubagentIDs
        )
        scheduleAgentStateCommit(agentStateBySessionID, immediate: true)
    }

    /// Makes one session snapshot the sole owner of the visible agent board.
    /// Missing snapshots deliberately produce an empty board so another
    /// session's agents can never leak into a newly opened conversation.
    @discardableResult
    func restoreAgentState(for sessionID: String) -> Bool {
        guard let state = agentStateBySessionID[sessionID] else {
            activeToolCalls = []
            recentEvents = []
            sessionAgents = []
            activeSubagents = []
            agentActivities = []
            synthesizedSubagentIDs = []
            return false
        }
        activeToolCalls = state.activeToolCalls
        recentEvents = state.recentEvents
        sessionAgents = state.sessionAgents
        // Persisted spawn rows are history, not proof that a worker is still
        // live. Only a current delegation.status result or fresh subagent.*
        // event may populate the live map.
        activeSubagents = []
        agentActivities = state.agentActivities
        synthesizedSubagentIDs = state.synthesizedSubagentIDs
        return true
    }

    func markResponseRead() { hasUnreadResponse = false }

    func markPopoverVisible() {
        isPopoverVisible = true
        hasUnreadResponse = false
    }

    /// Debug-only fixture activation. It uses the same session ownership
    /// boundary as gateway events so the streaming fixture can exercise the
    /// production `message.start`/delta/complete path without touching the
    /// transcript array per delta.
    func prepareScrollPerformanceFixtureSession(_ session: HermesSession) {
        sessionID = session.id
        sessionStorageID = session.id
        sessionProfileID = session.profileID
        kanbanAttributionSessionID = session.id
        status = .idle
    }

    func markUnreadUpdate() {
        guard !isPopoverVisible else { return }
        hasUnreadResponse = true
    }

    /// User messages after the last row Hermes returned: sent live, not yet
    /// confirmed by a reload.
    static func unconfirmedUserMessages(_ messages: [ChatMessage], storedIDs: Set<UUID>) -> [ChatMessage] {
        let start = (messages.lastIndex { storedIDs.contains($0.id) }).map { $0 + 1 } ?? 0
        return messages[start...].filter { $0.role == .user }
    }

    /// `pending` minus what Hermes now stores; a stored row may carry extra
    /// context after the typed text, or several steers joined into one.
    static func missingUserMessages(_ pending: [ChatMessage], from restored: [ChatMessage]) -> [ChatMessage] {
        let stored = restored.filter { $0.role == .user }.map(\.text)
        return pending.filter { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            let pendingContent = UserMessageAttachments.split(text)
            return !stored.contains { storedText in
                if storedText.contains(text) { return true }
                guard !pendingContent.names.isEmpty else { return false }
                let storedContent = UserMessageAttachments.split(storedText)
                return pendingContent.names.allSatisfy { storedContent.names.contains($0) }
                    && (pendingContent.text.isEmpty || storedContent.text.contains(pendingContent.text))
            }
        }
    }
}
