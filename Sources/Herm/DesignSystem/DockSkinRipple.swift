import AppKit

/// The selected skin is already live underneath one non-interactive snapshot.
@MainActor
enum DockSkinRipple {
    private static weak var activeOverlay: RippleOverlay?

    static func play(to theme: DockThemeID) {
        guard let app = NSApp else { return }
        // Rapid choices replace the old snapshot, including when the new skin is still.
        activeOverlay?.removeFromSuperview()
        guard theme.style.animates, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pointer = NSEvent.mouseLocation
        let windows = app.orderedWindows.filter {
            $0.isVisible && $0.occlusionState.contains(.visible) && !$0.inLiveResize
                && $0.appearance?.name != DockThemeStore.notchAppearance.name
        }
        guard
            let window = windows.first(where: { $0.frame.contains(pointer) })
                ?? windows.first(where: { $0.isKeyWindow }),
            let content = window.contentView, let host = content.superview, content.bounds.width > 1,
            content.bounds.height > 1, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let snapshot = rep.cgImage else { return }
        let overlay = RippleOverlay(frame: content.frame)
        activeOverlay = overlay
        overlay.wantsLayer = true
        overlay.layer?.contents = snapshot
        overlay.layer?.contentsGravity = .resize
        host.addSubview(overlay, positioned: .above, relativeTo: content)
        let location = overlay.convert(window.convertPoint(fromScreen: pointer), from: nil)
        let center = CGPoint(
            x: min(max(0, location.x), overlay.bounds.width),
            y: min(max(0, location.y), overlay.bounds.height))
        overlay.reveal(from: center, motion: theme.style.motion)
    }
}

private final class RippleOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Floating skins spread horizontally first; paper and graphite open evenly.
    /// Mechanical skins cut across the snapshot with a straight edge.
    func reveal(from center: CGPoint, motion: DockThemeMotion) {
        let reach = hypot(max(center.x, bounds.width - center.x), max(center.y, bounds.height - center.y)) + 2
        let straight = motion == .mechanical || motion == .snap
        func path(_ radius: CGFloat, aspect: CGFloat) -> CGPath {
            let hole = CGRect(
                x: center.x - radius * aspect, y: center.y - radius / aspect,
                width: 2 * radius * aspect, height: 2 * radius / aspect)
            let result = CGMutablePath()
            result.addRect(bounds)
            if straight {
                result.addRect(CGRect(x: hole.minX, y: bounds.minY, width: hole.width, height: bounds.height))
            } else {
                result.addEllipse(in: hole)
            }
            return result
        }
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.path = path(reach, aspect: 1)
        layer?.mask = mask
        let sweep = CAKeyframeAnimation(keyPath: "path")
        let aspect: CGFloat = motion == .float || motion == .bouncy ? 1.2 : 1
        sweep.values = [path(0.01, aspect: 1), path(reach * 0.42, aspect: aspect), path(reach, aspect: 1)]
        sweep.keyTimes = [0, 0.4, 1]
        sweep.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut)]
        sweep.duration = straight ? 0.2 : 0.38
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        mask.add(sweep, forKey: "skinReveal")
        CATransaction.commit()
    }
}
