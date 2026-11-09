import SwiftUI

/// Shared GitHub destination control for issue and pull-request headers.
struct GitHubLinkButton: View {
    let destination: URL
    let accessibilityLabel: String

    var body: some View {
        Link(destination: destination) {
            DockIconButtonLabel(icon: .arrowSquareOut)
        }
        .buttonStyle(.dockHover)
        .fixedSize()
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
