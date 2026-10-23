import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Herm

struct AttachmentThumbnailLoaderTests {
    @Test func thumbnailsAreBoundedCachedAndInvalidatedWhenFileChanges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        func writeImage(width: Int, height: Int) throws {
            let context = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
            let image = try #require(context.makeImage())
            let destination = try #require(
                CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        try writeImage(width: 2_400, height: 1_200)
        let loader = AttachmentThumbnailLoader()
        let first = try #require(await loader.image(at: url))
        #expect(first.width == AttachmentThumbnailLoader.maximumPixelSize)
        #expect(first.height == first.width / 2)
        #expect(await loader.image(at: url) === first)

        try writeImage(width: 100, height: 200)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let changed = try #require(await loader.image(at: url))
        #expect(changed !== first)
        #expect(changed.height == changed.width * 2)
        try FileManager.default.removeItem(at: url)
        #expect(await loader.image(at: url) == nil)
    }

    @Test func invalidAndRemoteInputsDoNotDecode() async throws {
        let loader = AttachmentThumbnailLoader()
        #expect(await loader.image(at: URL(string: "https://example.invalid/image.png")!) == nil)
        #expect(await loader.image(at: URL(string: "data:image/png;base64,bm90IGFuIGltYWdl")!) == nil)
    }
}
