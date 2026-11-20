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
    @Entry var dockButtonIsIconOnly = false
}

extension View {
    /// Apply to the common container for related actions, including adaptive stack alternatives.
    func dockButtonSize(_ size: DockButtonSize) -> some View {
        environment(\.dockButtonSize, size)
    }

    /// Shared by every filled/outlined text button. Links, rows and icon-only controls have separate contracts.
    func dockButtonMetrics() -> some View { modifier(DockButtonMetrics()) }

    /// An icon-only primary/secondary action: a square at its group's height, so it lines up
    /// with the labeled actions beside it instead of a padded, wider-than-tall box.
    func dockIconOnlyAction() -> some View { environment(\.dockButtonIsIconOnly, true) }
}

private struct DockButtonMetrics: ViewModifier {
    @Environment(\.dockButtonSize) private var size
    @Environment(\.dockWorkspaceScale) private var scale
    @Environment(\.dockButtonIsIconOnly) private var isIconOnly

    @ViewBuilder
    func body(content: Content) -> some View {
        if isIconOnly {
            let side = DockWorkspaceScale.points(size.height, scale: scale)
            content.dockFont(.control).frame(width: side, height: side)
        } else {
            labeled(content)
        }
    }

    private func labeled(_ content: Content) -> some View {
        content
            .dockFont(.control)
            .padding(
                .horizontal,
                DockWorkspaceScale.spacing(
                    DockWorkspaceScale.points(size.horizontalPadding, scale: scale), scale: scale)
            )
            .padding(.vertical, DockWorkspaceScale.spacing(DockWorkspaceScale.points(4, scale: scale), scale: scale))
            .frame(minHeight: DockWorkspaceScale.points(size.height, scale: scale))
    }
}
