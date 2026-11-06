import SwiftUI

/// Position shown while dragging and until Hermes reads the change back. An observable object, because the
/// picker lives in a popover whose `@State` changes do not reliably redraw it.
@MainActor
private final class EffortSliderState: ObservableObject {
    @Published var index: Int?
    private var settle: Task<Void, Never>?

    func commit(_ next: Int) {
        index = next
        settle?.cancel()
        // Hold the new position through the async readback; fall back to Hermes' value if it never lands.
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.index = nil }
        }
    }

    func drag(_ next: Int) {
        settle?.cancel()
        index = next
    }
}

/// Effort as a stepped bar. The fill, tint and motion escalate with the level:
/// calm below High, a shimmer from High, sparkles from Extra High, and a full spectrum at Ultra.
struct ComposerEffortSlider<Trailing: View>: View {
    let choices: [HermesReasoningVariant]
    @Binding var selection: HermesReasoningVariant?
    /// Sits level with the level name, at the end of the row.
    @ViewBuilder var trailing: Trailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Committed once on release so a drag sends one change, not one per step.
    @StateObject private var state = EffortSliderState()

    private let trackHeight: CGFloat = 22
    private let knob: CGFloat = 18

    private var committedIndex: Int { selection.flatMap { choices.firstIndex(of: $0) } ?? 0 }
    private var index: Int { state.index ?? committedIndex }
    private var variant: HermesReasoningVariant { choices[min(index, choices.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(ComposerEffortControls.title(variant))
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Self.ink(variant))
                    .animation(nil, value: index)
                Spacer(minLength: 0)
                trailing
            }
            track
                .frame(height: trackHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort")
        .accessibilityValue(ComposerEffortControls.title(variant))
        .accessibilityAdjustableAction { direction in
            let next = index + (direction == .increment ? 1 : -1)
            if choices.indices.contains(next) { selection = choices[next] }
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let steps = max(choices.count - 1, 1)
            let usable = width - knob
            let center = knob / 2 + usable * CGFloat(index) / CGFloat(steps)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dockControlSurface)
                Capsule()
                    .fill(Self.gradient(variant))
                    .overlay { effects(width: center + knob / 2) }
                    .clipShape(Capsule())
                    .frame(width: center + knob / 2)
                ForEach(choices.indices, id: \.self) { step in
                    Circle()
                        .fill(Color.dockPrimaryText.opacity(step < index ? 0.45 : 0.25))
                        .frame(width: 4, height: 4)
                        .position(x: knob / 2 + usable * CGFloat(step) / CGFloat(steps), y: trackHeight / 2)
                }
                Circle()
                    .fill(Color.dockPrimaryText)
                    .overlay(Circle().stroke(Color.dockSurface2, lineWidth: 2))
                    .frame(width: knob, height: knob)
                    .shadow(color: Self.ink(variant).opacity(0.5), radius: variant >= .xhigh ? 6 : 2)
                    .position(x: center, y: trackHeight / 2)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: index)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { state.drag(step(at: $0.location.x, usable: usable, steps: steps)) }
                    .onEnded {
                        let next = step(at: $0.location.x, usable: usable, steps: steps)
                        if next == committedIndex {
                            state.index = nil
                        } else {
                            state.commit(next)
                            selection = choices[next]
                        }
                    }
            )
        }
    }

    private func step(at x: CGFloat, usable: CGFloat, steps: Int) -> Int {
        let fraction = (x - knob / 2) / max(usable, 1)
        return min(max(Int((fraction * CGFloat(steps)).rounded()), 0), steps)
    }

    @ViewBuilder
    private func effects(width: CGFloat) -> some View {
        if !reduceMotion, variant >= .high {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let speed = variant >= .max ? 0.9 : 0.5
                    let phase = (time * speed).truncatingRemainder(dividingBy: 1)
                    let band = size.width * 0.5
                    let x = -band + (size.width + band) * phase
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: band, height: size.height)),
                        with: .linearGradient(
                            Gradient(colors: [.clear, Color.dockPrimaryText.opacity(0.28), .clear]),
                            startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + band, y: 0)))
                    let count = variant >= .ultra ? 14 : variant >= .max ? 8 : variant >= .xhigh ? 4 : 0
                    for item in 0..<count {
                        let seed = Double(item) * 12.9898
                        let px = (sin(seed) * 0.5 + 0.5) * size.width
                        let py = (sin(seed * 1.7 + 3) * 0.5 + 0.5) * size.height
                        let twinkle = max(0, sin(time * (1.5 + Double(item % 3) * 0.7) + seed))
                        let radius = 0.8 + twinkle * 1.2
                        context.fill(
                            Path(
                                ellipseIn: CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2)
                            ),
                            with: .color(Color.dockPrimaryText.opacity(0.35 + twinkle * 0.5)))
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private static func tint(_ variant: HermesReasoningVariant) -> DockAccentColor? {
        switch variant {
        case .none: nil
        case .minimal, .low: .cyan
        case .medium: .blue
        case .high: .indigo
        case .xhigh, .ultra: .violet
        case .max: .pink
        }
    }

    private static func ink(_ variant: HermesReasoningVariant) -> Color {
        tint(variant)?.color ?? Color.dockSecondaryText
    }

    private static func gradient(_ variant: HermesReasoningVariant) -> LinearGradient {
        let colors: [Color] =
            switch variant {
            case .none: [Color.dockSecondaryText.opacity(0.35)]
            case .ultra: [DockAccentColor.indigo.fill, DockAccentColor.violet.fill, DockAccentColor.pink.fill]
            case .max: [DockAccentColor.violet.fill, DockAccentColor.pink.fill]
            default: [tint(variant)!.fill.opacity(0.75), tint(variant)!.fill]
            }
        return LinearGradient(
            colors: colors.count == 1 ? colors + colors : colors, startPoint: .leading, endPoint: .trailing)
    }
}

extension HermesReasoningVariant: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Standard / Fast as a two-way capsule whose thumb slides to the chosen side, matching the effort bar.
struct ComposerSpeedSwitch: View {
    @Binding var isFast: Bool
    var isPending = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 24

    var body: some View {
        ZStack(alignment: isFast ? .trailing : .leading) {
            Capsule().fill(Color.dockControlSurface)
            GeometryReader { geometry in
                Capsule()
                    .fill(isFast ? DockAccentColor.amber.fill : Color.dockPrimaryText.opacity(0.18))
                    .frame(width: geometry.size.width / 2)
                    .frame(maxWidth: .infinity, alignment: isFast ? .trailing : .leading)
            }
            HStack(spacing: 0) {
                label("Standard", selected: !isFast)
                label("Fast", selected: isFast, icon: .lightning)
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: isFast)
        .contentShape(Capsule())
        .onTapGesture { isFast.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed")
        .accessibilityValue("\(isFast ? "Fast" : "Standard")\(isPending ? ", changing" : "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isFast.toggle() }
    }

    private func label(_ title: String, selected: Bool, icon: Ph? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon { DockIcon(icon, size: 11, color: selected ? Color.dockOnAccentText : Color.dockSecondaryText) }
            Text(title)
                .dockFont(.metadata, weight: selected ? .semibold : .regular)
                .foregroundStyle(selected && icon != nil ? Color.dockOnAccentText : Color.dockPrimaryText)
                .opacity(selected ? 1 : 0.6)
        }
        .frame(maxWidth: .infinity)
    }
}
