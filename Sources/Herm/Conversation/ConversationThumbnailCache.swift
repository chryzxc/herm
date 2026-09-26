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

        let target = NSSize(width: size, height: size)
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let sourceSize = source.size
        let scale = min(
            target.width / max(1, sourceSize.width),
            target.height / max(1, sourceSize.height)
        )
        let drawnSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawnRect = NSRect(
            x: (target.width - drawnSize.width) / 2,
            y: (target.height - drawnSize.height) / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )
        source.draw(in: drawnRect, from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        cache.setObject(Entry(result), forKey: cacheKey, cost: Int(size * size * 4))
        return result
    }
}
