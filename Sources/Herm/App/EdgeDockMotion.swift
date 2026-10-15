import AppKit
import QuartzCore
import SwiftUI

/// Content motion complements the native edge-anchored window resize.
@MainActor
enum EdgeDockMotion {
    static let revealDuration: TimeInterval = 0.46
    static let collapseDuration: TimeInterval = 0.26
    /// The notch shell's rail ⇄ preview spring; `morphSettle` is when it is visually at rest.
    static let morph = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let morphSettle: TimeInterval = 0.45
    static let windowResize: TimeInterval = 0.12

    static func reveal(_ view: NSView?, side: EdgeDockSide, fromShortcut: Bool) {
        guard let view else { return }
        view.wantsLayer = true
        view.alphaValue = 1
        cancel(view)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = view.layer else { return }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.15, 1]
        opacity.keyTimes = [0, 0.2, 1]
        opacity.duration = revealDuration
        opacity.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut)]
        layer.add(opacity, forKey: "dock.reveal.opacity")

        let slide = CASpringAnimation(keyPath: "transform.translation.x")
        slide.fromValue = (side == .right ? 1.0 : -1.0) * (fromShortcut ? 22 : 12)
        slide.toValue = 0
        slide.mass = 1
        slide.stiffness = 260
        slide.damping = 30
        slide.initialVelocity = 0
        slide.duration = revealDuration
        layer.add(slide, forKey: "dock.reveal.slide")
    }

    static func cancel(_ view: NSView?) {
        view?.layer?.removeAnimation(forKey: "dock.reveal.opacity")
        view?.layer?.removeAnimation(forKey: "dock.reveal.slide")
    }
}
