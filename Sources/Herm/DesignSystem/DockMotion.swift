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
                view.opacity(settled ? 1 : 0.85).offset(y: settled ? 0 : 6)
            }
            .onAppear { hasAppeared = true }
    }
}

extension View {
    func dockSurfaceReveal() -> some View {
        modifier(DockSurfaceReveal())
    }
}
