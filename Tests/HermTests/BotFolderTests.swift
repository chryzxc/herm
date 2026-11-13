import XCTest

@testable import Herm

@MainActor
final class BotFolderTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "BotFolderTests")
        defaults.removePersistentDomain(forName: "BotFolderTests")
    }

    private func bot(
        _ id: String, activeAt seconds: TimeInterval? = nil, section: String? = nil, sectionName: String? = nil
    ) -> BotSummary {
        let chat = seconds.map {
            BotChatReference(sessionID: "\(id)-main", profileID: id, lastActive: Date(timeIntervalSince1970: $0))
        }
        var bot = BotSummary(
            id: id, name: id, title: nil, description: nil, model: nil, provider: nil,
            isActive: true, chat: chat, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false,
            hasAvatar: false, isDefault: false)
        bot.sectionID = section
        bot.sectionName = sectionName
        return bot
    }

    func testRoomsLiveInOneFolderAndDeleteReturnsThemToTheTopLevel() {
        let store = BotFolderStore(defaults: defaults)
        let work = store.create(name: "Work", containing: "room:r")
        let play = store.create(name: "Play")
        store.move("room:r", to: play)
        XCTAssertNil(store.folders.first { $0.id == work }?.itemIDs.first)
        XCTAssertEqual(store.folderID(containing: "room:r"), play)
        store.delete(play)
        XCTAssertNil(store.folderID(containing: "room:r"))
    }

    func testFolderReorderRenameAndPersistenceDiscardLegacyFolders() {
        defaults.set(Data("[]".utf8), forKey: BotFolderStore.legacyStorageKey)
        let store = BotFolderStore(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: BotFolderStore.legacyStorageKey))
        let a = store.create(name: "A")
        let b = store.create(name: "B")
        let c = store.create(name: "C")
        store.moveFolder(c, before: a)
        store.moveFolder(a, before: nil)
        store.rename(b, to: "  Beta ")
        store.rename(b, to: "   ")
        store.toggleCollapsed(c)
        let reloaded = BotFolderStore(defaults: defaults).folders
        XCTAssertEqual(reloaded.map(\.name), ["C", "Beta", "A"])
        XCTAssertEqual(reloaded.map(\.isCollapsed), [true, false, false])
        XCTAssertTrue(a.range(of: #"^sec-[0-9a-z]+-[0-9a-z]{5}$"#, options: .regularExpression) != nil)
    }

    func testSyncAdoptsHermesSectionsAndTakesAgreedRenames() {
        let store = BotFolderStore(defaults: defaults)
        let local = store.create(name: "Old")
        store.sync([
            bot("a", section: local, sectionName: "Clients"),
            bot("b", section: "sec-x", sectionName: "Research"),
            bot("c", section: "sec-x", sectionName: "Research"),
            bot("d", section: "sec-nameless"),
        ])
        XCTAssertEqual(store.folders.map(\.name), ["Clients", "Research"])
        XCTAssertEqual(store.folderID(containing: "bot:b"), "sec-x")
        XCTAssertEqual(store.botSections["bot:d"], "sec-nameless")

        // Members disagree mid re-stamp: the local name stays.
        store.sync([bot("b", section: "sec-x", sectionName: "R2"), bot("c", section: "sec-x", sectionName: "Research")])
        XCTAssertEqual(store.folders.last?.name, "Research")
    }

    func testSectionsKeepActivityOrderIgnoreStaleIDsAndFlattenSearch() {
        let room = GroupRoom(id: "team", name: "Team", members: [], updatedAt: .distantPast)
        let items = BotChatsOrdering.items(
            [bot("a", activeAt: 10), bot("b", activeAt: 50), bot("c", activeAt: 20)],
            rooms: [(room, Date(timeIntervalSince1970: 30))])
        let folders = [
            BotFolder(id: "empty", name: "Empty"),
            BotFolder(id: "mixed", name: "Mixed", itemIDs: ["gone", "room:team", "bot:c"]),
        ]
        let botSections = ["bot:a": "mixed", "bot:b": "mixed", "bot:c": "deleted"]
        let sections = BotChatsOrdering.sections(
            items, folders: folders, botSections: botSections, isSearching: false)
        XCTAssertEqual(sections.folders.map(\.folder.name), ["Empty", "Mixed"])
        XCTAssertEqual(sections.folders[1].items.map(\.id), ["bot:b", "room:team", "bot:a"])
        XCTAssertEqual(sections.loose.map(\.id), ["bot:c"])

        let searching = BotChatsOrdering.sections(items, folders: folders, botSections: botSections, isSearching: true)
        XCTAssertTrue(searching.folders.isEmpty)
        XCTAssertEqual(searching.loose.count, 4)
    }

    func testDragPayloadResolvesToRoomOrBotChat() throws {
        let bots = [bot("a", activeAt: 10), bot("b")]
        let room = GroupRoom(id: "team", name: "Team", members: [], updatedAt: .distantPast)
        XCTAssertEqual(BotChatsOrdering.itemID(for: SessionPaneDrag(room: room), bots: bots), "room:team")
        let drag = try XCTUnwrap(SessionPaneDrag(bot: bots[0]))
        XCTAssertEqual(BotChatsOrdering.itemID(for: drag, bots: bots), "bot:a")
    }

    func testProfileSlug() {
        XCTAssertEqual(BotCreationSheet.profileSlug(from: "Trip Planner"), "trip-planner")
        XCTAssertEqual(BotCreationSheet.profileSlug(from: "  Café ✈️ bot!! v2_x "), "caf-bot-v2_x")
        XCTAssertEqual(BotCreationSheet.profileSlug(from: "🚀"), "")
        XCTAssertTrue(BotCreationSheet.isValidProfileName(BotCreationSheet.profileSlug(from: "Research Analyst 3")))
    }
}
