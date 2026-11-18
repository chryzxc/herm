import Foundation
import Testing

@testable import Herm

@MainActor
struct DockProfilePickerOrderTests {
    @Test func draggingMovesBeforeOrAfterAndPersists() {
        let suite = "profile-drag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bots = ["a", "b", "c"].map { id in
            BotSummary(
                id: id, name: id, title: nil, description: nil, model: nil,
                isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
                isHidden: false, hasAvatar: false, isDefault: false)
        }
        let order = DockProfilePickerOrder(defaults: defaults)
        order.move("a", relativeTo: "c", after: true, in: bots)
        #expect(order.ordered(bots).map(\.id) == ["b", "c", "a"])
        order.move("a", relativeTo: "b", after: false, in: bots)
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots).map(\.id) == ["a", "b", "c"])
        order.move("a", relativeTo: "missing", after: false, in: bots)
        order.move("a", relativeTo: "a", after: true, in: bots)
        #expect(order.ordered(bots).map(\.id) == ["a", "b", "c"])
    }

    @Test func movesAndPersistsWithoutChangingProfiles() {
        let suite = "profile-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bots = ["a", "b", "c"].map { id in
            BotSummary(
                id: id, name: id, title: nil, description: nil, model: nil,
                isActive: false, chat: BotChatReference(sessionID: "chat-\(id)", profileID: id),
                worker: BotWorkerReference(sessionID: "worker-\(id)", source: nil, title: nil, lastActive: nil),
                avatarURL: nil, preview: nil, lastActive: nil,
                isHidden: false, hasAvatar: false, isDefault: id == "a")
        }
        let order = DockProfilePickerOrder(defaults: defaults)
        order.move("b", by: -1, in: bots)
        #expect(order.ordered(bots).map(\.id) == ["b", "a", "c"])
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots) == [bots[1], bots[0], bots[2]])
        order.move("b", by: -1, in: bots)
        #expect(order.ordered([]).isEmpty)
        #expect(order.ordered(bots).map(\.id) == ["b", "a", "c"])
        order.move("b", by: 1, in: bots)
        #expect(order.ordered(bots) == bots)
        order.move("a", by: -1, in: bots)
        order.move("c", by: 1, in: bots)
        order.move("missing", by: 1, in: bots)
        order.move("a", by: 2, in: bots)
        #expect(order.ordered(bots) == bots)
        defaults.set(["c", "c", "missing", ""], forKey: "herm.sidebar.profilePickerOrder")
        let restored = DockProfilePickerOrder(defaults: defaults)
        #expect(restored.ordered(bots).map(\.id) == ["c", "a", "b"])
        #expect(restored.ordered([bots[0], bots[2]]).map(\.id) == ["c", "a"])
        #expect(restored.ordered([]).isEmpty)
        #expect(restored.ordered(bots).map(\.id) == ["c", "a", "b"])
        restored.move("a", by: 1, in: [bots[0]])
        #expect(restored.ordered([bots[0]]) == [bots[0]])
        let hidden = BotSummary(
            id: "hidden", name: "hidden", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: true, hasAvatar: false, isDefault: false)
        #expect(restored.ordered([hidden] + bots) == [bots[2], bots[0], bots[1]])
        defaults.set("not an array", forKey: "herm.sidebar.profilePickerOrder")
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots) == bots)
        defaults.set(["c", 42] as [Any], forKey: "herm.sidebar.profilePickerOrder")
        #expect(DockProfilePickerOrder(defaults: defaults).ordered(bots) == bots)
    }
}
