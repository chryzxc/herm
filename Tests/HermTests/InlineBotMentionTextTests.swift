import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct InlineBotMentionTextTests {
    private var cypher: BotSummary {
        BotSummary(
            id: "cypher", name: "Cypher", title: nil, description: nil, model: nil, isActive: false, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func typedMentionsBecomePillsWhenTheRosterRecognizesThem(colorScheme: ColorScheme) {
        BotMentions.update(bots: [cypher], avatars: [:])
        defer { BotMentions.update(bots: [], avatars: [:]) }
        let rendered = InlineBotMentionText.attributedString(
            text: "@cypher hey @unknown", botMentions: [], colorScheme: colorScheme)
        #expect(rendered.string == "\u{FFFC} hey @unknown")
        #expect(rendered.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func selectedBotsKeepPillsWhenMissingFromTheRoster(colorScheme: ColorScheme) {
        let rendered = InlineBotMentionText.attributedString(
            text: "hey @cypher, ask @forge too",
            botMentions: [.init(bot: cypher, range: NSRange(location: 4, length: 7))], colorScheme: colorScheme)
        #expect(rendered.string == "hey \u{FFFC}, ask @forge too")
        #expect(rendered.attribute(.attachment, at: 4, effectiveRange: nil) is NSTextAttachment)
    }

    @Test(arguments: [0, 12])
    func repeatedMentionsOfTheSelectedBotBecomePills(selectedLocation: Int) {
        let text = "@cypher and @cypher"
        let rendered = InlineBotMentionText.attributedString(
            text: text, botMentions: [.init(bot: cypher, range: NSRange(location: selectedLocation, length: 7))])
        #expect(rendered.string == "\u{FFFC} and \u{FFFC}")
    }

    @Test func markdownKeepsCodeAndLinksPlainForTypedAndSelectedMentions() {
        BotMentions.update(bots: [cypher], avatars: [:])
        defer { BotMentions.update(bots: [], avatars: [:]) }
        let text = "**Hi** @cypher; `@cypher` and [@cypher](https://example.com)"
        let source = text as NSString
        let ranges = [source.range(of: "@cypher"), source.range(of: "@cypher", options: .backwards)]
        for mentions in [[], ranges.map { ComposerBotMention(bot: cypher, range: $0) }] {
            let rendered = InlineBotMentionText.attributedString(text: text, botMentions: mentions)
            #expect(rendered.string.hasPrefix("Hi \u{FFFC}; @cypher and "))
            #expect(rendered.string.hasSuffix("@cypher"))
            let link = (rendered.string as NSString).range(of: "@cypher", options: .backwards)
            #expect(rendered.attribute(.link, at: link.location, effectiveRange: nil) != nil)
            #expect(rendered.attribute(.attachment, at: link.location, effectiveRange: nil) == nil)
        }
    }

    @Test func selectionSurvivesWhitespaceTrimmingAndReplyQuotes() {
        let text = "  @cypher and @cypher  "
        let selected = [ComposerBotMention(bot: cypher, range: NSRange(location: 14, length: 7))]
        let quoted = ReplyQuote(author: "Cypher", text: "Earlier reply").composing(text)
        let stored = ComposerBotMention.rebasing(selected, from: text, to: quoted)
        let body = ReplyQuote.split(quoted)!.body
        let visible = ComposerBotMention.rebasing(stored, from: quoted, to: body)
        let rendered = InlineBotMentionText.attributedString(text: body, botMentions: visible)
        #expect(rendered.string == "\u{FFFC} and \u{FFFC}")
    }

    @Test func userBubbleTracksTextSizeChanges() async throws {
        let text = "@cypher Please check this message and its **bold text**."
        let message = ChatMessage(
            role: .user, text: text, botMentions: [.init(bot: cypher, range: NSRange(location: 0, length: 7))])
        let row = ConversationMessageRow(
            message: message, isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
            botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in })
        func content(_ scale: CGFloat) -> some View {
            row.equatable().environment(\.dockWorkspaceScale, scale).frame(width: 300)
        }
        let host = NSHostingView(rootView: content(1))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func textView(in view: NSView) -> NativeMarkdownTextView? {
            (view as? NativeMarkdownTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        var smallPillWidth: CGFloat?
        for scale: CGFloat in [1, 1.3, 1.1, 1] {
            host.rootView = content(scale)
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let view = try #require(textView(in: host))
            let storage = try #require(view.textStorage)
            let body = (view.string as NSString).range(of: "Please")
            let bold = (view.string as NSString).range(of: "bold")
            #expect(body.location != NSNotFound && bold.location != NSNotFound)
            for range in [body, bold] where range.location != NSNotFound {
                let font = try #require(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                #expect(font.pointSize == DockTypography.size(.conversation, scale: scale))
            }
            let pill = try #require(storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            if scale == 1, smallPillWidth == nil { smallPillWidth = pill.bounds.width }
            if scale == 1.3 { #expect(pill.bounds.width > (smallPillWidth ?? 0)) }
            let container = try #require(view.textContainer)
            let layout = try #require(view.layoutManager)
            layout.ensureLayout(for: container)
            #expect(ceil(layout.usedRect(for: container).height) <= view.frame.height + 1)
        }
    }

    @Test func firstLayoutHugsShortUserMessage() throws {
        let text = "Generate a cat image"
        let row = ConversationMessageRow(
            message: ChatMessage(role: .user, text: text),
            isStreamingMessage: false, streamingText: nil, activeBotProfileID: nil,
            botsByID: [:], avatarImages: [:], botRosterRevision: 0, onImagePreview: { _ in })
        let host = NSHostingView(rootView: row.fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        func textView(in view: NSView) -> NativeMarkdownTextView? {
            (view as? NativeMarkdownTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let view = try #require(textView(in: host))
        let naturalWidth = ceil(InlineBotMentionText.attributedString(text: text, botMentions: []).size().width)
        #expect(view.frame.width >= naturalWidth)
        #expect(view.frame.width <= naturalWidth + 2)
    }

    @Test func firstLayoutDisplaysMentionAndBodyWithoutAnotherUpdate() throws {
        for width: CGFloat in [240, 700] {
            let body = "Please check the project and report what you find. "
            let content = ConversationMessageRow(
                message: ChatMessage(
                    role: .user, text: "@cypher " + String(repeating: body, count: 3),
                    botProfileID: "cypher", botDisplayName: "Cypher",
                    botMentions: [.init(bot: cypher, range: NSRange(location: 0, length: 7))]),
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
