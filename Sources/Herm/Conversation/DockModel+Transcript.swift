import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func loadCompletedReplyRoute(sessionID: String, admissionID: String, generation: Int, messageID: UUID) async {
        let profile = sessionProfileID ?? profileScopeID
        guard sessionResumeGeneration == generation, self.sessionID == sessionID,
            messages.contains(where: { $0.id == messageID && $0.role == .hermes && $0.hasBodyText }),
            let route = try? await interruptRPC.completedPromptRoute(
                sessionID: sessionID, admissionID: admissionID, profileID: profile),
            sessionResumeGeneration == generation, self.sessionID == sessionID,
            (sessionProfileID ?? profileScopeID) == profile,
            let index = messages.firstIndex(where: { $0.id == messageID && $0.role == .hermes && $0.hasBodyText })
        else { return }
        editChatMessage(at: index) { $0.responseRoute = route }
    }

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
        do {
            let loaded = try await readStoredTranscriptTail(
                storageSessionID: storageSessionID, profileID: profileID, minimumRowCount: minimumRowCount
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

    func readStoredTranscriptTail(
        storageSessionID: String, profileID: String?, minimumRowCount: Int, readOnly: Bool = false
    ) async throws -> (rows: [[String: Any]], cursor: TranscriptHistoryCursor) {
        sessionTranscriptCache.beginForegroundRead()
        defer { sessionTranscriptCache.endForegroundRead() }
        let cursor = TranscriptHistoryCursor(storageSessionID: storageSessionID, profileID: profileID)
        let limit = min(
            TranscriptHistoryPaging.maximumPageRowLimit,
            max(TranscriptHistoryPaging.conversationBufferRowLimit, minimumRowCount)
        )
        return try await fetchEarlierTranscriptRows(
            from: cursor,
            limit: limit,
            minimumDisplayRows: ConversationMessageWindow.initialLimit,
            maximumPages: limit == TranscriptHistoryPaging.conversationBufferRowLimit
                ? TranscriptHistoryPaging.maximumConversationBufferPages
                : TranscriptHistoryPaging.maximumPagesPerLoad,
            readOnly: readOnly
        )
    }

    var isShowingReadOnlyStoredTranscript: Bool { transcriptHistoryCursor?.readOnlyResolvedSessionID != nil }

    var hasReadableStoredTranscript: Bool {
        sessionTranscriptPreview != nil || (isShowingReadOnlyStoredTranscript && !messages.isEmpty)
    }

    func clearStoredTranscriptProjection() {
        clearStoredSearch()
        transcriptTimelineTask?.cancel()
        transcriptTimelineTask = nil
        transcriptHistoryCursor = nil
        replaceTranscriptRowIDs([:])
        transcriptTimeline = []
        lastTranscriptPrepend = nil
        isLoadingEarlierTranscript = false
        isLoadingTranscriptHistory = false
        clearMessagePins()
        messages = []
    }

    /// Reads older pages until at least `minimumDisplayRows` visible messages
    /// arrive or history is exhausted. Returned rows are display-projected and
    /// chronological.
    func fetchEarlierTranscriptRows(
        from start: TranscriptHistoryCursor,
        limit: Int,
        minimumDisplayRows: Int,
        maximumPages: Int = TranscriptHistoryPaging.maximumPagesPerLoad,
        alignToTurn: Bool = false,
        readOnly: Bool = false,
        externalOverlap: Set<Int>? = nil
    ) async throws -> (rows: [[String: Any]], cursor: TranscriptHistoryCursor) {
        var cursor = start
        var pages: [[[String: Any]]] = []
        var displayRows = 0
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
            let response =
                if externalOverlap != nil {
                    try await sessionTranscriptCache.externalReads.fetch(path, client: sessionRPCClient)
                } else if cursor.nextOffset == 0 {
                    try await sessionTranscriptCache.firstPage(path: path, client: sessionRPCClient)
                } else {
                    try await sessionRPCClient.fetchHTTP(path)
                }
            guard let page = TranscriptHistoryPaging.page(from: response) else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            try Task.checkCancellation()
            guard generation == sessionResumeGeneration else { throw CancellationError() }
            if readOnly || cursor.readOnlyResolvedSessionID != nil {
                guard let pagination = response["pagination"] as? [String: Any],
                    pagination["returned"] as? Int == page.rows.count, page.returned <= limit,
                    page.rows.allSatisfy({ TranscriptHistoryPaging.rowID($0) != nil && $0["role"] is String })
                else { throw HermesGateway.GatewayError.malformedResponse }
                cursor.readOnlyResolvedSessionID = try await verifyStoredTranscriptOwner(response, cursor: cursor)
                try Task.checkCancellation()
                guard generation == sessionResumeGeneration else { throw CancellationError() }
            }
            recordSessionSwitch(
                "history_fetch", startedAt: fetchStartedAt, extra: "page=\(pagesRead + 1) rows=\(page.returned)")
            pagesRead += 1
            cursor.isSingleTimestampedTailPage =
                start.nextOffset == 0 && pagesRead == 1 && page.returned == page.rows.count
                && page.rows.allSatisfy { $0["timestamp"] is NSNumber }
            let beforePage = alignToTurn ? cursor : nil
            let fresh = TranscriptHistoryPaging.advance(&cursor, with: page, limit: limit)
            let projectStartedAt = DispatchTime.now().uptimeNanoseconds
            let projected = await Self.projectStoredRowsOffMain(fresh)
            try Task.checkCancellation()
            guard generation == sessionResumeGeneration else { throw CancellationError() }
            recordSessionSwitch("history_project", startedAt: projectStartedAt, extra: "rows=\(fresh.count)")
            if var beforePage, cursor.hasMore, page.returned == page.rows.count,
                let boundary = projected.firstIndex(where: TranscriptHistoryPaging.startsTurn),
                let id = TranscriptHistoryPaging.rowID(projected[boundary], key: "row_id"),
                let offset = page.rows.firstIndex(where: { TranscriptHistoryPaging.rowID($0) == id })
            {
                // Leave the older half readable after cancellation. A clean prompt
                // keeps tool calls and their reply in the same parsed batch.
                let suffix = page.rows.suffix(from: offset)
                _ = TranscriptHistoryPaging.advance(
                    &beforePage, with: .init(rows: Array(suffix), returned: suffix.count, isPaginated: true),
                    limit: suffix.count)
                cursor = beforePage
                pages.append(Array(projected.suffix(from: boundary)))
                break
            }
            pages.append(projected)
            if minimumDisplayRows != .max {
                displayRows += projected.count { !(($0["text"] as? String) ?? "").isEmpty }
                if displayRows >= minimumDisplayRows,
                    externalOverlap.map({ $0.isEmpty || !cursor.seenRowIDs.isDisjoint(with: $0) }) ?? true
                {
                    break
                }
            }
        }
        return (pages.reversed().flatMap { $0 }, cursor)
    }

    private func verifyStoredTranscriptOwner(_ response: [String: Any], cursor: TranscriptHistoryCursor) async throws
        -> String
    {
        guard let profileID = cursor.profileID, response["profile"] as? String == profileID,
            let resolvedID = response["session_id"] as? String, !resolvedID.isEmpty
        else { throw HermesGateway.GatewayError.malformedResponse }
        if let pinnedID = cursor.readOnlyResolvedSessionID {
            guard resolvedID == pinnedID else { throw HermesGateway.GatewayError.malformedResponse }
        } else if resolvedID != cursor.storageSessionID {
            // Messages may resolve prefixes. The timeline only resolves an exact, owned ID to its compaction tip.
            guard
                let path = TranscriptHistoryPaging.sessionPath(
                    sessionID: cursor.storageSessionID, endpoint: "timeline", profileID: profileID,
                    query: [URLQueryItem(name: "limit", value: "1")]
                )
            else { throw HermesGateway.GatewayError.malformedResponse }
            let proof = try await sessionRPCClient.fetchHTTP(path)
            guard proof["profile"] as? String == profileID, proof["session_id"] as? String == resolvedID,
                TranscriptHistoryPaging.timelinePage(from: proof) != nil
            else { throw HermesGateway.GatewayError.malformedResponse }
        }
        return resolvedID
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
        guard let watchedMessage = streamingMessageID else { return }
        externalTurnWatchTask?.cancel()
        externalTurnWatchTask = Task { @MainActor [weak self] in
            let idleWindow = Duration.seconds(idleLimit)
            var lastChange = ContinuousClock.now
            var failures = 0
            var previousTail: Data?
            var lastFullRead: ContinuousClock.Instant?
            while !Task.isCancelled {
                let remaining = max(.zero, idleWindow - lastChange.duration(to: .now))
                do {
                    try await Task.sleep(for: Self.externalTurnPollDelay(failures: failures, remaining: remaining))
                } catch { return }
                guard let self, !Task.isCancelled, !self.hasShutDown, generation == self.sessionResumeGeneration,
                    self.streamingMessageID == watchedMessage,
                    let storageID = self.sessionStorageID
                else { return }
                if lastChange.duration(to: .now) >= idleWindow {
                    self.endExternalTurn(commit: true)
                    return
                }
                let revision = self.messagesRevision
                let tail: Data?
                if let path = TranscriptHistoryPaging.pagePath(
                    sessionID: storageID, profileID: self.sessionProfileID, limit: 1, offset: 0),
                    let response = try? await self.sessionTranscriptCache.externalReads.fetch(
                        path + "&inline_images=false", client: self.sessionRPCClient)
                {
                    tail = TranscriptHistoryPaging.externalTurnTail(response)
                } else {
                    tail = nil
                }
                guard !Task.isCancelled, generation == self.sessionResumeGeneration,
                    self.streamingMessageID == watchedMessage
                else { return }
                if let tail, tail == previousTail,
                    let lastFullRead, lastFullRead.duration(to: .now) < .seconds(30)
                {
                    failures = 0
                    continue
                }
                let knownRows = self.transcriptHistoryCursor?.seenRowIDs ?? Set(self.transcriptMessageIDsByRowID.keys)
                let loaded = try? await self.fetchEarlierTranscriptRows(
                    from: TranscriptHistoryCursor(storageSessionID: storageID, profileID: self.sessionProfileID),
                    limit: TranscriptHistoryPaging.pageRowLimit,
                    minimumDisplayRows: ConversationMessageWindow.initialLimit,
                    externalOverlap: knownRows)
                guard !Task.isCancelled, !self.hasShutDown, generation == self.sessionResumeGeneration,
                    self.streamingMessageID == watchedMessage
                else { return }
                guard let loaded else {
                    failures = min(failures + 1, 3)
                    continue
                }
                guard knownRows.isEmpty || !knownRows.isDisjoint(with: loaded.cursor.seenRowIDs) else {
                    failures = min(failures + 1, 3)
                    continue
                }
                failures = 0
                guard revision == self.messagesRevision else { continue }
                let tailChanged = tail != nil && previousTail != tail
                let (restored, references) = await Self.parseMessagesOffMain(
                    loaded.rows, defaultBotProfileID: self.activeBotProfileID,
                    defaultBotDisplayName: self.activeBotDisplayName, priority: .utility)
                guard generation == self.sessionResumeGeneration, self.streamingMessageID == watchedMessage,
                    revision == self.messagesRevision, !Task.isCancelled
                else { continue }
                previousTail = tail
                lastFullRead = .now
                let stable = Self.keepingMessageIDs(
                    restored, previous: self.transcriptMessageIDsByRowID, previousMessages: self.messages)
                let activityChanged = !ExternalTranscriptTail.sameActivity(
                    self.streamingTurnActivity, restored.trailingActivity)
                if tailChanged || activityChanged { lastChange = .now }
                let merge = ExternalTranscriptTail.merge(
                    current: self.messages, previousRows: self.transcriptMessageIDsByRowID,
                    tail: stable.messages, tailRows: stable.rowIDs, liveID: watchedMessage)
                if let merge {
                    lastChange = .now
                    self.applyExternalTail(merge, stableRows: stable.rowIDs, restored: restored, references: references)
                }
                self.transcriptHistoryCursor = ExternalTranscriptTail.cursor(
                    keeping: self.transcriptHistoryCursor, observing: loaded.cursor)
                if restored.trailingActivity.isEmpty {
                    guard !loaded.rows.isEmpty else { continue }
                    let replyPresent =
                        stable.messages.last.map { last in
                            last.role == .hermes && last.hasBodyText && self.messages.contains { $0.id == last.id }
                        } ?? false
                    self.endExternalTurn(commit: !replyPresent && merge?.inserted.isEmpty != false)
                    return
                }
                if activityChanged { self.streamingTurnActivity = restored.trailingActivity }
            }
        }
    }

    private func applyExternalTail(
        _ merge: ExternalTranscriptTail.Merge, stableRows: [Int: UUID], restored: RestoredTranscript,
        references: [UUID: StoredMessageReference]
    ) {
        let renamed = Dictionary(
            restored.rowIDs.compactMap { row, id in stableRows[row].map { (id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let existing = Set(messages.map(\.id))
        mergeTranscriptRowIDs(stableRows.filter { existing.contains($0.value) || merge.inserted.contains($0.value) })
        for (id, reference) in references {
            let stableID = renamed[id] ?? id
            if existing.contains(stableID) || merge.inserted.contains(stableID) {
                storedMessageReferences[stableID] = reference
            }
        }
        messages = merge.messages
    }

    static func externalTurnPollDelay(failures: Int, remaining: Duration) -> Duration {
        min(max(.zero, remaining), .seconds(3 << max(0, min(failures, 3))))
    }

    /// A re-read transcript keeps the IDs its stored rows already had, so
    /// SwiftUI updates rows in place instead of rebuilding and re-measuring
    /// every message on each 3s poll of a running Bot turn.
    static func keepingMessageIDs(
        _ restored: RestoredTranscript, previous: [Int: UUID], previousMessages: [ChatMessage] = []
    ) -> (
        messages: [ChatMessage], rowIDs: [Int: UUID]
    ) {
        var renamed: [UUID: UUID] = [:]
        var taken = Set<UUID>()
        for (rowID, id) in restored.rowIDs.sorted(by: { $0.key < $1.key }) where renamed[id] == nil {
            guard let old = previous[rowID], taken.insert(old).inserted else { continue }
            renamed[id] = old
        }
        let previousRoutes = Dictionary(
            previousMessages.compactMap { message in message.responseRoute.map { (message.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let messages = restored.messages.map { message in
            var message = message
            if let old = renamed[message.id] {
                message.id = old
                if message.role == .hermes, message.hasBodyText { message.responseRoute = previousRoutes[old] }
            }
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

    /// Refills the stored history buffer before the reader reaches its oldest message.
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
                    limit: TranscriptHistoryPaging.conversationBufferRowLimit,
                    minimumDisplayRows: 1,
                    maximumPages: TranscriptHistoryPaging.maximumConversationBufferPages
                )
                try await prepareEarlierTranscript(loaded, previousCursor: cursor, generation: generation)
            } catch is CancellationError {
                return
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
        let restored = Self.parseMessages(
            rows,
            defaultBotProfileID: activeBotProfileID,
            defaultBotDisplayName: activeBotDisplayName
        )
        let references = StoredMessageReference.references(rows: rows, rowIDs: restored.rowIDs)
        prependEarlierTranscript(restored, references: references, cursor: cursor)
    }

    private func prepareEarlierTranscript(
        _ loaded: (rows: [[String: Any]], cursor: TranscriptHistoryCursor),
        previousCursor: TranscriptHistoryCursor,
        generation: Int
    ) async throws {
        try Task.checkCancellation()
        guard generation == sessionResumeGeneration, transcriptHistoryCursor == previousCursor else {
            throw CancellationError()
        }
        let (restored, references) = await Self.parseMessagesOffMain(
            loaded.rows, defaultBotProfileID: activeBotProfileID, defaultBotDisplayName: activeBotDisplayName)
        try Task.checkCancellation()
        guard generation == sessionResumeGeneration, sessionStorageID == previousCursor.storageSessionID,
            transcriptHistoryCursor == previousCursor
        else { throw CancellationError() }
        earlierTranscriptRetryAfter = nil
        prependEarlierTranscript(restored, references: references, cursor: loaded.cursor)
    }

    private func prependEarlierTranscript(
        _ restored: RestoredTranscript, references: [UUID: StoredMessageReference], cursor: TranscriptHistoryCursor
    ) {
        transcriptHistoryCursor = cursor
        guard !restored.messages.isEmpty else {
            transcriptPresentationChanges.send()
            return
        }
        let reconciliation =
            cursor.readOnlyResolvedSessionID == nil
            ? reconcilePendingSends(
                for: composerDraftKey, restored: restored.messages, rowIDs: restored.rowIDs, visibleHistory: true)
            : SessionPendingSendReconciliation()
        var previous = transcriptMessageIDsByRowID
        for match in reconciliation.resolved where previous[match.rowID] == nil {
            previous[match.rowID] = match.messageID
        }
        let stable = Self.keepingMessageIDs(restored, previous: previous)
        let renamed = Dictionary(
            restored.rowIDs.compactMap { row, id in stable.rowIDs[row].map { (id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let superseded = Set(reconciliation.resolved.map(\.messageID))
        let existing = Set(messages.lazy.map(\.id)).subtracting(superseded)
        let inserted = stable.messages.filter { !existing.contains($0.id) }
        let retained = superseded.isEmpty ? messages : messages.filter { !superseded.contains($0.id) }
        mergeTranscriptRowIDs(stable.rowIDs)
        storedMessageReferences.merge(references.lazy.map { (renamed[$0.key] ?? $0.key, $0.value) }) {
            current, _ in current
        }
        transcriptPrependGeneration &+= 1
        lastTranscriptPrepend = TranscriptHistoryPrepend(
            generation: transcriptPrependGeneration,
            count: inserted.count,
            resultingCount: retained.count + inserted.count,
            removedCount: messages.count - retained.count,
            messagesRevision: messagesRevision &+ 1
        )
        messages = inserted + retained
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

    func loadTranscriptTimelineIfNeeded() {
        guard hasUnloadedTranscript, transcriptTimelineTask == nil, sessionTranscriptPreview == nil else { return }
        loadTranscriptTimeline(generation: sessionResumeGeneration)
    }

    /// Reads the prompt timeline on demand for the message map. Failure leaves
    /// the map covering loaded messages only.
    func loadTranscriptTimeline(generation: Int) {
        guard let cursor = transcriptHistoryCursor else { return }
        let timelineSessionID = cursor.readOnlyResolvedSessionID ?? cursor.storageSessionID
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
                            sessionID: timelineSessionID,
                            profileID: cursor.profileID,
                            afterRowID: after
                        )
                    else { break }
                    let response = try await sessionRPCClient.fetchHTTP(path)
                    try Task.checkCancellation()
                    guard generation == sessionResumeGeneration else { return }
                    if cursor.readOnlyResolvedSessionID != nil {
                        guard response["profile"] as? String == cursor.profileID,
                            response["session_id"] as? String == timelineSessionID
                        else { break }
                    }
                    guard let page = TranscriptHistoryPaging.timelinePage(from: response) else { break }
                    entries += page.entries
                    guard let next = page.nextCursor, next > after else { break }
                    after = next
                }
            } catch {
                DebugLog.write(
                    "model: transcript timeline read failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
            guard !Task.isCancelled, generation == sessionResumeGeneration,
                sessionStorageID == cursor.storageSessionID,
                transcriptHistoryCursor?.readOnlyResolvedSessionID == cursor.readOnlyResolvedSessionID
            else { return }
            transcriptTimeline = entries
        }
    }

    /// Searches stored history without publishing it into the transcript.
    func searchTranscript(_ input: MessageNavigatorSearchRequest) async throws -> [MessageNavigatorItem] {
        guard input.sessionID == (sessionID ?? "") else { throw CancellationError() }
        guard hasUnloadedTranscript, let cursor = transcriptHistoryCursor else {
            return try await MessageNavigator.searchInBackground(items: input.snapshot.items, query: input.query)
        }
        let generation = sessionResumeGeneration
        let index = try await loadStoredSearch(cursor: cursor, generation: generation)
        var batches: [[MessageNavigatorItem]] = []
        var olderCount = 0
        func collect(_ page: MessageNavigator.StoredSearchProjection) async throws {
            try Task.checkCancellation()
            let newerCount = olderCount
            let worker = Task.detached(priority: .userInitiated) {
                MessageNavigator.searchStoredPage(page, input: input, precedingNewerCount: newerCount)
            }
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            if !matches.isEmpty { batches.append(matches) }
            olderCount += page.messageCount
        }
        for page in index.pages { try await collect(page) }
        var tail = index.tail
        while tail.hasMore {
            let page = try await makeStoredSearchPage(from: tail)
            try await collect(page.projection)
            tail = page.cursor
        }
        let loaded = try await MessageNavigator.searchLoadedInBackground(input, olderCount: olderCount)
        try Task.checkCancellation()
        guard generation == sessionResumeGeneration, sessionStorageID == cursor.storageSessionID,
            transcriptHistoryCursor?.readOnlyResolvedSessionID == cursor.readOnlyResolvedSessionID
        else { throw CancellationError() }
        return batches.reversed().flatMap { batch in
            batch.map { item in
                var result = item
                result.ordinal += olderCount
                return result
            }
        } + loaded
    }

    func setTranscriptSearchDemand(_ host: ObjectIdentifier, active: Bool) {
        if active {
            transcriptSearchHosts.insert(host)
        } else if transcriptSearchHosts.remove(host) != nil, transcriptSearchHosts.isEmpty {
            clearStoredSearch()
        }
    }

    func clearStoredSearch() {
        storedSearchTask?.task.cancel()
        storedSearchTask = nil
        storedSearchCache = nil
    }

    private func loadStoredSearch(cursor: TranscriptHistoryCursor, generation: Int) async throws
        -> NavigatorStoredSearchIndex
    {
        let key = NavigatorHistorySearchKey(generation: generation, cursor: cursor)
        if let (cachedKey, projection) = storedSearchCache, cachedKey == key { return projection }
        if let pending = storedSearchTask, pending.key == key { return try await pending.task.value }
        clearStoredSearch()
        let id = UUID()
        // Keep the read shared while Find is open. Query cancellation still
        // cancels matching and prevents its delayed result from being shown.
        let task = Task { [weak self] () throws -> NavigatorStoredSearchIndex in
            guard let self else { throw CancellationError() }
            defer { if storedSearchTask?.id == id { storedSearchTask = nil } }
            var tail = cursor
            var pages: [MessageNavigator.StoredSearchProjection] = []
            var remainingBytes = MessageNavigator.StoredSearchProjection.maximumCachedBytes
            while tail.hasMore, remainingBytes > 0 {
                let next = try await makeStoredSearchPage(from: tail)
                guard next.projection.cost <= remainingBytes else { break }
                pages.append(next.projection)
                remainingBytes -= next.projection.cost
                tail = next.cursor
            }
            let index = NavigatorStoredSearchIndex(pages: pages, tail: tail)
            try Task.checkCancellation()
            if storedSearchTask?.id == id { storedSearchCache = (key, index) }
            return index
        }
        storedSearchTask = (key, id, task)
        return try await task.value
    }

    private func makeStoredSearchPage(from cursor: TranscriptHistoryCursor) async throws
        -> (projection: MessageNavigator.StoredSearchProjection, cursor: TranscriptHistoryCursor)
    {
        let loaded = try await fetchEarlierTranscriptRows(
            from: cursor, limit: TranscriptHistoryPaging.conversationBufferRowLimit,
            minimumDisplayRows: .max, maximumPages: 1)
        let rows = UncheckedTranscriptValue(value: loaded.rows)
        let worker = Task.detached(priority: .userInitiated) {
            let stored = Self.parseMessages(
                rows.value, defaultBotProfileID: nil, defaultBotDisplayName: nil, cancelOnTask: true)
            return try MessageNavigator.projectStoredSearch(stored)
        }
        let projection = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return (projection, loaded.cursor)
    }

    /// Loads through `rowID` (or to the beginning when nil) in turn-aligned prepends.
    @discardableResult
    func loadTranscriptHistory(through rowID: Int?) async -> UUID? {
        let generation = sessionResumeGeneration
        while isLoadingEarlierTranscript {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return nil
            }
            guard generation == sessionResumeGeneration else { return nil }
        }
        guard !Task.isCancelled else { return nil }
        if let rowID, let loaded = loadedMessageID(forRowID: rowID) { return loaded }
        guard hasUnloadedTranscript else {
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
            while let cursor = transcriptHistoryCursor, cursor.hasMore {
                try Task.checkCancellation()
                let loaded = try await fetchEarlierTranscriptRows(
                    from: cursor, limit: TranscriptHistoryPaging.maximumPageRowLimit,
                    minimumDisplayRows: .max, maximumPages: .max, alignToTurn: true)
                try await prepareEarlierTranscript(loaded, previousCursor: cursor, generation: generation)
                if let rowID, loaded.cursor.seenRowIDs.contains(rowID) { break }
                await Task.yield()
                guard generation == sessionResumeGeneration else { throw CancellationError() }
            }
        } catch is CancellationError {
            return nil
        } catch {
            guard generation == sessionResumeGeneration else { return nil }
            DebugLog.write(
                "model: transcript history read failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return nil
        }
        return rowID.flatMap(loadedMessageID(forRowID:))
    }
}
