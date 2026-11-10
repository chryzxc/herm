import Foundation
import Testing

@testable import Herm

struct SessionPaneStoreTests {
    @Test func dropTargetOpensANewPanelWhileThereIsRoom() {
        // Primary only: anywhere opens the first panel.
        #expect(SessionPaneStore.dropTarget(x: 100, width: 900, panelCount: 0) == .newPanel(0))
        #expect(SessionPaneStore.dropTarget(x: 880, width: 900, panelCount: 0) == .newPanel(0))
        // Primary + one panel (450pt columns): the panel body adds a tab, its trailing edge opens a panel.
        #expect(SessionPaneStore.dropTarget(x: 200, width: 900, panelCount: 1) == .newPanel(0))
        #expect(SessionPaneStore.dropTarget(x: 600, width: 900, panelCount: 1) == .tab(0))
        #expect(SessionPaneStore.dropTarget(x: 860, width: 900, panelCount: 1) == .newPanel(1))
    }

    @Test func dropTargetAddsTabsWhenFull() {
        // 300pt columns: primary, panel 0, panel 1.
        #expect(SessionPaneStore.dropTarget(x: 100, width: 900, panelCount: 2) == .tab(0))
        #expect(SessionPaneStore.dropTarget(x: 450, width: 900, panelCount: 2) == .tab(0))
        #expect(SessionPaneStore.dropTarget(x: 880, width: 900, panelCount: 2) == .tab(1))
    }

    @Test func resolveRejectsThePrimaryAndSelectsAnOpenTab() {
        #expect(SessionPaneStore.resolve(sessionID: "a", primaryID: "a", panelTabs: [], target: .newPanel(0)) == nil)
        #expect(
            SessionPaneStore.resolve(sessionID: "c", primaryID: "a", panelTabs: [["b"], ["d", "c"]], target: .tab(0))
                == .select(panel: 1, tab: 1))
    }

    @Test func resolveClampsAndFallsBackToATabWhenFull() {
        #expect(
            SessionPaneStore.resolve(sessionID: "c", primaryID: "a", panelTabs: [["b"]], target: .newPanel(9))
                == .newPanel(1))
        #expect(
            SessionPaneStore.resolve(sessionID: "d", primaryID: "a", panelTabs: [["b"], ["c"]], target: .newPanel(2))
                == .addTab(1))
        #expect(
            SessionPaneStore.resolve(sessionID: "d", primaryID: "a", panelTabs: [["b"]], target: .tab(4)) == .addTab(0))
        #expect(
            SessionPaneStore.resolve(sessionID: "b", primaryID: "a", panelTabs: [], target: .tab(3)) == .newPanel(0))
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
