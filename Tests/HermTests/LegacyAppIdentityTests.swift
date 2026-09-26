import Foundation
import Testing
@testable import Herm

struct LegacyAppIdentityTests {
    @Test func copiesLegacyDefaultsAndMovesStateOnce() throws {
        let suffix = UUID().uuidString
        let legacyID = "herm.tests.legacy.\(suffix)", currentID = "herm.tests.current.\(suffix)"
        let defaults = UserDefaults.standard
        defer {
            defaults.removePersistentDomain(forName: legacyID)
            defaults.removePersistentDomain(forName: currentID)
        }
        defaults.setPersistentDomain(["theme": "dark"], forName: legacyID)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("herm-home-\(suffix)")
        defer { try? FileManager.default.removeItem(at: home) }
        let legacyKeys = home.appendingPathComponent(".config/hermes-agent-dock")
        try FileManager.default.createDirectory(at: legacyKeys, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacyKeys.appendingPathComponent("providers.json"))

        LegacyAppIdentity.migrate(defaults: defaults, currentBundleID: currentID, legacyBundleID: legacyID, home: home)

        #expect(defaults.persistentDomain(forName: currentID)?["theme"] as? String == "dark")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/herm/providers.json").path))

        // Existing Herm settings are never overwritten.
        defaults.setPersistentDomain(["theme": "light"], forName: currentID)
        LegacyAppIdentity.migrate(defaults: defaults, currentBundleID: currentID, legacyBundleID: legacyID, home: home)
        #expect(defaults.persistentDomain(forName: currentID)?["theme"] as? String == "light")
    }
}
