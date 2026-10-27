import CoreGraphics
import Foundation

enum SessionSimulatorPlatform: String, CaseIterable {
    case ios, android

    var title: String { self == .ios ? "iOS Simulator" : "Android Emulator" }

}

enum SessionSimulatorGeometry {
    /// A neutral device shell, not a model-specific hardware skin. Pixels and input use the same rect.
    static func screenRadius(rect: CGRect, platform: SessionSimulatorPlatform) -> CGFloat {
        min(rect.width, rect.height) * (platform == .ios ? 0.14 : 0.12)
    }

    static func fittedRect(source: CGSize, bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Reserve a 40pt rail, 6pt gap, outer margins, and the native canvas's 10pt screen inset.
    static func stageCanvasSize(source: CGSize, available: CGSize) -> CGSize {
        let screen = fittedRect(
            source: source,
            bounds: CGRect(
                x: 0, y: 0, width: max(0, available.width - 82), height: max(0, available.height - 36)))
        return CGSize(width: screen.width + 20, height: screen.height + 20)
    }

    /// Input and captured pixels share a top-left origin. Letterboxing never sends input.
    static func normalizedPoint(_ point: CGPoint, imageRect: CGRect, clamp: Bool = false) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0, clamp || imageRect.contains(point) else { return nil }
        return CGPoint(
            x: min(1, max(0, (point.x - imageRect.minX) / imageRect.width)),
            y: min(1, max(0, (point.y - imageRect.minY) / imageRect.height)))
    }
}
