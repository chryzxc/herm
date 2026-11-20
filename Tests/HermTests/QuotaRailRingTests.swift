import Foundation
import Testing

@testable import Herm

struct QuotaRailRingTests {
    private static func window(_ id: String, _ label: String, _ remaining: Double?, display: String? = nil)
        -> ProviderQuotaWindow
    {
        ProviderQuotaWindow(
            id: id, label: label, remainingPercent: remaining, remainingDisplay: display, limitDisplay: nil,
            resetsAt: nil, resetsDisplay: nil)
    }

    private static func snapshot(_ provider: String, _ windows: [ProviderQuotaWindow]) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider, displayName: provider.capitalized, model: nil,
            updatedAt: Date(timeIntervalSince1970: 0), windows: windows, safeDetail: nil)
    }

    @Test func outerRingIsSessionAndInnerRingIsWeekly() {
        let rings = QuotaRailRing.make([
            Self.snapshot("claude", [Self.window("w", "Weekly", 40), Self.window("s", "Session", 72)])
        ])
        #expect(rings.count == 1)
        #expect(rings[0].arcs.map(\.label) == ["5h", "7d"])
        #expect(rings[0].arcs.map(\.remaining) == [72, 40])
        #expect(rings[0].summary == "5-hour 72% left, weekly 40% left")
    }

    @Test func skipsProvidersWithoutPercentagesAndKeepsOrder() {
        let rings = QuotaRailRing.make([
            Self.snapshot("openrouter", [Self.window("b", "Balance", nil, display: "$4.20")]),
            Self.snapshot("glm", [Self.window("m", "Monthly", 55)]),
            Self.snapshot("codex", [Self.window("s", "Session", 90)]),
            Self.snapshot("empty", []),
        ])
        #expect(rings.map(\.provider) == ["glm", "codex"])
        #expect(rings[0].arcs.count == 1)
    }

    @Test func clampsAndLimitsToTwoArcs() {
        let rings = QuotaRailRing.make([
            Self.snapshot(
                "kimi",
                [
                    Self.window("s", "Session", 140), Self.window("w", "Weekly", -5),
                    Self.window("x", "Extra", 15),
                ])
        ])
        #expect(rings[0].arcs.map(\.remaining) == [100, 0])
        #expect(rings[0].arcs.map(\.threshold) == [.healthy, .critical])
    }

    @Test func marksOnlyTheActivePoolAccount() {
        func pooled(_ id: String) -> ProviderQuotaSnapshot {
            var snapshot = Self.snapshot("pool-\(id)", [Self.window("s", "Session", 50)])
            snapshot.hermesCredential = HermesPooledCredential(
                provider: "openai-codex", id: id, label: id, position: 1)
            return snapshot
        }
        let rings = QuotaRailRing.make(
            [pooled("a"), pooled("b"), Self.snapshot("claude", [Self.window("s", "Session", 50)])],
            activeCredentialKeys: ["openai-codex/b"])
        #expect(rings.map(\.isActive) == [false, true, false])
        #expect(rings[1].summary == "Active, 5-hour 50% left")
    }

    @Test func carriesThePageBudgetMarkerForMultiDaySessions() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let codex = ProviderQuotaWindow(
            id: "s", label: "Session", remainingPercent: 40, remainingDisplay: nil, limitDisplay: nil,
            resetsAt: now.addingTimeInterval(6.7 * 86_400), resetsDisplay: nil)
        let rings = QuotaRailRing.make([Self.snapshot("codex", [codex])], now: now)
        #expect(rings[0].arcs[0].budget == QuotaForecasting.visibleDailyBudgetMarker(for: codex, now: now))
        #expect(rings[0].arcs[0].budget != nil)
        #expect(rings[0].summary == "Session 40% left")
    }
}
