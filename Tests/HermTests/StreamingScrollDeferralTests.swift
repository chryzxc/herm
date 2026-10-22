import Combine
import Testing
@testable import Herm

@MainActor
struct StreamingScrollDeferralTests {
    @Test func manualScrollDefersUpdatesAndSettlePresentsTheLatestTextOnce() {
        let streaming = StreamingText()
        streaming.appendPresentation("# Heading\n\nBefore scrolling.")
        let controller = ConversationScrollController()
        let presentation = StreamingTextPresentation()
        presentation.observe(streaming, controller: controller)
        var updates = 0
        let observation = presentation.objectWillChange.sink { updates += 1 }
        controller.userScrollDidMove()
        for delta in ["\n\n**First update.**", "\n\n- Second update.\n", "\n\n> Latest update.\n"] {
            streaming.appendPresentation(delta)
            #expect(updates == 0)
        }
        #expect(streaming.text.hasSuffix("> Latest update.\n"))
        controller.userScrollDidSettle()
        #expect(updates == 1)
        #expect(streaming.chunks.map(\.text).joined() == streaming.text)
        controller.userScrollDidSettle()
        #expect(updates == 1)
        streaming.appendPresentation("Normal following resumes.")
        #expect(updates == 2)
        withExtendedLifetime(observation) {}
    }

    @Test func firstTextAndClearingRemainVisibleDuringAScroll() {
        let streaming = StreamingText()
        let controller = ConversationScrollController()
        controller.userScrollDidMove()
        let presentation = StreamingTextPresentation()
        presentation.observe(streaming, controller: controller)
        var updates = 0
        let observation = presentation.objectWillChange.sink { updates += 1 }
        streaming.appendPresentation("# Initial snapshot\n\nReadable while scrolling.")
        #expect(updates == 1)
        streaming.appendPresentation("Deferred update.")
        #expect(updates == 1)
        streaming.clearPresentation()
        #expect(updates == 2)
        #expect(streaming.text.isEmpty)
        streaming.appendPresentation("A new response.")
        #expect(updates == 3)
        withExtendedLifetime(observation) {}
    }

    @Test func changingStreamsAndUnmountingCancelTheOldSubscriptions() {
        let first = StreamingText()
        first.appendPresentation("Old response")
        let second = StreamingText()
        second.appendPresentation("New response")
        let controller = ConversationScrollController()
        let presentation = StreamingTextPresentation()
        presentation.observe(first, controller: controller)
        var updates = 0
        let observation = presentation.objectWillChange.sink { updates += 1 }
        controller.userScrollDidMove()
        presentation.observe(second, controller: controller)
        #expect(updates == 1, "A new stream must display its initial snapshot immediately")
        first.appendPresentation(" must not return")
        second.appendPresentation(" is current")
        #expect(updates == 1)
        controller.userScrollDidSettle()
        #expect(updates == 2)
        first.appendPresentation(" remains detached")
        #expect(updates == 2)
        presentation.stopObserving()
        second.appendPresentation(" unmounted")
        controller.userScrollDidMove()
        controller.userScrollDidSettle()
        #expect(updates == 2)
        withExtendedLifetime(observation) {}
    }

    @Test func remountingPresentsTextReceivedWhileTheViewWasHidden() {
        let streaming = StreamingText()
        streaming.appendPresentation("Before hiding.")
        let presentation = StreamingTextPresentation()
        presentation.observe(streaming, controller: nil)
        var updates = 0
        let observation = presentation.objectWillChange.sink { updates += 1 }
        presentation.stopObserving()
        streaming.appendPresentation(" Received while hidden.")
        #expect(updates == 0)
        presentation.observe(streaming, controller: nil)
        #expect(updates == 1)
        #expect(streaming.text == "Before hiding. Received while hidden.")
        withExtendedLifetime(observation) {}
    }
}
