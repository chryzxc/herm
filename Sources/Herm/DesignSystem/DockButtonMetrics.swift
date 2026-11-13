import SwiftUI

/// Size belongs to the action group, never to its visual priority or native controlSize.
enum DockButtonSize: CaseIterable {
    case inline, compact, standard, accessible

    var height: CGFloat {
        switch self {
        case .inline: 24
        case .compact: DockControlMetrics.compactHeight
        case .standard: DockControlMetrics.standardHeight
        case .accessible: DockControlMetrics.hitTarget
        }
    }
    var horizontalPadding: CGFloat { self == .inline ? 7 : self == .compact ? 10 : 12 }
}

extension EnvironmentValues {
    @Entry var dockButtonSize: DockButtonSize = .compact
}

extension View {
    /// Apply to the common container for related actions, including adaptive stack alternatives.
    func dockButtonSize(_ size: DockButtonSize) -> some View {
        environment(\.dockButtonSize, size)
    }

    /// Shared by every filled/outlined text button. Links, rows and icon-only controls have separate contracts.
    func dockButtonMetrics() -> some View { modifier(DockButtonMetrics()) }
}

private struct DockButtonMetrics: ViewModifier {
    @Environment(\.dockButtonSize) private var size
    @Environment(\.dockWorkspaceScale) private var scale

    func body(content: Content) -> some View {
        content
            .dockFont(.control)
            .padding(.horizontal, DockWorkspaceScale.points(size.horizontalPadding, scale: scale))
            .padding(.vertical, DockWorkspaceScale.points(4, scale: scale))
            .frame(minHeight: DockWorkspaceScale.points(size.height, scale: scale))
    }
}
