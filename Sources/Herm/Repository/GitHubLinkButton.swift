import SwiftUI

/// Shared GitHub destination control for issue and pull-request headers.
struct GitHubLinkButton: View {
    let destination: URL
    let accessibilityLabel: String

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 5) {
                DockIcon(.arrowSquareOut, size: 12, color: Color.dockSecondaryText)
                Text("GitHub")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.dockSecondaryText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.dockControlSurface)
            )
        }
        .buttonStyle(.plain)
        .help("Open on GitHub")
        .accessibilityLabel(accessibilityLabel)
    }
}
