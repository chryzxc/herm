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
}
