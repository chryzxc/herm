import AppKit
import Testing

@testable import Herm

@MainActor
struct TranscriptImageHydrationTests {
    @Test func fileReferenceDecodesOnDemandAtTheRequestedSize() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = NSImage(size: NSSize(width: 640, height: 320), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let data = try #require(original.tiffRepresentation)
        try data.write(to: url)
        let model = DockModel.parseMessages([["role": "user", "content": "@image:`\(url.path)`"]])
        let message = try #require(model.messages.first)
        #expect(message.images.isEmpty)
        #expect(message.restoredImageURLs == [url])
        let thumbnail = try #require(await AttachmentThumbnailLoader.shared.image(at: url, maximumPixelSize: 440))
        #expect(thumbnail.width == 440)
        #expect(thumbnail.height == 220)
        let preview = try #require(await AttachmentThumbnailLoader.shared.image(at: url, maximumPixelSize: 1_800))
        #expect(preview.width == 640)
        let embedded = try #require(URL(string: "data:image/tiff;base64,\(data.base64EncodedString())"))
        let embeddedThumbnail = try #require(
            await AttachmentThumbnailLoader.shared.image(at: embedded, maximumPixelSize: 440))
        #expect(embeddedThumbnail.width == thumbnail.width)
        #expect(embeddedThumbnail.height == thumbnail.height)
        #expect(message.images.isEmpty)
    }
}
