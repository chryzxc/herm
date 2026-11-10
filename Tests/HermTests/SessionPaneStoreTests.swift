import Foundation
import Testing

@testable import Herm

struct SessionPaneStoreTests {
    @Test func dropTargetInsertsAtTheNearestColumnBoundary() {
        // One primary column, 900pt wide: dropping anywhere opens the first side slot.
        #expect(SessionPaneStore.dropTarget(x: 100, width: 900, sidePaneCount: 0) == .insert(0))
        #expect(SessionPaneStore.dropTarget(x: 880, width: 900, sidePaneCount: 0) == .insert(0))
        // Primary + one pane (450pt columns): the boundary nearest the cursor wins.
        #expect(SessionPaneStore.dropTarget(x: 400, width: 900, sidePaneCount: 1) == .insert(0))
        #expect(SessionPaneStore.dropTarget(x: 800, width: 900, sidePaneCount: 1) == .insert(1))
    }

    @Test func dropTargetReplacesTheHoveredPaneWhenFull() {
        // 300pt columns: primary, pane 0, pane 1. Hovering the primary replaces the nearest pane.
        #expect(SessionPaneStore.dropTarget(x: 100, width: 900, sidePaneCount: 2) == .replace(0))
        #expect(SessionPaneStore.dropTarget(x: 450, width: 900, sidePaneCount: 2) == .replace(0))
        #expect(SessionPaneStore.dropTarget(x: 850, width: 900, sidePaneCount: 2) == .replace(1))
    }

    @Test func placementRejectsSessionsAlreadyOnScreen() {
        #expect(SessionPaneStore.placement(sessionID: "a", primaryID: "a", openIDs: [], target: .insert(0)) == nil)
        #expect(SessionPaneStore.placement(sessionID: "b", primaryID: "a", openIDs: ["b"], target: .insert(1)) == nil)
    }

    @Test func placementClampsAndSwitchesToReplaceWhenFull() {
        #expect(
            SessionPaneStore.placement(sessionID: "c", primaryID: "a", openIDs: ["b"], target: .insert(9)) == .insert(1)
        )
        #expect(
            SessionPaneStore.placement(sessionID: "d", primaryID: "a", openIDs: ["b", "c"], target: .insert(2))
                == .replace(1))
        #expect(
            SessionPaneStore.placement(sessionID: "d", primaryID: "a", openIDs: ["b", "c"], target: .replace(0))
                == .replace(0))
        #expect(
            SessionPaneStore.placement(sessionID: "b", primaryID: "a", openIDs: [], target: .replace(3)) == .insert(0))
    }

    @Test func dragPayloadRoundTripsToADestination() throws {
        let session = HermesSession(
            id: "s1", profileID: "work", title: "Fix CI", preview: "", startedAt: nil, messageCount: 0,
            source: HermesFeatureIDs.sessionSource)
        let drag = try JSONDecoder().decode(
            SessionPaneDrag.self, from: JSONEncoder().encode(SessionPaneDrag(session: session)))
        #expect(drag.destination.sessionID == "s1")
        #expect(drag.destination.profileID == "work")
        #expect(drag.destination.session?.id == "s1")
    }
}
