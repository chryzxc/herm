import XCTest
@testable import HermesAgentDock

final class ConversationScrollMetricsTests: XCTestCase {
    func testSentinelAtViewportBottomCountsAsAtBottom() {
        XCTAssertTrue(ConversationScrollMetrics.isAtBottom(bottomMaxY: 720, viewportHeight: 720))
    }

    func testTransientStreamingGrowthStaysSticky() {
        XCTAssertTrue(ConversationScrollMetrics.isAtBottom(bottomMaxY: 780, viewportHeight: 720))
    }

    func testScrolledUpPastToleranceIsNotAtBottom() {
        XCTAssertFalse(ConversationScrollMetrics.isAtBottom(bottomMaxY: 720 + ConversationScrollMetrics.atBottomTolerance + 1, viewportHeight: 720))
    }

    func testPastEndViewportIsDetected() {
        XCTAssertTrue(ConversationScrollMetrics.isPastEnd(topMinY: -400, bottomMaxY: 600, viewportHeight: 720))
    }

    func testShortTranscriptIsNotPastEnd() {
        XCTAssertFalse(ConversationScrollMetrics.isPastEnd(topMinY: 0, bottomMaxY: 300, viewportHeight: 720))
        XCTAssertFalse(ConversationScrollMetrics.isPastEnd(topMinY: 100, bottomMaxY: 500, viewportHeight: 720))
    }

    func testBottomParkedViewportIsNotPastEnd() {
        XCTAssertFalse(ConversationScrollMetrics.isPastEnd(topMinY: -400, bottomMaxY: 720, viewportHeight: 720))
    }

    func testPastEndRepairIsBounded() {
        XCTAssertTrue(ConversationScrollSettle.canRepairPastEnd(repairCount: 0))
        XCTAssertFalse(ConversationScrollSettle.canRepairPastEnd(repairCount: ConversationScrollSettle.maxPastEndRepairs))
    }

    func testUnsettledScrollOffBottomAllowsOneReassertion() {
        XCTAssertTrue(ConversationScrollSettle.shouldReassert(
            bottomMaxY: 720 + ConversationScrollMetrics.atBottomTolerance + 400,
            viewportHeight: 720,
            reassertCount: 0
        ))
    }

    func testSettledAtBottomNeedsNoReassertion() {
        XCTAssertFalse(ConversationScrollSettle.shouldReassert(bottomMaxY: 720, viewportHeight: 720, reassertCount: 0))
    }

    func testReassertionIsBounded() {
        let offBottom: CGFloat = 720 + ConversationScrollMetrics.atBottomTolerance + 400
        XCTAssertLessThan(ConversationScrollSettle.maxReassertions, 2)
        XCTAssertFalse(ConversationScrollSettle.shouldReassert(bottomMaxY: offBottom, viewportHeight: 720, reassertCount: ConversationScrollSettle.maxReassertions))
        XCTAssertFalse(ConversationScrollSettle.shouldReassert(bottomMaxY: offBottom, viewportHeight: 720, reassertCount: ConversationScrollSettle.maxReassertions + 1))
    }
}
