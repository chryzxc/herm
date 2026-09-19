import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
private final class ClarificationResponseRPCClient: HermesRPCClientProtocol {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var calls: [Call] = []

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(Call(method: method, params: params))
        return [:]
    }

    func close() {}
}

@MainActor
struct ControlCenterAttentionTests {
    @Test func restoredCompletedItemTargetsItsSession() {
        let reference = ControlCenterModel.restoredAttentionReference(for: "completed:session-42")

        #expect(reference.source == .hermesSession)
        #expect(reference.sourceID == "session-42")
        #expect(reference.sessionID == "session-42")
    }

    @Test func restoredSpecializedItemsKeepTheirSource() {
        let approval = ControlCenterModel.restoredAttentionReference(for: "approval:session-approval")
        let reminder = ControlCenterModel.restoredAttentionReference(for: "reminder:reminder-1")

        #expect(approval.source == .hermesApproval)
        #expect(approval.sessionID == "session-approval")
        #expect(reminder.source == .appleReminder)
        #expect(reminder.sourceID == "reminder-1")
    }

    @Test func sessionAttentionProjectionExcludesOtherSessions() {
        let model = ControlCenterModel()
        model.ingestEvent("approval.request", params: [
            "session_id": "session-a",
            "payload": ["command": "echo A"]
        ])
        model.ingestEvent("approval.request", params: [
            "session_id": "session-b",
            "payload": ["command": "echo B"]
        ])

        #expect(model.attention(for: "session-a").count == 1)
        #expect(model.attention(for: "session-a").first?.detail == "echo A")
        #expect(model.attention(for: "session-b").count == 1)
        #expect(model.attention(for: "session-b").first?.detail == "echo B")
        #expect(model.attention(for: "session-missing").isEmpty)
        #expect(model.openAttention(for: "session-a").map(\.detail) == ["echo A"])
        #expect(model.openAttention(for: "session-b").map(\.detail) == ["echo B"])
        #expect(model.openAttention(for: "session-missing").isEmpty)
    }

    @Test func approvalEventsExposeActionTitleAndDetails() {
        let model = ControlCenterModel()

        model.ingestEvent("approval.request", params: [
            "session_id": "session-approval-title",
            "payload": [
                "title": "Review repository activity",
                "command": "gh api repos/example/project/events",
                "description": "network access"
            ]
        ])

        #expect(model.attention.first?.title == "Review repository activity")
        #expect(model.attention.first?.detail == "gh api repos/example/project/events")
    }

    @Test func approvalEventsShowExactCommandInsteadOfSafetyCategory() {
        let model = ControlCenterModel()

        model.ingestEvent("approval.request", params: [
            "session_id": "session-recursive-delete",
            "payload": [
                "command": "rm -rf -- .omo",
                "description": "recursive delete",
                "pattern_key": "recursive delete"
            ]
        ])

        let item = model.attention.first
        #expect(item?.title == "Run command")
        #expect(item?.detail == "rm -rf -- .omo")
    }

    @Test func completedResponsesDoNotAppearAsNeedsMeAttention() {
        let model = ControlCenterModel()

        model.ingestEvent("message.complete", params: [
            "session_id": "session-complete",
            "payload": [:]
        ])

        #expect(model.openAttention(for: "session-complete").isEmpty)
    }

    @Test func clarificationEventsExposeAResponseAction() {
        let model = ControlCenterModel()

        model.ingestEvent("clarification.request", params: [
            "session_id": "session-clarify",
            "payload": ["question": "Which account should I use?"]
        ])

        let item = model.attention.first
        #expect(item?.kind == .clarification)
        #expect(item?.detail == "Which account should I use?")
        #expect(item?.actions.contains(.respond) == true)
    }

    @Test func clarificationEventsPreserveSuggestedResponses() {
        let model = ControlCenterModel()

        model.ingestEvent("clarify.request", params: [
            "session_id": "session-clarify-choices",
            "payload": [
                "question": "Which approach should I take?",
                "choices": ["Use the first approach", "Use the second approach"]
            ]
        ])

        #expect(model.attention.first?.choices == ["Use the first approach", "Use the second approach"])
    }

    @Test func clarificationEventsPreserveHermesRequestIdentity() {
        let model = ControlCenterModel()

        model.ingestEvent("clarify.request", params: [
            "session_id": "session-clarify-request",
            "payload": [
                "request_id": "clarify-42",
                "question": "Which environment?"
            ]
        ])

        #expect(model.attention.first?.reference.sessionID == "session-clarify-request")
        #expect(model.attention.first?.reference.clarificationRequestID == "clarify-42")
    }

    @Test func respondingToClarificationUsesRequestIdentityAndResolvesAfterRPC() async {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let sessionID = "session-clarify-response-\(UUID().uuidString)"
        model.ingestEvent("clarify.request", params: [
            "session_id": sessionID,
            "payload": [
                "request_id": "clarify-response-42",
                "question": "Which environment?"
            ]
        ])
        let item = try! #require(model.attention.first)

        model.respond(to: item, action: .respond, response: "production")
        for _ in 0..<20 { await Task.yield() }

        let clarificationCalls = client.calls.filter { $0.method == "clarify.respond" }
        #expect(clarificationCalls.count == 1)
        #expect(clarificationCalls.first?.params["request_id"] as? String == "clarify-response-42")
        #expect(clarificationCalls.first?.params["answer"] as? String == "production")
        #expect(model.attention.first?.state == .resolved)
    }

    @Test func respondingToClarificationWithoutUsableRequestIdentityFailsSafely() async {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let sessionID = "session-clarify-invalid-\(UUID().uuidString)"
        model.ingestEvent("clarify.request", params: [
            "session_id": sessionID,
            "payload": ["question": "Which environment?"]
        ])
        let item = try! #require(model.attention.first)

        model.respond(to: item, action: .respond, response: "production")
        for _ in 0..<20 { await Task.yield() }

        #expect(client.calls.filter { $0.method == "clarify.respond" }.isEmpty)
        #expect(model.attention.first?.state == .open)
    }

    @Test func respondingToClarificationWithWhitespaceRequestIdentityFailsSafely() async {
        let client = ClarificationResponseRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let sessionID = "session-clarify-whitespace-\(UUID().uuidString)"
        model.ingestEvent("clarify.request", params: [
            "session_id": sessionID,
            "payload": [
                "request_id": "   ",
                "question": "Which environment?"
            ]
        ])
        let item = try! #require(model.attention.first)

        model.respond(to: item, action: .respond, response: "production")
        for _ in 0..<20 { await Task.yield() }

        #expect(client.calls.filter { $0.method == "clarify.respond" }.isEmpty)
        #expect(model.attention.first?.state == .open)
    }

    @Test func partialAttentionEventsPreserveExistingDetail() {
        let model = ControlCenterModel()

        model.ingestEvent("approval.request", params: [
            "session_id": "session-approval",
            "payload": ["command": "delete the temporary export"]
        ])
        model.ingestEvent("approval.request", params: [
            "session_id": "session-approval",
            "payload": [:]
        ])

        #expect(model.attention.first?.detail == "delete the temporary export")
    }

    @Test func reminderProjectionUsesStableAppleReference() {
        let reminder = ReminderSummary(id: "rem-1", title: "Call back", list: "Personal", dueDate: Date(), isOverdue: true)
        let item = ControlCenterModel.reminderAttention(for: reminder)

        #expect(item.id == "reminder:rem-1")
        #expect(item.reference == ControlReference(source: .appleReminder, sourceID: "rem-1"))
        #expect(item.kind == .reminder)
        #expect(item.actions.contains(.complete))
    }

    @Test func overdueRemindersRankBeforeOrdinaryReminders() {
        let overdue = ControlCenterModel.reminderAttention(for: ReminderSummary(id: "overdue", title: "Urgent", list: nil, dueDate: Date(), isOverdue: true))
        let ordinary = ControlCenterModel.reminderAttention(for: ReminderSummary(id: "ordinary", title: "Later", list: nil, dueDate: Date(), isOverdue: false))

        #expect(ControlCenterModel.attentionRank(overdue) < ControlCenterModel.attentionRank(ordinary))
    }
}
