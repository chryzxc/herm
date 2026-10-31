import SwiftUI

/// A themed slider: a slim track, accent fill and a round thumb. Replaces the
/// native `Slider`, which ignores the selected skin.
struct DockSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    @Environment(\.isEnabled) private var isEnabled

    private let thumb: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - thumb, 1)
            let fraction =
                (clamped - range.lowerBound) / max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dockSurface4).frame(height: 4)
                Capsule().fill(Color.dockAccent).frame(width: width * fraction + thumb / 2, height: 4)
                Circle().fill(Color.dockPrimaryText).frame(width: thumb, height: thumb)
                    .overlay(Circle().stroke(Color.dockBorderStrong, lineWidth: DockLayout.hairline))
                    .offset(x: width * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let ratio = min(max((drag.location.x - thumb / 2) / width, 0), 1)
                    var next = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                    if let step { next = (next / step).rounded() * step }
                    value = min(max(next, range.lowerBound), range.upperBound)
                })
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityValue(Text(clamped.formatted()))
        .accessibilityAdjustableAction { direction in
            let delta = step ?? (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (direction == .increment ? delta : -delta), range.lowerBound), range.upperBound)
        }
    }

    private var clamped: Double { min(max(value, range.lowerBound), range.upperBound) }
}
