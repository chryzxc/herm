import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
struct RemoteProviderAvailabilityTests {
    @Test func firstMissingUsageReportsProviderAndEmptyClearsIt() async {
        let client = SuspendedQuotaClient()
        let defaults = UserDefaults(suiteName: "RemoteProviderAvailabilityTests-\(UUID().uuidString)")!
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        for malformed in [true, false] {
            control.refreshProviderQuota(only: [HermesRemoteProviderService.readerID], isLocalBackend: false)
            await client.waitForRead()
            await withCheckedContinuation { continuation in
                var subscription: AnyCancellable?
                subscription = control.$projectionRefreshStates.dropFirst().filter {
                    $0["provider.quota"]?.isRefreshing == false
                }.sink { _ in
                    subscription?.cancel()
                    continuation.resume()
                }
                client.releaseRead(malformed: malformed)
            }
            #expect((control.providerQuotaDiagnostic(for: "codex-hermes") != nil) == malformed)
            #expect(control.reportedProviderQuotas.isEmpty)
        }
    }

    @Test(.enabled(if: !GatewayConnectionStore.isLocalBackend))
    func remoteDisconnectRefreshesWithoutSharingAKey() async throws {
        let client = ShareFailureClient()
        let defaults = UserDefaults(suiteName: "RemoteProviderAvailabilityTests-\(UUID().uuidString)")!
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        let row = HermesProviderRow.rows(from: ["providers": [["slug": "openrouter"]]])[0]
        try await control.saveHermesProviderKey(nil, row: row)
        #expect(client.disconnected)
        #expect(!client.saved)
        #expect(client.catalogReads > 0)
        #expect(client.profileReads == 0)
        #expect(control.providerQuotaReadsInFlight > 0)
    }

    @Test func malformedBackendUsageRetainsReadingAndFreshness() async {
        let client = SuspendedQuotaClient()
        let defaults = UserDefaults(suiteName: "RemoteProviderAvailabilityTests-\(UUID().uuidString)")!
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        let id = HermesRemoteProviderService.snapshotID(
            "codex-hermes", profile: nil, slug: "openai-codex", account: nil)
        let old = Date(timeIntervalSince1970: 1_000)
        let previous = ProviderQuotaSnapshot(
            provider: id, displayName: "Previous", model: nil, updatedAt: old, windows: [], safeDetail: nil)
        control.reportedProviderQuotas = [previous]
        control.providerQuotaReaderIDs = [id: HermesRemoteProviderService.readerID]
        control.providerQuotaFreshness.checkedAt = [id: old]
        control.recordProjectionSuccess("provider.quota")
        control.refreshProviderQuota(only: [HermesRemoteProviderService.readerID], isLocalBackend: false)
        await client.waitForRead()
        await withCheckedContinuation { continuation in
            var subscription: AnyCancellable?
            subscription = control.$projectionRefreshStates.dropFirst().filter {
                $0["provider.quota"]?.isRefreshing == false
            }.sink { _ in
                subscription?.cancel()
                continuation.resume()
            }
            client.releaseRead(malformed: true)
        }
        #expect(control.reportedProviderQuotas.contains(previous))
        #expect(control.providerQuotaFreshness.checkedAt[id] == old)
        #expect(control.projectionRefreshStates["provider.quota"]?.isStale == true)
    }

    @Test func partialBotShareFailureStillRefreshesCatalogAndQuota() async throws {
        let client = ShareFailureClient()
        let defaults = UserDefaults(suiteName: "RemoteProviderAvailabilityTests-\(UUID().uuidString)")!
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        let row = HermesProviderRow.rows(from: [
            "providers": [
                [
                    "slug": "openrouter", "name": "OpenRouter", "key_env": "OPENROUTER_API_KEY",
                ]
            ]
        ])[0]
        do {
            try await control.saveHermesProviderKey("test-key", row: row)
            Issue.record("Expected a partial sharing failure")
        } catch let error as BotKeyShareError {
            #expect(error.localizedDescription.contains("Saved"))
        }
        #expect(client.saved)
        #expect(client.catalogReads > 0)
        #expect(control.providerQuotaReadsInFlight > 0)
    }

    @Test func targetedBackendReadReplacesPreviousSnapshots() async {
        let client = SuspendedQuotaClient()
        let defaults = UserDefaults(suiteName: "RemoteProviderAvailabilityTests-\(UUID().uuidString)")!
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        let previous = ProviderQuotaSnapshot(
            provider: "old-backend-account", displayName: "Old", model: nil, updatedAt: .now,
            windows: [], safeDetail: nil)
        control.reportedProviderQuotas = [previous]
        control.providerQuotaReaderIDs = [previous.provider: HermesRemoteProviderService.readerID]
        control.refreshProviderQuota(only: [HermesRemoteProviderService.readerID], isLocalBackend: false)
        await client.waitForRead()
        await withCheckedContinuation { continuation in
            var subscription: AnyCancellable?
            subscription = control.$projectionRefreshStates.dropFirst().filter {
                $0["provider.quota"]?.isRefreshing == false
            }.sink { _ in
                subscription?.cancel()
                continuation.resume()
            }
            client.releaseRead(replacement: true)
        }
        #expect(!control.reportedProviderQuotas.contains { $0.provider == previous.provider })
        #expect(control.reportedProviderQuotas.contains { $0.provider.hasPrefix("codex-hermes-") })
    }

    @Test func profileChangeClearsSpinnerDuringSuspendedRemoteRead() async {
        let client = SuspendedQuotaClient()
        let defaults = UserDefaults(suiteName: "RemoteProviderAvailabilityTests-\(UUID().uuidString)")!
        let dock = DockModel(defaults: defaults, rpcClient: client)
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        control.dockModel = dock
        control.refreshProviderQuota(only: [HermesRemoteProviderService.readerID], isLocalBackend: false)
        await client.waitForRead()
        #expect(control.projectionRefreshStates["provider.quota"]?.isRefreshing == true)
        control.setProjectProfile("work")
        #expect(control.projectionRefreshStates["provider.quota"]?.isRefreshing == false)
        client.releaseRead()
    }

    @Test func targetedRefreshKeepsRemoteBackendSnapshots() {
        let control = ControlCenterModel()
        let remote = ProviderQuotaSnapshot(
            provider: "remote-account", displayName: "Backend account", model: nil, updatedAt: .now,
            windows: [], safeDetail: nil)
        control.reportedProviderQuotas = [remote]
        control.providerQuotaReaderIDs = [remote.provider: "remote-backend"]

        control.refreshProviderQuota(only: [], isLocalBackend: false)

        #expect(control.reportedProviderQuotas == [remote])
    }

    @Test func remoteBackendKeepsIndependentLocalReaders() {
        #expect(ProviderBackendAvailability(isLocalBackend: true).allowsLocalAuth)
        #expect(!ProviderBackendAvailability(isLocalBackend: false).allowsLocalAuth)
        #expect(ControlCenterModel.quotaReaderIDs(isLocalBackend: false, only: nil) == ["claude", "antigravity"])
        #expect(
            ControlCenterModel.quotaReaderIDs(isLocalBackend: false, only: ["codex-hermes", "claude"]) == ["claude"])
        #expect(
            ControlCenterModel.quotaReaderIDs(isLocalBackend: true, only: ["codex-hermes", "claude"]) == [
                "codex-hermes", "claude",
            ])
    }

    @Test func remoteLoginDistinguishesLocalClaudeFromHermes() {
        #expect(ProviderBackendAvailability(isLocalBackend: false).allowsLogin(for: QuotaProviderCatalog.claude))
        #expect(!ProviderBackendAvailability(isLocalBackend: false).allowsLogin(for: QuotaProviderCatalog.codexHermes))
        #expect(ProviderBackendAvailability(isLocalBackend: true).allowsLogin(for: QuotaProviderCatalog.codexHermes))
    }

    @Test(arguments: [false, true])
    func remoteRefreshRetainsLocalSnapshotsAndClearsHermes(quiet: Bool) {
        let control = ControlCenterModel()
        let local = ProviderQuotaSnapshot(
            provider: "claude", displayName: "Claude", model: nil, updatedAt: .now, windows: [], safeDetail: nil)
        let hermes = ProviderQuotaSnapshot(
            provider: "codex", displayName: "Codex", model: nil, updatedAt: .now, windows: [], safeDetail: nil)
        control.reportedProviderQuotas = [local, hermes]
        control.providerQuotaReaderIDs = ["claude": "claude", "codex": "codex-hermes"]
        control.providerQuotaFreshness.checkedAt = ["claude": .now, "codex": .now]
        control.hermesActiveCredentialKeys = ["openai-codex/a"]
        control.refreshProviderQuota(only: [], quiet: quiet, isLocalBackend: false)
        #expect(control.reportedProviderQuotas.map(\.provider) == ["claude"])
        #expect(control.providerQuotas.map(\.provider) == ["claude"])
        #expect(control.providerQuotaFreshness.checkedAt["claude"] != nil)
        #expect(control.providerQuotaFreshness.checkedAt["codex"] == nil)
        #expect(control.hermesActiveCredentialKeys.isEmpty)
    }
}

@MainActor
private final class SuspendedQuotaClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private var pending: CheckedContinuation<[String: Any], any Error>?
    private var waiter: CheckedContinuation<Void, Never>?

    func connect() async throws {}
    func close() {}
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "model.options" else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func releaseRead(replacement: Bool = false, malformed: Bool = false) {
        if malformed {
            pending?.resume(returning: ["providers": [["slug": "openai-codex"]]])
        } else if replacement {
            pending?.resume(returning: [
                "providers": [
                    [
                        "slug": "openai-codex", "usage": ["windows": [["label": "Week", "used_percent": 25]]],
                    ]
                ]
            ])
        } else {
            pending?.resume(returning: ["providers": [[String: Any]]()])
        }
        pending = nil
    }
}

@MainActor
private final class ShareFailureClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var saved = false
    var disconnected = false
    var catalogReads = 0
    var profileReads = 0
    func connect() async throws {}
    func close() {}
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == HermesFeatureIDs.ID.modelSaveKey.rawValue {
            saved = true
            return [:]
        }
        if method == HermesFeatureIDs.ID.modelDisconnect.rawValue {
            disconnected = true
            return [:]
        }
        if method == HermesFeatureIDs.ID.profilesList.rawValue {
            profileReads += 1
            throw URLError(.cannotConnectToHost)
        }
        if method == HermesFeatureIDs.ID.modelOptions.rawValue {
            catalogReads += 1
            return ["providers": []]
        }
        return [:]
    }
}
