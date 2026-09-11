import Foundation
import Testing
@testable import HermesAgentDock

struct AppearanceServiceTests {
    @Test func parsesHermesSkinAndInstalledPetTables() {
        let inventory = AppearanceCLIProjection.inventory(
            skinsOutput: "* default          builtin  Classic Hermes - gold\n  slate            builtin  Cool blue",
            petsOutput: "Installed pets (1):\n  nukey                    Nukey"
        )
        #expect(inventory.skins.map(\.id) == ["default", "slate"])
        #expect(inventory.skins.first?.isActive == true)
        #expect(inventory.skins.last?.name == "Cool blue")
        #expect(inventory.installedPets.map(\.id) == ["nukey"])
    }

    @Test func boundsHumanAppearanceTables() {
        let skins = (0..<70).map { "  skin\($0)  builtin  Skin \($0)" }.joined(separator: "\n")
        let pets = (0..<20).map { "  pet\($0)  Pet \($0)" }.joined(separator: "\n")
        let inventory = AppearanceCLIProjection.inventory(skinsOutput: skins, petsOutput: pets)
        #expect(inventory.skins.count == AppearanceCLIProjection.maxSkins)
        #expect(inventory.installedPets.count == AppearanceCLIProjection.maxPets)
    }

    @Test func ignoresMalformedAppearanceRows() {
        let inventory = AppearanceCLIProjection.inventory(
            skinsOutput: "not a skin row\n  valid  builtin  Usable",
            petsOutput: "Installed pets (1):\nmalformed row with too many columns\n  valid-pet  Pet"
        )
        #expect(inventory.skins.map(\.id) == ["valid"])
        #expect(inventory.installedPets.map(\.id) == ["valid-pet"])
    }

    @Test func parsesStrictReadOnlyAppearanceInventory() throws {
        let service = AppearanceService()
        let inventory = try service.parseFixture(#"{"schema":"hermes.appearance.inventory.fixture.v1","state":"ready","activeSkinID":"solarized","skins":[{"id":"solarized","name":"Solarized","active":true},{"id":"plain","name":"Plain","active":false}],"pets":[{"id":"cat","name":"Cat","active":true}],"desktopPlugins":[{"id":"clock","name":"Clock","mode":"standalone","status":"enabled"}]}"#)
        #expect(inventory.state == .ready)
        #expect(inventory.activeSkinID == "solarized")
        #expect(inventory.skins.count == 2)
        #expect(inventory.pets.first?.isActive == true)
        #expect(inventory.desktopPlugins.first?.mode == .standalone)
    }

    @Test func rejectsHumanOutputSecretsAndUnknownFields() {
        let service = AppearanceService()
        #expect(throws: AppearanceParseError.unsupportedInput) {
            try service.parseFixture("Skin: Solarized\nPet: Cat")
        }
        #expect(throws: AppearanceParseError.unsupportedInput) {
            try service.parseFixture(#"{"schema":"hermes.appearance.inventory.fixture.v1","state":"ready","activeSkinID":"x","skins":[],"pets":[],"desktopPlugins":[],"token":"secret"}"#)
        }
        #expect(throws: AppearanceParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.appearance.inventory.fixture.v1","state":"ready","activeSkinID":"x","skins":[{"id":"x","name":"X","active":true,"unexpected":1}],"pets":[],"desktopPlugins":[]}"#)
        }
        #expect(throws: AppearanceParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.appearance.inventory.fixture.v1","state":"ready","activeSkinID":"x","skins":[],"pets":[{"id":"cat","name":"Cat","unexpected":true}],"desktopPlugins":[]}"#)
        }
        #expect(throws: AppearanceParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.appearance.inventory.fixture.v1","state":"ready","activeSkinID":"x","skins":[],"pets":[],"desktopPlugins":[{"id":"clock","name":"Clock","mode":"standalone","unexpected":"enabled"}]}"#)
        }
    }

    @Test func supportsEveryBoundedInventoryState() throws {
        let service = AppearanceService()
        for state in AppearanceInventoryState.allCases {
            let input = "{\"schema\":\"hermes.appearance.inventory.fixture.v1\",\"state\":\"\(state.rawValue)\",\"activeSkinID\":null,\"skins\":[],\"pets\":[],\"desktopPlugins\":[]}"
            #expect(try service.parseFixture(input).state == state)
        }
    }

    @Test func appearanceMutationsFailClosedWithoutVerifiedHermesCommandContract() {
        let service = AppearanceService()
        #expect(service.operation(.selectSkin, identifier: "solarized", confirmed: true) == .unavailable(.unverifiedContract))
        #expect(service.operation(.selectPet, identifier: "cat", confirmed: true) == .unavailable(.unverifiedContract))
        #expect(service.operation(.selectSkin, identifier: "solarized", confirmed: false) == .unavailable(.confirmationRequired))
        #expect(service.operation(.enableDesktopPlugin, identifier: "clock", confirmed: true) == .unavailable(.unverifiedContract))
        #expect(service.operation(.reloadDesktopPlugin, identifier: "clock", confirmed: true) == .unavailable(.unsupportedCommand))
    }

    @Test func rejectsUnsafeLabelsAndPluginModes() {
        let service = AppearanceService()
        #expect(throws: AppearanceParseError.unsupportedInput) {
            try service.parseFixture(#"{"schema":"hermes.appearance.inventory.fixture.v1","state":"ready","activeSkinID":"x","skins":[{"id":"x","name":"password=hunter2","active":true}],"pets":[],"desktopPlugins":[]}"#)
        }
        #expect(throws: AppearanceParseError.malformedFixture) {
            try service.parseFixture(#"{"schema":"hermes.appearance.inventory.fixture.v1","state":"ready","activeSkinID":null,"skins":[],"pets":[],"desktopPlugins":[{"id":"x","name":"X","mode":"unknown","status":"enabled"}]}"#)
        }
    }
}
