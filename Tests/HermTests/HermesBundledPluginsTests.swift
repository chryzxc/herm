import Foundation
import Testing

@testable import Herm

@MainActor
struct HermesBundledPluginsTests {
    @Test func installsMissingOrDifferentVersionsOnly() {
        #expect(HermesBundledPlugins.needsInstall(bundled: "1.2.0", installed: nil))
        #expect(HermesBundledPlugins.needsInstall(bundled: "1.2.0", installed: "1.1.0"))
        #expect(!HermesBundledPlugins.needsInstall(bundled: "1.2.0", installed: "1.2.0"))
        #expect(!HermesBundledPlugins.needsInstall(bundled: "", installed: nil))
    }

    @Test func everyBundledPluginShipsAVersionedManifest() throws {
        let folder = try #require(Bundle.module.url(forResource: "HermesPlugins", withExtension: nil))
        for name in HermesBundledPlugins.names {
            let manifest = try String(
                contentsOf: folder.appendingPathComponent("\(name)/plugin.yaml"), encoding: .utf8)
            #expect(manifest.contains("name: \(name)\n"))
            #expect(!HermesBundledPlugins.manifestVersion(manifest).isEmpty)
        }
        #expect(HermesBundledPlugins.manifestVersion("name: x\nversion: 1.2.0\n") == "1.2.0")
    }
}
