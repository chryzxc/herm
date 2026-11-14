import Foundation
import Testing

@testable import Herm

@MainActor
struct RemoteProviderBalanceTests {
    @Test func inventoryAndCreditsShareOneCardWithIndependentTimes() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let inventory = HermesRemoteProviderService.snapshots(
            from: [
                "providers": [
                    [
                        "slug": "openrouter", "usage": ["windows": [["label": "Limit", "used_percent": 25]]],
                    ]
                ]
            ], profile: nil, now: date)[0]
        let json =
            #"{"provider":"openrouter","source":"credits_api","fetched_at":"2026-01-01T00:00:00Z","#
            + #""details":["Credits balance: $12.34"]}"#
        let decoded = try HermesRemoteProviderBalanceService.decode(json)
        let balanceID = HermesRemoteProviderService.snapshotID(
            "openrouter", profile: nil, slug: "openrouter-balance", account: nil)
        let balance = ProviderQuotaSnapshot(
            provider: balanceID, displayName: decoded.displayName, model: nil, updatedAt: decoded.updatedAt,
            windows: decoded.windows, safeDetail: decoded.safeDetail)
        let control = ControlCenterModel()
        control.reportedProviderQuotas = [inventory, balance]
        control.providerQuotaReaderIDs = [
            inventory.provider: HermesRemoteProviderService.readerID,
            balance.provider: HermesRemoteProviderService.balanceReaderID,
        ]
        control.applyProviderQuotaPresentation()
        #expect(control.providerQuotas.count == 1)
        #expect(control.providerQuotas[0].windows.count == 2)
        #expect(control.providerQuotas[0].updatedAt == date)
        #expect(control.providerQuotas[0].safeDetail?.contains("Credits:") == true)
        #expect(control.providerQuotas[0].safeDetail?.contains("key limit:") == true)
    }

    @Test func acceptsCreditsWithoutInventingTotal() throws {
        let json =
            #"{"provider":"openrouter","source":"credits_api","fetched_at":"2026-01-01T00:00:00Z","#
            + #""details":["Credits balance: $12.34"],"windows":[],"unavailable_reason":null}"#
        let balance = try HermesRemoteProviderBalanceService.decode(json)
        #expect(balance.windows.first?.remainingDisplay == "$12.34")
        #expect(balance.windows.first?.remainingPercent == nil)
        #expect(balance.windows.first?.amount == 12.34)
    }

    @Test func rejectsDuplicateOrMalformedCredits() {
        let json =
            #"{"provider":"openrouter","source":"credits_api","fetched_at":"2026-01-01T00:00:00Z","#
            + #""details":["Credits balance: $1.00","Credits balance: $2.00"]}"#
        #expect(throws: (any Error).self) { try HermesRemoteProviderBalanceService.decode(json) }
        #expect(throws: (any Error).self) { try HermesRemoteProviderBalanceService.decode("{") }
    }

    @Test func rejectsUnsupportedHelp() {
        #expect(!HermesRemoteProviderBalanceService.supports("usage --json"))
        #expect(HermesRemoteProviderBalanceService.supports("usage --json --provider"))
    }
}
