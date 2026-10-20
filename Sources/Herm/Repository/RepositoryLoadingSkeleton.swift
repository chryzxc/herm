import SwiftUI

enum RepositoryShimmerMotion {
    static let duration: TimeInterval = 2.0

    static func progress(at time: TimeInterval) -> CGFloat {
        CGFloat(time.truncatingRemainder(dividingBy: duration) / duration)
    }

    static func bandWidth(for containerWidth: CGFloat) -> CGFloat {
        min(120, max(36, containerWidth * 0.28))
    }

    static func offset(containerWidth: CGFloat, at time: TimeInterval) -> CGFloat {
        let bandWidth = bandWidth(for: containerWidth)
        return -bandWidth + (containerWidth + bandWidth * 2) * progress(at: time)
    }
}

/// Shared placeholder used by GitHub repository detail surfaces while their
/// canonical payload is loading. The highlight crosses the block once from
/// leading to trailing per cycle and becomes static under Reduce Motion.
struct RepositoryShimmerBlock: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color.dockSurface4.opacity(0.30))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(height: height)
            .overlay {
                if !reduceMotion {
                    TimelineView(.dockMotion()) { context in
                        GeometryReader { geometry in
                            let renderedWidth = geometry.size.width
                            LinearGradient(
                                colors: [.clear, Color.dockPrimaryText.opacity(0.05), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(
                                width: RepositoryShimmerMotion.bandWidth(for: renderedWidth),
                                height: geometry.size.height
                            )
                            .offset(x: RepositoryShimmerMotion.offset(
                                containerWidth: renderedWidth,
                                at: context.date.timeIntervalSinceReferenceDate
                            ))
                        }
                    }
                }
            }
            .clipShape(shape)
            .accessibilityHidden(true)
    }
}
