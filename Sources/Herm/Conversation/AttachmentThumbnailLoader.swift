import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// File reads and image decoding stay off the UI actor, including cache misses.
actor AttachmentThumbnailLoader {
    static let shared = AttachmentThumbnailLoader()
    static let maximumPixelSize = 840

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func image(at url: URL, maximumPixelSize: Int = AttachmentThumbnailLoader.maximumPixelSize) -> CGImage? {
        guard url.isFileURL || url.scheme == "data" else { return nil }
        let identity = url.isFileURL ? url.absoluteString : SHA256.hash(data: Data(url.absoluteString.utf8)).description
        var key = "\(maximumPixelSize)|\(identity)"
        if url.isFileURL {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            key += "|\(modified)|\(attributes[.size] ?? "")"
        }
        if let entry = cache.object(forKey: key as NSString) { return entry.image }
        let source: CGImageSource?
        if url.isFileURL {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else {
            source = (try? Data(contentsOf: url)).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        }
        guard let source,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                ] as CFDictionary)
        else { return nil }
        cache.setObject(Entry(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }
}

struct AttachmentThumbnailView: View {
    let url: URL
    var maximumPixelSize = AttachmentThumbnailLoader.maximumPixelSize
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await AttachmentThumbnailLoader.shared.image(at: url, maximumPixelSize: maximumPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
