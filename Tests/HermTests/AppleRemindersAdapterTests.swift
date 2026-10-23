import Foundation
import Testing

@testable import Herm

@MainActor
struct AppleRemindersAdapterTests {
    @Test func parsesAndOrdersOverdueReminders() {
        let output = """
            {"reminders":[
              {"id":"later","title":"Later","dueDate":"2030-01-02T10:00:00Z","isOverdue":false},
              {"id":"overdue","title":"Overdue","dueDate":"2020-01-02T10:00:00Z","isOverdue":true}
            ]}
            """

        let reminders = AppleRemindersAdapter.parse(output)

        #expect(reminders.count == 2)
        #expect(reminders.first?.id == "overdue")
        #expect(reminders.first?.isOverdue == true)
    }

    @Test func ignoresMalformedReminderRows() {
        let reminders = AppleRemindersAdapter.parse(
            "[{\"title\":\"Missing id\"},{\"id\":\"valid\",\"title\":\"Keep me\"}]")

        #expect(reminders.count == 1)
        #expect(reminders.first?.id == "valid")
    }

    @Test func rejectsFailedShellResults() {
        #expect(AppleRemindersAdapter.shellResultSucceeded(["code": 1, "stderr": "Not authorized"]) == false)
        #expect(AppleRemindersAdapter.shellResultSucceeded(["code": 0, "stdout": "[]"]) == true)
    }
}
