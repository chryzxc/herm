import SwiftUI

/// Shared placeholder used by GitHub repository detail surfaces while their
/// canonical payload is loading. The restrained pulse follows Herm's single
/// live-loading motion and becomes static when Reduce Motion is enabled.
struct RepositoryShimmerBlock: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHighlighted = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.dockSurface4.opacity(isHighlighted ? 0.54 : 0.26))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(height: height)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                value: isHighlighted
            )
            .onAppear { isHighlighted = !reduceMotion }
            .onChange(of: reduceMotion) { _, isReduced in
                isHighlighted = !isReduced
            }
            .accessibilityHidden(true)
    }
}
