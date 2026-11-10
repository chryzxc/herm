import Foundation
import Testing

@testable import Herm

@MainActor
struct MessageReactionTests {
    private let heart: [String: Any] = ["emoji": "❤️", "author": "agent", "at": 12.5]

    @Test func parsesReactionsFromObjectAndJSONMetadata() {
        let object = MessageReaction.parse(displayMetadata: ["reactions": [heart, ["emoji": " "]]])
        #expect(object == [MessageReaction(emoji: "❤️", author: "agent", at: 12.5)])
        let json = #"{"reactions":[{"emoji":"👍","author":"user"}]}"#
        #expect(MessageReaction.parse(displayMetadata: json) == [MessageReaction(emoji: "👍", author: "user", at: nil)])
        #expect(MessageReaction.parse(displayMetadata: "not json").isEmpty)
        #expect(MessageReaction.parse(displayMetadata: nil).isEmpty)
    }

    @Test func restoredHistoryCarriesReactions() {
        let rows: [[String: Any]] = [
            ["role": "user", "text": "ship it", "row_id": 4, "display_metadata": ["reactions": [heart]]],
            ["role": "assistant", "text": "done", "row_id": 5],
        ]
        let restored = DockModel.parseMessages(rows)
        #expect(restored.messages.map(\.reactions.count) == [1, 0])
    }

    @Test func targetPrefersKnownRowThenNewestOfRoleForNewerRows() {
        let old = ChatMessage(role: .user, text: "old")
        let reply = ChatMessage(role: .hermes, text: "reply")
        let live = ChatMessage(role: .user, text: "live")
        let messages = [old, reply, live]
        let known = [1: old.id, 2: reply.id]
        #expect(MessageReaction.targetIndex(rowID: 1, role: "user", messages: messages, knownRows: known) == 0)
        #expect(MessageReaction.targetIndex(rowID: 3, role: "user", messages: messages, knownRows: known) == 2)
        #expect(MessageReaction.targetIndex(rowID: 3, role: "assistant", messages: messages, knownRows: known) == 1)
        // An earlier unknown row must not land on the newest message.
        #expect(MessageReaction.targetIndex(rowID: 0, role: "user", messages: messages, knownRows: known) == nil)
    }
}
