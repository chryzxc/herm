import XCTest

@testable import Herm

@MainActor
final class SessionIndexWorkingMergeTests: XCTestCase {
    func testLiveSnapshotClearsMissedCompletion() {
        let live = HermesSession(
            id: "a", title: "", preview: "", startedAt: nil, updatedAt: nil, messageCount: 0, source: "herm",
            isWorking: true)
        let loaded = HermesSession(
            id: "a", title: "", preview: "", startedAt: nil, updatedAt: nil, messageCount: 0, source: "herm")
        let merged = DockModel.mergingSessionIndex([loaded], with: [live], working: [])
        XCTAssertFalse(merged[0].isWorking)
        XCTAssertTrue(DockModel.mergingSessionIndex([loaded], with: [live], working: nil)[0].isWorking)
    }

    func testIndexWorkingSetsOtherRow() {
        let known = HermesSession(
            id: "a", title: "", preview: "", startedAt: nil, updatedAt: nil, messageCount: 0, source: "herm")
        let merged = DockModel.mergingSessionIndex([known], with: [known], working: ["a"])
        XCTAssertTrue(merged[0].isWorking)
        XCTAssertTrue(DockModel.mergingSessionIndex([known], with: [], working: ["a"])[0].isWorking)
        XCTAssertTrue(DockModel.mergingSessionIndex([known], with: [known], keeping: "a", working: ["a"])[0].isWorking)
    }

    func testSidebarUsesLiveRowInsteadOfOlderSummary() {
        for working in [false, true] {
            let session = HermesSession(
                id: "a", title: "", preview: "", startedAt: nil, messageCount: 0, source: "herm", isWorking: working)
            let summary = SessionSummary(id: "a", title: "", state: working ? "idle" : "working", preview: nil)
            let status = SidebarSessionStatusResolver.resolve(
                session: session, summary: summary, activeSessionID: nil, activeStatus: nil,
                attention: nil, seenAt: nil, isProfileBaselined: false
            )
            XCTAssertEqual(status, working ? .working : .none)
            let selectedStatus = SidebarSessionStatusResolver.resolve(
                session: session, summary: summary, activeSessionID: "a", activeStatus: working ? .idle : .working,
                attention: nil, seenAt: nil, isProfileBaselined: false
            )
            XCTAssertEqual(selectedStatus, working ? .working : .none)
        }
    }
}
