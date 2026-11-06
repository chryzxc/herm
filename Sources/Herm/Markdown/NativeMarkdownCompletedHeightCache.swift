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
    struct Measurement {
        let height: CGFloat
        let codeSize: NSSize?
    }
    private final class MeasurementBox {
        let value: Measurement
        init(_ value: Measurement) { self.value = value }
    }
    private static let cache: NSCache<Box, MeasurementBox> = {
        let cache = NSCache<Box, MeasurementBox>()
        // One eight-message history page can contain thousands of small Markdown sections.
        cache.countLimit = 32_000
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private(set) static var hits = 0
    private(set) static var misses = 0
    static func measurement(for key: Key) -> Measurement? {
        guard let value = cache.object(forKey: Box(key)) else {
            misses += 1
            return nil
        }
        hits += 1
        return value.value
    }
    static func height(for key: Key) -> CGFloat? { measurement(for: key)?.height }
    static func codeSize(for key: Key) -> NSSize? { cache.object(forKey: Box(key))?.value.codeSize }

    static func store(_ height: CGFloat, for key: Key, codeSize: NSSize? = nil) {
        guard height.isFinite, height >= 0, key.width.isFinite else { return }
        cache.setObject(
            MeasurementBox(Measurement(height: height, codeSize: codeSize)),
            forKey: Box(key), cost: key.source.utf8.count + 128)
    }
    static func removeAll() {
        cache.removeAllObjects()
        hits = 0
        misses = 0
    }
}
