import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// Reads the newest stored rows of a paged resume. When the REST read is
    /// unavailable, falls back to one resume that inlines the transcript
    /// (the session is live by now, so Hermes answers from memory).
    func loadTranscriptTail(
        storageSessionID: String,
        profileID: String?,
        minimumRowCount: Int,
        fallbackResumeParams: [String: Any]
    ) async throws -> (rows: [[String: Any]], cursor: TranscriptHistoryCursor?) {
        let generation = sessionResumeGeneration
        let cursor = TranscriptHistoryCursor(storageSessionID: storageSessionID, profileID: profileID)
        let limit = min(
            TranscriptHistoryPaging.maximumPageRowLimit,
            max(TranscriptHistoryPaging.pageRowLimit, minimumRowCount)
        )
        do {
            let loaded = try await fetchEarlierTranscriptRows(
                from: cursor,
                limit: limit,
                minimumDisplayRows: ConversationMessageWindow.initialLimit
            )
            return (loaded.rows, loaded.cursor)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard generation == sessionResumeGeneration else { throw CancellationError() }
            DebugLog.write(
                "model: transcript page read failed, resuming inline: \(Self.safeUserDiagnostic(error.localizedDescription))"
            )
            var params = fallbackResumeParams
            params.removeValue(forKey: "defer_history")
            params.removeValue(forKey: "omit_messages")
            let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionResume.rawValue, params: params)
            try Task.checkCancellation()
            guard generation == sessionResumeGeneration else { throw CancellationError() }
            guard let requested = params["session_id"] as? String,
                Self.resumeResponseProvesSessionOwnership(
                    requestedSessionID: requested,
                    resolvedSessionID: (result["session_id"] as? String) ?? requested,
                    result: result),
                Self.stableSessionID(from: result).map({ $0 == storageSessionID }) ?? true,
                let rows = result["messages"] as? [[String: Any]]
            else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            return (rows, nil)
        }
    }

    /// Reads older pages until at least `minimumDisplayRows` visible messages
    /// arrive or history is exhausted. Returned rows are display-projected and
    /// chronological.
    func fetchEarlierTranscriptRows(
        from start: TranscriptHistoryCursor,
        limit: Int,
        minimumDisplayRows: Int,
        maximumPages: Int = TranscriptHistoryPaging.maximumPagesPerLoad,
        through targetRowID: Int? = nil
    ) async throws -> (rows: [[String: Any]], cursor: TranscriptHistoryCursor) {
        var cursor = start
        var collected: [[String: Any]] = []
        var pagesRead = 0
        let generation = sessionResumeGeneration
        while cursor.hasMore, pagesRead < maximumPages {
            try Task.checkCancellation()
            guard generation == sessionResumeGeneration else { throw CancellationError() }
            guard
                let path = TranscriptHistoryPaging.pagePath(
                    sessionID: cursor.storageSessionID,
                    profileID: cursor.profileID,
                    limit: limit,
                    offset: cursor.nextOffset
                )
            else { throw HermesGateway.GatewayError.malformedResponse }
            let fetchStartedAt = DispatchTime.now().uptimeNanoseconds
            guard let page = TranscriptHistoryPaging.page(from: try await sessionRPCClient.fetchHTTP(path)) else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            try Task.checkCancellation()
            guard generation == sessionResumeGeneration else { throw CancellationError() }
            recordSessionSwitch(
                "history_fetch", startedAt: fetchStartedAt, extra: "page=\(pagesRead + 1) rows=\(page.returned)")
            pagesRead += 1
            let fresh = TranscriptHistoryPaging.advance(&cursor, with: page, limit: limit)
            let projectStartedAt = DispatchTime.now().uptimeNanoseconds
            let projected = await Self.projectStoredRowsOffMain(fresh)
            try Task.checkCancellation()
            guard generation == sessionResumeGeneration else { throw CancellationError() }
            recordSessionSwitch("history_project", startedAt: projectStartedAt, extra: "rows=\(fresh.count)")
            collected = projected + collected
            if let targetRowID {
                if cursor.seenRowIDs.contains(targetRowID) { break }
            } else if collected.filter({ !(($0["text"] as? String) ?? "").isEmpty }).count >= minimumDisplayRows {
                break
            }
        }
        return (collected, cursor)
    }

    /// A stored turn with tool calls but no reply, that this gateway is not
    /// running: a Bot's `hermes -p <bot> chat -Q` writes straight to its
    /// profile's state.db, so no events reach Herm. Show its activity as a
    /// live turn and re-read stored rows until the reply lands.
    func showExternalTurn(_ activity: [ActiveToolCall], generation: Int) {
        // ponytail: idle-time heuristic; a single tool call quieter than this
        // reads as finished. Switch to a Hermes liveness flag if one appears.
        let idleLimit: TimeInterval = 15 * 60
        guard let latest = activity.map(\.startedAt).max(), Date().timeIntervalSince(latest) < idleLimit else {
            // Long dead: keep what it did visible instead of dropping it.
            messages.append(
                ChatMessage(
                    role: .hermes, text: "", timestamp: activity.first?.startedAt ?? Date(),
                    botProfileID: activeBotProfileID, botDisplayName: activeBotDisplayName, activity: activity))
            return
        }
        adoptRunningTurn(inflight: nil, activity: activity)
        externalTurnWatchTask?.cancel()
        externalTurnWatchTask = Task { @MainActor [weak self] in
            var lastChange = Date()
            var signature = ""
            var rowsSignature = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, generation == self.sessionResumeGeneration,
                    self.streamingMessageID != nil,
                    let storageID = self.sessionStorageID
                else { return }
                let limit = min(
                    TranscriptHistoryPaging.maximumPageRowLimit,
                    max(TranscriptHistoryPaging.pageRowLimit, self.transcriptHistoryCursor?.nextOffset ?? 0)
                )
                guard
                    let loaded = try? await self.fetchEarlierTranscriptRows(
                        from: TranscriptHistoryCursor(storageSessionID: storageID, profileID: self.sessionProfileID),
                        limit: limit,
                        minimumDisplayRows: ConversationMessageWindow.initialLimit
                    ), generation == self.sessionResumeGeneration, self.streamingMessageID != nil
                else { continue }
                // Stored rows only append, so an unchanged tail means nothing to re-parse on the main actor.
                let tail = loaded.rows.last
                let tailID = tail.flatMap { TranscriptHistoryPaging.rowID($0, key: "row_id") } ?? -1
                let nextRows = "\(loaded.rows.count)|\(tailID)|\(Self.messageText(tail?["content"]).utf8.count)"
                guard nextRows != rowsSignature else {
                    if Date().timeIntervalSince(lastChange) > idleLimit {
                        self.endExternalTurn(commit: true)
                        return
                    }
                    continue
                }
                rowsSignature = nextRows
                let restored = Self.parseMessages(
                    loaded.rows, defaultBotProfileID: self.activeBotProfileID,
                    defaultBotDisplayName: self.activeBotDisplayName)
                let next = Self.externalTurnSignature(restored.trailingActivity) + "|\(restored.messages.count)"
                guard next != signature else {
                    if Date().timeIntervalSince(lastChange) > idleLimit {
                        self.endExternalTurn(commit: true)
                        return
                    }
                    continue
                }
                signature = next
                lastChange = Date()
                let liveRow = self.messages.first { $0.id == self.streamingMessageID }
                let stable = Self.keepingMessageIDs(restored, previous: self.transcriptMessageIDsByRowID)
                self.transcriptHistoryCursor = loaded.cursor
                self.transcriptMessageIDsByRowID = stable.rowIDs
                self.storedMessageReferences = StoredMessageReference.references(
                    rows: loaded.rows, rowIDs: stable.rowIDs)
                self.messages = stable.messages + [liveRow].compactMap { $0 }
                if restored.trailingActivity.isEmpty {
                    self.endExternalTurn(commit: false)
                    self.scrollToLatestMessageRequest &+= 1
                    return
                }
                self.streamingTurnActivity = restored.trailingActivity
            }
        }
    }

    /// A re-read transcript keeps the IDs its stored rows already had, so
    /// SwiftUI updates rows in place instead of rebuilding and re-measuring
    /// every message on each 3s poll of a running Bot turn.
    static func keepingMessageIDs(_ restored: RestoredTranscript, previous: [Int: UUID]) -> (
        messages: [ChatMessage], rowIDs: [Int: UUID]
    ) {
        var renamed: [UUID: UUID] = [:]
        var taken = Set<UUID>()
        for (rowID, id) in restored.rowIDs.sorted(by: { $0.key < $1.key }) where renamed[id] == nil {
            guard let old = previous[rowID], taken.insert(old).inserted else { continue }
            renamed[id] = old
        }
        let messages = restored.messages.map { message in
            var message = message
            message.id = renamed[message.id] ?? message.id
            return message
        }
        return (messages, restored.rowIDs.mapValues { renamed[$0] ?? $0 })
    }

    private static func externalTurnSignature(_ activity: [ActiveToolCall]) -> String {
        activity.map { "\($0.id):\($0.result?.count ?? -1)" }.joined(separator: ",")
    }

    /// Ends the mirrored turn: `commit` keeps its activity as a reply row,
    /// otherwise the stored reply already replaced it.
    private func endExternalTurn(commit: Bool) {
        if commit { commitStreamingMessage() } else { discardStreamingMessage() }
        streamingMessageID = nil
        streamingTurnActivity = []
        status = .idle
        conversationActivityPhase = .idle
        isSending = false
        if let sessionStorageID { updateSessionActivity(sessionID: sessionStorageID, isWorking: false) }
    }

    var canLoadEarlierTranscript: Bool {
        guard let cursor = transcriptHistoryCursor, cursor.hasMore, !isLoadingEarlierTranscript else { return false }
        return cursor.storageSessionID == sessionStorageID
    }

    /// Prepends the next page of stored history once the reader reaches the
    /// oldest loaded message.
    func loadEarlierTranscriptIfAvailable() {
        guard canLoadEarlierTranscript, let cursor = transcriptHistoryCursor else { return }
        if let retryAfter = earlierTranscriptRetryAfter, retryAfter > Date() { return }
        isLoadingEarlierTranscript = true
        let generation = sessionResumeGeneration
        Task { @MainActor in
            defer {
                if generation == sessionResumeGeneration { isLoadingEarlierTranscript = false }
            }
            do {
                let loaded = try await fetchEarlierTranscriptRows(
                    from: cursor,
                    limit: TranscriptHistoryPaging.pageRowLimit,
                    minimumDisplayRows: 1
                )
                guard generation == sessionResumeGeneration,
                    sessionStorageID == cursor.storageSessionID
                else { return }
                earlierTranscriptRetryAfter = nil
                prependEarlierTranscript(loaded.rows, cursor: loaded.cursor)
            } catch {
                guard generation == sessionResumeGeneration else { return }
                // Scroll events call this continuously at the top edge; back
                // off instead of re-requesting a failing page on every frame.
                earlierTranscriptRetryAfter = Date().addingTimeInterval(5)
                DebugLog.write(
                    "model: earlier transcript page failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func prependEarlierTranscript(_ rows: [[String: Any]], cursor: TranscriptHistoryCursor) {
        transcriptHistoryCursor = cursor
        // Loaded prompts leave the navigator's unloaded list with the cursor.
        messageNavigatorNeedsRefresh = true
        let restored = Self.parseMessages(
            rows,
            defaultBotProfileID: activeBotProfileID,
            defaultBotDisplayName: activeBotDisplayName
        )
        guard !restored.messages.isEmpty else { return }
        let reconciliation = reconcilePendingSends(
            for: composerDraftKey, restored: restored.messages, rowIDs: restored.rowIDs, visibleHistory: true)
        var previous = transcriptMessageIDsByRowID
        for match in reconciliation.resolved where previous[match.rowID] == nil {
            previous[match.rowID] = match.messageID
        }
        let stable = Self.keepingMessageIDs(restored, previous: previous)
        let renamed = Dictionary(
            restored.rowIDs.compactMap { row, id in stable.rowIDs[row].map { (id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let superseded = Set(reconciliation.resolved.map(\.messageID))
        let existing = Set(messages.map(\.id)).subtracting(superseded)
        let inserted = stable.messages.filter { !existing.contains($0.id) }
        let retained = messages.filter { !superseded.contains($0.id) }
        transcriptMessageIDsByRowID.merge(stable.rowIDs) { current, _ in current }
        storedMessageReferences.merge(StoredMessageReference.references(rows: rows, rowIDs: stable.rowIDs)) {
            current, _ in current
        }
        transcriptPrependGeneration &+= 1
        lastTranscriptPrepend = TranscriptHistoryPrepend(
            generation: transcriptPrependGeneration,
            count: inserted.count,
            resultingCount: retained.count + inserted.count,
            removedCount: messages.count - retained.count
        )
        messages = inserted + retained
        if let sessionID {
            rehydratePendingTranscriptImages(
                restored.pendingImages.map {
                    .init(messageID: renamed[$0.messageID] ?? $0.messageID, fileURLs: $0.fileURLs)
                }, requestedSessionID: sessionID)
        }
        DebugLog.write("model: loaded \(restored.messages.count) earlier messages (offset \(cursor.nextOffset))")
    }

    /// Stored prompts older than the loaded transcript, oldest first.
    var unloadedTranscriptPrompts: [TranscriptTimelineEntry] {
        guard let cursor = transcriptHistoryCursor, cursor.hasMore,
            cursor.storageSessionID == sessionStorageID
        else { return [] }
        return transcriptTimeline.filter { !cursor.seenRowIDs.contains($0.rowID) }
    }

    /// True while stored history older than the loaded transcript remains.
    var hasUnloadedTranscript: Bool {
        guard let cursor = transcriptHistoryCursor else { return false }
        return cursor.hasMore && cursor.storageSessionID == sessionStorageID
    }

    /// Reads the prompt timeline of the paged transcript so the navigator can
    /// list and search prompts that are not loaded yet. Failure leaves the
    /// navigator covering loaded messages only.
    func loadTranscriptTimeline(generation: Int) {
        guard let cursor = transcriptHistoryCursor else { return }
        transcriptTimelineTask?.cancel()
        transcriptTimelineTask = Task { @MainActor in
            var entries: [TranscriptTimelineEntry] = []
            var after = 0
            do {
                for _ in 0..<TranscriptHistoryPaging.maximumTimelinePages {
                    try Task.checkCancellation()
                    guard generation == sessionResumeGeneration else { return }
                    guard
                        let path = TranscriptHistoryPaging.timelinePath(
                            sessionID: cursor.storageSessionID,
                            profileID: cursor.profileID,
                            afterRowID: after
                        ),
                        let page = TranscriptHistoryPaging.timelinePage(
                            from: try await sessionRPCClient.fetchHTTP(path)
                        )
                    else { break }
                    try Task.checkCancellation()
                    guard generation == sessionResumeGeneration else { return }
                    entries += page.entries
                    guard let next = page.nextCursor, next > after else { break }
                    after = next
                }
            } catch {
                DebugLog.write(
                    "model: transcript timeline read failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
            guard generation == sessionResumeGeneration,
                sessionStorageID == cursor.storageSessionID
            else { return }
            transcriptTimeline = entries
        }
    }

    /// Loads all older history through `rowID` (or all of it when nil) in one
    /// prepend and returns the loaded message to show for that row. Search and
    /// navigator jumps use this; scrolling keeps reading page by page.
    @discardableResult
    func loadTranscriptHistory(through rowID: Int?) async -> UUID? {
        let generation = sessionResumeGeneration
        while isLoadingEarlierTranscript {
            try? await Task.sleep(for: .milliseconds(20))
            guard generation == sessionResumeGeneration else { return nil }
        }
        if let rowID, let loaded = loadedMessageID(forRowID: rowID) { return loaded }
        guard hasUnloadedTranscript, let cursor = transcriptHistoryCursor else {
            return rowID.flatMap(loadedMessageID(forRowID:))
        }
        isLoadingEarlierTranscript = true
        isLoadingTranscriptHistory = true
        defer {
            if generation == sessionResumeGeneration {
                isLoadingEarlierTranscript = false
                isLoadingTranscriptHistory = false
            }
        }
        do {
            let loaded = try await fetchEarlierTranscriptRows(
                from: cursor,
                limit: TranscriptHistoryPaging.maximumPageRowLimit,
                minimumDisplayRows: .max,
                maximumPages: .max,
                through: rowID
            )
            guard generation == sessionResumeGeneration,
                sessionStorageID == cursor.storageSessionID
            else { return nil }
            earlierTranscriptRetryAfter = nil
            prependEarlierTranscript(loaded.rows, cursor: loaded.cursor)
        } catch {
            guard generation == sessionResumeGeneration else { return nil }
            DebugLog.write(
                "model: transcript history read failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return nil
        }
        return rowID.flatMap(loadedMessageID(forRowID:))
    }
}
