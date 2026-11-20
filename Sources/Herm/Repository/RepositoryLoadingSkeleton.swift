import SwiftUI

/// Shared placeholder used by GitHub detail and list surfaces while their canonical
/// payload is loading. It breathes with one slow opacity pulse on the shared
/// `dockMotion` clock, so any number of blocks cost one render per tick and hold
/// still while scrolling. (`repeatForever` re-rendered each block at the display
/// rate.) It is static under Reduce Motion or when the host is hidden.
struct RepositoryShimmerBlock: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockHostVisible) private var hostVisible

    var body: some View {
        let animates = DockMotion.isEnabled(reduceMotion: reduceMotion) && hostVisible
        TimelineView(.dockMotion(rate: 15, paused: !animates)) { context in
            let breath = animates ? DockMotionSchedule.breath(context.date, period: 2.4) : 0
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.dockSurface4.opacity(0.30 - 0.14 * breath))
        }
        .frame(maxWidth: width ?? .infinity, alignment: .leading)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
