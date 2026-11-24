import AppKit
import SwiftUI

/// A text attachment keeps the mention on the first baseline and lets later
/// lines wrap across the full bubble width.
struct InlineBotMentionText: NSViewRepresentable {
    let text: String
    var botMentions: [ComposerBotMention] = []
    let themeRevision: Int

    /// What the rendered text depends on. Unrelated environment changes call
    /// updateNSView too, and rebuilding every bubble on each one was heavy.
    struct RenderKey: Equatable {
        let text: String
        let botMentions: [ComposerBotMention]
        let colorScheme: ColorScheme
        let themeRevision: Int
        let rosterRevision: Int
        let bodySize: CGFloat
    }

    final class Coordinator {
        var applied: RenderKey?
        var naturalWidth: CGFloat = 0
        var measuredSizes: [(width: CGFloat, size: CGSize)] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeMarkdownTextView {
        // Fill before the first sizeThatFits: SwiftUI can measure a fresh view
        // before updateNSView, which cached a zero-height (empty) bubble.
        let view = NativeMarkdownTextView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NativeMarkdownTextView, context: Context) {
        view.markdownOpenURL = context.environment.markdownOpenURL
        let key = RenderKey(
            text: text, botMentions: botMentions, colorScheme: context.environment.colorScheme,
            themeRevision: themeRevision, rosterRevision: BotMentions.revision,
            bodySize: DockTypography.size(.conversation, scale: context.environment.dockWorkspaceScale))
        guard key != context.coordinator.applied else { return }
        context.coordinator.applied = key
        context.coordinator.measuredSizes.removeAll(keepingCapacity: true)
        let attributed = Self.attributedString(
            text: text, botMentions: botMentions, colorScheme: key.colorScheme, bodySize: key.bodySize)
        view.setMarkdownText(attributed)
        let naturalBounds = attributed.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        context.coordinator.naturalWidth = ceil(naturalBounds.width) + 1
        view.setAccessibilityLabel(text)
        view.invalidateIntrinsicContentSize()
        view.window?.invalidateCursorRects(for: view)
    }

    static func attributedString(
        text: String, botMentions: [ComposerBotMention], colorScheme: ColorScheme? = nil,
        bodySize: CGFloat = DockTypography.size(.conversation)
    ) -> NSAttributedString {
        var palette = NativeMarkdownPalette(bodySize: bodySize)
        palette.rendersBotMentions = false
        let content = NativeMarkdownAttributedTextBuilder.document(text, palette: palette).string
        // Picked identities survive a roster refresh; typed mentions use the current roster.
        let scale = bodySize / DockTypography.size(.conversation)
        let selected = BotMentions.pilled(
            content, bots: botMentions.map(\.bot), colorScheme: colorScheme, textScale: scale)
        return BotMentions.pilled(selected, colorScheme: colorScheme, textScale: scale)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeMarkdownTextView, context: Context) -> CGSize? {
        let availableWidth: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 1 {
            availableWidth = proposed
        } else if nsView.bounds.width > 1 {
            availableWidth = nsView.bounds.width
        } else {
            availableWidth = NativeMarkdownDocumentSizing.fallbackWidth
        }
        let coordinator = context.coordinator
        // Short messages hug their unwrapped width. Wrapping messages use the
        // full proposal so a narrower fitted line cannot change their layout again.
        let width = min(availableWidth, coordinator.naturalWidth)
        if let measured = coordinator.measuredSizes.first(where: { $0.width == width }) { return measured.size }
        // Keep sizing probes detached from the on-screen TextKit container.
        let bounds = nsView.attributedString().boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: width, height: ceil(bounds.height))
        // Stack layout repeats a handful of trial widths while adjacent rows move.
        coordinator.measuredSizes.append((width, size))
        if coordinator.measuredSizes.count > 4 { coordinator.measuredSizes.removeFirst() }
        return size
    }
}
