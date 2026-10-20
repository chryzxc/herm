import SwiftUI

/// Captures stable content before entering the clock, sharing its frame with all leaves.
/// The single unmasked sweep stays inside the existing footprint; elapsed text keeps its own clock.
struct DockLiveActivityDecoration<Content: View>: View {
    var active = true
    @ViewBuilder let content: Content

    var body: some View {
        if active {
            DockBotFrameClock { frame in
                content
                    .environment(\.dockBotIndicatorFrame, frame)
                    .overlay(alignment: .bottom) {
                        if frame.moves {
                            GeometryReader { proxy in
                                LinearGradient(colors: [.clear, Color.dockPrimaryText.opacity(0.3), .clear],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: proxy.size.width * 0.45, height: 1)
                                    .offset(x: proxy.size.width * (1.45 * frame.sweep - 0.45), y: proxy.size.height - 1)
                            }
                            .clipped()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
            }
        } else {
            content
        }
    }
}
