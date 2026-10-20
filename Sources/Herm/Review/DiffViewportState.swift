import AppKit

struct DiffViewportMetadata: Codable {
    struct Offset: Codable {
        let x: Double
        let y: Double
    }
    let comparison: String
    let offsets: [Offset]
}

/// Scrolling stays outside SwiftUI observation; persistence receives debounced metadata only.
@MainActor
final class DiffViewportState {
    var activeKey = ""
    private(set) var restorationRevision = 0
    var comparison = ""
    var origins: [NSPoint] = []
    var changed: ((DiffViewportMetadata) -> Void)?
    private var pending: Task<Void, Never>?

    var metadata: DiffViewportMetadata {
        DiffViewportMetadata(
            comparison: comparison, offsets: origins.prefix(2).map { .init(x: Double($0.x), y: Double($0.y)) })
    }
    func restore(_ metadata: DiffViewportMetadata) {
        restorationRevision += 1
        comparison = metadata.comparison
        origins = metadata.offsets.prefix(2).compactMap { point in
            guard point.x.isFinite, point.y.isFinite, (0...10_000_000).contains(point.x),
                (0...10_000_000).contains(point.y)
            else { return nil }
            return NSPoint(x: point.x, y: point.y)
        }
    }
    func record(_ origin: NSPoint, column: Int) {
        guard (0...1).contains(column), origin.x.isFinite, origin.y.isFinite else { return }
        while origins.count <= column { origins.append(.zero) }
        origins[column] = origin
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            changed?(metadata)
        }
    }
}
