import AppKit
import Foundation

/// A disposable projection of a transcript that Hermes has already returned.
struct SessionTranscriptPreview {
    struct ReadCoverage {
        let updatedAt: Date
        let latestRowAt: Date
    }

    let messages: [ChatMessage]
    let rowIDs: [Int: UUID]
    let references: [UUID: StoredMessageReference]
    let pendingImages: [RestoredTranscript.PendingImages]
    // A background read does not establish that this chat has been opened before.
    var isPreloaded = false
    var readCoverage: ReadCoverage?
    let navigator = MessageNavigatorSnapshot(items: [])
}

enum SessionTranscriptLoadState: Equatable {
    case ready
    case loading
    case refreshing
    case failed(String)

    var allowsActions: Bool {
        if case .ready = self { return true }
        return false
    }

    var statusText: String? {
        switch self {
        case .ready: nil
        case .loading: "Loading…"
        case .refreshing: "Refreshing…"
        case .failed: "Not current"
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

@MainActor
final class SessionTranscriptCache {
    private struct Entry {
        let preview: SessionTranscriptPreview
        let cost: Int
    }

    static let messageLimit = 36
    private let maximumEntries = 8
    private let maximumCost = 16 * 1024 * 1024
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var totalCost = 0
    private struct PageKey: Hashable {
        let client: ObjectIdentifier
        let path: String
    }
    let externalReads = ExternalTranscriptReads()
    private var warmingPages: [PageKey: Task<UncheckedTranscriptValue<[String: Any]>, Error>] = [:]
    private(set) var foregroundReads = 0

    func beginForegroundRead() { foregroundReads += 1 }
    func endForegroundRead() { foregroundReads -= 1 }

    func warmFirstPage(path: String, client: HermesRPCClientProtocol) async throws -> [String: Any] {
        let key = PageKey(client: ObjectIdentifier(client), path: path)
        if let pending = warmingPages[key] { return try await pending.value.value }
        let task = Task(priority: .utility) { UncheckedTranscriptValue(value: try await client.fetchHTTP(path)) }
        warmingPages[key] = task
        defer { warmingPages[key] = nil }
        // The shared read may still have a foreground reader if warm-up is cancelled.
        return try await task.value.value
    }

    func firstPage(path: String, client: HermesRPCClientProtocol) async throws -> [String: Any] {
        if let pending = warmingPages[PageKey(client: ObjectIdentifier(client), path: path)] {
            do {
                return try await pending.value.value
            } catch {
                try Task.checkCancellation()
                // A failed speculative request must not prevent a foreground retry.
            }
        }
        return try await client.fetchHTTP(path)
    }

    var hasPreloadCapacity: Bool { entries.count < maximumEntries && totalCost < maximumCost }

    func contains(_ key: String) -> Bool { entries[key] != nil }

    func value(for key: String) -> SessionTranscriptPreview? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.preview
    }

    func store(_ restored: RestoredTranscript, references: [UUID: StoredMessageReference], for key: String) {
        remove(key)
        guard let entry = makeEntry(restored, references: references) else { return }
        insert(entry, for: key)
    }

    /// Replaces the entry only when the new transcript is cacheable; otherwise the existing one stays.
    func refresh(_ restored: RestoredTranscript, references: [UUID: StoredMessageReference], for key: String) {
        guard let entry = makeEntry(restored, references: references) else { return }
        remove(key)
        insert(entry, for: key)
    }

    func preload(
        _ restored: RestoredTranscript, references: [UUID: StoredMessageReference], for key: String,
        readCoverage: SessionTranscriptPreview.ReadCoverage?
    ) {
        guard !restored.messages.isEmpty, entries[key] == nil, entries.count < maximumEntries,
            let entry = makeEntry(restored, references: references, isPreloaded: true, readCoverage: readCoverage),
            totalCost + entry.cost <= maximumCost
        else { return }
        insert(entry, for: key)
    }

    private func makeEntry(
        _ restored: RestoredTranscript, references: [UUID: StoredMessageReference], isPreloaded: Bool = false,
        readCoverage: SessionTranscriptPreview.ReadCoverage? = nil
    ) -> Entry? {
        let messages = Array(restored.messages.suffix(Self.messageLimit))
        let ids = Set(messages.map(\.id))
        let cost = messages.reduce(0) { total, message in
            total + message.text.utf8.count
                + message.activity.reduce(0) { sum, call in
                    sum + call.input.utf8.count + call.context.utf8.count + (call.result?.utf8.count ?? 0)
                        + (call.diffPreview?.utf8.count ?? 0)
                        + (call.args?.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } ?? 0)
                }
        }
        guard messages.allSatisfy({ $0.images.isEmpty && !$0.isError }),
            restored.pendingImages.allSatisfy({ $0.fileURLs.allSatisfy(\.isFileURL) }), cost <= maximumCost
        else {
            return nil
        }
        let preview = SessionTranscriptPreview(
            messages: messages,
            rowIDs: restored.rowIDs.filter { ids.contains($0.value) },
            references: Dictionary(uniqueKeysWithValues: ids.compactMap { id in references[id].map { (id, $0) } }),
            pendingImages: restored.pendingImages.filter { ids.contains($0.messageID) }, isPreloaded: isPreloaded,
            readCoverage: readCoverage)
        return Entry(preview: preview, cost: cost)
    }

    private func insert(_ entry: Entry, for key: String) {
        entries[key] = entry
        order.append(key)
        totalCost += entry.cost
        while order.count > maximumEntries || totalCost > maximumCost {
            guard let oldest = order.first else { break }
            remove(oldest)
        }
    }

    func remove(_ key: String) {
        if let entry = entries.removeValue(forKey: key) { totalCost -= entry.cost }
        order.removeAll { $0 == key }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }
}

extension DockModel {
    /// A preload contains Hermes rows. A bot may also have finished since the last visit.
    func openingPreview(for key: String, session: HermesSession, seenAt: Date?) -> SessionTranscriptPreview? {
        guard var preview = sessionTranscriptCache.value(for: key) else { return nil }
        if let coverage = preview.readCoverage {
            if coverage.updatedAt != session.lastUpdatedAt
                || seenAt.map({ $0 >= max(coverage.updatedAt, coverage.latestRowAt) }) != true
                || session.isWorking || session.hasUnreadUpdate
            {
                preview.readCoverage = nil
            }
        }
        let storageID = session.id
        guard botActivityBySessionID[storageID]?.isEmpty == false else { return preview }
        let tail = Array(
            transcriptWithBotActivities(preview.messages, for: [storageID]).suffix(SessionTranscriptCache.messageLimit))
        let ids = Set(tail.map(\.id))
        return SessionTranscriptPreview(
            messages: tail, rowIDs: preview.rowIDs.filter { ids.contains($0.value) },
            references: preview.references.filter { ids.contains($0.key) },
            pendingImages: preview.pendingImages.filter { ids.contains($0.messageID) },
            isPreloaded: preview.isPreloaded,
            readCoverage: preview.readCoverage
        )
    }

    func recordSessionSwitch(
        _ stage: String, startedAt: UInt64, extra: String = "", generation: Int? = nil, token: String? = nil
    ) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        HermPerformanceRecorder.recordSessionOpen(stage: stage, milliseconds: milliseconds)
        DebugLog.writePerformance(
            "session_switch token=\(token ?? sessionSwitchToken) generation=\(generation ?? sessionResumeGeneration) stage=\(stage) ms=\(milliseconds) \(extra)"
        )
    }

    func recordSessionSwitchLayout() {
        guard sessionSwitchStartedAt != 0 else { return }
        if sessionTranscriptPreview != nil {
            guard !sessionSwitchCachedLayoutRecorded else { return }
            sessionSwitchCachedLayoutRecorded = true
            recordSessionSwitch("cached_layout", startedAt: sessionSwitchStartedAt)
        } else if sessionActionsReady {
            guard !sessionSwitchFreshLayoutRecorded else { return }
            sessionSwitchFreshLayoutRecorded = true
            recordSessionSwitch("fresh_layout", startedAt: sessionSwitchStartedAt)
        }
    }

    func loadPreviewImages() {
        sessionPreviewImageTask?.cancel()
        guard let preview = sessionTranscriptPreview, !preview.pendingImages.isEmpty else { return }
        let generation = sessionResumeGeneration
        let pendingImages = preview.pendingImages
        sessionPreviewImageTask = Task { @MainActor [weak self] in
            var queue = TranscriptImageHydration.Queue(pendingImages)
            var application = TranscriptImageHydration.Application()
            while !Task.isCancelled {
                let jobs = queue.next(prioritizing: [])
                guard !jobs.isEmpty else { return }
                let batch = await TranscriptImageHydration.Worker.shared.prepare(
                    jobs, load: DockModel.transcriptImageData)
                guard let self, !Task.isCancelled, generation == sessionResumeGeneration,
                    let current = sessionTranscriptPreview
                else { return }
                var messages = current.messages
                if application.apply(batch, to: &messages) {
                    sessionTranscriptPreview = SessionTranscriptPreview(
                        messages: messages, rowIDs: current.rowIDs,
                        references: current.references, pendingImages: current.pendingImages,
                        isPreloaded: current.isPreloaded, readCoverage: current.readCoverage)
                }
                await Task.yield()
            }
        }
    }
}
