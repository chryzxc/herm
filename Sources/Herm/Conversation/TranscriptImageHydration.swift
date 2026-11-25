import AppKit
import Foundation

/// Small, pull-based batches keep decoding ahead of the UI without queueing a transcript's worth of bytes.
enum TranscriptImageHydration {
    @MainActor
    static func reusePreview(
        _ preview: SessionTranscriptPreview?, in transcript: RestoredTranscript
    ) -> (messages: [ChatMessage], pending: [RestoredTranscript.PendingImages]) {
        guard let preview else { return (transcript.messages, transcript.pendingImages) }
        let images = Dictionary(
            preview.messages.lazy.filter { !$0.images.isEmpty }.map { ($0.id, $0.images) },
            uniquingKeysWith: { first, _ in first })
        let previewReferences = Dictionary(
            preview.pendingImages.map { ($0.messageID, $0.fileURLs) }, uniquingKeysWith: { first, _ in first })
        var transferred = Set<UUID>()
        var pending: [RestoredTranscript.PendingImages] = []
        for entry in transcript.pendingImages {
            // The preview can finish with fewer images if a file was inaccessible. Retry
            // the original list rather than appending to a partial or differently ordered set.
            if !entry.fileURLs.isEmpty, previewReferences[entry.messageID] == entry.fileURLs,
                images[entry.messageID]?.count == entry.fileURLs.count
            {
                transferred.insert(entry.messageID)
            } else {
                pending.append(entry)
            }
        }
        guard !transferred.isEmpty else { return (transcript.messages, pending) }
        let messages = transcript.messages.map { message in
            guard transferred.contains(message.id), let carried = images[message.id] else { return message }
            return message.attachingImages(carried)
        }
        return (messages, pending)
    }

    struct Job: Sendable {
        let messageID: UUID
        let url: URL
        let isLastAttachment: Bool
    }

    struct Queue {
        static let batchSize = 4
        private var urls: [UUID: ArraySlice<URL>] = [:]
        private let newestFirst: [UUID]
        private var fallbackIndex = 0

        init(_ pending: [RestoredTranscript.PendingImages]) {
            var order: [UUID] = []
            for entry in pending where !entry.fileURLs.isEmpty {
                if urls[entry.messageID] == nil { order.append(entry.messageID) }
                urls[entry.messageID, default: []].append(contentsOf: entry.fileURLs)
            }
            newestFirst = Array(order.reversed())
        }

        mutating func next(prioritizing visible: [UUID]) -> [Job] {
            guard !urls.isEmpty else { return [] }
            var batch: [Job] = []
            for id in visible {
                take(id, into: &batch)
                if batch.count == Self.batchSize { return batch }
            }
            while batch.count < Self.batchSize, fallbackIndex < newestFirst.count {
                let id = newestFirst[fallbackIndex]
                take(id, into: &batch)
                if urls[id] == nil { fallbackIndex += 1 }
            }
            return batch
        }

        private mutating func take(_ id: UUID, into batch: inout [Job]) {
            guard var remaining = urls[id] else { return }
            while batch.count < Self.batchSize, let url = remaining.popFirst() {
                batch.append(Job(messageID: id, url: url, isLastAttachment: remaining.isEmpty))
            }
            urls[id] = remaining.isEmpty ? nil : remaining
        }
    }

    struct Prepared: Sendable {
        let job: Job
        let data: Data?
        let thumbnail: CGImage?
    }

    actor Worker {
        static let shared = Worker()

        func prepare(_ jobs: [Job], load: @Sendable (URL) -> Data?) -> [Prepared] {
            jobs.compactMap { job in
                guard !Task.isCancelled else { return nil }
                let data = load(job.url)
                return Prepared(job: job, data: data, thumbnail: data.flatMap(ConversationThumbnailCache.prepare))
            }
        }
    }

    @MainActor
    struct Application {
        private var partial: [UUID: [(NSImage, CGImage?)]] = [:]
        private var indexes: [UUID: Int] = [:]
        private var indexed = false

        mutating func apply(_ batch: [Prepared], to messages: inout [ChatMessage], reindex: Bool = false) -> Bool {
            if !indexed || reindex {
                indexes = Dictionary(
                    messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                indexed = true
            }
            var changed = false
            for image in batch {
                let id = image.job.messageID
                if let data = image.data, let source = NSImage(data: data) {
                    partial[id, default: []].append((source, image.thumbnail))
                }
                guard image.job.isLastAttachment,
                    let images = partial.removeValue(forKey: id), let index = indexes[id]
                else { continue }
                let message = messages[index]
                let previousCount = message.images.count
                let imageCount = previousCount + images.count
                for (offset, image) in images.enumerated() {
                    guard let thumbnail = image.1 else { continue }
                    let key = ConversationThumbnailCache.key(
                        messageID: id, index: previousCount + offset,
                        imageCount: imageCount, contentRevision: message.contentRevision)
                    ConversationThumbnailCache.storePrepared(thumbnail, source: image.0, key: key)
                }
                messages[index] = message.attachingImages(images.map { $0.0 })
                changed = true
            }
            return changed
        }
    }
}
