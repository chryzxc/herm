import XCTest
@testable import HermesAgentDock

final class ComposerLayoutTests: XCTestCase {
    func testLargePastedContentIsCappedToComposerMaximumHeight() {
        XCTAssertEqual(ComposerLayout.height(for: 4_000), 120)
    }

    func testComposerContentHeightPreservesNormalMeasuredHeight() {
        XCTAssertEqual(ComposerLayout.height(for: 96), 96)
    }

    func testEmptyComposerUsesMinimumHeight() {
        XCTAssertEqual(ComposerLayout.height(for: 0), 34)
    }

    func testIdleComposerHeightFitsCompactTarget() {
        XCTAssertEqual(ComposerLayout.idleHeight, 100)
        XCTAssertTrue((92...100).contains(Int(ComposerLayout.idleHeight)))
    }
}
