import SwiftUI

/// Keeps the same composer mounted as an empty chat becomes a conversation.
struct ConversationComposerLayout<Transcript: View, Composer: View>: View {
    let showsWelcome: Bool
    let hermFaceID: String?
    var trailingContentInset: CGFloat = 0
    @ViewBuilder var transcript: Transcript
    @ViewBuilder var composer: Composer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ConversationComposerPlacement(progress: showsWelcome ? 0 : 1) {
            StartupAssistantView(hermFaceID: hermFaceID, isActive: showsWelcome)
                .fixedSize(horizontal: false, vertical: true)
                .dockPadding(.trailing, trailingContentInset)
                .dockPadding(.bottom, 12)
                .opacity(showsWelcome ? 1 : 0)
                .accessibilityHidden(!showsWelcome)
                .allowsHitTesting(false)

            transcript
                .opacity(showsWelcome ? 0 : 1)
                .accessibilityHidden(showsWelcome)
                .allowsHitTesting(!showsWelcome)
            composer
        }
        .animation(
            reduceMotion || !DockThemeStyle.current.animates
                ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.48),
            value: showsWelcome
        )
    }
}

/// Interpolates finite positions instead of animating an unbounded spacer.
struct ConversationComposerPlacement: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    static func composerY(
        height: CGFloat, contentHeight: CGFloat, composerHeight: CGFloat, progress: CGFloat
    ) -> CGFloat {
        let bottom = max(0, height - composerHeight)
        let centered = min(bottom, max(0, (height - contentHeight - composerHeight) / 2 + contentHeight))
        return centered + (bottom - centered) * progress
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let width = bounds.width
        let welcomeSize = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let composerSize = subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let y = Self.composerY(
            height: bounds.height, contentHeight: welcomeSize.height, composerHeight: composerSize.height,
            progress: progress)
        let welcomeY =
            Self.composerY(
                height: bounds.height, contentHeight: welcomeSize.height, composerHeight: composerSize.height,
                progress: 0) - welcomeSize.height
        subviews[0].place(
            at: CGPoint(x: bounds.midX, y: bounds.minY + welcomeY), anchor: .top,
            proposal: ProposedViewSize(width: width, height: welcomeSize.height))
        subviews[1].place(
            at: bounds.origin, proposal: ProposedViewSize(width: width, height: max(0, y)))
        subviews[2].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + y),
            proposal: ProposedViewSize(width: width, height: composerSize.height))
    }
}
