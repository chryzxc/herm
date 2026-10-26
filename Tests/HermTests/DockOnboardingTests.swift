import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class OnboardingClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var status: String? = "disabled"
    var fails = false
    var malformed = false
    var failsRoster = false
    var profiles: [[String: Any]] = [["name": "default", "is_default": true]]
    var restart = false
    var acknowledges = true
    var applyToggle = true
    var writes: [[String: Any]] = []
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if fails { throw URLError(.cannotConnectToHost) }
        switch method {
        case "plugins.manage":
            if params["action"] as? String == "toggle" {
                writes.append(params)
                if applyToggle && acknowledges { status = "enabled" }
                return ["ok": acknowledges, "restart_required": restart]
            }
            if malformed { return ["plugins": [["name": "Bots"]]] }
            return ["plugins": status.map { [["key": "hermes-bots", "name": "Bots", "status": $0]] } ?? []]
        case "profiles.list":
            if failsRoster { throw URLError(.cannotConnectToHost) }
            return ["profiles": profiles]
        default: return ["sessions": []]
        }
    }
}

@MainActor
struct DockOnboardingTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "DockOnboardingTests.\(UUID().uuidString)")!
    }

    @Test func progressResumesAndCompletionOnlyStoresLocalPreferences() {
        let store = defaults()
        let client = OnboardingClient()
        let model = DockOnboardingModel(client: client, defaults: store)
        #expect(model.step == 0)
        #expect(!store.bool(forKey: DockOnboardingModel.completedKey))
        model.step = 2
        #expect(DockOnboardingModel(client: client, defaults: store).step == 2)
        model.finish()
        #expect(store.bool(forKey: DockOnboardingModel.completedKey))
        #expect(DockOnboardingModel(client: client, defaults: store).step == 0)
        #expect(client.writes.isEmpty)
        store.set(99, forKey: DockOnboardingModel.stepKey)
        #expect(DockOnboardingModel(client: client, defaults: store).step == 3)
    }

    @Test func disabledPluginRequiresExplicitActionAndAuthoritativeRefresh() async {
        let client = OnboardingClient()
        let model = DockOnboardingModel(client: client, defaults: defaults())
        await model.enablePlugin()
        #expect(client.writes.isEmpty)
        await model.refresh()
        #expect(model.canEnablePlugin)
        #expect(!model.canUseBots)
        #expect(client.writes.isEmpty)
        await model.enablePlugin()
        #expect(client.writes.count == 1)
        #expect(client.writes.first?["key"] as? String == "hermes-bots")
        #expect(client.writes.first?["enable"] as? Bool == true)
        #expect(client.writes.first?["profile"] == nil)
        #expect(model.canUseBots)
        #expect(!model.canEnablePlugin)
    }

    @Test func botStepRequiresVerifiedSupportBeforeContinuing() async {
        let client = OnboardingClient()
        let model = DockOnboardingModel(client: client, defaults: defaults())
        #expect(model.canContinue)
        model.step = 1
        #expect(!model.canContinue)
        await model.refresh()
        #expect(!model.canContinue)
        await model.enablePlugin()
        #expect(model.canContinue)
        client.fails = true
        await model.refresh()
        #expect(!model.canContinue)
    }

    @Test func restartAndUnacknowledgedChangesNeverUnlockBots() async {
        for scenario in 0..<3 {
            let client = OnboardingClient()
            client.restart = scenario == 0
            client.acknowledges = scenario != 1
            client.applyToggle = scenario != 2
            let model = DockOnboardingModel(client: client, defaults: defaults())
            await model.refresh()
            await model.enablePlugin()
            #expect(!model.canUseBots)
            #expect(!model.busy)
            if scenario == 0 { #expect(model.restartRequired) }
            if scenario == 2 { #expect(model.plugin?.enabled == false) }
        }
    }

    @Test func unavailableMalformedAndUnexpectedStatesFailClosed() async {
        let client = OnboardingClient()
        let model = DockOnboardingModel(client: client, defaults: defaults())
        client.status = "enabled"
        await model.refresh()
        #expect(model.canUseBots)
        client.fails = true
        await model.refresh()
        #expect(!model.canUseBots && !model.canEnablePlugin)
        client.fails = false
        client.malformed = true
        await model.refresh()
        #expect(!model.canUseBots && !model.canEnablePlugin)
        client.malformed = false
        client.status = "error"
        await model.refresh()
        #expect(!model.canUseBots && !model.canEnablePlugin)
        #expect(client.writes.isEmpty)
    }

    @Test func failedRosterRefreshDoesNotUnlockRetainedBots() async {
        let client = OnboardingClient()
        client.status = "enabled"
        let model = DockOnboardingModel(client: client, defaults: defaults())
        await model.refresh()
        #expect(model.canUseBots)
        client.failsRoster = true
        await model.refresh()
        #expect(!model.canUseBots)
    }

    @Test func renderOnboardingAcrossThemes() async throws {
        guard let directory = ProcessInfo.processInfo.environment["ONBOARDING_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        _ = DockThemeStore.shared
        let originalTheme = DockThemeRuntime.current
        let originalAppearance = NSApp.appearance
        defer {
            DockThemeRuntime.current = originalTheme
            DockThemeRuntime.revision &+= 1
            NSApp.appearance = originalAppearance
        }
        let client = OnboardingClient()
        client.status = "enabled"
        client.profiles += [
            ["name": "aegis", "title": "DevOps"],
            ["name": "archon", "title": "Planner"],
            ["name": "atlas", "title": "Researcher"],
            ["name": "beacon", "title": "Auditor"],
            ["name": "very-long-bot-profile-name", "title": "Long role label for layout coverage"],
        ]
        let model = DockOnboardingModel(client: client, defaults: defaults())
        await model.refresh()
        for (theme, dark) in [(DockThemeID.clean, false), (.storm, true), (.glass, false), (.mono, true)] {
            DockThemeRuntime.current = theme
            DockThemeRuntime.revision &+= 1
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for step in 0..<5 {
                model.step = min(step, 3)
                let root = Group {
                    if step == 4 {
                        ScrollView {
                            DockOnboardingAppearance().skinPicker.padding(24)
                        }
                    } else {
                        DockOnboardingView(setup: model, bots: model.bots, close: {}, finish: {})
                    }
                }
                .frame(width: 680, height: 560)
                .background(DockWindowBackground())
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<3 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(40))
                }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("\(theme.rawValue)-\(step).png"))
                window.orderOut(nil)
            }
        }
    }

    @Test func builtInBotsNeedNoPluginMutationAndEnableRechecksState() async {
        let client = OnboardingClient()
        let model = DockOnboardingModel(client: client, defaults: defaults())
        await model.refresh()
        client.status = nil
        await model.enablePlugin()
        #expect(client.writes.isEmpty)
        #expect(model.canUseBots)
        #expect(!model.canEnablePlugin)
    }
}
