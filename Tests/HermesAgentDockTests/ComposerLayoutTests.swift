import XCTest
@testable import HermesAgentDock

final class ComposerLayoutTests: XCTestCase {
    func testLargePastedContentIsCappedToComposerMaximumHeight() {
        XCTAssertEqual(ComposerLayout.height(for: 4_000), ComposerLayout.maxHeight)
    }

    func testComposerContentHeightPreservesNormalMeasuredHeight() {
        XCTAssertEqual(ComposerLayout.height(for: 96), 96)
    }

    func testEmptyComposerUsesMinimumHeight() {
        XCTAssertEqual(ComposerLayout.height(for: 0), ComposerLayout.minHeight)
    }
}
