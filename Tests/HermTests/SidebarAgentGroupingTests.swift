import XCTest

@testable import Herm

final class SidebarAgentGroupingTests: XCTestCase {
    private func session(
        _ id: String, profile: String?, at seconds: TimeInterval, isWorking: Bool = false
    ) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: id, preview: "", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: seconds), messageCount: 1, source: "desktop",
            isWorking: isWorking)
    }

    func testScopedRowsReplaceScanCopyAndAdoptSelectedProfile() {
        let all = [
            session("a", profile: "default", at: 10),
            session("b", profile: "coder", at: 30),
            session("a", profile: "coder", at: 5),
        ]
        let scoped = [session("a", profile: nil, at: 40, isWorking: true)]
        let merged = SidebarAgentGrouping.merged(all: all, scoped: scoped, scopeProfileID: "default")

        XCTAssertEqual(merged.map(\.id), ["a", "b", "a"])
        XCTAssertTrue(merged[0].isWorking)
        XCTAssertEqual(merged[2].profileID, "coder")
    }

    func testGroupsFollowNewestChatAndKeepRosterOrderForIdleBots() {
        let sessions = [
            session("x", profile: "coder", at: 50),
            session("y", profile: nil, at: 20),
            session("z", profile: "coder", at: 10),
        ]
        let groups = SidebarAgentGrouping.groups(
            sessions, botIDs: ["default", "writer", "coder", "idle"], scopeProfileID: "default")

        XCTAssertEqual(groups.map(\.profileID), ["coder", "default", "writer", "idle"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["x", "z"])
        XCTAssertEqual(groups[1].sessions.map(\.id), ["y"])
        XCTAssertTrue(groups[2].sessions.isEmpty)
    }

    func testExpandedRowsKeepNewestThreePlusChatsNeedingAttention() {
        let sessions = (0..<6).map { session("s\($0)", profile: "coder", at: TimeInterval(100 - $0)) }
        let visible = SidebarAgentGrouping.visibleSessions(sessions, showsAll: false) { $0.id == "s5" }
        XCTAssertEqual(visible.map(\.id), ["s0", "s1", "s2", "s5"])

        let all = SidebarAgentGrouping.visibleSessions(sessions, showsAll: true) { _ in false }
        XCTAssertEqual(all.count, 6)
    }
}
