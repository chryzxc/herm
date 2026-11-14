import Testing

@testable import Herm

@MainActor
struct RemoteProviderAvailabilityTests {
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
