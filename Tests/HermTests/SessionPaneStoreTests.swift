import Foundation
import Testing

@testable import Herm

struct SessionPaneStoreTests {
    @Test func dropTargetSplitsASingleColumnBetweenTabAndNewColumn() {
        // One column: the leading half adds a tab, the trailing half opens a second column.
        #expect(SessionPaneStore.dropTarget(x: 100, width: 900, columnCount: 0) == .tab(0))
        #expect(SessionPaneStore.dropTarget(x: 440, width: 900, columnCount: 1) == .tab(0))
        #expect(SessionPaneStore.dropTarget(x: 460, width: 900, columnCount: 1) == .newPanel(1))
        #expect(SessionPaneStore.newColumnZone(columnCount: 3) == 0)
    }

    @Test func dropTargetAddsTabsOrOpensAColumnAtTheTrailingEdge() {
        // Two 450pt columns: the body of either column adds a tab, the last quarter opens a column.
        #expect(SessionPaneStore.dropTarget(x: 200, width: 900, columnCount: 2) == .tab(0))
        #expect(SessionPaneStore.dropTarget(x: 600, width: 900, columnCount: 2) == .tab(1))
        #expect(SessionPaneStore.dropTarget(x: 860, width: 900, columnCount: 2) == .newPanel(2))
        // Three columns is full: every drop adds a tab.
        #expect(SessionPaneStore.dropTarget(x: 880, width: 900, columnCount: 3) == .tab(2))
    }

    @Test func resizingTradesWidthBetweenNeighborsAboveTheMinimum() {
        let even: [CGFloat] = [0.5, 0.5]
        let close = { (lhs: [CGFloat], rhs: [CGFloat]) in zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.0001 } }
        #expect(close(SessionPaneStore.resized(even, divider: 0, delta: 0.1, minFraction: 0.2), [0.6, 0.4]))
        #expect(close(SessionPaneStore.resized(even, divider: 0, delta: 0.9, minFraction: 0.2), [0.8, 0.2]))
        #expect(SessionPaneStore.resized(even, divider: 1, delta: 0.1, minFraction: 0.2) == even)
        // A stale share list falls back to equal columns.
        #expect(SessionPaneStore.fractions([0.7, 0.3], count: 3).count == 3)
    }

    @Test func dropTargetFollowsResizedColumns() {
        // 900pt split 0.75 / 0.25: x = 600 is still the first column; the last quarter of
        // the 225pt second column opens a new one.
        let shares: [CGFloat] = [0.75, 0.25]
        #expect(SessionPaneStore.dropTarget(x: 600, width: 900, columnCount: 2, fractions: shares) == .tab(0))
        #expect(SessionPaneStore.dropTarget(x: 700, width: 900, columnCount: 2, fractions: shares) == .tab(1))
        #expect(SessionPaneStore.dropTarget(x: 890, width: 900, columnCount: 2, fractions: shares) == .newPanel(2))
    }

    @Test func resolveRejectsTheUnsplitPrimaryAndSelectsAnOpenTab() {
        #expect(SessionPaneStore.resolve(sessionID: "a", primaryID: "a", panelTabs: [], target: .newPanel(1)) == nil)
        #expect(
            SessionPaneStore.resolve(sessionID: "a", primaryID: "a", panelTabs: [["b"], ["a"]], target: .tab(0))
                == .select(panel: 1, tab: 0))
    }

    @Test func resolveClampsAndFallsBackToATabWhenFull() {
        #expect(
            SessionPaneStore.resolve(sessionID: "c", primaryID: "a", panelTabs: [], target: .newPanel(9))
                == .newPanel(1))
        #expect(
            SessionPaneStore.resolve(
                sessionID: "d", primaryID: "a", panelTabs: [["a"], ["b"], ["c"]], target: .newPanel(3))
                == .addTab(2))
        #expect(
            SessionPaneStore.resolve(sessionID: "d", primaryID: "a", panelTabs: [["a"], ["b"]], target: .tab(7))
                == .addTab(1))
    }

    @Test func newTabsOpenBesideTheSelectedTab() {
        let tabs = ["a", "b", "c"].map { QuickDestination(sessionID: $0) }
        #expect(SessionPaneStore.tabInsertionIndex(tabs: tabs, selectedID: "a") == 1)
        #expect(SessionPaneStore.tabInsertionIndex(tabs: tabs, selectedID: "c") == 3)
        #expect(SessionPaneStore.tabInsertionIndex(tabs: tabs, selectedID: nil) == 3)
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
