import SwiftUI

/// Draw the workspace backdrop only while a section header is at the viewport edge.
struct SessionSidebarStickyBackground: ViewModifier {
    nonisolated static let coordinateSpace = "session-sidebar-scroll"
    @State private var isAtTop = false

    func body(content: Content) -> some View {
        content
            .background {
                // Glass has no backdrop: rows fade out underneath instead (see below).
                if isAtTop, !DockThemeRuntime.current.usesNativeMaterial {
                    background
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .named(Self.coordinateSpace)).minY <= 0.5
            } action: {
                isAtTop = $0
            }
    }

    private var background: some View { Color.dockCanvas }
}

extension View {
    func sessionSidebarStickyBackground() -> some View {
        modifier(SessionSidebarStickyBackground())
    }

    /// Glass can't paint an opaque header backdrop (any translucent fill either
    /// shows rows through or reads as a separate slab), so section rows fade
    /// out as they slide under the pinned header. Apply to a section's content.
    func sessionSidebarFadesUnderStickyHeader() -> some View {
        let fades = DockThemeRuntime.current.usesNativeMaterial
        // ponytail: fixed header height (12 top spacing + 30 header + 2 bottom); measure if headers change size.
        return visualEffect { content, proxy in
            let minY = proxy.frame(in: .named(SessionSidebarStickyBackground.coordinateSpace)).minY
            return content.opacity(fades ? min(max((minY - 28) / 16, 0), 1) : 1)
        }
    }
}
