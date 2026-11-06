import AppKit
import Foundation

/// A disposable projection of a transcript that Hermes has already returned.
struct SessionTranscriptPreview {
    let messages: [ChatMessage]
    let rowIDs: [Int: UUID]
    let references: [UUID: StoredMessageReference]
    let pendingImages: [RestoredTranscript.PendingImages]
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

    private let maximumEntries = 8
    private let maximumCost = 16 * 1024 * 1024
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var totalCost = 0

    func value(for key: String) -> SessionTranscriptPreview? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.preview
    }

    func store(_ restored: RestoredTranscript, references: [UUID: StoredMessageReference], for key: String) {
        let messages = Array(restored.messages.suffix(36))
        let ids = Set(messages.map(\.id))
        let cost = messages.reduce(0) { total, message in
            total + message.text.utf8.count
                + message.activity.reduce(0) { sum, call in
                    sum + call.input.utf8.count + call.context.utf8.count + (call.result?.utf8.count ?? 0)
                        + (call.diffPreview?.utf8.count ?? 0)
                        + (call.args?.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } ?? 0)
                }
        }
        remove(key)
        guard !messages.isEmpty, messages.allSatisfy({ $0.images.isEmpty && !$0.isError }),
            restored.pendingImages.allSatisfy({ $0.fileURLs.allSatisfy(\.isFileURL) }), cost <= maximumCost
        else {
            return
        }
        let preview = SessionTranscriptPreview(
            messages: messages,
            rowIDs: restored.rowIDs.filter { ids.contains($0.value) },
            references: references.filter { ids.contains($0.key) },
            pendingImages: restored.pendingImages.filter { ids.contains($0.messageID) })
        entries[key] = Entry(preview: preview, cost: cost)
        order.append(key)
        totalCost += cost
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
    func recordSessionSwitch(
        _ stage: String, startedAt: UInt64, extra: String = "", generation: Int? = nil, token: String? = nil
    ) {
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
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
            let worker = Task.detached(priority: .userInitiated) {
                pendingImages.map { image in
                    (
                        image.messageID,
                        image.fileURLs.compactMap { url -> Data? in
                            guard !Task.isCancelled else { return nil }
                            return DockModel.transcriptImageData(url)
                        }
                    )
                }
            }
            let loaded = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, generation == sessionResumeGeneration,
                let current = sessionTranscriptPreview
            else { return }
            var messages = current.messages
            for (id, data) in loaded {
                guard let index = messages.firstIndex(where: { $0.id == id }) else { continue }
                let images = data.compactMap { NSImage(data: $0) }
                if !images.isEmpty { messages[index] = messages[index].attachingImages(images) }
            }
            sessionTranscriptPreview = SessionTranscriptPreview(
                messages: messages, rowIDs: current.rowIDs,
                references: current.references, pendingImages: current.pendingImages)
        }
    }
}
