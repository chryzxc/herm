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
    /// index. The old projection is cleared before the target request starts;
    /// late responses are rejected by the generation guard below.
    func setProfileScope(_ profileID: String?) {
        let normalized = profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = normalized?.isEmpty == false ? normalized : nil
        let nextUnavailable = next == nil
        guard profileScopeID != next || profileScopeUnavailable != nextUnavailable else {
            if sessionProfileID == nil { sessionProfileID = next }
            return
        }
        profileScopeID = next
        profileScopeUnavailable = nextUnavailable
        sessionProfileID = next
        if let next { defaults.set(next, forKey: profileScopeKey) }
        else { defaults.removeObject(forKey: profileScopeKey) }
        sessionLoadGeneration &+= 1
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        isLoadingSessions = false
        sessions = []
        sessionProjectionState = .loading
        newChat()
        loadSessions()
    }

    func artifactSessions() async throws -> [HermesSession] {
        let rows = try await interruptRPC.artifactSessions()
        var seen = Set<ProfileScopedID>()
        return rows.compactMap { row in
            guard let session = Self.parseSession(row, profileID: row["profile"] as? String),
                  seen.insert(session.scopedID).inserted else { return nil }
            return session
        }
    }

    func artifactMessages(for session: HermesSession, offset: Int) async throws -> [String: Any] {
        // Include pre-compaction output and page through the entire transcript.
        do {
            return try await interruptRPC.sessionMessages(sessionID: session.id, profileID: session.profileID,
                                                       limit: 100, offset: offset, includeCompacted: true)
        } catch HermesGateway.GatewayError.httpError(404) {
            return ["data": []] // pruned since the session list was read
        }
    }

    func resultPeek(for session: HermesSession) async throws -> EdgeResultContent? {
        let started = Date()
        defer { DebugLog.write("workflow: result.read_ms=\(Int(Date().timeIntervalSince(started) * 1000))") }
        let result = try await interruptRPC.sessionMessages(sessionID: session.id, profileID: session.profileID, latest: true)
        return try EdgeResultContent.parse(result, session: session)
    }

    func markQuickResultReviewed(_ snapshot: HermesSession) {
        guard let live = sessions.first(where: { $0.id == snapshot.id && $0.profileID == snapshot.profileID }),
              !live.isWorking, live.lastUpdatedAt == snapshot.lastUpdatedAt else { return }
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
              normalized != "hermes session" else { return }
        currentSessionTitle = trimmed
    }

    @discardableResult
    func loadSessions(profileID: String? = nil, quiet: Bool = false) -> Task<Void, Never>? {
        let scope = profileID ?? profileScopeID
        if profileScopeUnavailable, scope == nil {
            sessions = []
            sessionProjectionState = .empty
            return nil
        }
        guard !isLoadingSessions, !(quiet && isPollingSessions) else { return nil }
        if quiet { isPollingSessions = true } else { isLoadingSessions = true }
        sessionLoadGeneration &+= 1
        let generation = sessionLoadGeneration
        let previousProjectionState = sessionProjectionState
        if !quiet { sessionProjectionState = Self.refreshingProjectionState(sessionProjectionState) }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if quiet { isPollingSessions = false } else { isLoadingSessions = false } }
            do {
                try await sessionRPCClient.connect()
                var params: [String: Any] = ["limit": 50]
                if let scope, !scope.isEmpty { params["profile"] = scope }
                let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionList.rawValue, params: params)
                guard self.sessionLoadGeneration == generation, self.profileScopeID == scope else { return }
                guard let rawSessions = result["sessions"] as? [[String: Any]] else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                await migrateLegacyLocalPins()
                let index = try? await Self.fetchSessionIndex(client: sessionRPCClient, profileID: scope)
                guard self.sessionLoadGeneration == generation, self.profileScopeID == scope else { return }
                if let index { pinnedSessions = index.pinned }
                // session.list rows carry only `started_at`; take recency from
                // the `/api/sessions` rows so a cold start does not show (and
                // sort by) when an old chat began.
                let feedIDs = index?.feedIDs ?? []
                let loaded = rawSessions.compactMap { Self.parseSession($0, profileID: scope) }
                    .filter { !feedIDs.contains($0.id) || $0.id == self.navigationSessionID }
                    .map { Self.withRecency($0, from: index?.lastActive ?? [:]) }
                let working = index?.working
                // The session index can lag behind the live gateway stream.
                // Keep a newer event timestamp until Hermes publishes an equal
                // or newer canonical row, so navigation never regresses its
                // visible “Updated” time after a completed message.
                let merged = self.applyPersistedUnreadState(Self.mergingSessionIndex(loaded, with: sessions, keeping: self.navigationSessionID, working: working))
                sessions = merged
                sessionProjectionState = merged.isEmpty ? .empty : .ready(merged)
                DebugLog.write("model: loaded \(sessions.count) saved sessions")
            } catch {
                guard self.sessionLoadGeneration == generation, self.profileScopeID == scope else { return }
                sessionProjectionState = Self.failedOrStale(previousProjectionState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
                DebugLog.write("model: session list failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
        sessionLoadTask = task
        return task
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
                    _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.sessionClose.rawValue, params: ["session_id": liveID])
                }
            }
            var params: [String: Any] = ["session_id": session.id]
            if let profileID = session.profileID ?? profileScopeID { params["profile"] = profileID }
            _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionDelete.rawValue, params: params)
            sessions.removeAll { $0.id == session.id }
            DebugLog.write("model: deleted saved session \(session.id)")
            return true
        } catch {
            sessionDeletionError = "Could not delete the session: \(Self.safeUserDiagnostic(error.localizedDescription))"
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
            loadSessions()
            return true
        } catch {
            sessionVisibilityError = Self.safeUserDiagnostic(error.localizedDescription)
            return false
        }
    }

    func isSessionPinned(_ sessionID: String) -> Bool {
        pinnedSessions.contains { $0.id == sessionID }
    }

    /// Toggles Hermes' pin flag through the same `PATCH /api/sessions/{id}`
    /// Hermes Desktop uses, so a pin made here shows up there and in the CLI.
    @discardableResult
    func toggleSessionPinned(_ session: HermesSession) async -> Bool {
        guard pinningSessionID == nil else { return false }
        let pinned = !isSessionPinned(session.id)
        pinningSessionID = session.id
        defer { pinningSessionID = nil }
        do {
            try await Self.writeSessionPin(client: sessionRPCClient, sessionID: session.id,
                                           profileID: session.profileID ?? profileScopeID, pinned: pinned)
            // ponytail: optimistic local flip; a list page already in flight can
            // briefly show the old pin until the next load (Desktop fences this).
            if pinned { pinnedSessions.append(session) } else { pinnedSessions.removeAll { $0.id == session.id } }
            loadSessions()
            return true
        } catch {
            DebugLog.write("model: session pin failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    /// `/api/sessions` back-fills every pinned row past `limit`, so the recent
    /// page plus the pins is the full pinned set. Its rows also carry
    /// `last_active`, which session.list omits.
    /// Rows that hold messages yet never called a model: plugin feeds and
    /// delivery logs, not conversations. They show inside the chat they
    /// report on, so the session list leaves them out.
    static func isModellessFeed(_ row: [String: Any]) -> Bool {
        let messages = (row["message_count"] as? NSNumber)?.intValue ?? 0
        guard messages > 0, let calls = (row["api_call_count"] as? NSNumber)?.intValue, calls == 0 else { return false }
        return ((row["model"] as? String) ?? "").isEmpty
    }

    static func fetchSessionIndex(client: HermesRPCClientProtocol, profileID: String?) async throws -> (pinned: [HermesSession], lastActive: [String: Date], feedIDs: Set<String>, working: Set<String>) {
        var path = "/api/sessions?limit=100&order=recent"
        if let profileID, !profileID.isEmpty,
           let encoded = profileID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&profile=\(encoded)"
        }
        guard let rows = try await client.fetchHTTP(path)["sessions"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        let lastActive = Dictionary(rows.compactMap { row in
            parseSession(row, profileID: profileID).flatMap { session in session.updatedAt.map { (session.id, $0) } }
        }, uniquingKeysWith: max)
        let feedIDs = Set(rows.filter(isModellessFeed).compactMap { $0["id"] as? String })
        // `is_active` stays true for 5 min after the last write; a tighter
        // window keeps the spinner from lingering once a turn has finished.
        let working = Set(rows.compactMap { row -> String? in
            guard row["is_active"] as? Bool == true, let id = row["id"] as? String,
                  let date = parseSession(row, profileID: profileID)?.updatedAt,
                  Date().timeIntervalSince(date) < 90 else { return nil }
            return id
        })
        let pinned = rows.filter { $0["pinned"] as? Bool == true }.compactMap { parseSession($0, profileID: profileID) }.map { session in
            guard working.contains(session.id) else { return session }
            return HermesSession(id: session.id, profileID: session.profileID, title: session.title, preview: session.preview,
                                 startedAt: session.startedAt, updatedAt: session.updatedAt, messageCount: session.messageCount,
                                 source: session.source, isHidden: session.isHidden, isWorking: true, hasUnreadUpdate: session.hasUnreadUpdate)
        }
        return (pinned, lastActive, feedIDs, working)
    }

    static func withRecency(_ session: HermesSession, from lastActive: [String: Date]) -> HermesSession {
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
            hasUnreadUpdate: session.hasUnreadUpdate
        )
    }

    static func writeSessionPin(client: HermesRPCClientProtocol, sessionID: String, profileID: String?, pinned: Bool) async throws {
        guard let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        var body: [String: Any] = ["pinned": pinned]
        if let profileID, !profileID.isEmpty { body["profile"] = profileID }
        _ = try await client.sendHTTP("PATCH", path: "/api/sessions/\(encoded)", body: body)
    }

    /// One-time move of pins older Herm builds kept in UserDefaults into Hermes.
    /// Pins that fail to write (other than a deleted session) stay for the next load.
    func migrateLegacyLocalPins() async {
        let key = "hermes.dock.pinned-sessions.v1"
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let references = saved["references"] as? [[String: String]] else { return }
        var remaining: [[String: String]] = []
        for reference in references {
            guard let sessionID = reference["sessionID"] else { continue }
            do {
                try await Self.writeSessionPin(client: sessionRPCClient, sessionID: sessionID,
                                               profileID: reference["profileID"], pinned: true)
            } catch HermesGateway.GatewayError.httpError(404), HermesGateway.GatewayError.httpRefused(404, _) {
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
            var params: [String: Any] = ["session_id": session.id, "title": cleanTitle]
            if let profileID = session.profileID ?? profileScopeID { params["profile"] = profileID }
            _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionTitle.rawValue, params: params)
            if session.id == sessionID { currentSessionTitle = cleanTitle }
            loadSessions()
            return true
        } catch {
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
        guard !profileScopeUnavailable else {
            isRestoringSession = false
            sessionProjectionState = .empty
            return nil
        }
        restoreGeneration &+= 1
        let generation = restoreGeneration
        isRestoringSession = true
        let previousProjectionState = sessionProjectionState
        let scope = profileScopeID
        sessionProjectionState = .loading
        return Task {
            defer { isRestoringSession = false }
            do {
                try await sessionRPCClient.connect()
                let scopedLastSessionKey = lastSessionIDKey(for: scope)
                if let savedSessionID = defaults.string(forKey: scopedLastSessionKey),
                   !savedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   await resumeSession(HermesSession(id: savedSessionID, title: "", preview: "", startedAt: nil, messageCount: 0, source: ""), reportFailure: false) {
                    return
                }
                var listParams: [String: Any] = ["limit": 1]
                if let scope, !scope.isEmpty { listParams["profile"] = scope }
                let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionList.rawValue, params: listParams)
                guard generation == restoreGeneration else { return }
                guard let rawSessions = result["sessions"] as? [[String: Any]] else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let latest = rawSessions.compactMap { Self.parseSession($0, profileID: scope) }.first
                guard generation == restoreGeneration else { return }
                guard let latest else {
                    sessionProjectionState = .empty
                    defaults.removeObject(forKey: scopedLastSessionKey)
                    DebugLog.write("model: no saved session to restore")
                    return
                }
                guard generation == restoreGeneration else { return }
                sessions = [latest]
                sessionProjectionState = .ready([latest])
                guard generation == restoreGeneration else { return }
                _ = await resumeSession(latest, reportFailure: true)
            } catch {
                guard generation == restoreGeneration else { return }
                sessionProjectionState = Self.failedOrStale(previousProjectionState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
                DebugLog.write("model: latest session restore failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func resumeSession(_ session: HermesSession) {
        Task { _ = await resumeSession(session, reportFailure: true) }
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
                source: "herm"
            ),
            reportFailure: true
        )
    }

    /// Creates a bounded Hermes branch from one completed message. The
    /// source message ID is sent to Hermes so the source conversation remains
    /// unchanged and the returned branch is the only conversation selected.
    func branchConversation(from message: ChatMessage) async {
        guard let sessionID, !sessionID.isEmpty,
              message.role == .hermes,
              message.hasBodyText else { return }
        // Hermes has no message anchor: it keeps the first `count` visible
        // rows. Count them locally, with older paged history loaded first.
        await loadTranscriptHistory(through: nil)
        // Count only what Hermes counts: persisted user/assistant rows. Local
        // error cards, feed lines and system-role rows are never copied, and
        // one kanban wake row expands into several local notices.
        var rowCount = 0
        var position: Int?
        var previousWasKanban = false
        for candidate in messages where (candidate.role == .user || candidate.role == .hermes)
            && (candidate.hasBodyText || !candidate.images.isEmpty) && !candidate.isError {
            if let event = candidate.systemEvent, event.isFeed || event.label == "System" { continue }
            let continuesKanbanRow = candidate.kanbanNotice != nil && previousWasKanban
            previousWasKanban = candidate.kanbanNotice != nil
            if !continuesKanbanRow { rowCount += 1 }
            if candidate.id == message.id { position = rowCount - 1; break }
        }
        guard let position else { return }
        let count = await storedBranchCount(through: message) ?? position + 1
        do {
            var params: [String: Any] = [
                "session_id": sessionID,
                "count": count
            ]
            if let profileID = sessionProfileID ?? profileScopeID, !profileID.isEmpty {
                params["profile"] = profileID
            }
            let result = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.sessionBranch.rawValue,
                params: params
            )
            // `session_id` is a live runtime handle; resume needs the stored key.
            let branchID = Self.stableSessionID(from: result)
                ?? (result["session_id"] as? String)
                ?? (result["branch_session_id"] as? String)
                ?? (result["id"] as? String)
            guard let branchID, !branchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            _ = await resumeSession(HermesSession(
                id: branchID,
                profileID: sessionProfileID ?? profileScopeID,
                title: "",
                preview: "",
                startedAt: nil,
                messageCount: 0,
                source: "herm"
            ), reportFailure: true)
        } catch {
            DebugLog.write("model: message branch failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
        }
    }

    /// Hermes' `session.branch` keeps the first `count` stored user/assistant
    /// rows with text, including rows the transcript hides (scaffolding,
    /// compaction summaries), so the displayed position undercounts. Count the
    /// stored rows instead; nil falls back to the displayed position.
    func storedBranchCount(through message: ChatMessage) async -> Int? {
        guard let target = storedMessageReferences[message.id]?.rowID, let storageID = sessionStorageID else { return nil }
        var cursor = TranscriptHistoryCursor(storageSessionID: storageID, profileID: sessionProfileID ?? profileScopeID)
        var rows: [[String: Any]] = []
        do {
            while cursor.hasMore {
                guard let path = TranscriptHistoryPaging.pagePath(
                    sessionID: storageID, profileID: cursor.profileID,
                    limit: TranscriptHistoryPaging.maximumPageRowLimit, offset: cursor.nextOffset
                ), let page = TranscriptHistoryPaging.page(from: try await sessionRPCClient.fetchHTTP(path)) else { return nil }
                rows = TranscriptHistoryPaging.advance(&cursor, with: page, limit: TranscriptHistoryPaging.maximumPageRowLimit) + rows
            }
        } catch { return nil }
        var count = 0
        for row in rows {
            guard let role = row["role"] as? String, role == "user" || role == "assistant" else { continue }
            let content = row["content"]
            let text = (content as? String) ?? ((content as? [[String: Any]])?.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.joined() ?? "")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            count += 1
            if TranscriptHistoryPaging.rowID(row) == target { return count }
        }
        return nil
    }

    @discardableResult
    func resumeSession(_ session: HermesSession, reportFailure: Bool, profileID: String? = nil) async -> Bool {
        let owningProfileID = profileID ?? session.profileID ?? profileScopeID
        // The session queue uses Hermes' durable storage identity, whereas a
        // resume can expose a different runtime identity. Both identify the
        // same active conversation and must retain its unsent composer text.
        let isRefreshingActiveSession = session.id == sessionID || session.id == sessionStorageID
        if let sessionStorageID, streamingMessageID != nil {
            inFlightTurnActivityBySessionID[sessionStorageID] = streamingTurnActivity
            unconfirmedUserMessagesBySessionID[sessionStorageID] = Self.unconfirmedUserMessages(
                messages, storedIDs: Set(transcriptMessageIDsByRowID.values)
            )
        }
        commitStreamingMessage()
        if let sessionStorageID {
            cacheAgentState(for: sessionStorageID)
        }
        // Reopening the selected session refreshes its transcript, but is not
        // a session change. Its composer belongs to that active conversation
        // and must survive navigation through a Control page or a repeated
        // click in the session queue.
        if !isRefreshingActiveSession {
            resetComposerForSessionChange()
            invalidateRuntimeModelOptionsRefresh()
            if profileID == nil {
                detachInFlightBotActivities(as: .canceled)
            }
        }
        // A refresh re-reads at least as much history as the reader already
        // paged in, so refreshing never collapses the transcript they scrolled.
        let refreshedTranscriptRowCount = isRefreshingActiveSession ? (transcriptHistoryCursor?.nextOffset ?? 0) : 0
        sessionResumeGeneration &+= 1
        interruptGeneration &+= 1
        let resumeGeneration = sessionResumeGeneration
        transcriptHistoryCursor = nil
        isLoadingEarlierTranscript = false
        isLoadingTranscriptHistory = false
        earlierTranscriptRetryAfter = nil
        transcriptTimeline = []
        transcriptMessageIDsByRowID = [:]
        clearMessagePins()
        sessionID = session.id
        updateSessionActivity(sessionID: session.id, unread: false)
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
        sessionModelOptionID = nil
        sessionModelValue = nil
        sessionReasoningVariant = nil
        sessionStorageID = session.id
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
        currentSessionTitle = session.displayTitle
        restorePendingApproval(for: [session.id])
        do {
            try await sessionRPCClient.connect()
            var resumeParams: [String: Any] = [
                "session_id": session.id,
                "source": "herm",
                // Page the transcript over REST instead of shipping it whole in
                // this response: long sessions produced multi-megabyte frames
                // and parsed thousands of rows nobody had scrolled to. Hermes
                // hydrates the model history in the background either way.
                "defer_history": true,
                "omit_messages": true,
            ]
            if let owningProfileID, !owningProfileID.isEmpty { resumeParams["profile"] = owningProfileID }
            let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionResume.rawValue, params: resumeParams)
            guard resumeGeneration == sessionResumeGeneration, sessionID == session.id else { return false }
            let reportedSessionID = (result["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedSessionID = (reportedSessionID?.isEmpty == false) ? reportedSessionID! : session.id
            // The response must prove it belongs to the conversation the user
            // opened. While another session is responding, the gateway can
            // resolve `session.resume` to that active session; adopting its
            // identity and transcript here would project one session's
            // conversation into another, so fail closed instead.
            guard Self.resumeResponseProvesSessionOwnership(
                requestedSessionID: session.id,
                resolvedSessionID: resolvedSessionID,
                result: result
            ) else {
                guard resumeGeneration == sessionResumeGeneration, sessionID == session.id else { return false }
                let safeMessage = "Hermes returned a different session than the one requested. Try opening it again."
                sessionProjectionState = Self.failedOrStale(sessionProjectionState, safeMessage: safeMessage)
                if reportFailure {
                    status = .offline
                    messages = [ChatMessage(role: .hermes, text: "I couldn't load that conversation: \(safeMessage)", modelName: currentModelName)]
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
            sessionStorageID = Self.stableSessionID(from: result) ?? session.id
            storageIDsByRuntimeID[resolvedSessionID] = sessionStorageID
            restorePendingApproval(for: [session.id, resolvedSessionID, sessionStorageID])
            persistActiveSessionID(sessionID)
            let model = (result["model"] as? String) ?? (result["model_name"] as? String)
            if let model {
                currentModelName = model
                sessionModelValue = model
            }
            refreshSessionModelOptions()
            refreshSessionReasoningVariant()
            guard result["messages"] is [[String: Any]] else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            var transcriptRows = result["messages"]
            if TranscriptHistoryPaging.resumeResponseDefersTranscript(result),
               let storageID = sessionStorageID {
                let tail = try await loadTranscriptTail(
                    storageSessionID: storageID,
                    profileID: owningProfileID,
                    minimumRowCount: refreshedTranscriptRowCount,
                    fallbackResumeParams: resumeParams
                )
                guard resumeGeneration == sessionResumeGeneration else { return false }
                transcriptRows = tail.rows
                transcriptHistoryCursor = tail.cursor
            }
            let restored = await Self.parseMessagesOffMain(
                transcriptRows,
                defaultBotProfileID: profileID,
                defaultBotDisplayName: profileID == nil ? nil : session.displayTitle
            )
            guard resumeGeneration == sessionResumeGeneration else { return false }
            transcriptMessageIDsByRowID = restored.rowIDs
            storedMessageReferences = StoredMessageReference.references(rows: transcriptRows, rowIDs: restored.rowIDs)
            // A turn that went live while the transcript loaded keeps its row.
            let liveRow = streamingMessageID.flatMap { id in messages.first { $0.id == id } }
            // Mid-turn messages Hermes has not stored yet stay until it does.
            let pendingUserMessages = sessionStorageID
                .flatMap { unconfirmedUserMessagesBySessionID.removeValue(forKey: $0) }
                .map { Self.missingUserMessages($0, from: restored.messages) } ?? []
            messages = restored.messages + [liveRow].compactMap { $0 }
            let stashedTurnActivity = sessionStorageID.flatMap { inFlightTurnActivityBySessionID.removeValue(forKey: $0) }
            if liveRow == nil, (result["running"] as? Bool) == true {
                adoptRunningTurn(inflight: result["inflight"] as? [String: Any], activity: stashedTurnActivity ?? restored.trailingActivity)
            } else if liveRow == nil, !restored.trailingActivity.isEmpty {
                showExternalTurn(restored.trailingActivity, generation: resumeGeneration)
            }
            // Only a turn still running can apply them; otherwise Hermes dropped them.
            if streamingMessageID != nil, !pendingUserMessages.isEmpty {
                let index = messages.firstIndex { $0.id == streamingMessageID } ?? messages.endIndex
                messages.insert(contentsOf: Self.missingUserMessages(pendingUserMessages, from: messages), at: index)
            }
            rehydratePendingTranscriptImages(
                restored.pendingImages,
                requestedSessionID: session.id
            )
            if transcriptHistoryCursor?.hasMore == true {
                loadTranscriptTimeline(generation: resumeGeneration)
            }
            restorePendingClarification(for: [session.id, resolvedSessionID, sessionStorageID])
            // Questions still waiting on this session (Herm was detached when Hermes asked).
            for request in result["open_requests"] as? [[String: Any]] ?? [] {
                if let event = HermesGateway.event(forServerRequest: request) {
                    receiveGatewayEvent(event.type, params: event.params)
                }
            }
            // Open requests captured above land in the pending map but are not
            // presented by the session-filtered handler; project them now.
            restorePendingApproval(for: [session.id, resolvedSessionID, sessionStorageID])
            mergePersistedBotActivities(for: [session.id, sessionStorageID, kanbanAttributionSessionID])
            projectBotMessagesIntoActivity()
            restoreBotDispatches(calls: restored.messages.flatMap(\.activity) + restored.trailingActivity,
                                 rows: transcriptRows as? [[String: Any]] ?? [])
            // Hermes' authoritative plan; todo events missed while detached never replay.
            if let todos = (result["todo_state"] as? [String: Any])?["todos"] as? [[String: Any]] {
                applyTodos(todos, sessionID: resolvedSessionID)
            }
            scrollToLatestMessageRequest &+= 1
            cacheCurrentAgentState()
            refreshDelegationStatus()
            startDelegationMonitoring()
            if approvalText == nil, clarificationQuestion == nil, streamingMessageID == nil {
                status = .idle
            }
            DebugLog.write("model: resumed session \(session.id) (\(messages.count) messages, \(activeSubagents.count) rehydrated agents)")
            Task { await refreshMessagePins() }
            return true
        } catch {
            guard resumeGeneration == sessionResumeGeneration, sessionID == session.id else { return false }
            sessionProjectionState = Self.failedOrStale(sessionProjectionState, safeMessage: "Hermes session data is unavailable. Try refreshing.")
            if reportFailure, !isRefreshingActiveSession {
                status = .offline
                messages = [ChatMessage(role: .hermes, text: "I couldn't load that conversation: \(Self.safeUserDiagnostic(error.localizedDescription))", modelName: currentModelName)]
                scrollToLatestMessageRequest &+= 1
            } else if reportFailure {
                status = .offline
            }
            DebugLog.write("model: session resume failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return false
        }
    }

    func resetComposerForSessionChange() {
        composer.reset()
        attachedContexts = []
        clearPendingImages()
        removePendingPDF()
    }

    func newChat(projectPath: String? = nil) {
        detachInFlightBotActivities(as: .canceled)
        commitStreamingMessage()
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        streamingMessageGeneration &+= 1
        if let sessionStorageID {
            cacheAgentState(for: sessionStorageID)
        }
        resetComposerForSessionChange()
        invalidateRuntimeModelOptionsRefresh()
        sessionResumeGeneration &+= 1
        restoreGeneration &+= 1
        interruptGeneration &+= 1
        delegationMonitoringTask?.cancel()
        delegationMonitoringTask = nil
        sessionID = nil
        activeBotProfileID = nil
        activeBotDisplayName = nil
        sessionProfileID = profileScopeID
        sessionStorageID = nil
        transcriptMessageIDsByRowID = [:]
        clearMessagePins()
        newSessionCreationAuthorized = true
        newSessionProjectPath = projectPath
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
        sessionReasoningVariant = nil
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
        streamingMessagePublishedText = ""
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
            _ = try await createAuthorizedSession(source: "herm")
        } catch {
            sessionProjectionState = .failed(safeMessage: "Hermes could not start a new session. Try again.")
            DebugLog.write("model: project chat creation failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
        }
    }

    static func failedOrStale<Value: Equatable & Sendable>(_ state: HermesProjectionState<Value>, safeMessage: String) -> HermesProjectionState<Value> {
        switch state {
        case .ready(let value), .stale(let value, _): return .stale(value, safeMessage: safeMessage)
        default: return .failed(safeMessage: safeMessage)
        }
    }

    /// Background session refreshes keep the last authoritative list visible.
    /// Only a projection without a successful value may enter the loading state.
    static func refreshingProjectionState<Value: Equatable & Sendable>(_ state: HermesProjectionState<Value>) -> HermesProjectionState<Value> {
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
        agentStateStore.save(agentStateBySessionID)
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
            return !text.isEmpty && !stored.contains { $0.contains(text) }
        }
    }
}
