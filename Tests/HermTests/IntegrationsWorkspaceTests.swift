import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class IntegrationsFixture: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [String] = []
    var failReads = false
    var richInventory = false
    var failWrites = false
    var connectorPolicyLayers: [[String: Any]]?
    var blockedPath: String?
    var pending: CheckedContinuation<Void, Never>?
    var platforms: [[String: Any]] = [
        [
            "id": "telegram", "name": "Telegram", "description": "Bot messages and notifications", "enabled": true,
            "configured": true, "state": "connected",
            "env_vars": [
                ["key": "TOKEN", "prompt": "Bot token", "is_password": true, "is_set": true, "required": true]
            ],
        ],
        ["id": "discord", "name": "Discord", "description": "Community conversations", "state": "disabled"],
    ]
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(method)
        if failReads { throw HermesGateway.GatewayError.malformedResponse }
        if method == "profiles.describe" {
            return [
                "name": params["name"] ?? "default",
                "skills": richInventory ? [["name": "swift-review", "enabled": true]] : [],
            ]
        }
        if method == "connectors.list" { return ["available": true, "connectors": [["connector": "calendar"]]] }
        if method == "connectors.policy.get" {
            return connectorPolicyLayers.map { ["layers": $0] } ?? [:]
        }
        if method == "skills.manage" {
            return [
                "info": [
                    "skill_md_preview":
                        "# Swift review\nReview actor ownership and state transitions before changing code."
                ]
            ]
        }
        if method == "connectors.catalog" {
            return [
                "connectors": [
                    [
                        "slug": "calendar", "name": "Calendar",
                        "description": "Read events and manage connected calendars",
                    ]
                ]
            ]
        }
        if method == "connectors.accounts.list" {
            return [
                "accounts": [
                    ["connector": "calendar", "connection_id": "personal", "alias": "personal", "status": "connected"]
                ]
            ]
        }
        if method == "plugins.list" { return ["plugins": []] }
        if method == "plugins.manage" {
            if params["action"] as? String == "list" {
                return [
                    "plugins": richInventory
                        ? [
                            [
                                "key": "notes", "name": "Notes", "description": "Save and retrieve agent notes",
                                "status": "enabled", "source": "user", "version": "1.2.0",
                                "settings_schema": [
                                    ["key": "label", "label": "Notebook", "type": "string", "value": "Research"]
                                ],
                            ]
                        ] : []
                ]
            }
            if failWrites { throw HermesGateway.GatewayError.malformedResponse }
            return ["ok": true]
        }
        if method == "mcp.catalog" {
            return [
                "servers": richInventory
                    ? [
                        [
                            "name": "documentation", "description": "Search reference documentation", "installed": true,
                            "enabled": true, "transport": "http", "requires": ["API_KEY"],
                        ]
                    ] : []
            ]
        }
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        calls.append(path)
        let captured = platforms
        if path == blockedPath { await withCheckedContinuation { pending = $0 } }
        if failReads { throw HermesGateway.GatewayError.malformedResponse }
        if path.hasPrefix("/api/messaging/platforms") { return ["platforms": captured] }
        if path.hasPrefix("/api/tools/toolsets") {
            return [
                "items": [
                    [
                        "name": "web", "label": "Web", "enabled": true, "configured": true,
                        "description": "Search public sources", "tools": ["web_search"],
                    ]
                ]
            ]
        }
        if path == "/api/dashboard/plugins/catalog" { return ["entries": []] }
        return [:]
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        calls.append(method + " " + path)
        if failWrites { throw HermesGateway.GatewayError.malformedResponse }
        return ["ok": true]
    }
}

@MainActor
struct IntegrationsWorkspaceTests {
    private func store() -> WorkspaceStore {
        WorkspaceStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("integrations-\(UUID()).json"))
    }
    @Test func navigationAndCategoryContracts() {
        #expect(ControlTab.globalNavigation.filter { $0 == .integrations }.count == 1)
        #expect(ControlTab.integrations.globalRailLabel == "Integrations")
        #expect(
            IntegrationsCategory.allCases.map(\.title) == [
                "Messaging", "Skills", "Tools", "Connectors", "Plugins", "MCP servers",
            ])
        #expect(IntegrationsCategory.messaging.section == nil)
        #expect(IntegrationsCategory.mcp.section == .mcp)
    }
    @Test func defaultsAndIndependentBrowsing() {
        let store = store()
        let state = IntegrationsWorkspaceState(client: IntegrationsFixture(), store: store)
        #expect(state.category == .skills)
        state.currentBrowsing.search = "swift"
        state.currentBrowsing.discover = true
        state.selectCategory(.messaging)
        state.currentBrowsing.search = "telegram"
        state.selectCategory(.skills)
        #expect(state.currentBrowsing.search == "swift" && state.currentBrowsing.discover)
        state.selectCategory(.messaging)
        #expect(state.currentBrowsing.search == "telegram")
        #expect(store.lastIntegrationsCategory == .messaging)
        #expect(IntegrationsWorkspaceState(client: IntegrationsFixture(), store: store).category == .messaging)
    }
    @Test func invalidAndLegacyPreferencesFallBackToSkills() throws {
        for preference in ["", "removed-category"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("integrations-old-\(UUID()).json")
            let data = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 2, "lastIntegrationsCategory": preference,
            ])
            try data.write(to: url)
            #expect(WorkspaceStore(fileURL: url).lastIntegrationsCategory == .skills)
        }
    }
    @Test func selectedCategoryLoadsLazilyAndRefreshesAlone() async {
        let client = IntegrationsFixture()
        let state = IntegrationsWorkspaceState(client: client, store: store())
        #expect(client.calls.isEmpty)
        state.selectCategory(.messaging)
        await state.load()
        await state.load()
        #expect(client.calls == ["/api/messaging/platforms"])
        await state.load(force: true)
        #expect(client.calls == ["/api/messaging/platforms", "/api/messaging/platforms"])
        state.selectCategory(.tools)
        await state.load()
        #expect(client.calls.last?.hasPrefix("/api/tools/toolsets") == true)
        #expect(!client.calls.contains("profiles.describe"))
    }
    @Test func dirtyFormGuardsNavigationAndDiscardIsExplicit() {
        let state = IntegrationsWorkspaceState(client: IntegrationsFixture(), store: store())
        state.isDirty = true
        state.selectCategory(.messaging)
        #expect(state.category == .skills)
        var left = false
        state.requestNavigation { left = true }
        #expect(!left && state.showsLeaveConfirmation)
        state.keepEditing()
        #expect(!left && state.isDirty)
        state.requestNavigation { left = true }
        state.discardAndLeave()
        #expect(left && !state.isDirty && state.discardRevision == 1)
    }
    @Test func scopeAndProfileChangesClearOldInventoriesWithoutLoadingOthers() async {
        let client = IntegrationsFixture()
        let state = IntegrationsWorkspaceState(client: client, store: store())
        state.selectCategory(.messaging)
        await state.load()
        await state.useProfile("research")
        #expect(state.profileID == "research")
        #expect(client.calls == ["/api/messaging/platforms", "/api/messaging/platforms?profile=research"])
        #expect(state.workflow.loadedSections.isEmpty)
        #expect(state.workflow.service.profileID == "research")
        state.selectCategory(.connectors)
        #expect(state.scopeTitle == "Account connections")
        #expect(WorkflowIntegrationView.isAccountAction("Disconnect"))
        #expect(!WorkflowIntegrationView.isAccountAction("Remove server"))
    }
    @Test func failedReadsRetainStaleInventoryAndFailedSavesRemainRetryable() async throws {
        let client = IntegrationsFixture()
        let state = IntegrationsWorkspaceState(client: client, store: store())
        state.selectCategory(.messaging)
        await state.load()
        let platform = try #require(state.messaging.platforms.first)
        client.failWrites = true
        let saved = await state.messaging.save(platform, enabled: false, drafts: [:], profileID: nil)
        #expect(!saved && !state.messaging.isStale)
        #expect(!platform.hasChanges(enabled: true, drafts: ["TOKEN": ""]))
        client.failReads = true
        await state.load(force: true)
        #expect(state.messaging.platforms.count == 2 && state.messaging.isStale)
        client.failReads = false
        state.selectCategory(.tools)
        await state.load()
        client.failReads = true
        await state.load(force: true)
        #expect(state.workflow.toolsets.count == 1 && state.workflow.staleSections.contains(.tools))
    }
    @Test func invalidatingReadRejectsLateMessagingResponse() async {
        let client = IntegrationsFixture()
        client.blockedPath = "/api/messaging/platforms"
        let state = IntegrationsWorkspaceState(client: client, store: store())
        state.selectCategory(.messaging)
        let read = Task { await state.load() }
        while client.pending == nil { await Task.yield() }
        state.messaging.invalidate()
        client.pending?.resume()
        await read.value
        #expect(!state.messaging.hasLoaded && state.messaging.platforms.isEmpty)
    }

    @Test func connectorPolicyReadFailsClosedWithoutAVerifiedMemberRevision() async throws {
        let client = IntegrationsFixture()
        for (layers, expected): ([[String: Any]]?, Bool?) in [
            (nil, nil), ([], false), ([["kind": "member", "revision": "r1"]], true),
        ] {
            client.connectorPolicyLayers = layers
            let connectors = try await HermesWorkflowRPC(client: client, profileID: nil).connectors()
            #expect(connectors.first?.policyWritable == expected)
        }
        #expect(client.calls.contains("connectors.policy.get"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @Test func expandedPageHasAnOptionalCloseAndKeepsExistingCloseBehavior() throws {
        let without = DockExpandedPage(title: "Integrations", subtitle: "") { Text("Content") }
        let withClose = DockExpandedPage(title: "Review", subtitle: "") {
        } content: {
            Text("Content")
        }
        #expect(without.close == nil)
        #expect(withClose.close != nil && withClose.showsClose)
        for view in [AnyView(without), AnyView(withClose)] {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 450, height: 200)
            host.layoutSubtreeIfNeeded()
            #expect(host.bitmapImageRepForCachingDisplay(in: host.bounds) != nil)
        }
    }

    @Test func validCategoryPreferenceSurvivesDiskReload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("integrations-persisted-\(UUID()).json")
        let workspace = WorkspaceStore(fileURL: url)
        workspace.selectIntegrationsCategory(.mcp)
        // WorkspaceStore writes asynchronously; wait only until this particular write is visible.
        for _ in 0..<100 {
            if WorkspaceStore(fileURL: url).lastIntegrationsCategory == .mcp { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The category preference was not persisted")
    }

    @Test func renderAllCategoryDetailsAndRecoveryStates() async throws {
        let previous = DockThemeRuntime.current
        defer { DockThemeRuntime.current = previous }
        DockThemeRuntime.current = .clean
        let directory = URL(fileURLWithPath: "/tmp/herm-integrations-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for category in IntegrationsCategory.allCases {
            for width: CGFloat in [450, 900, 1200] {
                let client = IntegrationsFixture()
                client.richInventory = true
                client.connectorPolicyLayers = [["kind": "member", "revision": "r1"]]
                let state = IntegrationsWorkspaceState(client: client, store: store())
                state.selectCategory(category)
                await state.load()
                state.currentBrowsing.showsDetail = true
                state.workflow.preview = "# Swift review\nCheck ownership and state transitions."
                try capture(state, width: width, directory: directory, name: "\(category.rawValue)-\(Int(width))")
            }
        }
        for kind in ["empty", "unavailable", "stale", "unsaved"] {
            let client = IntegrationsFixture()
            let state = IntegrationsWorkspaceState(client: client, store: store())
            state.selectCategory(.messaging)
            if kind == "empty" { client.platforms = [] }
            if kind == "unavailable" { client.failReads = true }
            await state.load()
            if kind == "stale" {
                client.failReads = true
                await state.load(force: true)
            }
            state.isDirty = kind == "unsaved"
            state.currentBrowsing.showsDetail = kind == "unsaved"
            try capture(state, width: 450, directory: directory, name: kind)
        }
    }

    private func capture(_ state: IntegrationsWorkspaceState, width: CGFloat, directory: URL, name: String) throws {
        let host = NSHostingView(rootView: IntegrationsWorkspaceView(state: state).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 720)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent(name + ".png"))
        for field in descendants(host).compactMap({ $0 as? NSTextField }) where !field.isHidden {
            let frame = field.convert(field.bounds, to: host)
            #expect(frame.minX >= -1 && frame.maxX <= width + 1)
        }
    }

    @Test func renderResponsiveWorkspaceAndThemes() async throws {
        let previous = DockThemeRuntime.current
        defer { DockThemeRuntime.current = previous }
        let directory = URL(fileURLWithPath: "/tmp/herm-integrations-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (theme, dark): (DockThemeID, Bool) in [(.clean, false), (.clean, true), (.glass, true), (.mono, true)] {
            DockThemeRuntime.current = theme
            for width: CGFloat in [450, 900, 1200] {
                let state = IntegrationsWorkspaceState(client: IntegrationsFixture(), store: store())
                state.selectCategory(.messaging)
                await state.load()
                for detail in [false, true] {
                    state.currentBrowsing.showsDetail = detail
                    state.currentBrowsing.selection = detail ? "telegram" : nil
                    let view = IntegrationsWorkspaceView(state: state)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 720)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(
                        to: directory.appendingPathComponent(
                            "\(theme.rawValue)-\(dark ? "dark" : "light")-\(Int(width))-\(detail ? "detail" : "list").png"
                        ))
                    for field in descendants(host).compactMap({ $0 as? NSTextField }) where !field.isHidden {
                        let frame = field.convert(field.bounds, to: host)
                        #expect(frame.minX >= -1 && frame.maxX <= width + 1)
                    }
                }
            }
        }
    }
}
