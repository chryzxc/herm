import XCTest

@testable import Herm

final class SidebarAgentGroupingTests: XCTestCase {
    private func session(
        _ id: String, profile: String?, at seconds: TimeInterval, isWorking: Bool = false
    ) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: id, preview: "", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: seconds), messageCount: 1, source: "desktop",
            isWorking: isWorking)
    }

    func testScopedRowsReplaceScanCopyAndAdoptSelectedProfile() {
        let all = [
            session("a", profile: "default", at: 10),
            session("b", profile: "coder", at: 30),
            session("a", profile: "coder", at: 5),
        ]
        let scoped = [session("a", profile: nil, at: 40, isWorking: true)]
        let merged = SidebarAgentGrouping.merged(all: all, scoped: scoped, scopeProfileID: "default")

        XCTAssertEqual(merged.map(\.id), ["a", "b", "a"])
        XCTAssertTrue(merged[0].isWorking)
        XCTAssertEqual(merged[2].profileID, "coder")
    }

    private func bot(_ id: String, activeAt seconds: TimeInterval? = nil, isDefault: Bool = false) -> BotSummary {
        let chat = seconds.map {
            BotChatReference(sessionID: "\(id)-main", profileID: id, lastActive: Date(timeIntervalSince1970: $0))
        }
        return BotSummary(
            id: id, name: id, title: nil, description: nil, model: nil, provider: nil,
            isActive: true, chat: chat, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false,
            hasAvatar: false,
            isDefault: isDefault)
    }

    func testBotsPageListsNewestChatFirstAndKeepsRosterOrderForIdleBots() {
        let bots = [bot("default"), bot("writer", activeAt: 10), bot("idle"), bot("coder", activeAt: 50)]
        let room = GroupRoom(id: "team", name: "Team", members: [], updatedAt: .distantPast)
        let items = BotChatsOrdering.items(bots, rooms: [(room, Date(timeIntervalSince1970: 30))])
        XCTAssertEqual(
            items.map(\.id), ["bot:coder", "room:team", "bot:writer", "bot:default", "bot:idle"])
    }

    func testBotsPageOpensOpenBotElseLastUsedElseDefault() {
        let bots = [bot("writer"), bot("main", isDefault: true), bot("coder")]
        XCTAssertNil(BotChatsOrdering.initialBot(bots, activeID: "coder", lastID: "writer"))
        XCTAssertEqual(BotChatsOrdering.initialBot(bots, activeID: nil, lastID: "coder")?.id, "coder")
        XCTAssertEqual(BotChatsOrdering.initialBot(bots, activeID: "gone", lastID: "gone")?.id, "main")
        XCTAssertNil(BotChatsOrdering.initialBot([], activeID: nil, lastID: nil))
    }

    @MainActor
    func testRosterUpdateTracksMainChatsHiddenFromChats() {
        BotMentions.update(bots: [bot("writer", activeAt: 10), bot("idle")], avatars: [:])
        XCTAssertEqual(BotMentions.mainChatSessionIDs, ["writer-main"])
        BotMentions.update(bots: [], avatars: [:])
        XCTAssertTrue(BotMentions.mainChatSessionIDs.isEmpty)
    }

    func testMainChatAndSessionsReportWorkSeparately() {
        let now = Date()
        let main = BotChatReference(sessionID: "main", profileID: "coder", lastActive: now)
        var bot = BotSummary(
            id: "coder", name: "coder", title: nil, description: nil, model: nil,
            isActive: true, chat: main, recentSession: main, avatarURL: nil, preview: nil, lastActive: now,
            isHidden: false, hasAvatar: false, isDefault: false)
        // A busy main chat is Bots-page work only; its watermark is not session activity.
        bot.mainChatBusy = true
        XCTAssertTrue(bot.isMainChatWorking)
        XCTAssertNil(bot.sessionsLastActive)
        XCTAssertFalse(bot.isSessionWorking)

        bot.mainChatBusy = false
        bot.sessionsBusy = true
        XCTAssertFalse(bot.isMainChatWorking)
        XCTAssertTrue(bot.isSessionWorking)
    }
}
