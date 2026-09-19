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

    func testPresentationKeepsStoredCountWhenSessionProjectionIsUnavailable() {
        let state = PinnedSessionState(references: [
            PinnedSessionReference(profileID: "default", sessionID: "still-loading")
        ])

        let loading = PinnedSessionPresentation(
            sessions: [],
            state: state,
            profileID: "default",
            projection: .loading
        )
        XCTAssertEqual(loading.status, .loading)
        XCTAssertEqual(loading.count, 1)
        XCTAssertTrue(loading.sessions.isEmpty)

        let unavailable = PinnedSessionPresentation(
            sessions: [],
            state: state,
            profileID: "default",
            projection: .unavailable(safeMessage: "Session data is unavailable.")
        )
        XCTAssertEqual(unavailable.status, .unavailable("Session data is unavailable."))
        XCTAssertEqual(unavailable.count, 1)

        let failed = PinnedSessionPresentation(
            sessions: [],
            state: state,
            profileID: "default",
            projection: .failed(safeMessage: "Session data failed.")
        )
        XCTAssertEqual(failed.status, .failed("Session data failed."))
        XCTAssertEqual(failed.count, 1)

        let staleSession = HermesSession(
            id: "still-loading",
            profileID: "default",
            title: "Previous session",
            preview: "",
            startedAt: nil,
            messageCount: 1,
            source: ""
        )
        let stale = PinnedSessionPresentation(
            sessions: [],
            state: state,
            profileID: "default",
            projection: .stale([staleSession], safeMessage: "Showing the last session index.")
        )
        XCTAssertEqual(stale.status, .stale("Showing the last session index."))
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale.sessions.map(\.id), ["still-loading"])

        let empty = PinnedSessionPresentation(
            sessions: [],
            state: state,
            profileID: "default",
            projection: .empty
        )
        XCTAssertEqual(empty.status, .empty)
        XCTAssertEqual(empty.count, 0)
    }

    func testPresentationTreatsUnrequestedEmptyProjectionAsLoading() {
        let state = PinnedSessionState(references: [
            PinnedSessionReference(profileID: "default", sessionID: "persisted")
        ])

        let initial = PinnedSessionPresentation(
            sessions: [],
            state: state,
            profileID: "default",
            projection: .empty,
            hasRequestedSessionIndex: false
        )

        XCTAssertEqual(initial.status, .loading)
        XCTAssertEqual(initial.count, 1)
        XCTAssertTrue(initial.sessions.isEmpty)
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

    func testReconciliationPreservesPinsWhileIndexIsLoadingAndCleansAfterAuthoritativeLoad() {
        let defaults = UserDefaults(suiteName: "PinnedSessionTests.loading")!
        defaults.removePersistentDomain(forName: "PinnedSessionTests.loading")
        let store = PinnedSessionStore(defaults: defaults)
        store.toggle(profileID: "bot-b", sessionID: "still-loading")

        let loading = PinnedSessionReconciliation.authoritativeReferences(
            sessions: [],
            projection: .loading,
            profileID: "bot-b"
        )
        XCTAssertNil(loading)
        XCTAssertTrue(store.state.contains(profileID: "bot-b", sessionID: "still-loading"))

        let loaded = PinnedSessionReconciliation.authoritativeReferences(
            sessions: [],
            projection: .empty,
            profileID: "bot-b"
        )
        guard let loaded else {
            return XCTFail("an empty projection is authoritative")
        }
        XCTAssertEqual(loaded, [])
        XCTAssertTrue(store.reconcile(available: loaded, profileID: "bot-b"))
        XCTAssertFalse(store.state.contains(profileID: "bot-b", sessionID: "still-loading"))
        defaults.removePersistentDomain(forName: "PinnedSessionTests.loading")
    }

    func testPinnedRowActionPersistsWithoutChangingCanonicalSelection() {
        let defaults = UserDefaults(suiteName: "PinnedSessionTests.row-action")!
        defaults.removePersistentDomain(forName: "PinnedSessionTests.row-action")
        let store = PinnedSessionStore(defaults: defaults)
        var selectedSessionID: String? = "already-selected"

        PinnedSessionRowInteraction.select("pinned-session", selectedSessionID: &selectedSessionID)
        PinnedSessionRowInteraction.togglePin(
            store: store,
            profileID: "default",
            sessionID: "pinned-session"
        )

        XCTAssertEqual(selectedSessionID, "pinned-session")
        XCTAssertTrue(PinnedSessionStore(defaults: defaults).state.contains(
            profileID: "default",
            sessionID: "pinned-session"
        ))
        defaults.removePersistentDomain(forName: "PinnedSessionTests.row-action")
    }
}
