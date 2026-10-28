import SwiftUI

/// Shared motion policy for controls and one-shot surface effects.
enum DockMotion {
    static func isEnabled(reduceMotion: Bool, theme: DockThemeID = DockThemeRuntime.current) -> Bool {
        !reduceMotion && theme.style.animates
    }

    static func animation(reduceMotion: Bool, duration: TimeInterval = 0.2) -> Animation? {
        isEnabled(reduceMotion: reduceMotion) ? .dockEase(duration: duration) : nil
    }

    static func pressScale(isPressed: Bool, isEnabled: Bool, reduceMotion: Bool) -> CGFloat {
        isPressed && isEnabled && Self.isEnabled(reduceMotion: reduceMotion) ? DockThemeStyle.current.pressScale : 1
    }

    static func hoverOffset(isHovered: Bool, isPressed: Bool, isEnabled: Bool, reduceMotion: Bool) -> CGFloat {
        guard isHovered, !isPressed, isEnabled, Self.isEnabled(reduceMotion: reduceMotion) else { return 0 }
        switch DockThemeStyle.current.motion {
        case .float: return -1
        case .bouncy: return -1.5
        case .glide, .snap, .mechanical: return 0
        }
    }

    static var revealDistance: CGFloat {
        switch DockThemeStyle.current.motion {
        case .float: 5
        case .bouncy: 7
        case .glide: 3
        case .snap, .mechanical: 0
        }
    }
}

/// Suppress inherited explicit animations as well as local implicit animations.
struct DockMotionAccessibility: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if !DockMotion.isEnabled(reduceMotion: reduceMotion) {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

private struct DockSurfaceReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        let settled = hasAppeared || !DockMotion.isEnabled(reduceMotion: reduceMotion)
        content
            // Animate only this compositing effect, never the child's layout or live data.
            .animation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.22)) { view in
                view.opacity(settled ? 1 : 0.85).offset(y: settled ? 0 : DockMotion.revealDistance)
            }
            .onAppear { hasAppeared = true }
    }
}

extension View {
    func dockSurfaceReveal() -> some View {
        modifier(DockSurfaceReveal())
    }
}
