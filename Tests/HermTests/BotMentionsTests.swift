import AppKit
import Testing

@testable import Herm

@MainActor
struct BotMentionsTests {
    @Test func pillsKnownBotsAnywhereButLeavesCodeLinksAndStrangersAlone() {
        let forge = BotSummary(
            id: "forge", name: "Forge", title: nil, description: nil, model: nil, isActive: false, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
        BotMentions.update(bots: [forge], avatars: [:])
        defer { BotMentions.update(bots: [], avatars: [:]) }

        let text = "Ask @Forge. Not me@forge, @nobody or `@forge`"
        #expect(BotMentions.matches(in: text).map { ($0.range.location, $0.bot.id) }.map(\.0) == [4, 38])

        let attributed = NSMutableAttributedString(
            string: "hi @forge and @forge", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        attributed.addAttribute(
            .font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            range: NSRange(location: 14, length: 6))
        let pilled = BotMentions.pilled(attributed)
        #expect(pilled.string == "hi \u{FFFC} and @forge")
    }
}
