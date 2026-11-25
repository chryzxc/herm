import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct HermesPoolRotationTests {
    @Test func readsReportedPoolsAndWritesOneScopedSetting() async throws {
        let client = PoolRotationFixture()
        let service = HermesPoolRotationService(rpc: HermesControlRPC(client: client), profile: "work+qa")
        let pools = try await service.pools()
        #expect(client.reads == ["/api/credentials/pool?profile=work%2Bqa", "/api/config?profile=work%2Bqa"])
        #expect(pools.map(\.id) == ["anthropic", "custom:local.example", "openai-codex"])
        #expect(pools.map(\.strategy) == [.fillFirst, .leastUsed, .roundRobin])

        try await service.save(.random, for: pools[1])
        let write = try #require(client.writes.first)
        #expect(write.method == "PUT")
        #expect(write.path == "/api/config?profile=work%2Bqa")
        let config = try #require(write.body["config"] as? [String: [String: String]])
        #expect(config == ["credential_pool_strategies": ["custom:local.example": "random"]])
    }

    @Test func settingsWaitForAcknowledgmentAndRejectAnOldProfile() async throws {
        let client = PoolRotationFixture()
        let rpc = HermesControlRPC(client: client)
        var profile = "work"
        let model = HermesPoolRotationModel(service: { HermesPoolRotationService(rpc: rpc, profile: profile) })
        await model.load()
        let scope = try #require(model.scope)
        let pool = HermesPoolRotationService.Pool(id: "openai-codex", strategy: .roundRobin)
        client.onWrite = { [weak model] in
            #expect(model?.savingPool == pool.id)
            #expect(model.flatMap { Self.strategy(for: pool.id, in: $0) } == .roundRobin)
        }
        client.writeResponse = ["ok": false]
        await #expect(throws: HermesGateway.GatewayError.self) {
            try await model.save(.random, for: pool, scope: scope)
        }
        #expect(Self.strategy(for: pool.id, in: model) == .roundRobin)
        #expect(model.savingPool == nil)

        client.writeResponse = ["ok": true]
        try await model.save(.random, for: pool, scope: scope)
        #expect(Self.strategy(for: pool.id, in: model) == .random)
        #expect(Self.strategy(for: "anthropic", in: model) == .fillFirst)

        profile = "personal"
        #expect(model.visibleState == .loading)
        try await model.save(.leastUsed, for: pool, scope: scope)
        #expect(client.writes.count == 2)
    }

    private static func strategy(for provider: String, in model: HermesPoolRotationModel)
        -> HermesPoolRotationService.Strategy?
    {
        guard case .ready(let pools) = model.visibleState else { return nil }
        return pools.first { $0.id == provider }?.strategy
    }

    @Test func renderAccountRotation() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POOL_ROTATION_SNAPSHOT_DIR"] else { return }
        let client = PoolRotationFixture()
        let rpc = HermesControlRPC(client: client)
        let model = HermesPoolRotationModel(service: { HermesPoolRotationService(rpc: rpc, profile: nil) })
        await model.load()
        let providers = HermesProviderRow.rows(from: [
            "providers": [
                ["slug": "anthropic", "name": "Anthropic"], ["slug": "openai-codex", "name": "OpenAI Codex"],
            ]
        ])
        for width: CGFloat in [460, 680] {
            let content = SettingsSection(title: "Account pooling", subtitle: "", tint: .dockAccent) {
                QuotaPoolRotationSettings(model: model, providers: providers)
            }
            .padding(20)
            .frame(width: width)
            .background(Color.dockCanvas)
            .dockThemedRoot()
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let cgImage = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("rotation-\(Int(width)).png"))
        }
    }
}

@MainActor
private final class PoolRotationFixture: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var reads: [String] = []
    var writes: [(method: String, path: String, body: [String: Any])] = []
    var writeResponse: [String: Any] = ["ok": true]
    var onWrite: (() -> Void)?

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        reads.append(path)
        if path.hasPrefix("/api/credentials/pool") {
            return [
                "providers": [
                    ["provider": "openai-codex", "entries": [["id": "one"], ["id": "two"]]],
                    ["provider": "anthropic", "entries": [["id": "three"]]],
                    ["provider": "custom:local.example", "entries": [["id": "four"]]],
                    ["provider": "empty", "entries": []],
                ]
            ]
        }
        return [
            "credential_pool_strategies": [
                "openai-codex": " ROUND_ROBIN ", "custom:local.example": "least_used", "not-registered": "random",
            ]
        ]
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        writes.append((method, path, body))
        onWrite?()
        return writeResponse
    }
}
