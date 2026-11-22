import SwiftUI

/// macOS's default disclosure only toggles from its caret; make the header a button.
struct DockDisclosureGroupStyle: DisclosureGroupStyle {
    var alignment: VerticalAlignment = .center
    var animatesExpansion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DockMotion.disclosure(reduceMotion: reduceMotion || !animatesExpansion)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: alignment, spacing: 6) {
                    DockIcon(.caretRight, size: 10, color: .dockSecondaryText)
                        .frame(height: 14)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            DockRetainedDisclosureContent(isExpanded: configuration.isExpanded, animatesExpansion: animatesExpansion) {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dockPadding(.leading, 16)
            }
        }
    }
}

/// Mount on first use, then keep nested inputs and disclosures alive while closed.
struct DockRetainedDisclosureContent<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isExpanded: Bool
    var animatesExpansion = true
    @ViewBuilder var content: () -> Content
    @State private var hasExpanded = false

    var body: some View {
        DockDisclosureLayout(progress: isExpanded ? 1 : 0) {
            if isExpanded || hasExpanded {
                VStack(alignment: .leading, spacing: 0) { content() }
                    // Only the reveal animates. The toggle's transaction would otherwise reach the
                    // rows, scroll views and hover chrome inside and move them from stale frames,
                    // so content drifted while the clip opened.
                    .transaction(value: isExpanded) { $0.animation = nil }
                    .geometryGroup()
                    .opacity(isExpanded ? 1 : 0)
                    .transition(.identity)
            }
        }
        .clipped()
        .disabled(!isExpanded)
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(DockMotion.disclosure(reduceMotion: reduceMotion || !animatesExpansion), value: isExpanded)
        .onChange(of: isExpanded, initial: true) { _, expanded in
            if expanded { hasExpanded = true }
        }
    }
}

/// Lay out the body at its natural height and reveal it from the header.
/// A reversal continues from the current visible fraction.
private struct DockDisclosureLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: natural.width, height: natural.height * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: proposal.width, height: nil))
    }
}

extension AnyTransition {
    /// Release expensive panel content after collapse. Keep its full width
    /// while the visible height and the space occupied in the stack recede.
    static var dockPanelReveal: AnyTransition {
        .modifier(active: DockPanelReveal(progress: 0), identity: DockPanelReveal(progress: 1))
    }
}

private struct DockPanelReveal: AnimatableModifier {
    nonisolated var progress: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Children take their final frames at once; only the clip and fade move.
        DockDisclosureLayout(progress: progress) { content.geometryGroup() }
            .clipped()
            .opacity(Double(min(1, max(0, progress))))
    }
}
