import XCTest

@testable import Herm

@MainActor
final class AllBotSessionsParsingTests: XCTestCase {
    func testRowsKeepOwningProfileAndSkipFeedsAndDuplicates() throws {
        let body: [String: Any] = [
            "recents": [
                "sessions": [
                    ["id": "a", "title": "Fix pin popover", "profile": "nexus", "last_active": 200.0],
                    ["id": "a", "title": "Fix pin popover", "profile": "nexus", "last_active": 200.0],
                    // Same id in another profile is a different session.
                    ["id": "a", "title": "Find jobs", "profile": "scout", "last_active": 100.0],
                    ["id": "feed", "profile": "nexus", "message_count": 3, "api_call_count": 0],
                ]
            ]
        ]
        let sessions = try DockModel.parseAllBotSessions(body)
        XCTAssertEqual(sessions.map(\.profileID), ["nexus", "scout"])
        XCTAssertEqual(sessions.map(\.title), ["Fix pin popover", "Find jobs"])
        XCTAssertEqual(sessions.first?.updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testFailedScanIsNotAnEmptyList() {
        // Hermes omits `sessions` when the scan failed; an empty list would read as data loss.
        let failed: [String: Any] = ["recents": ["failed": true, "retry": true]]
        XCTAssertThrowsError(try DockModel.parseAllBotSessions(failed))
        XCTAssertEqual(try DockModel.parseAllBotSessions(["recents": ["sessions": []]]), [])
    }
}
