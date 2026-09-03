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
