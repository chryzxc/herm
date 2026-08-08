import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct ControlCenterAttentionTests {
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
}
