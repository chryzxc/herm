import XCTest

@testable import Herm

final class SessionRecentsPresentationTests: XCTestCase {
    func testNewSectionsAppendToExistingOrder() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let statuses: [SessionRailSection] = [.unread, .needsYou, .running, .archived]
        XCTAssertEqual(SessionRailSection.stored(defaults), [.pinned, .recents, .projects, .automations] + statuses)
        defaults.set(["projects", "pinned", "recents"], forKey: SessionRailSection.storageKey)
        XCTAssertEqual(SessionRailSection.stored(defaults), [.projects, .pinned, .recents, .automations] + statuses)
        defaults.set(
            ["archived", "automations", "recents", "pinned", "projects"], forKey: SessionRailSection.storageKey)
        XCTAssertEqual(
            SessionRailSection.stored(defaults),
            [.archived, .automations, .recents, .pinned, .projects, .unread, .needsYou, .running])
    }

    func testMetadataPartitionsSessionsWithoutChangingOrder() {
        let sources = ["conversation", " CRON ", "cron_output", "automation", "unknown"]
        let sessions = sources.enumerated().map { index, source in
            HermesSession(id: "\(index)", title: "cron", preview: "", startedAt: nil, messageCount: 0, source: source)
        }
        let recents = SessionRecentsPresentation(sessions)
        XCTAssertEqual(recents.conversations.map(\.id), ["0", "4"])
        XCTAssertEqual(recents.automations.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(recents.conversations, SessionRecentsType.conversations.matching(sessions))
        XCTAssertEqual(recents.automations, SessionRecentsType.automation.matching(sessions))
        XCTAssertEqual(sessions[1].sourceBadgeTitle, "Cron")
        XCTAssertEqual(sessions[2].sourceBadgeTitle, "Cron output")
        XCTAssertEqual(sessions[3].sourceBadgeTitle, "Automation")
    }
}
