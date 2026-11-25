import AppKit
import Testing

@testable import Herm

struct TranscriptImageHydrationTests {
    @Test func queuesVisibleImagesFirstAndKeepsAttachmentOrderAcrossBatches() {
        let rest = UUID()
        let newest = UUID()
        let visible = UUID()
        let urls = (0..<9).map { URL(fileURLWithPath: "/tmp/transcript-\($0).png") }
        var queue = TranscriptImageHydration.Queue([
            .init(messageID: rest, fileURLs: [urls[0]]),
            .init(messageID: visible, fileURLs: Array(urls[1...6])),
            .init(messageID: newest, fileURLs: Array(urls[7...])),
        ])
        let first = queue.next(prioritizing: [visible])
        let second = queue.next(prioritizing: [visible])
        let third = queue.next(prioritizing: [])
        #expect(first.map(\.url) == Array(urls[1...4]))
        #expect(first.allSatisfy { !$0.isLastAttachment })
        #expect(second.map(\.url) == Array(urls[5...8]))
        #expect(second.map(\.isLastAttachment) == [false, true, false, true])
        #expect(third.map(\.url) == [urls[0]])
        #expect(queue.next(prioritizing: [visible]).isEmpty)
    }

    @MainActor
    @Test func completePreviewTransfersOnceButPartialOrChangedListsRetry() {
        let row = ChatMessage(role: .user, text: "Images")
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let urls = [URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.png")]
        let references = RestoredTranscript.PendingImages(messageID: row.id, fileURLs: urls)
        let restored = RestoredTranscript(messages: [row], pendingImages: [references])
        func preview(images: [NSImage], references: [RestoredTranscript.PendingImages]) -> SessionTranscriptPreview {
            SessionTranscriptPreview(
                messages: [row.attachingImages(images)], rowIDs: [:], references: [:], pendingImages: references)
        }

        let transferred = TranscriptImageHydration.reusePreview(
            preview(images: [image, image], references: [references]), in: restored)
        #expect(transferred.messages.first?.images.count == 2)
        #expect(transferred.pending.isEmpty)

        let partiallyLoaded = TranscriptImageHydration.reusePreview(
            preview(images: [image], references: [references]), in: restored)
        #expect(partiallyLoaded.messages.first?.images.isEmpty == true)
        #expect(partiallyLoaded.pending.first?.fileURLs == urls)

        let changed = RestoredTranscript.PendingImages(messageID: row.id, fileURLs: Array(urls.reversed()))
        let changedHandoff = TranscriptImageHydration.reusePreview(
            preview(images: [image, image], references: [changed]), in: restored)
        #expect(changedHandoff.messages.first?.images.isEmpty == true)
        #expect(changedHandoff.pending.first?.fileURLs == urls)
    }

    @MainActor
    @Test func splitAttachmentBatchesCommitToTheCurrentRowWithoutLosingALaterEdit() async throws {
        let original = ChatMessage(role: .user, text: "Original")
        let inserted = ChatMessage(role: .user, text: "New row")
        let image = NSImage(size: NSSize(width: 160, height: 80), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let data = try #require(image.tiffRepresentation)
        let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/attachment-\($0).tiff") }
        var queue = TranscriptImageHydration.Queue([.init(messageID: original.id, fileURLs: urls)])
        var application = TranscriptImageHydration.Application()
        var messages = [original]
        let first = await TranscriptImageHydration.Worker.shared.prepare(queue.next(prioritizing: [])) { _ in data }
        #expect(!application.apply(first, to: &messages))
        messages.insert(inserted, at: 0)
        let last = await TranscriptImageHydration.Worker.shared.prepare(queue.next(prioritizing: [])) { _ in nil }
        #expect(application.apply(last, to: &messages, reindex: true))
        #expect(messages[0].images.isEmpty)
        #expect(messages[1].id == original.id)
        #expect(messages[1].images.count == 4)
        let key = ConversationThumbnailCache.key(
            messageID: original.id, index: 0, imageCount: 4, contentRevision: original.contentRevision)
        #expect(ConversationThumbnailCache.cachedImage(forKey: key) != nil)
    }
}
