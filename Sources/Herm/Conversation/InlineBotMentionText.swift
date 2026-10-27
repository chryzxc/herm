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
    }

    final class Coordinator {
        var applied: RenderKey?
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
            themeRevision: themeRevision, rosterRevision: BotMentions.revision)
        guard key != context.coordinator.applied else { return }
        context.coordinator.applied = key
        view.textStorage?.setAttributedString(
            Self.attributedString(text: text, botMentions: botMentions, colorScheme: key.colorScheme))
        view.setAccessibilityLabel(text)
        view.invalidateIntrinsicContentSize()
    }

    static func attributedString(
        text: String, botMentions: [ComposerBotMention], colorScheme: ColorScheme? = nil
    ) -> NSAttributedString {
        var palette = NativeMarkdownPalette()
        palette.rendersBotMentions = false
        let content = NativeMarkdownAttributedTextBuilder.document(text, palette: palette).string
        // Picked identities survive a roster refresh; typed mentions use the current roster.
        let selected = BotMentions.pilled(content, bots: botMentions.map(\.bot), colorScheme: colorScheme)
        return BotMentions.pilled(selected, colorScheme: colorScheme)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeMarkdownTextView, context: Context) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 1 {
            width = proposed
        } else if nsView.bounds.width > 1 {
            width = nsView.bounds.width
        } else {
            width = NativeMarkdownDocumentSizing.fallbackWidth
        }
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        // A trial proposal must not change wrapping in the displayed bubble.
        defer {
            if nsView.bounds.width > 1 {
                container.size = NSSize(width: nsView.bounds.width, height: .greatestFiniteMagnitude)
            }
        }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let huggedWidth = min(width, ceil(used.width))
        container.size = NSSize(width: huggedWidth, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: huggedWidth, height: ceil(layout.usedRect(for: container).height))
    }
}
