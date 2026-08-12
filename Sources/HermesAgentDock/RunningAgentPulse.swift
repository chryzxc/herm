import SwiftUI

/// Keeps each running indicator's animation local to its node, avoiding a
/// full map/canvas invalidation for every pulse frame in large delegations.
struct RunningAgentPulse: View {
    let color: Color
    @State private var isExpanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(isExpanded ? 0 : 0.4), lineWidth: 1.2)
            .scaleEffect(isExpanded ? 1.42 : 1.04)
            .frame(width: 58, height: 58)
            .onAppear {
                withAnimation(.easeOut(duration: 1.45).repeatForever(autoreverses: false)) {
                    isExpanded = true
                }
            }
            .accessibilityHidden(true)
    }
}
