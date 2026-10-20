import XCTest
@testable import Herm

@MainActor
final class SessionIndexWorkingMergeTests: XCTestCase {
    func testObservedWorkingSurvivesIndexThatDroppedIt() {
        let live = HermesSession(id: "a", title: "", preview: "", startedAt: nil, updatedAt: nil, messageCount: 0, source: "herm", isWorking: true)
        let loaded = HermesSession(id: "a", title: "", preview: "", startedAt: nil, updatedAt: nil, messageCount: 0, source: "herm")
        let merged = DockModel.mergingSessionIndex([loaded], with: [live], working: [])
        XCTAssertTrue(merged[0].isWorking)
    }

    func testIndexWorkingSetsOtherRow() {
        let known = HermesSession(id: "a", title: "", preview: "", startedAt: nil, updatedAt: nil, messageCount: 0, source: "herm")
        let merged = DockModel.mergingSessionIndex([known], with: [known], working: ["a"])
        XCTAssertTrue(merged[0].isWorking)
    }
}
