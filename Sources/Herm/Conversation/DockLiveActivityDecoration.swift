import SwiftUI

/// A live activity block keeps its sweep inside its existing footprint.
struct DockLiveActivityDecoration<Content: View>: View {
    var active = true
    @ViewBuilder let content: Content

    var body: some View {
        if active {
            content
                .environment(\.dockBotIndicatorLive, true)
                .overlay(alignment: .bottom) {
                    DockLiveActivitySweep()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

private struct DockLiveActivitySweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dockHostVisible) private var hostVisible
    @Environment(\.dockHostResizing) private var hostResizing

    var body: some View {
        if hostVisible && !hostResizing && DockMotion.isEnabled(reduceMotion: reduceMotion) {
            DockLayerMotion(
                kind: .sweep(period: 1.8, fraction: 0.45, clamp: 0...(.infinity)),
                color: Color.dockPrimaryText.opacity(0.3)
            )
            .frame(height: 1)
            .clipped()
        }
    }
}
