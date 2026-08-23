import Testing
@testable import HermesAgentDock

struct CommandDoubleTapDetectorTests {
    @Test func detectsTwoCommandTapsWithinInterval() {
        var detector = CommandDoubleTapDetector()

        let firstPress = detector.handle(isCommandDown: true, at: 1.0)
        let firstRelease = detector.handle(isCommandDown: false, at: 1.1)
        let secondPress = detector.handle(isCommandDown: true, at: 1.2)

        #expect(!firstPress)
        #expect(!firstRelease)
        #expect(secondPress)
    }

    @Test func ignoresSlowSecondTap() {
        var detector = CommandDoubleTapDetector()

        let firstPress = detector.handle(isCommandDown: true, at: 1.0)
        let firstRelease = detector.handle(isCommandDown: false, at: 1.1)
        let secondPress = detector.handle(isCommandDown: true, at: 1.1 + CommandDoubleTapDetector.maximumInterval + 0.01)

        #expect(!firstPress)
        #expect(!firstRelease)
        #expect(!secondPress)
    }

    @Test func doesNotTriggerWhileCommandRemainsHeld() {
        var detector = CommandDoubleTapDetector()

        let firstPress = detector.handle(isCommandDown: true, at: 1.0)
        let repeatedPress = detector.handle(isCommandDown: true, at: 1.1)

        #expect(!firstPress)
        #expect(!repeatedPress)
    }

    @Test func interveningKeyBetweenTapsDoesNotTrigger() {
        var detector = CommandDoubleTapDetector()

        let firstPress = detector.handle(isCommandDown: true, at: 1.0)
        detector.noteKeyActivity()
        let firstRelease = detector.handle(isCommandDown: false, at: 1.1)
        let secondPress = detector.handle(isCommandDown: true, at: 1.2)

        #expect(!firstPress)
        #expect(!firstRelease)
        #expect(!secondPress)
    }

    @Test func keyActivityBeforeFirstPressDoesNotAffectLaterPair() {
        var detector = CommandDoubleTapDetector()

        detector.noteKeyActivity()
        detector.handle(isCommandDown: true, at: 1.0)
        detector.handle(isCommandDown: false, at: 1.1)
        let secondPress = detector.handle(isCommandDown: true, at: 1.2)

        #expect(secondPress)
    }
}
