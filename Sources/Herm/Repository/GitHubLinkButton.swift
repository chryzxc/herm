import SwiftUI

/// Shared GitHub destination control for issue and pull-request headers.
struct GitHubLinkButton: View {
    let destination: URL
    let accessibilityLabel: String

    var body: some View {
        Link(destination: destination) {
            DockIcon(.arrowSquareOut, size: 13, color: Color.dockSecondaryText)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
                        .fill(Color.dockControlSurface.opacity(0.6))
                )
        }
        .buttonStyle(.dockHover)
        .fixedSize()
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
