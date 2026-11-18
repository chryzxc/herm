import XCTest
@testable import Herm

final class SessionRecentsPresentationTests: XCTestCase {
    func testMetadataPartitionsSessionsWithoutChangingOrder() {
        let sources = ["conversation", " CRON ", "cron_output", "automation", "unknown"]
        let sessions = sources.enumerated().map { index, source in
            HermesSession(id: "\(index)", title: "cron", preview: "", startedAt: nil, messageCount: 0, source: source)
        }
        XCTAssertEqual(SessionRecentsType.conversations.matching(sessions).map(\.id), ["0", "4"])
        XCTAssertEqual(SessionRecentsType.automation.matching(sessions).map(\.id), ["1", "2", "3"])
        XCTAssertEqual(sessions[1].sourceBadgeTitle, "Cron")
        XCTAssertEqual(sessions[2].sourceBadgeTitle, "Cron output")
        XCTAssertEqual(sessions[3].sourceBadgeTitle, "Automation")
    }
}
