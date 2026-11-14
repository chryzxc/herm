import Foundation
import Testing
@testable import Herm

struct SecurityHardeningTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func freshBrowserUsesDynamicLoopbackPort() throws {
        let args = AgentBrowserLaunch.arguments(profile: URL(fileURLWithPath: "/profile"), userAgent: "test-agent")
        #expect(args.filter { $0.hasPrefix("--remote-debugging-port=") } == ["--remote-debugging-port=0"])
        #expect(args.contains("--remote-debugging-address=127.0.0.1"))
        #expect(args.contains("--user-data-dir=/profile"))
        #expect(args.contains("--user-agent=test-agent"))
        #expect(args.contains("--force-device-scale-factor=2"))
        #expect(args.last == "about:blank")
    }

    @Test func bundledPluginsDefaultToDisabled() throws {
        let plugins = try source("Sources/Herm/HermesRuntime/HermesBundledPlugins.swift")
        #expect(plugins.contains("row?.enabled ?? false"))
    }

    @Test func bothSimulatorInstallersRequireHashes() throws {
        for path in ["Sources/Herm/HermesRuntime/HermesSimulatorSetup.swift", "Scripts/setup-simulator-bridge.sh"] {
            let installer = try source(path)
            #expect(installer.contains("--require-hashes"))
            #expect(installer.contains("--only-binary=:all:"))
        }
    }
}
