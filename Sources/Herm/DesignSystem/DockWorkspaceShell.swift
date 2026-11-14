import SwiftUI

/// Shell metrics shared by every desktop destination.
enum DockShell {
    static var isFlat: Bool { DockThemeStyle.current.flatShell }
    /// Gap between the card and the window's trailing and bottom edges.
    static var margin: CGFloat { isFlat ? 0 : 8 }
    static var radius: CGFloat { isFlat ? 0 : 12 }
}

private struct DockShellToolbarHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Height of the shell's title row; panes keep it in the frame tint instead of painting the canvas there.
    var dockShellToolbarHeight: CGFloat {
        get { self[DockShellToolbarHeightKey.self] }
        set { self[DockShellToolbarHeightKey.self] = newValue }
    }
}

/// Frame tint over the title row, canvas below it.
struct DockShellFill: View {
    @Environment(\.dockShellToolbarHeight) private var toolbarHeight

    var body: some View {
        VStack(spacing: 0) {
            Color.dockSidebar.frame(height: toolbarHeight)
            Color.dockCanvas
        }
    }
}

/// The one window layout for every desktop page: a tinted chrome frame (icon
/// rail and title row, `Color.dockSidebar`) around a single rounded content
/// card painted with `Color.dockCanvas`. Pages render inside `content` and
/// inherit the curve, edge and tint; they must not paint their own frame.
///
/// Inside the card, left-hand panes (lists, navigation) use `Color.dockCanvas`
/// so the curve stays visible. Only the rail and title rows use `dockSidebar`.
struct DockWorkspaceShell<Rail: View, Content: View>: View {
    let toolbarHeight: CGFloat
    @ViewBuilder let rail: () -> Rail
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            rail()
            let insets = EdgeInsets(
                top: toolbarHeight, leading: 0, bottom: DockShell.margin, trailing: DockShell.margin)
            content()
                // Lay out inside the card, not just mask to it, or trailing/bottom content is clipped by the margin.
                .dockPadding(EdgeInsets(top: 0, leading: 0, bottom: DockShell.margin, trailing: DockShell.margin))
                // The frame tint is opaque, so the card carries its own canvas and skin backdrop
                // (Hermes Desktop paints its backdrop inside the chat surface the same way).
                .background {
                    if DockThemeStyle.current.material != .glass { DockShellFill().overlay(DockBackdrop()) }
                }
                .mask(
                    ToolbarRowAndCardShape(
                        toolbarHeight: toolbarHeight, margin: DockShell.margin, radius: DockShell.radius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: DockShell.radius, style: .continuous)
                        .stroke(Color.dockBorderLight, lineWidth: DockLayout.hairline)
                        .dockPadding(insets)
                }
        }
        .environment(\.dockShellToolbarHeight, toolbarHeight)
        .dockPaneTint(Color.dockSidebar)
    }
}

extension View {
    /// A pane inside the shell's card (list, navigation, content). Painting it
    /// with the canvas keeps the card's curve visible against the chrome.
    func dockShellPane() -> some View { background(DockShellFill()) }

    /// Chrome that frames the card: icon rail and title rows.
    func dockShellChrome(_ isActive: Bool = true) -> some View { background(isActive ? Color.dockSidebar : .clear) }
}
