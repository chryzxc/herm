import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct InlineBotMentionTextTests {
    @Test func firstLayoutDisplaysMentionAndBodyWithoutAnotherUpdate() throws {
        for width: CGFloat in [240, 700] {
            let body = "Please check the project and report what you find. "
            let content = ConversationMessageRow(
                message: ChatMessage(
                    role: .user, text: String(repeating: body, count: 3),
                    botProfileID: "cypher", botDisplayName: "Cypher"),
                isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
                botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in }
            )
            let host = NSHostingView(rootView: content.fixedSize(horizontal: false, vertical: true))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()

            func textView(in view: NSView) -> NativeMarkdownTextView? {
                (view as? NativeMarkdownTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
            }
            let view = try #require(textView(in: host))
            #expect(view.string.contains(body))
            #expect(view.frame.width > 100)
            #expect(view.frame.height > 20)
            let container = try #require(view.textContainer)
            let layout = try #require(view.layoutManager)
            layout.ensureLayout(for: container)
            #expect(container.size.width > 100)
            #expect(layout.usedRect(for: container).height <= view.frame.height)
            #expect(layout.glyphRange(for: container).length == layout.numberOfGlyphs)
        }
    }
}
