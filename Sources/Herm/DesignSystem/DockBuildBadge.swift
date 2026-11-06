import SwiftUI

struct DockBuildBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var build: HermBuildInfo = .current
    var includesCommit = false

    var body: some View {
        if let label = build.badge(includesCommit: includesCommit) {
            let tint: DockAccentColor = build.channel == .nightly ? .blue : .violet
            HStack(spacing: 4) {
                DockIcon(build.channel == .nightly ? .moonStars : .terminal, size: 11, color: tint.color)
                    .scaleEffect(appeared || !DockMotion.isEnabled(reduceMotion: reduceMotion) ? 1 : 0.65)
                    .opacity(appeared || !DockMotion.isEnabled(reduceMotion: reduceMotion) ? 1 : 0.5)
                Text(label)
                    .dockFont(.metadata, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
            }
            .dockPadding(.horizontal, 2)
            .dockPill(tint: tint.fill)
            .overlay(Capsule().stroke(tint.color.opacity(0.3), lineWidth: DockLayout.hairline))
            .fixedSize()
            .accessibilityLabel("Herm \(label) build")
            .onAppear {
                withAnimation(DockMotion.animation(reduceMotion: reduceMotion, duration: 0.35)) {
                    appeared = true
                }
            }
        }
    }
}
