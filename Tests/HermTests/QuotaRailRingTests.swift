import AppKit
import Foundation
import SwiftUI
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

    @MainActor
    @Test func includesBalancesInOrderWithoutInventingPercentageRings() throws {
        let deepSeek = try #require(
            ControlCenterModel.parseProviderQuota(
                DeepSeekQuotaService.normalize([
                    "is_available": true,
                    "balance_infos": [["currency": "CNY", "total_balance": "12.50"]],
                ])))
        #expect(deepSeek.windows.first?.amount == nil)
        let rings = QuotaRailRing.make([
            Self.snapshot("openrouter", [Self.window("credits", "Credits", nil, display: "$4.20")]),
            Self.snapshot("glm", [Self.window("m", "Monthly", 55)]),
            deepSeek,
            Self.snapshot("codex", [Self.window("s", "Session", 90)]),
            Self.snapshot("spend", [Self.window("usage", "Key usage", nil, display: "$2.00 spent")]),
            Self.snapshot("unknown", [Self.window("balance", "Balance", nil)]),
            Self.snapshot("empty", []),
        ])
        #expect(rings.map(\.provider) == ["openrouter", "glm", "deepseek", "codex"])
        let openRouterRing = try #require(rings.first)
        let deepSeekRing = try #require(rings.first { $0.provider == "deepseek" })
        #expect(openRouterRing.arcs.isEmpty)
        #expect(openRouterRing.summary == "Credits $4.20")
        #expect(deepSeekRing.arcs.isEmpty)
        #expect(deepSeekRing.summary == "Balance ¥12.50")
        #expect(rings.first { $0.provider == "glm" }?.arcs.count == 1)
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

    @Test func reorderingRailProvidersKeepsUnreportedProvidersInPlace() {
        let full = ["codex", "unreported", "claude", "deepseek"]
        #expect(
            QuotaRailRing.merging(ringOrder: ["deepseek", "codex", "claude"], into: full)
                == ["deepseek", "unreported", "codex", "claude"])
        #expect(QuotaRailRing.merging(ringOrder: ["codex", "claude", "deepseek"], into: full) == full)
    }

    @MainActor
    @Test func railBalanceStaysAboveConnectionWhileDestinationsScroll() async throws {
        let app = NSApplication.shared
        let key = "accessibilityEnhancedUserInterface"
        let previous = app.value(forKey: key)
        app.setValue(true, forKey: key)
        defer { app.setValue(previous, forKey: key) }
        let suite = "quota-rail-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        let model = DockModel(defaults: defaults, rpcClient: HermesOfflineFixtureRPCClient(scenario: .available))
        defer { model.shutdown() }
        let control = ControlCenterModel()
        control.providerQuotas = [Self.snapshot("deepseek", [Self.window("balance", "Balance", nil, display: "$4.20")])]
        let rail = SessionNavRail(
            model: model, controlCenter: control, workspaceStore: WorkspaceStore(fileURL: storeURL),
            agentUpdateService: HermesUpdateService(), navigationState: SessionNavigationState(),
            dockThemeStore: DockThemeStore(defaults: defaults), isChatsActive: true, isGitHubActive: false,
            onOpenChats: {}, onOpenGlobal: { _ in }, onOpenArtifacts: {}, onOpenGitHub: { _ in },
            onOpenPlugin: { _ in }, isFullscreen: false, isDockedWindow: true, onFullscreenToggle: {}, onOpenWindow: nil
        )
        .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: rail)
        host.frame = NSRect(x: 0, y: 0, width: 52, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func element(_ label: String, in view: AnyObject) -> AnyObject? {
            if view.accessibilityLabel?() == label { return view }
            return (view.accessibilityChildren?() ?? []).lazy.compactMap { element(label, in: $0 as AnyObject) }.first
        }
        let balanceLabel = "Deepseek quota, Balance $4.20"
        for _ in 0..<25 {
            host.layoutSubtreeIfNeeded()
            if element(balanceLabel, in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let mark = try #require(element(balanceLabel, in: host))
        #expect(mark.accessibilityRole?() != .button)
        #expect(mark.accessibilityPerformPress?() != true)
        let connection = try #require(element("Connected to Hermes Agent. Connection details", in: host))
        let connectionFrame = try #require(connection.accessibilityFrame?())
        let markFrame = try #require(mark.accessibilityFrame?())
        #expect((0...8).contains(markFrame.minY - connectionFrame.maxY))

        func firstScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { firstScroll(in: $0) }.first
        }
        let destinations = try #require(firstScroll(in: host))
        #expect(DockEdgeAutoscroll.scrollStep(in: destinations, toward: .towardEnd) != 0)
        host.layoutSubtreeIfNeeded()
        #expect(element(balanceLabel, in: host)?.accessibilityFrame?() == markFrame)
    }
}
