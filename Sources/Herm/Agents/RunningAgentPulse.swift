import SwiftUI

/// Keeps each running indicator's animation local to its node, avoiding a
/// full map/canvas invalidation for every pulse frame in large delegations.
struct RunningAgentPulse: View {
    let color: Color

    var body: some View {
        TimelineView(.dockMotion()) { context in
            // easeOut ripple: expands fast, fades as it settles.
            let t = 1 - pow(1 - DockMotionSchedule.loop(context.date, period: 1.45), 2)
            Circle()
                .stroke(color.opacity(0.4 * (1 - t)), lineWidth: 1.2)
                .scaleEffect(1.04 + 0.38 * t)
                .frame(width: 58, height: 58)
        }
        .accessibilityHidden(true)
    }
}
