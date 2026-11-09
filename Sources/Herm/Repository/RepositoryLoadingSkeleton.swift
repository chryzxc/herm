import SwiftUI

/// Shared placeholder used by GitHub detail and list surfaces while their canonical
/// payload is loading. It breathes with one slow opacity pulse that Core Animation
/// drives, so dozens of blocks cost nothing on the main thread. It is static under
/// Reduce Motion or when the host is hidden.
struct RepositoryShimmerBlock: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockHostVisible) private var hostVisible
    @State private var dim = false

    var body: some View {
        let animates = DockMotion.isEnabled(reduceMotion: reduceMotion) && hostVisible
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.dockSurface4.opacity(animates && dim ? 0.16 : 0.30))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(height: height)
            .animation(
                animates ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : nil, value: dim
            )
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
}
