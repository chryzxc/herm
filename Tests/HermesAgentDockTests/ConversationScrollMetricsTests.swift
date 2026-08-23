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
}
