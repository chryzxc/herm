import AppKit
import SwiftUI

/// Renders `@bot` mentions in message text as the bot's avatar pill, in every
/// transcript renderer. `BotModeModel` keeps the roster current; mentions of
/// unknown handles and mentions inside code or links stay plain text.
@MainActor
enum BotMentions {
    /// Bumped when the roster or avatars change, so cached renders redraw.
    private(set) static var revision = 0
    private static var byHandle: [String: BotSummary] = [:]
    private static var botsByID: [String: BotSummary] = [:]
    private static var avatars: [String: Data] = [:]
    private static var pills: [String: NSImage] = [:]
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![\w@/.])@([A-Za-z0-9][A-Za-z0-9_-]*)"#)

    static func update(bots: [BotSummary], avatars: [String: Data]) {
        let index = index(bots)
        guard index != byHandle || avatars != self.avatars else { return }
        byHandle = index
        botsByID = Dictionary(bots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.avatars = avatars
        pills.removeAll()
        revision &+= 1
    }

    private static func index(_ bots: [BotSummary]) -> [String: BotSummary] {
        var index: [String: BotSummary] = [:]
        for bot in bots { index[bot.name.lowercased()] = bot }
        for bot in bots { index[bot.id.lowercased()] = bot }
        return index
    }

    /// Known-bot mentions in `text`, as UTF-16 ranges covering the `@handle`.
    static func matches(in text: String, bots: [BotSummary]? = nil) -> [(range: NSRange, bot: BotSummary)] {
        let byHandle = bots.map(index) ?? byHandle
        guard !byHandle.isEmpty, text.contains("@") else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            byHandle[ns.substring(with: match.range(at: 1)).lowercased()].map { (match.range, $0) }
        }
    }

    static func previewURL(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = "herm-bot-preview"
        components.host = "bot"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url!
    }

    static func previewBotID(_ url: URL) -> String? {
        guard url.scheme == "herm-bot-preview", url.host == "bot",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            items.count == 1, items[0].name == "id", let id = items[0].value, !id.isEmpty
        else { return nil }
        return id
    }

    static func pill(for bot: BotSummary, colorScheme: ColorScheme? = nil, textScale: CGFloat = 1) -> NSImage? {
        let dark =
            colorScheme.map { $0 == .dark }
            ?? (NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let key = "\(bot.id)|\(bot.name)|\(dark)|\(DockThemeRuntime.revision)|\(textScale)"
        if let cached = pills[key] { return cached }
        let renderer = ImageRenderer(
            content: BotChip(
                id: bot.id, botsByID: botsByID, avatarImages: avatars, displayName: bot.name, showsPreview: true
            )
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.dockWorkspaceScale, textScale))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        pills[key] = image
        return image
    }

    /// Replaces mentions with pill attachments, skipping code and link runs.
    static func pilled(
        _ text: NSAttributedString, bots: [BotSummary]? = nil, colorScheme: ColorScheme? = nil, textScale: CGFloat = 1
    ) -> NSAttributedString {
        let found = matches(in: text.string, bots: bots)
        guard !found.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for (range, bot) in found.reversed() {
            let attributes = text.attributes(at: range.location, effectiveRange: nil)
            let font = attributes[.font] as? NSFont
            let intent = (attributes[.inlinePresentationIntent] as? NSNumber).map {
                InlinePresentationIntent(rawValue: $0.uintValue)
            }
            guard attributes[.link] == nil, intent?.contains(.code) != true,
                font?.fontDescriptor.symbolicTraits.contains(.monoSpace) != true,
                let image = pill(for: bot, colorScheme: colorScheme, textScale: textScale)
            else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -4, width: image.size.width, height: image.size.height)
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttribute(.link, value: previewURL(bot.id), range: NSRange(location: 0, length: 1))
            replacement.addAttribute(.toolTip, value: "Preview " + bot.name, range: NSRange(location: 0, length: 1))
            if let style = attributes[.paragraphStyle] {
                replacement.addAttribute(
                    .paragraphStyle, value: style, range: NSRange(location: 0, length: replacement.length))
            }
            result.replaceCharacters(in: range, with: replacement)
        }
        return result
    }
}

extension Text {
    /// SwiftUI counterpart of `BotMentions.pilled` for one plain run.
    @MainActor static func withMentionPills(_ value: AttributedSubstring) -> Text {
        let plain = String(value.characters)
        let found = BotMentions.matches(in: plain)
        guard !found.isEmpty else { return Text(AttributedString(value)) }
        let ns = plain as NSString
        var text = Text("")
        var cursor = 0
        for (range, bot) in found {
            let offset = { (utf16: Int) in
                plain.distance(from: plain.startIndex, to: String.Index(utf16Offset: utf16, in: plain))
            }
            let lower = value.characters.index(value.startIndex, offsetBy: offset(cursor))
            let upper = value.characters.index(value.startIndex, offsetBy: offset(range.location))
            text = text + Text(AttributedString(value[lower..<upper]))
            if let image = BotMentions.pill(for: bot) {
                text = text + Text(Image(nsImage: image)).baselineOffset(-4)
            } else {
                text = text + Text(ns.substring(with: range))
            }
            cursor = NSMaxRange(range)
        }
        let tail = value.characters.index(
            value.startIndex,
            offsetBy: plain.distance(from: plain.startIndex, to: String.Index(utf16Offset: cursor, in: plain)))
        return text + Text(AttributedString(value[tail...]))
    }
}
