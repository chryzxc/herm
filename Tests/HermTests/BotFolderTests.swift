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

    private func bot(_ id: String, activeAt seconds: TimeInterval? = nil) -> BotSummary {
        let chat = seconds.map {
            BotChatReference(sessionID: "\(id)-main", profileID: id, lastActive: Date(timeIntervalSince1970: $0))
        }
        return BotSummary(
            id: id, name: id, title: nil, description: nil, model: nil, provider: nil,
            isActive: true, chat: chat, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false,
            hasAvatar: false, isDefault: false)
    }

    func testItemsLiveInOneFolderAndDeleteReturnsThemToTheTopLevel() {
        let store = BotFolderStore(defaults: defaults)
        let work = store.create(name: "Work", containing: "bot:a")
        let play = store.create(name: "Play")
        store.move("bot:a", to: play)
        XCTAssertNil(store.folders.first { $0.id == work }?.itemIDs.first)
        XCTAssertEqual(store.folderID(containing: "bot:a"), play)
        store.move("bot:a", to: nil)
        XCTAssertNil(store.folderID(containing: "bot:a"))
        store.move("room:r", to: play)
        store.delete(play)
        XCTAssertNil(store.folderID(containing: "room:r"))
    }

    func testFolderReorderRenameAndPersistence() {
        let store = BotFolderStore(defaults: defaults)
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
    }

    func testSectionsKeepActivityOrderIgnoreStaleIDsAndFlattenSearch() {
        let room = GroupRoom(id: "team", name: "Team", members: [], updatedAt: .distantPast)
        let items = BotChatsOrdering.items(
            [bot("a", activeAt: 10), bot("b", activeAt: 50), bot("c", activeAt: 20)],
            rooms: [(room, Date(timeIntervalSince1970: 30))])
        let folders = [
            BotFolder(name: "Empty"),
            BotFolder(name: "Mixed", itemIDs: ["bot:a", "gone", "room:team", "bot:b"]),
        ]
        let sections = BotChatsOrdering.sections(items, folders: folders, isSearching: false)
        XCTAssertEqual(sections.folders.map(\.folder.name), ["Empty", "Mixed"])
        XCTAssertEqual(sections.folders[1].items.map(\.id), ["bot:b", "room:team", "bot:a"])
        XCTAssertEqual(sections.loose.map(\.id), ["bot:c"])

        let searching = BotChatsOrdering.sections(items, folders: folders, isSearching: true)
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
