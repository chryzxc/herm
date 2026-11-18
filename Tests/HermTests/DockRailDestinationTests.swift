import Testing

@testable import Herm

struct DockRailDestinationTests {
    private typealias Item = DockRailItem

    @Test func defaultPinsKeepTheRailCompact() {
        #expect(Item.pins(DockRailDestination.defaultPins) == [.builtIn(.automations), .builtIn(.calendar)])
    }

    @Test func pinningAndUnpinningRoundTripsWithoutLosingOtherChoices() {
        let original = DockRailDestination.defaultPins
        let pinned = Item.toggling(.builtIn(.github), in: original)
        #expect(Item.pins(pinned) == [.builtIn(.github), .builtIn(.automations), .builtIn(.calendar)])
        #expect(Item.toggling(.builtIn(.github), in: pinned) == original)
        #expect(Item.toggling(.builtIn(.artifacts), in: "") == "artifacts")
        #expect(Item.toggling(.builtIn(.artifacts), in: "artifacts") == "")
    }

    @Test func stalePreferencesAreIgnoredAndDuplicatesNormalized() {
        #expect(Item.pins("unknown,artifacts,artifacts,plugin:") == [.builtIn(.artifacts)])
        #expect(Item.toggling(.builtIn(.usage), in: "unknown,artifacts,artifacts") == "artifacts,usage")
    }

    @Test func botsPinsPreservePreferencesAndOrder() {
        let bots = Item.builtIn(.bots)
        #expect(Item(rawValue: "bots") == bots)
        #expect(Item.ordered("unknown,bots,github,bots") == [bots, .builtIn(.github)])
        #expect(!Item.pins(DockRailDestination.defaultPins).contains(bots))
        let pinned = Item.toggling(bots, in: DockRailDestination.defaultPins)
        #expect(pinned == "automations,calendar,bots")
        #expect(Item.raw(Item.moving(bots, to: 0, in: Item.ordered(pinned))) == "bots,automations,calendar")
        #expect(Item.toggling(bots, in: pinned) == DockRailDestination.defaultPins)
        #expect(DockRailDestination.bots.tab?.rawValue == "Bots")
    }

    @Test func userOrderIsPreservedAndMovesClamp() {
        let items = Item.ordered("artifacts,github,automations")
        #expect(items == [.builtIn(.artifacts), .builtIn(.github), .builtIn(.automations)])
        #expect(
            Item.moving(.builtIn(.artifacts), to: 2, in: items)
                == [.builtIn(.github), .builtIn(.automations), .builtIn(.artifacts)])
        #expect(
            Item.moving(.builtIn(.artifacts), to: 9, in: items)
                == [.builtIn(.github), .builtIn(.automations), .builtIn(.artifacts)])
        #expect(Item.toggling(.builtIn(.usage), in: "artifacts,github") == "artifacts,github,usage")
    }

    @Test func pluginPinsRoundTripBesideBuiltIns() {
        let raw = Item.toggling(.plugin("whiteboard"), in: "calendar")
        #expect(raw == "calendar,plugin:whiteboard")
        #expect(Item.ordered(raw) == [.builtIn(.calendar), .plugin("whiteboard")])
        #expect(Item.toggling(.plugin("whiteboard"), in: raw) == "calendar")
    }

    @Test func reorderingTheVisibleRailKeepsHiddenPluginPins() {
        let raw = "calendar,plugin:gone,github"
        let saved = Item.raw(visible: [.builtIn(.github), .builtIn(.calendar)], keepingHiddenFrom: raw)
        #expect(saved == "github,calendar,plugin:gone")
    }
}
