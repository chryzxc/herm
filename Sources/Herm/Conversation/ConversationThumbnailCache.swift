import AppKit
import ImageIO

@MainActor
enum ConversationThumbnailCache {
    private final class Entry: NSObject {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 512
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func key(
        messageID: UUID,
        index: Int,
        imageCount: Int,
        contentRevision: Int,
        size: CGFloat = 220
    ) -> String {
        "\(messageID.uuidString):\(index):\(imageCount):\(contentRevision):\(Int(size.rounded()))"
    }

    static func cachedImage(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)?.image
    }

    static func image(_ source: NSImage, key: String, size: CGFloat = 220) -> NSImage {
        if let cached = cachedImage(forKey: key) { return cached }

        let target = fittedSize(source.size, size: size)
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        cache.setObject(Entry(result), forKey: key as NSString, cost: Int(target.width * target.height * 4))
        return result
    }

    nonisolated static func prepare(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Chat renders at up to 220 points, so keep enough pixels for a Retina display.
        return AttachmentThumbnailLoader.thumbnail(from: source, maximumPixelSize: 440)
    }

    static func storePrepared(_ thumbnail: CGImage, source: NSImage, key: String) {
        let image = NSImage(cgImage: thumbnail, size: fittedSize(source.size, size: 220))
        cache.setObject(Entry(image), forKey: key as NSString, cost: thumbnail.bytesPerRow * thumbnail.height)
    }

    private static func fittedSize(_ source: NSSize, size: CGFloat) -> NSSize {
        let scale = min(size / max(1, source.width), size / max(1, source.height))
        return NSSize(width: max(1, source.width * scale), height: max(1, source.height * scale))
    }
}
