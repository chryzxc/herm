import Testing

@testable import Herm

struct DockRailDestinationTests {
    @Test func defaultPinsKeepTheRailCompact() {
        #expect(DockRailDestination.pins(DockRailDestination.defaultPins) == [.automations, .calendar])
    }

    @Test func pinningAndUnpinningRoundTripsWithoutLosingOtherChoices() {
        let original = DockRailDestination.defaultPins
        let pinned = DockRailDestination.toggling(.github, in: original)
        #expect(DockRailDestination.pins(pinned) == [.github, .automations, .calendar])
        #expect(DockRailDestination.toggling(.github, in: pinned) == original)
        #expect(DockRailDestination.toggling(.artifacts, in: "") == "artifacts")
        #expect(DockRailDestination.toggling(.artifacts, in: "artifacts") == "")
    }

    @Test func stalePreferencesAreIgnoredAndDuplicatesNormalized() {
        #expect(DockRailDestination.pins("unknown,artifacts,artifacts") == [.artifacts])
        #expect(DockRailDestination.toggling(.usage, in: "unknown,artifacts,artifacts") == "artifacts,usage")
    }

    @Test func botsPinsPreservePreferencesAndOrder() {
        let bots = DockRailDestination(rawValue: "bots")
        #expect(bots != nil)
        #expect(DockRailDestination.ordered("unknown,bots,github,bots").map(\.rawValue) == ["bots", "github"])
        #expect(!DockRailDestination.pins(DockRailDestination.defaultPins).contains { $0.rawValue == "bots" })
        if let bots {
            let pinned = DockRailDestination.toggling(bots, in: DockRailDestination.defaultPins)
            #expect(pinned == "automations,calendar,bots")
            let reordered = DockRailDestination.moving(bots, to: 0, in: DockRailDestination.ordered(pinned))
            #expect(DockRailDestination.raw(reordered) == "bots,automations,calendar")
            #expect(DockRailDestination.toggling(bots, in: pinned) == DockRailDestination.defaultPins)
            #expect(bots.tab?.rawValue == "Bots")
        }
    }

    @Test func userOrderIsPreservedAndMovesClamp() {
        let items = DockRailDestination.ordered("artifacts,github,automations")
        #expect(items == [.artifacts, .github, .automations])
        #expect(DockRailDestination.moving(.artifacts, to: 2, in: items) == [.github, .automations, .artifacts])
        #expect(DockRailDestination.moving(.artifacts, to: 9, in: items) == [.github, .automations, .artifacts])
        #expect(DockRailDestination.toggling(.usage, in: "artifacts,github") == "artifacts,github,usage")
    }
}
