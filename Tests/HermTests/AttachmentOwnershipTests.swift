import AppKit
import Foundation
import Testing

@testable import Herm

@MainActor
struct AttachmentOwnershipTests {
    @Test func cleanupPreservesSelectedTemporaryFilesAndDeletesOwnedPastes() throws {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selected-\(UUID()).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = DockModel(approvalSoundPlayer: {})
        defer { model.shutdown() }
        model.stageImageFile(at: url)
        model.removePendingImage(try #require(model.pendingImages.first))
        #expect(try Data(contentsOf: url) == data)
        #expect(model.stageImage(try #require(NSImage(data: data))))
        let pasted = try #require(model.pendingImages.first)
        #expect(pasted.ownsTemporaryFile)
        model.clearPendingImages()
        #expect(!FileManager.default.fileExists(atPath: pasted.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func pastedPNGIsStagedWithoutReencoding() throws {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let model = DockModel(approvalSoundPlayer: {})
        defer { model.shutdown() }
        #expect(model.stageImage(try #require(NSImage(data: png)), pngData: png))
        let staged = try #require(model.pendingImages.first)
        #expect(try Data(contentsOf: staged.fileURL) == png)
        // Without clipboard bytes the image is still encoded to a readable PNG.
        #expect(model.stageImage(try #require(NSImage(data: png))))
        #expect(NSImage(contentsOf: try #require(model.pendingImages.last).fileURL) != nil)
        model.clearPendingImages()
    }
}
