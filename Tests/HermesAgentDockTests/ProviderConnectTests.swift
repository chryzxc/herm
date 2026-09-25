import Foundation
import Testing
@testable import HermesAgentDock

struct ProviderConnectTests {
    @Test func catalogListsEverySupportedProviderExactlyOnce() {
        let ids = QuotaProviderCatalog.all.map(\.id)
        #expect(ids == ["codex-hermes", "opencode", "glm", "claude", "antigravity"])
        #expect(Set(ids).count == ids.count)
        #expect(QuotaProviderCatalog.descriptor(for: "glm")?.displayName == "GLM Coding Plan")
        #expect(QuotaProviderCatalog.descriptor(for: "unknown") == nil)
    }

    @Test func apiKeyStorageKeysMatchQuotaServiceParsers() {
        #expect(QuotaProviderCatalog.glm.storageKey == "glm")
        #expect(QuotaProviderCatalog.opencode.storageKey == "opencode-go")
        #expect(QuotaProviderCatalog.codexHermes.storageKey == nil)
        #expect(QuotaProviderCatalog.claude.storageKey == nil)
        #expect(QuotaProviderCatalog.antigravity.storageKey == nil)
    }

    @Test func keyStoreRoundTripsAndRemovesKeys() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-key-store-\(UUID().uuidString)", isDirectory: true)
        let store = ProviderKeyStore(fileURL: directory.appendingPathComponent("providers.json"))

        #expect(store.savedKey("glm") == nil)
        #expect(!store.contains("glm"))

        store.save(" test-key-123 ", storageKey: "glm")
        #expect(store.savedKey("glm") == "test-key-123")
        #expect(store.contains("glm"))

        store.save("opencode-key", storageKey: "opencode-go")
        #expect(store.savedKey("opencode-go") == "opencode-key")
        #expect(store.savedKey("glm") == "test-key-123")

        store.save(nil, storageKey: "glm")
        #expect(store.savedKey("glm") == nil)
        #expect(store.savedKey("opencode-go") == "opencode-key")
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func keyStoreFileIsOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-key-store-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("providers.json")
        ProviderKeyStore(fileURL: fileURL).save("key", storageKey: "glm")

        let filePermissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(filePermissions == 0o600)
        #expect(directoryPermissions == 0o700)
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    @Test func resolvesExecutablesAcrossSearchDirectories() {
        let fileExists: (String) -> Bool = { ["/opt/homebrew/bin/codex", "/Users/x/.local/bin/claude"].contains($0) }
        #expect(ProviderLoginModel.executablePath(command: "codex login", searchDirectories: ["/opt/homebrew/bin", "/usr/local/bin"], fileExists: fileExists) == "/opt/homebrew/bin/codex")
        #expect(ProviderLoginModel.executablePath(command: "claude auth login", searchDirectories: ["/usr/bin", "/Users/x/.local/bin"], fileExists: fileExists) == "/Users/x/.local/bin/claude")
        #expect(ProviderLoginModel.executablePath(command: "missing login", searchDirectories: ["/usr/bin"], fileExists: fileExists) == nil)
        #expect(ProviderLoginModel.executablePath(command: "/usr/local/bin/custom --flag", searchDirectories: [], fileExists: fileExists) == nil)
        #expect(ProviderLoginModel.executablePath(command: "/opt/local/bin/custom", searchDirectories: [], fileExists: { $0 == "/opt/local/bin/custom" }) == "/opt/local/bin/custom")
    }

    @MainActor
    @Test func searchDirectoriesIncludeShellPathAndStandardLocations() {
        let directories = ProviderLoginModel.defaultSearchDirectories(
            environment: ["PATH": "/custom/bin"],
            homePath: "/Users/x",
            nodeVersionDirectoriesAt: nil
        )
        #expect(directories.first == "/custom/bin")
        for expected in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/Users/x/.local/bin", "/Users/x/.volta/bin"] {
            #expect(directories.contains(expected))
        }
    }

    @MainActor
    @Test func loginOutputIsBounded() {
        let many = (1...500).map { "line \($0)" }
        let capped = ProviderLoginModel.cappedLines([], newLines: many)
        #expect(capped.count == 400)
        #expect(capped.last == "line 500")

        let long = [String(repeating: "a", count: 9_000), String(repeating: "b", count: 9_000)]
        let characterCapped = ProviderLoginModel.cappedLines([], newLines: long)
        #expect(characterCapped.count == 1)
    }
}
