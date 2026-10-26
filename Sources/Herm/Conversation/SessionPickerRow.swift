import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Rows sliding under a still pointer otherwise flip hover on every row they
/// pass, each building and tearing down its action buttons. Like Finder, hover
/// pauses while the list scrolls. `content` is stored, not a closure, so the
/// scroll-phase flip does not rebuild the rail.
struct HoverPausingScrollView<Content: View>: View {
    let content: Content
    @State private var isScrolling = false

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if #available(macOS 15, *) {
            ScrollView { content.allowsHitTesting(!isScrolling) }
                .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
        } else {
            ScrollView { content }
        }
    }
}

/// Sweeps an accent highlight across a working session's title. Static under
/// Reduce Motion; only working rows pay for the timeline.
struct WorkingTitleShimmer: ViewModifier {
    let isActive: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive && !reduceMotion {
            content.overlay {
                TimelineView(.dockMotion()) { context in
                    GeometryReader { geo in
                        let phase =
                            context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                        let band = max(geo.size.width * 0.4, 40)
                        LinearGradient(colors: [.clear, color, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (geo.size.width + band) * phase)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else if isActive {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}
