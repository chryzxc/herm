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
        } catch {
            DebugLog.write("model: transcript page read failed, resuming inline: \(Self.safeUserDiagnostic(error.localizedDescription))")
            var params = fallbackResumeParams
            params.removeValue(forKey: "defer_history")
            params.removeValue(forKey: "omit_messages")
            let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionResume.rawValue, params: params)
            guard let rows = result["messages"] as? [[String: Any]] else {
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
        while cursor.hasMore, pagesRead < maximumPages {
            guard let path = TranscriptHistoryPaging.pagePath(
                sessionID: cursor.storageSessionID,
                profileID: cursor.profileID,
                limit: limit,
                offset: cursor.nextOffset
            ) else { throw HermesGateway.GatewayError.malformedResponse }
            guard let page = TranscriptHistoryPaging.page(from: try await sessionRPCClient.fetchHTTP(path)) else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            pagesRead += 1
            let fresh = TranscriptHistoryPaging.advance(&cursor, with: page, limit: limit)
            collected = TranscriptHistoryPaging.displayRows(fromStoredRows: fresh) + collected
            if let targetRowID {
                if cursor.seenRowIDs.contains(targetRowID) { break }
            } else if collected.filter({ !(($0["text"] as? String) ?? "").isEmpty }).count >= minimumDisplayRows {
                break
            }
        }
        return (collected, cursor)
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
                      sessionStorageID == cursor.storageSessionID else { return }
                earlierTranscriptRetryAfter = nil
                prependEarlierTranscript(loaded.rows, cursor: loaded.cursor)
            } catch {
                guard generation == sessionResumeGeneration else { return }
                // Scroll events call this continuously at the top edge; back
                // off instead of re-requesting a failing page on every frame.
                earlierTranscriptRetryAfter = Date().addingTimeInterval(5)
                DebugLog.write("model: earlier transcript page failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func prependEarlierTranscript(_ rows: [[String: Any]], cursor: TranscriptHistoryCursor) {
        transcriptHistoryCursor = cursor
        // Loaded prompts leave the navigator's unloaded list with the cursor.
        cachedMessageNavigatorItems = nil
        let restored = Self.parseMessages(
            rows,
            defaultBotProfileID: activeBotProfileID,
            defaultBotDisplayName: activeBotDisplayName
        )
        guard !restored.messages.isEmpty else { return }
        transcriptMessageIDsByRowID.merge(restored.rowIDs) { current, _ in current }
        storedMessageReferences.merge(StoredMessageReference.references(rows: rows, rowIDs: restored.rowIDs)) { current, _ in current }
        transcriptPrependGeneration &+= 1
        lastTranscriptPrepend = TranscriptHistoryPrepend(
            generation: transcriptPrependGeneration,
            count: restored.messages.count,
            resultingCount: messages.count + restored.messages.count
        )
        messages.insert(contentsOf: restored.messages, at: 0)
        if let sessionID {
            rehydratePendingTranscriptImages(restored.pendingImages, requestedSessionID: sessionID)
        }
        DebugLog.write("model: loaded \(restored.messages.count) earlier messages (offset \(cursor.nextOffset))")
    }

    /// Stored prompts older than the loaded transcript, oldest first.
    var unloadedTranscriptPrompts: [TranscriptTimelineEntry] {
        guard let cursor = transcriptHistoryCursor, cursor.hasMore,
              cursor.storageSessionID == sessionStorageID else { return [] }
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
        Task { @MainActor in
            var entries: [TranscriptTimelineEntry] = []
            var after = 0
            do {
                for _ in 0..<TranscriptHistoryPaging.maximumTimelinePages {
                    guard let path = TranscriptHistoryPaging.timelinePath(
                        sessionID: cursor.storageSessionID,
                        profileID: cursor.profileID,
                        afterRowID: after
                    ), let page = TranscriptHistoryPaging.timelinePage(
                        from: try await sessionRPCClient.fetchHTTP(path)
                    ) else { break }
                    entries += page.entries
                    guard let next = page.nextCursor, next > after else { break }
                    after = next
                }
            } catch {
                DebugLog.write("model: transcript timeline read failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
            guard generation == sessionResumeGeneration,
                  sessionStorageID == cursor.storageSessionID else { return }
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
                  sessionStorageID == cursor.storageSessionID else { return nil }
            earlierTranscriptRetryAfter = nil
            prependEarlierTranscript(loaded.rows, cursor: loaded.cursor)
        } catch {
            guard generation == sessionResumeGeneration else { return nil }
            DebugLog.write("model: transcript history read failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            return nil
        }
        return rowID.flatMap(loadedMessageID(forRowID:))
    }
}
