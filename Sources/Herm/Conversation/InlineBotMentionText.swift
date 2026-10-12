import AppKit
import SwiftUI

/// A text attachment keeps the mention on the first baseline and lets later
/// lines wrap across the full bubble width.
struct InlineBotMentionText: NSViewRepresentable {
    let text: String
    let botID: String
    let displayName: String?
    let botsByID: [String: BotSummary]
    let avatarImages: [String: Data]
    let themeRevision: Int

    func makeNSView(context: Context) -> NativeMarkdownTextView {
        // Fill before the first sizeThatFits: SwiftUI can measure a fresh view
        // before updateNSView, which cached a zero-height (empty) bubble.
        let view = NativeMarkdownTextView()
        apply(to: view, colorScheme: context.environment.colorScheme)
        return view
    }

    func updateNSView(_ view: NativeMarkdownTextView, context: Context) {
        apply(to: view, colorScheme: context.environment.colorScheme)
    }

    private func apply(to view: NativeMarkdownTextView, colorScheme: ColorScheme) {
        let renderer = ImageRenderer(content:
            BotChip(id: botID, botsByID: botsByID, avatarImages: avatarImages, displayName: displayName)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let content = NSMutableAttributedString()
        if let image = renderer.nsImage {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -4, width: image.size.width, height: image.size.height)
            content.append(NSAttributedString(attachment: attachment))
            content.append(NSAttributedString(string: " "))
        } else {
            content.append(NSAttributedString(string: "@\(displayName ?? botID) "))
        }
        content.append(NativeMarkdownMessageView.Coordinator.attributedString(for: text))
        view.textStorage?.setAttributedString(content)
        view.setAccessibilityLabel("@\(displayName ?? botsByID[botID]?.name ?? botID) \(text)")
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeMarkdownTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? NativeMarkdownDocumentSizing.fallbackWidth)
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }
}
