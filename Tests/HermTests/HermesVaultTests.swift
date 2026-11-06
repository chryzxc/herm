import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class VaultFixtureClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [(String, [String: Any])] = []
    var fail = false
    var malformed = false
    var acknowledge = true
    var rows: [[String: Any]] = []
    var sourceRows: [[String: Any]] = [
        [
            "name": "local", "display_name": "Hermes vault", "enabled": true, "installed": true,
            "unlocked": true, "needs_unlock": false,
        ],
        [
            "name": "bitwarden", "display_name": "Bitwarden", "enabled": true, "installed": true,
            "unlocked": false, "needs_unlock": true,
        ],
    ]

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if fail {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-fixture-input"])
        }
        if malformed { return [:] }
        switch method {
        case "vault.list": return ["items": rows]
        case "vault.sources": return ["sources": sourceRows]
        case "vault.add": return acknowledge ? ["id": "new-item"] : [:]
        case "vault.remove": return ["removed": acknowledge]
        case "vault.source.set": return ["name": params["name"] ?? "", "enabled": params["enabled"] ?? false]
        case "vault.unlock": return ["name": params["name"] ?? "", "unlocked": acknowledge]
        case "vault.lock": return ["locked": acknowledge]
        default: throw HermesVaultError.unavailable
        }
    }
}

@Suite("Hermes vault")
@MainActor
struct HermesVaultTests {
    @Test func renderSettingsFixtures() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HERM_VAULT_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let previous = DockThemeRuntime.current
        let appearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = previous
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = appearance
        }
        for theme: DockThemeID in [.clean, .island, .glass, .mono] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = NSAppearance(named: theme == .clean ? .aqua : .darkAqua)
            for width in [360.0, 700.0] {
                let client = VaultFixtureClient()
                client.rows = [
                    [
                        "id": "one", "kind": "login", "label": "Example", "identifier": "account",
                        "origin": "https://example.com",
                    ]
                ]
                let rpc = HermesControlRPC(client: client)
                let host = NSHostingView(
                    rootView:
                        HermesVaultSettings(rpc: rpc, profile: "research", bots: [])
                        .padding(20).frame(width: width, height: 800, alignment: .top)
                        .background(Color.dockOpaqueCanvas).dockThemedRoot())
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                #expect(client.calls.contains { $0.0 == "vault.list" })
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: root.appendingPathComponent("vault-\(theme.rawValue)-\(Int(width)).png"))
                window.contentView = nil
            }
        }
    }

    @Test func metadataAndProfileScope() async throws {
        let client = VaultFixtureClient()
        client.rows = [
            [
                "id": "one", "kind": "login", "label": "Example", "identifier": "account",
                "origin": "https://example.com", "password": "private-fixture-input",
            ]
        ]
        let snapshot = try await HermesVaultService(client: client, profile: "research").inventory()
        #expect(snapshot.items.first?.label == "Example")
        #expect(snapshot.items.first?.backend == "local")
        #expect(!String(describing: snapshot.items).contains("private-fixture-input"))
        #expect(client.calls.map(\.0) == ["vault.list", "vault.sources"])
        #expect(client.calls.allSatisfy { $0.1["profile"] as? String == "research" })
    }

    @Test func malformedInventoryFailsClosed() async {
        let client = VaultFixtureClient()
        let model = HermesVaultModel(service: HermesVaultService(client: client, profile: "first"))
        await model.load()
        #expect(model.available)
        client.malformed = true
        await model.load()
        #expect(!model.available)
        #expect(model.items.isEmpty && model.sources.isEmpty)
        var performed = false
        await model.perform { _ in performed = true }
        #expect(!performed)
    }

    @Test func originValidation() {
        #expect(HermesVaultService.validOrigin("https://example.com/login"))
        #expect(HermesVaultService.validOrigin("http://localhost:3000"))
        for invalid in ["", "example.com", "file:///tmp/login", "javascript:alert(1)", "https://name:pass@example.com"]
        {
            #expect(!HermesVaultService.validOrigin(invalid))
        }
    }

    @Test func typedMutationsUseTheSelectedProfile() async throws {
        let client = VaultFixtureClient()
        let service = HermesVaultService(client: client, profile: "selected")
        let source = try HermesVaultSource(client.sourceRows[1])
        try await service.addLogin(
            label: "Example", origin: "https://example.com", identifier: "account",
            type: "username", password: "fixture-input", otp: "")
        try await service.remove(HermesVaultItem(["id": "one", "kind": "login", "label": "Example"]))
        try await service.setEnabled(source, enabled: false)
        try await service.unlock(source, password: "fixture-input")
        try await service.lock(source)
        #expect(
            client.calls.map(\.0) == ["vault.add", "vault.remove", "vault.source.set", "vault.unlock", "vault.lock"])
        #expect(client.calls.allSatisfy { $0.1["profile"] as? String == "selected" })
        let payload = client.calls[0].1["secret"] as? [String: String]
        #expect(payload?["identifier_type"] == "username")
        #expect(payload?["password"] == "fixture-input")
        #expect(payload?["otp_secret"] == nil)
        #expect(client.calls[0].1["password"] == nil)
    }

    @Test func refusalsAndExternalDeletionNeverSucceed() async throws {
        let client = VaultFixtureClient()
        let service = HermesVaultService(client: client, profile: nil)
        let external = try HermesVaultItem(["id": "one", "kind": "login", "label": "Example", "backend": "bitwarden"])
        await #expect(throws: HermesVaultError.self) { try await service.remove(external) }
        #expect(client.calls.isEmpty)
        client.acknowledge = false
        let local = try HermesVaultItem(["id": "one", "kind": "login", "label": "Example"])
        await #expect(throws: HermesVaultError.self) { try await service.remove(local) }
        await #expect(throws: HermesVaultError.self) {
            try await service.addLogin(
                label: "Example", origin: "https://example.com", identifier: "account",
                type: "email", password: "fixture-input", otp: "")
        }
    }

    @Test func actionsRefreshAuthoritativeStateAndHideErrors() async {
        let client = VaultFixtureClient()
        let model = HermesVaultModel(service: HermesVaultService(client: client, profile: "first"))
        await model.load()
        let saved = await model.perform { try await $0.lock(HermesVaultSource(client.sourceRows[1])) }
        #expect(saved)
        #expect(client.calls.suffix(3).map(\.0) == ["vault.lock", "vault.list", "vault.sources"])
        client.fail = true
        let failed = await model.perform { try await $0.lock(HermesVaultSource(client.sourceRows[1])) }
        #expect(!failed && !model.available && !model.busy)
        #expect(!model.notice.contains("private-fixture-input"))
        #expect(model.notice.contains("failed"))
    }
}
