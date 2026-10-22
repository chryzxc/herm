import AppKit

/// Numeric presentation measurements only; eviction cannot remove transcript data.
@MainActor
enum NativeMarkdownCompletedHeightCache {
    struct Key: Hashable {
        let source: String
        let kind: MarkdownRenderSectionKind
        let width: CGFloat
        let bodySize: CGFloat
        let bodyWeight: CGFloat
        let themeRevision: Int
        let mentionRevision: Int
        let themeID: DockThemeID
    }
    private final class Box: NSObject {
        let value: Key
        init(_ value: Key) { self.value = value }
        override var hash: Int { value.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Box)?.value == value }
    }
    private static let cache: NSCache<Box, NSNumber> = {
        let cache = NSCache<Box, NSNumber>()
        cache.countLimit = 4_000
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private(set) static var hits = 0
    private(set) static var misses = 0
    static func height(for key: Key) -> CGFloat? {
        guard let value = cache.object(forKey: Box(key)) else {
            misses += 1
            return nil
        }
        hits += 1
        return CGFloat(value.doubleValue)
    }
    static func store(_ height: CGFloat, for key: Key) {
        guard height.isFinite, height >= 0, key.width.isFinite else { return }
        cache.setObject(NSNumber(value: Double(height)), forKey: Box(key), cost: key.source.utf8.count + 128)
    }
    static func removeAll() {
        cache.removeAllObjects()
        hits = 0
        misses = 0
    }
}
