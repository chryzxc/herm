import Foundation
import Testing

@testable import Herm

struct NotificationActionTests {
    @Test func bannerButtonsMapToApprovalChoices() {
        #expect(HermNotificationAction.choice(for: HermNotificationAction.approve) == ApprovalChoice.once)
        #expect(HermNotificationAction.choice(for: HermNotificationAction.deny) == ApprovalChoice.deny)
        #expect(HermNotificationAction.choice(for: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
        #expect(HermNotificationAction.categories.count == 2)
    }
}

struct ApprovalAuthGateTests {
    @Test func onlyBroadApprovalsNeedAuthAndOnlyWhenEnabled() {
        let defaults = UserDefaults(suiteName: "ApprovalAuthGateTests")!
        defaults.removePersistentDomain(forName: "ApprovalAuthGateTests")
        #expect(!ApprovalAuthGate.requiresAuth(ApprovalChoice.always, defaults: defaults))
        defaults.set(true, forKey: ApprovalAuthGate.key)
        #expect(ApprovalAuthGate.requiresAuth(ApprovalChoice.always, defaults: defaults))
        #expect(ApprovalAuthGate.requiresAuth(ApprovalChoice.session, defaults: defaults))
        #expect(!ApprovalAuthGate.requiresAuth(ApprovalChoice.once, defaults: defaults))
        #expect(!ApprovalAuthGate.requiresAuth(ApprovalChoice.deny, defaults: defaults))
    }
}

struct OnDeviceAssistTests {
    @Test func cleanKeepsOneBoundedLine() {
        #expect(OnDeviceAssist.clean(nil) == nil)
        #expect(OnDeviceAssist.clean("  \n") == nil)
        #expect(OnDeviceAssist.clean("Deletes build output.\nExtra") == "Deletes build output.")
        #expect(OnDeviceAssist.clean(String(repeating: "a", count: 300))?.count == OnDeviceAssist.maxExplanationLength)
    }
}

@Suite struct ImageTextRecognizerTests {
    @Test func joinKeepsReadingOrderAndDropsBlanks() {
        #expect(ImageTextRecognizer.join([" Total ", "", "$4"]) == "Total\n$4")
        #expect(ImageTextRecognizer.join(["  "]) == nil)
    }
}

@Suite struct SessionTitleCleaningTests {
    @Test func stripsQuotesPunctuationAndExtraLines() {
        #expect(OnDeviceAssist.cleanTitle("\"Fix login bug.\"\nBecause...") == "Fix login bug")
        #expect(OnDeviceAssist.cleanTitle("  ") == nil)
        #expect(OnDeviceAssist.cleanTitle(nil) == nil)
        #expect(
            (OnDeviceAssist.cleanTitle(String(repeating: "word ", count: 40))?.count ?? 99)
                <= OnDeviceAssist.maxTitleLength)
    }
}

@Suite @MainActor struct SessionSpotlightTests {
    @Test func identifierRoundTripsAndEntryIsCapped() {
        let session = HermesSession(
            id: "abc|1", profileID: "work", title: "", preview: String(repeating: "x", count: 400), startedAt: nil,
            messageCount: 1, source: "herm")
        let id = SessionSpotlightIndex.identifier(for: session)
        #expect(id == "work|abc|1")
        #expect(SessionSpotlightIndex.sessionID(from: id) == "abc|1")
        let item = SessionSpotlightIndex.item(for: session)
        #expect(item.attributeSet.title == "Untitled chat")
        #expect((item.attributeSet.contentDescription?.count ?? 999) <= 160)
    }
}
