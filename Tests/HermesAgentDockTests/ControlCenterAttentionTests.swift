import Foundation
import Testing
@testable import HermesAgentDock

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

    @Test func approvalEventsExposeActionTitleAndDetails() {
        let model = ControlCenterModel()

        model.ingestEvent("approval.request", params: [
            "session_id": "session-approval-title",
            "payload": [
                "title": "Review repository activity",
                "command": "gh api repos/example/project/events"
            ]
        ])

        #expect(model.attention.first?.title == "Review repository activity")
        #expect(model.attention.first?.detail == "gh api repos/example/project/events")
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
