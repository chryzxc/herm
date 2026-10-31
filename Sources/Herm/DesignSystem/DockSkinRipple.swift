import AppKit

/// Reveals a skin change as a circle that grows from the pointer across every window.
/// The old appearance is a snapshot above the live content; the new skin is already
/// applied beneath, and the snapshot is cut away by an expanding hole.
@MainActor
enum DockSkinRipple {
    private static let duration: CFTimeInterval = 0.75

    static func play() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let app = NSApp else { return }
        let pointer = NSEvent.mouseLocation
        for window in app.windows
        where window.isVisible && window.appearance?.name != DockThemeStore.notchAppearance.name {
            guard let content = window.contentView, let host = content.superview, content.bounds.width > 1,
                let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { continue }
            content.cacheDisplay(in: content.bounds, to: rep)
            guard let snapshot = rep.cgImage else { continue }
            let overlay = RippleOverlay(frame: content.frame)
            overlay.wantsLayer = true
            overlay.layer?.contents = snapshot
            overlay.layer?.contentsGravity = .resize
            let origin = window.convertPoint(fromScreen: pointer)
            let center = CGPoint(x: origin.x - content.frame.minX, y: origin.y - content.frame.minY)
            host.addSubview(overlay, positioned: .above, relativeTo: nil)
            overlay.reveal(from: center, duration: duration) { overlay.removeFromSuperview() }
        }
    }
}

private final class RippleOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func reveal(from center: CGPoint, duration: CFTimeInterval, completion: @escaping () -> Void) {
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: bounds.maxX, y: 0), CGPoint(x: 0, y: bounds.maxY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
        ]
        let radius = corners.map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
        func path(_ r: CGFloat) -> CGPath {
            let p = CGMutablePath()
            p.addRect(bounds)
            p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            return p
        }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.path = path(radius)
        layer?.mask = mask
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = path(0)
        grow.toValue = path(radius)
        grow.duration = duration
        grow.timingFunction = CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        mask.add(grow, forKey: "ripple")
        CATransaction.commit()
    }
}
