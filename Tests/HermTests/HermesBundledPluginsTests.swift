import Foundation
import Testing

@testable import Herm

@MainActor
private final class BundledPluginClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rows: [[String: Any]] = []
    var installs: [[String: Any]] = []
    var failList = false
    var failInstall = false

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if params["action"] as? String == "list" {
            if failList { throw CocoaError(.fileReadUnknown) }
            return ["plugins": rows]
        }
        installs.append(params)
        return ["ok": !failInstall]
    }
}

@MainActor
struct HermesBundledPluginsTests {
    private func stage(_ source: URL, _ name: String) async throws -> URL {
        URL(fileURLWithPath: "/fixture/\(name)")
    }

    @Test func installPreservesChoicesAndSkipsMatchingVersions() async throws {
        let client = BundledPluginClient()
        #expect(await HermesBundledPlugins.install(client: client, stageRepository: stage))
        #expect(client.installs.count == 2)
        #expect(client.installs.allSatisfy { $0["enable"] as? Bool == false })
        #expect(client.installs.allSatisfy { $0["force"] as? Bool == true })

        client.installs = []
        client.rows = [
            ["name": "herm", "key": "herm", "status": "enabled", "version": "old"],
            ["name": "herm-simulator", "key": "herm-simulator", "status": "disabled", "version": "old"],
        ]
        #expect(await HermesBundledPlugins.install(client: client, stageRepository: stage))
        #expect(client.installs.compactMap { $0["enable"] as? Bool } == [true, false])

        let folder = try #require(Bundle.module.url(forResource: "HermesPlugins", withExtension: nil))
        for index in client.rows.indices {
            let name = try #require(client.rows[index]["name"] as? String)
            let text = try String(contentsOf: folder.appendingPathComponent("\(name)/plugin.yaml"), encoding: .utf8)
            client.rows[index]["version"] = HermesBundledPlugins.manifestVersion(text)
        }
        client.installs = []
        #expect(await HermesBundledPlugins.install(client: client, stageRepository: stage))
        #expect(client.installs.isEmpty)
    }

    @Test func failuresReturnFalseAndRetriesNeverEnableMissingPlugins() async {
        let client = BundledPluginClient()
        client.failList = true
        #expect(!(await HermesBundledPlugins.install(client: client, stageRepository: stage)))
        #expect(client.installs.isEmpty)
        client.failList = false
        #expect(!(await HermesBundledPlugins.install(client: client) { _, _ in throw CocoaError(.fileWriteUnknown) }))
        #expect(client.installs.isEmpty)
        client.failInstall = true
        #expect(!(await HermesBundledPlugins.install(client: client, stageRepository: stage)))
        client.failInstall = false
        #expect(await HermesBundledPlugins.install(client: client, stageRepository: stage))
        #expect(client.installs.count == 3)
        #expect(client.installs.allSatisfy { $0["enable"] as? Bool == false })
    }

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
