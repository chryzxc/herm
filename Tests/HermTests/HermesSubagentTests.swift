import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class SubagentFixtureClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var reads: [String] = []
    var writes: [(String, [String: Any])] = []
    var fail = false
    var acknowledge = true
    var config: [String: Any] = [
        "delegation": [
            "provider": "auto", "model": "", "max_iterations": 250,
            "max_concurrent_children": 10, "child_timeout_seconds": 0,
            "reasoning_effort": "",
        ]
    ]
    var routing: [String: Any] = [
        "configured": "default", "blocked_reason": NSNull(),
        "backends": [["name": "default", "label": "Default", "description": "", "available": true]],
        "model_map": ["options": [[String: Any]](), "default": NSNull()],
        "profile_routes": ["profiles": [[String: Any]](), "default": NSNull()], "profiles": ["default", "research"],
    ]

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "plugins.manage" { return ["plugins": [[String: Any]]()] }
        return ["providers": [["slug": "fixture", "name": "Fixture provider", "models": ["fixture-model"]]]]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        reads.append(path)
        if fail { throw HermesSubagentError.unavailable }
        if path.contains("/api/delegation/routing") { return routing }
        if path.contains("/plugins/catalog") {
            return [
                "entries": [
                    [
                        "name": "advanced-delegation", "tier": "official", "installed": false,
                        "description": "Model and profile routes for delegated work.",
                    ]
                ]
            ]
        }
        return config
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        writes.append((path, body))
        if path.contains("/api/config"),
            let patch = (body["config"] as? [String: Any])?["delegation"] as? [String: Any],
            var values = config["delegation"] as? [String: Any]
        {
            values.merge(patch) { _, new in new }
            config["delegation"] = values
        }
        return ["ok": acknowledge, "backend": body["backend"] ?? "default"]
    }
}

@Suite("Hermes subagents")
@MainActor
struct HermesSubagentTests {
    @Test func defaultsAreScopedAndOnlyChangedFieldsAreWritten() async throws {
        let client = SubagentFixtureClient()
        let service = HermesSubagentService(rpc: HermesControlRPC(client: client), profile: "research+qa")
        let saved = try await service.defaults()
        var draft = saved
        draft.turns = 100
        try await service.saveDefaults(draft, previous: saved)
        #expect(client.reads == ["/api/config?profile=research%2Bqa"])
        #expect(client.writes.first?.0 == "/api/config?profile=research%2Bqa")
        let patch = (client.writes.first?.1["config"] as? [String: Any])?["delegation"] as? [String: Int]
        #expect(patch == ["max_iterations": 100])
        #expect(draft.patch(from: saved)["api_key"] == nil)
    }

    @Test func malformedDefaultsAndInvalidLimitsFailClosed() async throws {
        #expect(throws: HermesGateway.GatewayError.self) { try HermesSubagentDefaults([:]) }
        let client = SubagentFixtureClient()
        let service = HermesSubagentService(rpc: HermesControlRPC(client: client), profile: "default")
        let saved = try await service.defaults()
        var draft = saved
        draft.parallel = 0
        await #expect(throws: HermesSubagentError.self) { try await service.saveDefaults(draft, previous: saved) }
        #expect(client.writes.isEmpty)
    }

    @Test func unregisteredRoutingCannotBeSelected() async throws {
        let client = SubagentFixtureClient()
        let service = HermesSubagentService(rpc: HermesControlRPC(client: client), profile: "research")
        await #expect(throws: HermesSubagentError.self) { try await service.selectBackend("model_map") }
        #expect(client.writes.isEmpty)
        try await service.selectBackend("default")
        #expect(client.writes.first?.0 == "/api/delegation/backend?profile=research")
        #expect(client.writes.first?.1["backend"] as? String == "default")
        client.acknowledge = false
        await #expect(throws: HermesGateway.GatewayError.self) { try await service.selectBackend("default") }
    }

    @Test func routeRenamePreservesOptionsAndDefault() async throws {
        let client = SubagentFixtureClient()
        client.routing["model_map"] = [
            "options": [
                [
                    "name": "old", "description": "Reasoning", "provider": "fixture",
                    "model": "fixture-model", "request_overrides": ["custom": true],
                    "service_tier": "fast",
                ]
            ], "default": "old",
        ]
        let service = HermesSubagentService(rpc: HermesControlRPC(client: client), profile: "research")
        let current = try await service.routing()
        var route = try #require(current.models.first)
        route.name = "new"
        try await service.saveModelRoute(route, originalName: "old")
        let body = try #require(client.writes.first?.1)
        let rows = try #require(body["options"] as? [[String: Any]])
        #expect(rows.first?["name"] as? String == "new")
        #expect(rows.first?["original_name"] as? String == "old")
        #expect(rows.first?["service_tier"] as? String == "fast")
        #expect(rows.first?["request_overrides"] as? [String: Bool] == ["custom": true])
        #expect(body["default"] as? String == "new")
    }

    @Test func addingRouteDoesNotInventADefaultAndProfilesStayScoped() async throws {
        let client = SubagentFixtureClient()
        let service = HermesSubagentService(rpc: HermesControlRPC(client: client), profile: "research")
        let route = HermesSubagentRoute(
            name: "fast", description: "Small tasks", provider: "fixture", model: "fixture-model", directEndpoint: false
        )
        try await service.saveModelRoute(route, originalName: nil)
        #expect(client.writes.first?.1["default"] is NSNull)
        var profile = route
        profile.name = "research"
        try await service.saveProfileRoutes([profile], defaultName: "research")
        #expect(client.writes.last?.0 == "/api/delegation/backends/profile_routes?profile=research")
        #expect(client.writes.last?.1["default"] as? String == "research")
    }

    @Test func refreshPreservesStaleDataAndDisablesActions() async {
        let client = SubagentFixtureClient()
        let model = HermesSubagentModel(
            service: HermesSubagentService(rpc: HermesControlRPC(client: client), profile: "research"))
        await model.load()
        #expect(model.available && model.routingAvailable)
        let saved = model.defaults
        client.fail = true
        await model.load()
        #expect(!model.available && !model.routingAvailable)
        #expect(model.defaults == saved)
        #expect(!model.busy)
    }

    @Test func directEndpointIsPreservedWhenEditingLimits() async throws {
        let client = SubagentFixtureClient()
        var config = try #require(client.config["delegation"] as? [String: Any])
        config["base_url"] = "https://example.com"
        client.config["delegation"] = config
        let service = HermesSubagentService(rpc: HermesControlRPC(client: client), profile: "research")
        let saved = try await service.defaults()
        var draft = saved
        draft.timeout = 60
        try await service.saveDefaults(draft, previous: saved)
        draft.provider = "other"
        await #expect(throws: HermesSubagentError.self) { try await service.saveDefaults(draft, previous: saved) }
        #expect(client.writes.count == 1)
    }

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
                let client = SubagentFixtureClient()
                let host = NSHostingView(
                    rootView: HermesSubagentSettings(
                        rpc: HermesControlRPC(client: client), profile: "research", bots: [], avatarImages: [:]
                    )
                    .padding(20).frame(width: width, height: 1050, alignment: .top)
                    .background(Color.dockOpaqueCanvas).dockThemedRoot())
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 1050),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: root.appendingPathComponent("subagents-\(theme.rawValue)-\(Int(width)).png"))
                window.contentView = nil
            }
        }
    }
}
