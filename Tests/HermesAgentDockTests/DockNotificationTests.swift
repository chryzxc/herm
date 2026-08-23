import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct DockNotificationTests {
    @Test func clarificationRequestStopsWorkingStateAndPreservesChoices() {
        let model = DockModel(initialSessionID: "session-clarify")
        model.receiveGatewayEvent("clarify.request", params: [
            "session_id": "session-clarify",
            "payload": [
                "question": "Which task list should I check?",
                "choices": ["Personal", "Work"]
            ]
        ])

        #expect(model.status == .needsClarification)
        #expect(model.clarificationQuestion == "Which task list should I check?")
        #expect(model.clarificationChoices == ["Personal", "Work"])
        #expect(!model.isSending)
        #expect(model.messages.last?.role == .hermes)
        #expect(model.messages.last?.text.contains("Which task list should I check?") == true)
        #expect(model.messages.last?.text.contains("- Personal") == true)
        #expect(model.messages.last?.text.contains("- Work") == true)
    }

    @Test func unselectedSessionCannotProjectGatewayActivity() {
        let model = DockModel()

        model.receiveGatewayEvent("approval.request", params: [
            "session_id": "other-session",
            "payload": ["command": "git push"]
        ])

        #expect(model.approvalText == nil)
        #expect(model.recentEvents.isEmpty)
    }

    @Test func completionNotificationsAreOptIn() {
        let model = DockModel()
        model.setCompletionNotificationsEnabled(true)
        #expect(model.completionNotificationsEnabled == true)
        model.setCompletionNotificationsEnabled(false)
        #expect(model.completionNotificationsEnabled == false)
    }

    @Test func composerFocusRequestIsObservableByThePopover() {
        let model = DockModel()
        let initial = model.composerFocusRequest

        model.requestComposerFocus()

        #expect(model.composerFocusRequest == initial &+ 1)
    }

    @Test func hiddenUpdatesRemainUnreadUntilThePopoverOpens() {
        let model = DockModel()

        model.markPopoverHidden()
        model.markUnreadUpdate()
        #expect(model.hasUnreadResponse)

        model.markPopoverVisible()
        #expect(!model.hasUnreadResponse)
    }

    @Test func visibleUpdatesDoNotCreateAnUnreadBadge() {
        let model = DockModel()

        model.markPopoverVisible()
        model.markUnreadUpdate()

        #expect(!model.hasUnreadResponse)
    }

    @Test func commandCenterUpdatesBecomeUnreadAtTheGlobalBoundary() {
        let model = DockModel()
        model.markPopoverHidden()

        model.receiveGatewayEvent("background.complete", params: [
            "session_id": "another-session",
            "payload": ["task_id": "background-task", "text": "Finished"]
        ])

        #expect(model.hasUnreadResponse)
    }

    @Test func routineProgressDoesNotCreateAnUnreadBadge() {
        let model = DockModel()
        model.markPopoverHidden()

        model.receiveGatewayEvent("message.delta", params: [
            "session_id": "another-session",
            "payload": ["delta": "Still working"]
        ])

        #expect(!model.hasUnreadResponse)
    }

    @Test func approvalPanelPlaysASoundOnlyWhenFirstPresented() {
        var soundCount = 0
        let model = DockModel(approvalSoundPlayer: { soundCount += 1 }, initialSessionID: "session-approval")
        let event: [String: Any] = ["session_id": "session-approval", "payload": ["command": "git push"]]

        model.receiveGatewayEvent("approval.request", params: event)
        model.receiveGatewayEvent("approval.request", params: event)

        #expect(model.approvalText == "git push")
        #expect(soundCount == 1)
    }
}
