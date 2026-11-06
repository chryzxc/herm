import AppKit
import Testing

@testable import Herm

@MainActor
struct BotMentionsTests {
    @Test func activityChangesDoNotInvalidateMentionArtwork() {
        var bot = BotSummary(
            id: "fixture", name: "Fixture", title: nil, description: nil, model: nil, isActive: false, chat: nil,
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false)
        BotMentions.update(bots: [bot], avatars: [:])
        defer { BotMentions.update(bots: [], avatars: [:]) }
        let revision = BotMentions.revision
        bot.liveBusy = true
        BotMentions.update(bots: [bot], avatars: [:])
        #expect(BotMentions.revision == revision)
        #expect(BotMentions.matches(in: "@fixture").first?.bot.liveBusy == true)
    }
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
        let link = pilled.attribute(.link, at: 3, effectiveRange: nil) as? URL
        #expect(link.flatMap(BotMentions.previewBotID) == forge.id)
        #expect(pilled.attribute(.link, at: 10, effectiveRange: nil) == nil)
    }
    @Test func previewLinksRoundTripExactIdentitiesAndRejectMalformedLinks() {
        let id = "bot-name /?#&"
        #expect(BotMentions.previewBotID(BotMentions.previewURL(id)) == id)
        for value in [
            "https://bot?id=forge", "herm-bot-preview://other?id=forge", "herm-bot-preview://bot?id=",
            "herm-bot-preview://bot?id=forge&id=other",
        ] {
            #expect(BotMentions.previewBotID(URL(string: value)!) == nil)
        }
    }

}
