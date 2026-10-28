import Testing

@testable import Herm

struct DockRailDestinationTests {
    @Test func defaultPinsKeepTheRailCompact() {
        #expect(DockRailDestination.pins(DockRailDestination.defaultPins) == [.automations, .calendar, .bots])
    }

    @Test func pinningAndUnpinningRoundTripsWithoutLosingOtherChoices() {
        let original = DockRailDestination.defaultPins
        let pinned = DockRailDestination.toggling(.github, in: original)
        #expect(DockRailDestination.pins(pinned) == [.github, .automations, .calendar, .bots])
        #expect(DockRailDestination.toggling(.github, in: pinned) == original)
        #expect(DockRailDestination.toggling(.bots, in: "") == "bots")
        #expect(DockRailDestination.toggling(.bots, in: "bots") == "")
    }

    @Test func stalePreferencesAreIgnoredAndDuplicatesNormalized() {
        #expect(DockRailDestination.pins("unknown,bots,bots") == [.bots])
        #expect(DockRailDestination.toggling(.usage, in: "unknown,bots,bots") == "bots,usage")
    }
}
