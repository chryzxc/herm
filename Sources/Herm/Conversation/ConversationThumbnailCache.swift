import AppKit

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

    static func image(_ source: NSImage, key: String, size: CGFloat = 220) -> NSImage {
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached.image }

        let sourceSize = source.size
        let scale = min(size / max(1, sourceSize.width), size / max(1, sourceSize.height))
        // Keep the bitmap fitted too, or the view scales square padding a second time.
        let target = NSSize(width: max(1, sourceSize.width * scale), height: max(1, sourceSize.height * scale))
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        cache.setObject(Entry(result), forKey: cacheKey, cost: Int(target.width * target.height * 4))
        return result
    }
}
