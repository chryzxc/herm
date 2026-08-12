import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct DockNotificationTests {
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
        let model = DockModel(approvalSoundPlayer: { soundCount += 1 })
        let event: [String: Any] = ["payload": ["command": "git push"]]

        model.receiveGatewayEvent("approval.request", params: event)
        model.receiveGatewayEvent("approval.request", params: event)

        #expect(model.approvalText == "git push")
        #expect(soundCount == 1)
    }
}
