import CoreGraphics
import Foundation

enum SessionSimulatorPlatform: String, CaseIterable {
    case ios, android

    var title: String { self == .ios ? "iOS Simulator" : "Android Emulator" }

}

enum SessionSimulatorGeometry {
    static func fittedRect(source: CGSize, bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Input and captured pixels share a top-left origin. Letterboxing never sends input.
    static func normalizedPoint(_ point: CGPoint, imageRect: CGRect, clamp: Bool = false) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0, clamp || imageRect.contains(point) else { return nil }
        return CGPoint(
            x: min(1, max(0, (point.x - imageRect.minX) / imageRect.width)),
            y: min(1, max(0, (point.y - imageRect.minY) / imageRect.height)))
    }
}
