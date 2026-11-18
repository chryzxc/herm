import XCTest

@testable import Herm

final class AllProfilesSessionsTests: XCTestCase {
    private func session(
        _ id: String, profile: String?, at seconds: TimeInterval, pinned: Bool = false
    ) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: id, preview: "", startedAt: nil,
            updatedAt: Date(timeIntervalSince1970: seconds), messageCount: 1, source: "desktop", isPinned: pinned)
    }

    private func bot(_ id: String) -> BotSummary {
        BotSummary(
            id: id, name: id.capitalized, title: nil, description: nil, model: nil, provider: nil,
            isActive: true, chat: nil, avatarURL: nil, preview: nil, lastActive: nil, isHidden: false,
            hasAvatar: false, isDefault: id == "default")
    }

    func testMergesEveryProfilesPinsNewestFirst() {
        let scopePinned = [session("a", profile: nil, at: 10)]
        let scanned = [
            session("b", profile: "coder", at: 30, pinned: true),
            session("c", profile: "coder", at: 40),
            session("d", profile: "writer", at: 20, pinned: true),
        ]
        let pinned = AllProfilesSessions.pinned(scopePinned: scopePinned, scanned: scanned, scopeProfileID: "default")

        XCTAssertEqual(pinned.map(\.id), ["b", "d", "a"])
    }

    func testSelectedProfilesPinsComeOnlyFromItsOwnList() {
        // The scan can lag an unpin the selected profile already acknowledged.
        let scanned = [session("a", profile: "default", at: 10, pinned: true)]
        let pinned = AllProfilesSessions.pinned(scopePinned: [], scanned: scanned, scopeProfileID: "default")

        XCTAssertTrue(pinned.isEmpty)
    }

    func testPinStateIsProfileScoped() {
        // The same id pinned in the selected profile does not pin another profile's row.
        let scopePinned = [session("a", profile: nil, at: 10)]

        XCTAssertTrue(
            AllProfilesSessions.isPinned(
                session("a", profile: "default", at: 10), scopePinned: scopePinned, scopeProfileID: "default"))
        XCTAssertFalse(
            AllProfilesSessions.isPinned(
                session("a", profile: "coder", at: 10), scopePinned: scopePinned, scopeProfileID: "default"))
        XCTAssertTrue(
            AllProfilesSessions.isPinned(
                session("b", profile: "coder", at: 10, pinned: true), scopePinned: scopePinned,
                scopeProfileID: "default"))
        // A stale scan flag cannot override the selected profile's own list.
        XCTAssertFalse(
            AllProfilesSessions.isPinned(
                session("c", profile: "default", at: 10, pinned: true), scopePinned: scopePinned,
                scopeProfileID: "default"))
    }

    func testOwnerBotFallsBackToSelectedProfileForUnscopedRows() {
        let bots = [bot("default"), bot("coder")]

        XCTAssertEqual(
            AllProfilesSessions.ownerBot(session("a", profile: "coder", at: 1), bots: bots, scopeProfileID: "default")?
                .id, "coder")
        XCTAssertEqual(
            AllProfilesSessions.ownerBot(session("a", profile: nil, at: 1), bots: bots, scopeProfileID: "default")?.id,
            "default")
        XCTAssertNil(
            AllProfilesSessions.ownerBot(session("a", profile: "gone", at: 1), bots: bots, scopeProfileID: "default"))
    }

    @MainActor
    func testSnapshotRefreshesMergedPinsWhenOnlyPinsChange() {
        let scan = [session("b", profile: "coder", at: 30, pinned: true)]
        var inputs = SessionNavSidebarSnapshot.Inputs(
            activeSessionID: nil, activeStatus: .idle, profileScopeID: "default", agentDisplayName: "Herm",
            isLoadingSessions: false, isCreatingSession: false, deletingSessionID: nil, renamingSessionID: nil,
            updatingSessionVisibilityID: nil, sessions: [], sessionProjectionState: .ready([]),
            activeSessions: [], projects: [], projectIDBySessionID: [:], projectSessionsByProjectID: [:],
            projectProfileID: nil, isLoadingProjects: false, isRefreshingProjectNavigation: false,
            attention: [], latestActivities: [], allBotSessionsState: .ready(scan))
        let first = SessionNavSidebarSnapshot(inputs: inputs)
        XCTAssertEqual(first.allProfilePinned.map(\.id), ["b"])

        // Conversations are unchanged, so groups are reused; the pins must not be.
        inputs.pinnedSessions = [session("a", profile: nil, at: 40)]
        let next = SessionNavSidebarSnapshot(inputs: inputs, reusing: first)
        XCTAssertEqual(next.allProfilePinned.map(\.id), ["a", "b"])
    }

    @MainActor
    func testAllProfileScanKeepsHermesPinnedFlag() throws {
        let body: [String: Any] = [
            "recents": [
                "sessions": [
                    ["id": "a", "profile": "coder", "pinned": true, "message_count": 2, "title": "One"],
                    ["id": "b", "profile": "writer", "pinned": false, "message_count": 2, "title": "Two"],
                ]
            ]
        ]
        let sessions = try DockModel.parseAllBotSessions(body)

        XCTAssertEqual(sessions.map(\.isPinned), [true, false])
        XCTAssertEqual(sessions.map(\.profileID), ["coder", "writer"])
    }
}
