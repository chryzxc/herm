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
    /// The top island's spring overshoots slightly, like the iPhone Dynamic Island.
    static let islandMorph = Animation.spring(response: 0.42, dampingFraction: 0.7)
    /// Closing must never overshoot: an island that dips below the collapsed size
    /// uncovers the camera housing, so it settles critically damped.
    static let islandCollapse = Animation.spring(response: 0.36, dampingFraction: 1)
    static let morphSettle: TimeInterval = 0.45
    static let windowResize: TimeInterval = 0.12

    /// The panel grows and shrinks with the notch's own springs.
    static func panelMorph(side: EdgeDockSide, opening: Bool) -> Animation {
        opening ? (side == .top ? islandMorph : morph) : (side == .top ? islandCollapse : morph)
    }

    static func reveal(_ view: NSView?, side: EdgeDockSide, fromShortcut: Bool) {
        guard let view else { return }
        view.wantsLayer = true
        view.alphaValue = 1
        cancel(view)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let layer = view.layer
        else { return }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.15, 1]
        opacity.keyTimes = [0, 0.2, 1]
        opacity.duration = revealDuration
        opacity.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut)]
        layer.add(opacity, forKey: "dock.reveal.opacity")

        // Slides in from the anchored edge; layer y points up, so top drops down.
        let slide = CASpringAnimation(keyPath: side == .top ? "transform.translation.y" : "transform.translation.x")
        slide.fromValue = (side == .left ? -1.0 : 1.0) * (fromShortcut ? 22 : 12)
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

/// Reveals the panel through a notch-shaped mask that grows from the collapsed notch, like the quick preview.
struct EdgeSurfaceReveal: ViewModifier {
    let isActive: Bool
    let side: EdgeDockSide
    let revealed: Bool
    let collapsed: CGSize

    @ViewBuilder func body(content: Content) -> some View {
        if isActive {
            content.mask {
                GeometryReader { geometry in
                    EdgeNotchShape(side: side).fill(.black)
                        .frame(
                            width: revealed ? geometry.size.width : min(collapsed.width, geometry.size.width),
                            height: revealed ? geometry.size.height : min(collapsed.height, geometry.size.height)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.alignment)
                }
            }
        } else {
            content
        }
    }
}
