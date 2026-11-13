import Foundation
import Testing

@testable import Herm

struct ConversationChangeSummaryTests {
    private func call(_ id: String, diff: String?, complete: Bool = true) -> ActiveToolCall {
        ActiveToolCall(
            id: id, name: "patch", input: "", context: "", startedAt: .now,
            isComplete: complete, diffPreview: diff)
    }

    @Test func groupsRenderedDiffsByFileWithoutInventingChanges() {
        let changes = ConversationChangeSummary.files(in: [
            call(
                "1",
                diff:
                    "Review changes\na/src/a.swift → b/src/a.swift\n@@ -1 +1 @@\n-old\n+new\na/src/b.swift → b/src/b.swift\n@@ -1 +1 @@\n-a\n+b"
            ),
            call("2", diff: "a/src/a.swift → b/src/a.swift\n@@ -1 +1 @@\n-new\n+newer"),
            call("3", diff: nil),
            call("4", diff: "a/ignored → b/ignored\n+x", complete: false),
        ])
        #expect(changes.map(\.path) == ["src/a.swift", "src/b.swift"])
        #expect(changes[0].previews.count == 2)
        #expect(changes[1].previews.count == 1)
    }

    @Test func omitsUnattributedAndUnchangedOutput() {
        #expect(ConversationChangeSummary.files(in: [call("1", diff: "ordinary output")]).isEmpty)
        #expect(ConversationChangeSummary.files(in: [call("2", diff: "a/x → b/x\n@@ -1 +1 @@\n same")]).isEmpty)
    }

    @Test func onlyFinalReplyReceivesAllTurnActivity() {
        let user = ChatMessage(role: .user, text: "edit", timestamp: .now)
        let interim = ChatMessage(
            role: .hermes, text: "working", timestamp: .now,
            activity: [
                call("1", diff: "a/x → b/x\n@@ -1 +1 @@\n-old\n+new")
            ])
        let reply = ChatMessage(role: .hermes, text: "done", timestamp: .now)
        let messages = [user, interim, reply]
        #expect(ConversationChangeSummary.turnFiles(messages: messages, at: 1, streamingID: nil).isEmpty)
        #expect(ConversationChangeSummary.turnFiles(messages: messages, at: 2, streamingID: reply.id).isEmpty)
        #expect(ConversationChangeSummary.turnFiles(messages: messages, at: 2, streamingID: nil).map(\.path) == ["x"])
    }

    @Test func restoresPersistedRuntimeDiffMetadata() {
        let rows: [[String: Any]] = [
            ["role": "user", "content": "edit"],
            [
                "role": "tool", "tool_name": "patch", "tool_call_id": "1", "content": "{}",
                "display_metadata": ["tool_result_metadata": ["inline_diff": "a/x → b/x\n@@ -1 +1 @@\n-old\n+new"]],
            ],
            ["role": "assistant", "content": "done"],
        ]
        let projected = TranscriptHistoryPaging.displayRows(fromStoredRows: rows)
        let restored = DockModel.parseMessages(projected).messages
        #expect(ConversationChangeSummary.turnFiles(messages: restored, at: 1, streamingID: nil).map(\.path) == ["x"])
    }
}
