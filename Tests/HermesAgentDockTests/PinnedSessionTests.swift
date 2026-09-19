import XCTest
@testable import HermesAgentDock

final class PinnedSessionTests: XCTestCase {
    func testStateDeduplicatesReferencesAndPreservesPinOrder() {
        let state = PinnedSessionState(references: [
            PinnedSessionReference(profileID: "default", sessionID: "session-b"),
            PinnedSessionReference(profileID: "default", sessionID: "session-a"),
            PinnedSessionReference(profileID: "default", sessionID: "session-b")
        ])

        XCTAssertEqual(state.references.map(\.sessionID), ["session-b", "session-a"])
        XCTAssertEqual(state.count, 2)
        XCTAssertTrue(state.contains(profileID: "default", sessionID: "session-a"))
    }

    func testProfileScopeDoesNotLeakPinsBetweenSessions() {
        var state = PinnedSessionState()
        state.toggle(profileID: "bot-a", sessionID: "same-id")

        XCTAssertTrue(state.contains(profileID: "bot-a", sessionID: "same-id"))
        XCTAssertFalse(state.contains(profileID: "bot-b", sessionID: "same-id"))
        XCTAssertEqual(state.references(for: "bot-b"), [])
    }

    func testUnpinRemovesOnlyTheCanonicalReference() {
        var state = PinnedSessionState(references: [
            PinnedSessionReference(profileID: "default", sessionID: "session-a"),
            PinnedSessionReference(profileID: "bot", sessionID: "session-a")
        ])

        state.toggle(profileID: "default", sessionID: "session-a")

        XCTAssertFalse(state.contains(profileID: "default", sessionID: "session-a"))
        XCTAssertTrue(state.contains(profileID: "bot", sessionID: "session-a"))
    }

    func testReconcileRemovesUnavailableSessionsAndReturnsChangedState() {
        var state = PinnedSessionState(references: [
            PinnedSessionReference(profileID: "default", sessionID: "available"),
            PinnedSessionReference(profileID: "default", sessionID: "gone")
        ])

        let changed = state.reconcile(available: [
            PinnedSessionReference(profileID: "default", sessionID: "available")
        ])

        XCTAssertTrue(changed)
        XCTAssertEqual(state.references.map(\.sessionID), ["available"])
    }

    func testReconcileOnlyCleansTheAuthoritativeProfileScope() {
        var state = PinnedSessionState(references: [
            PinnedSessionReference(profileID: "bot-a", sessionID: "kept-a"),
            PinnedSessionReference(profileID: "bot-a", sessionID: "gone-a"),
            PinnedSessionReference(profileID: "bot-b", sessionID: "kept-b")
        ])

        let changed = state.reconcile(
            available: [PinnedSessionReference(profileID: "bot-a", sessionID: "kept-a")],
            profileID: "bot-a"
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(state.references, [
            PinnedSessionReference(profileID: "bot-a", sessionID: "kept-a"),
            PinnedSessionReference(profileID: "bot-b", sessionID: "kept-b")
        ])
    }

    func testPresentationKeepsPinnedOrderAndAccurateCount() {
        let sessions = [
            HermesSession(id: "session-a", profileID: "default", title: "A", preview: "", startedAt: nil, messageCount: 1, source: ""),
            HermesSession(id: "session-b", profileID: "default", title: "B", preview: "", startedAt: nil, messageCount: 1, source: ""),
            HermesSession(id: "other", profileID: "bot", title: "Other", preview: "", startedAt: nil, messageCount: 1, source: "")
        ]
        let state = PinnedSessionState(references: [
            PinnedSessionReference(profileID: "default", sessionID: "session-b"),
            PinnedSessionReference(profileID: "default", sessionID: "session-a"),
            PinnedSessionReference(profileID: "default", sessionID: "missing")
        ])

        let presentation = PinnedSessionPresentation(sessions: sessions, state: state, profileID: "default")

        XCTAssertEqual(presentation.count, 2)
        XCTAssertEqual(presentation.sessions.map(\.id), ["session-b", "session-a"])
    }

    func testStorePersistsPinsAcrossInstancesAndReconcilesUnavailableReferences() {
        let defaults = UserDefaults(suiteName: "PinnedSessionTests.persistence")!
        defaults.removePersistentDomain(forName: "PinnedSessionTests.persistence")

        let first = PinnedSessionStore(defaults: defaults)
        first.toggle(profileID: "default", sessionID: "kept")
        first.toggle(profileID: "default", sessionID: "gone")
        first.toggle(profileID: "bot", sessionID: "other-profile")

        let second = PinnedSessionStore(defaults: defaults)
        XCTAssertEqual(second.state.references.map(\.sessionID), ["kept", "gone", "other-profile"])

        XCTAssertTrue(second.reconcile(
            available: [PinnedSessionReference(profileID: "default", sessionID: "kept")],
            profileID: "default"
        ))
        XCTAssertEqual(
            PinnedSessionStore(defaults: defaults).state.references.map(\.sessionID),
            ["kept", "other-profile"]
        )

        defaults.removePersistentDomain(forName: "PinnedSessionTests.persistence")
    }
}
