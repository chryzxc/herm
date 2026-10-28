import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class WorkflowFixture: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [(String, [String: Any])] = []
    var replies: [String: [String: Any]] = [:]
    var failures = Set<String>()
    var searchDelay = false
    var blockCatalog = false
    var catalogContinuation: CheckedContinuation<Void, Never>?
    var blockedMethods = Set<String>()
    var pendingRequests: [String: CheckedContinuation<Void, Never>] = [:]
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        if blockedMethods.contains(method) {
            await withCheckedContinuation { pendingRequests[method] = $0 }
        }
        if failures.contains(method) {
            throw NSError(
                domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unknown method: \(method)"])
        }
        if let result = replies[method] { return result }
        if method == "session.resume" {
            return [
                "session_id": "runtime", "stored_session_id": params["session_id"] ?? "owner",
                "info": ["profile_name": params["profile"] ?? "default", "cwd": "/tmp/worktree"],
                "running": false,
            ]
        }
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        calls.append(("GET " + path, [:]))
        if path == "/api/dashboard/plugins/catalog", blockCatalog {
            await withCheckedContinuation { catalogContinuation = $0 }
        }
        if path.hasPrefix("/api/sessions/search") {
            if searchDelay && path.contains("q=older") { try? await Task.sleep(for: .milliseconds(150)) }
            return replies["search"] ?? [
                "results": [
                    [
                        "session_id": path.contains("q=older") ? "older" : "newer", "profile": "research",
                        "snippet": "A past decision",
                    ]
                ]
            ]
        }
        return replies["GET"] ?? [:]
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        calls.append((method + " " + path, body))
        return replies[method] ?? ["ok": true]
    }
}

@MainActor
struct WorkflowRoadmapTests {
    private var owner: HermesSession {
        HermesSession(
            id: "owner", profileID: "research", title: "Research", preview: "", startedAt: nil,
            messageCount: 0, source: "herm")
    }
    private func options(accounts: [[String: Any]] = []) -> [String: Any] {
        [
            "provider": "codex", "model": "configured",
            "providers": [["slug": "codex", "models": ["configured"], "usage": ["accounts": accounts]]],
        ]
    }
    private func refusing(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("An unacknowledged or wrongly scoped operation succeeded")
        } catch {}
    }
    @Test func wrongProfileCannotResumeOrMutate() async {
        let client = WorkflowFixture()
        await refusing {
            _ = try await HermesWorkflowRPC(client: client, profileID: "coding").resumeOwned(owner)
        }
        #expect(client.calls.isEmpty)
    }
    @Test func resumeRequiresDurableOwnerAndNamedProfileEcho() async {
        for result: [String: Any] in [
            ["session_id": "other", "info": ["profile_name": "research"]],
            ["session_id": "runtime", "stored_session_id": "owner", "info": ["profile_name": "coding"]],
            ["session_id": "runtime", "stored_session_id": "owner"],
        ] {
            let client = WorkflowFixture()
            client.replies["session.resume"] = result
            await refusing {
                _ = try await HermesWorkflowRPC(client: client, profileID: "research").sessionDirectory(
                    owner)
            }
            #expect(client.calls.count == 1)
        }
    }
    @Test func launchProfileCannotAcceptAnotherProfileResponse() async {
        let client = WorkflowFixture()
        client.replies["session.resume"] = [
            "session_id": "launch-owner", "info": ["profile_name": "coding", "cwd": "/tmp/worktree"],
            "running": false,
        ]
        let launch = HermesSession(
            id: "launch-owner", title: "Launch", preview: "", startedAt: nil, messageCount: 0,
            source: "herm")
        await refusing {
            _ = try await HermesWorkflowRPC(client: client, profileID: nil).resumeOwned(launch)
        }
        await refusing {
            _ = try EdgeResultContent.parse(
                ["profile": "coding", "data": [["role": "assistant", "content": "Wrong owner"]]],
                session: launch)
        }
    }
    @Test func directoryReadUsesOneScopedResume() async throws {
        let client = WorkflowFixture()
        let directory = try await HermesWorkflowRPC(client: client, profileID: "research")
            .sessionDirectory(owner)
        #expect(directory == "/tmp/worktree")
        #expect(client.calls.count == 1)
        #expect(client.calls[0].1["profile"] as? String == "research")
        #expect(client.calls[0].1["session_id"] as? String == "owner")
    }
    @Test func connectorOperationOpensOnlyHTTPSLinksAndRequiresEveryTargetConnected() throws {
        let pending = try HermesWorkflowRPC.connectorOperation([
            "op_id": "op", "settled": false,
            "targets": [["state": "initiated", "connect_url": "http://insecure.test"]],
        ])
        #expect(pending.url == nil && !pending.settled && !pending.connected)
        let done = try HermesWorkflowRPC.connectorOperation([
            "op_id": "op", "settled": true,
            "targets": [
                ["state": "connected", "connect_url": "https://portal.test/a"], ["state": "failed"],
            ],
        ])
        #expect(done.url?.host == "portal.test" && done.settled && !done.connected)
        #expect(throws: (any Error).self) { try HermesWorkflowRPC.connectorOperation(["targets": []]) }
    }

    @Test func toolsetsHideInternalsAndToggleWithinProfile() async throws {
        let client = WorkflowFixture()
        client.replies["GET"] = [
            "items": [
                [
                    "name": "web", "label": "Web", "description": "Search", "enabled": true, "configured": false,
                    "tools": ["web_search"],
                ],
                ["name": "moa", "label": "MoA", "enabled": false],
            ]
        ]
        let rpc = HermesWorkflowRPC(client: client, profileID: "coding")
        let toolsets = try await rpc.toolsets()
        #expect(toolsets.map(\.id) == ["web"])
        #expect(toolsets.first?.configured == false && toolsets.first?.tools == ["web_search"])
        #expect(client.calls.first?.0 == "GET /api/tools/toolsets?profile=coding")
        client.replies["PUT"] = ["ok": true, "name": "web", "enabled": false]
        try await rpc.setToolset("web", enabled: false)
        #expect(client.calls.last?.0 == "PUT /api/tools/toolsets/web?profile=coding")
        client.replies["PUT"] = ["ok": true, "name": "web", "enabled": true]
        await refusing { try await rpc.setToolset("web", enabled: false) }
    }

    @Test func popularityStopsAfterRateLimitAndKeepsCompletedBatches() async throws {
        var requests = 0
        let slugs = (0..<250).map { "acme/repo\($0)" }
        let result = await HermesWorkflowRPC.githubStars(slugs, token: "fixture") { request in
            requests += 1
            let status = requests == 1 ? 200 : 429
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data("{\"data\":{\"r0\":{\"stargazerCount\":42}}}".utf8), response)
        }
        #expect(requests == 2)
        #expect(result.count == 1)
        #expect(result[slugs.sorted()[0]] == 42)
    }

    @Test func popularityStopsAfterTransportFailure() async {
        var requests = 0
        let result = await HermesWorkflowRPC.githubStars((0..<250).map { "acme/repo\($0)" }, token: "fixture") { _ in
            requests += 1
            throw URLError(.timedOut)
        }
        #expect(requests == 1)
        #expect(result.isEmpty)
    }

    @Test func failedToolsAndConnectorsRefreshRetainsLastInventory() async {
        let client = WorkflowFixture()
        let model = WorkflowIntegrationModel(client: client, profileID: nil)
        client.replies["GET"] = ["items": [["name": "browser", "enabled": true]]]
        client.replies["connectors.list"] = ["available": true, "connectors": [["connector": "calendar"]]]
        await model.load(.tools)
        await model.load(.connectors)
        #expect(model.toolsets.map(\.id) == ["browser"])
        #expect(model.connectors.map(\.id) == ["calendar"])
        client.replies["GET"] = [:]
        client.failures.insert("connectors.list")
        await model.refresh(section: .tools)
        await model.refresh(section: .connectors)
        #expect(model.toolsets.map(\.id) == ["browser"])
        #expect(model.connectors.map(\.id) == ["calendar"])
        #expect(model.status.contains("Tools: Refresh failed"))
        #expect(model.status.contains("Connectors: Refresh failed"))
    }

    @Test func whitespaceHubSearchDoesNotRequestRuntime() async {
        let client = WorkflowFixture()
        let model = WorkflowIntegrationModel(client: client, profileID: nil)
        await model.searchHub("   ")
        #expect(client.calls.isEmpty)
        #expect(!model.busy)
    }

    @Test func pluginPageLoadsOnlyItsInventoryAndReusesItUntilRefresh() async {
        let client = WorkflowFixture()
        client.replies["plugins.manage"] = ["plugins": []]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        await model.load(.plugins)
        await model.load(.plugins)
        #expect(client.calls.count == 1)
        #expect(client.calls.first?.0 == "plugins.manage")
        #expect(model.loadedSections == [.plugins])
        await model.refresh(section: .plugins)
        #expect(client.calls.count == 2)
    }

    @Test func cachedPluginTabDoesNotWaitForCancelledReadsInAnotherTab() async {
        let client = WorkflowFixture()
        client.replies["plugins.manage"] = ["plugins": []]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        await model.load(.plugins)
        client.blockedMethods = ["profiles.describe"]
        let skills = Task { await model.load(.skills) }
        for _ in 0..<200 {
            if client.pendingRequests["profiles.describe"] != nil { break }
            await Task.yield()
        }
        #expect(model.busy)
        skills.cancel()
        await model.load(.plugins)
        #expect(!model.busy)
        client.blockedMethods = []
        for continuation in client.pendingRequests.values { continuation.resume() }
        await skills.value
        #expect(model.loadedSections == [.plugins])
        #expect(!model.busy)
    }

    @Test func supersededManualReadCannotPublishAfterReturningToCacheAndChangingProfile() async {
        let client = WorkflowFixture()
        client.replies["plugins.manage"] = ["plugins": []]
        client.replies["profiles.describe"] = ["name": "research", "skills": [["name": "old", "enabled": true]]]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        await model.load(.plugins)
        client.blockedMethods = ["profiles.describe"]
        let manualRefresh = Task { await model.refresh(section: .skills) }
        for _ in 0..<200 {
            if client.pendingRequests["profiles.describe"] != nil { break }
            await Task.yield()
        }
        await model.load(.plugins)
        await model.useProfile("coding", section: .plugins)
        client.blockedMethods = []
        for continuation in client.pendingRequests.values { continuation.resume() }
        await manualRefresh.value
        #expect(model.service.profileID == "coding")
        #expect(model.skills.isEmpty)
        #expect(model.loadedSections == [.plugins])
    }

    @Test func profilePickerDoesNotFetchPluginOrSessionInventories() async {
        let client = WorkflowFixture()
        client.replies["profiles.list"] = ["profiles": []]
        let inventory = await BotService(client: client).rosterList()
        #expect(inventory.availability == .ready)
        #expect(client.calls.map(\.0) == ["profiles.list"])
    }

    @Test(arguments: ["Enable plugin", "Disable plugin", "Install plugin", "Remove plugin"])
    func pluginMutationsRefreshOnlyPlugins(_ action: String) async {
        let client = WorkflowFixture()
        client.replies["plugins.manage"] = ["ok": true, "plugins": []]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        await model.perform(action, item: WorkflowIntegrationItem(id: "memory", detail: "memory"))
        #expect(client.calls.count == 2)
        #expect(client.calls.allSatisfy { $0.0 == "plugins.manage" })
        #expect(client.calls.last?.1["action"] as? String == "list")
        #expect(!model.busy)
    }

    @Test func pluginChangesInvalidateOtherTabsWithoutReloadingThemImmediately() async {
        let client = WorkflowFixture()
        client.replies["GET"] = ["items": []]
        client.replies["plugins.manage"] = ["ok": true, "plugins": []]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        await model.load(.tools)
        #expect(model.loadedSections == [.tools])
        let priorCalls = client.calls.count
        await model.perform("Enable plugin", item: WorkflowIntegrationItem(id: "memory", detail: "memory"))
        #expect(client.calls.count == priorCalls + 2)
        #expect(model.loadedSections == [.plugins])
        await model.load(.tools)
        #expect(client.calls.count == priorCalls + 3)
        #expect(model.loadedSections == [.plugins, .tools])
    }

    @Test func pluginSettingsSaveRefreshesOnlyItsInventory() async {
        let client = WorkflowFixture()
        client.replies["plugins.manage"] = ["ok": true, "plugins": []]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        let plugin = WorkflowPlugin(
            id: "memory", name: "memory", detail: "", enabled: true,
            removable: true, desktopHalf: false,
            settings: [
                WorkflowPluginSetting(
                    id: "label", label: "Label", detail: "", kind: "string", value: "old",
                    choices: [], env: nil, hasValue: false)
            ])
        await model.saveSettings(plugin, drafts: ["label": "new"])
        #expect(client.calls.count == 2)
        #expect(client.calls.allSatisfy { $0.0 == "plugins.manage" })
        #expect(client.calls.first?.1["action"] as? String == "settings")
        #expect(client.calls.last?.1["action"] as? String == "list")
    }

    @Test func pluginPageProfileChangeInvalidatesItsInventoryCache() async {
        let client = WorkflowFixture()
        client.replies["plugins.manage"] = ["plugins": []]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        await model.load(.plugins)
        await model.useProfile("coding", section: .plugins)
        #expect(client.calls.count == 2)
        #expect(client.calls.last?.1["profile"] as? String == "coding")
        #expect(model.loadedSections == [.plugins])
    }

    @Test func emptyCatalogDoesNotRepeatOrRequestStarsUntilExplicitRefresh() async {
        let client = WorkflowFixture()
        client.replies["GET"] = ["entries": []]
        var starReads = 0
        let model = WorkflowIntegrationModel(client: client, profileID: nil) { _ in
            starReads += 1
            return [:]
        }
        await model.loadCatalog()
        await model.loadCatalog()
        #expect(client.calls.count == 1)
        #expect(starReads == 0)
        await model.loadCatalog(force: true)
        #expect(client.calls.count == 2)
        #expect(starReads == 0)
    }

    @Test func failedCatalogCanRetryAndClearsItsOwnError() async {
        let client = WorkflowFixture()
        let model = WorkflowIntegrationModel(client: client, profileID: nil) { _ in [:] }
        await model.loadCatalog()
        #expect(model.status.contains("Plugin catalog:"))
        client.replies["GET"] = ["entries": [["name": "memory"]]]
        await model.loadCatalog()
        #expect(model.catalog.map(\.id) == ["memory"])
        #expect(!model.status.contains("Plugin catalog:"))
        #expect(!model.catalogLoading)
    }

    @Test func catalogCoalescesConcurrentReadsAndDiscardsCancelledResponses() async {
        let client = WorkflowFixture()
        client.blockCatalog = true
        client.replies["GET"] = ["entries": [["name": "memory"]]]
        let model = WorkflowIntegrationModel(client: client, profileID: nil) { _ in [:] }
        let first = Task { await model.loadCatalog() }
        for _ in 0..<200 {
            if client.catalogContinuation != nil { break }
            await Task.yield()
        }
        await model.loadCatalog()
        #expect(client.calls.count == 1)
        first.cancel()
        client.catalogContinuation?.resume()
        await first.value
        #expect(model.catalog.isEmpty)
        #expect(!model.catalogLoading)
        client.blockCatalog = false
        await model.loadCatalog()
        #expect(client.calls.count == 2)
        #expect(model.catalog.map(\.id) == ["memory"])
    }

    @Test func catalogIndexExcludesInstalledDuplicatesAndPreservesSearchAndRanking() {
        let catalog = [
            WorkflowPluginCatalogEntry(
                id: "official", title: "Official", detail: "Recall", installed: false,
                category: "memory", official: true, repo: URL(string: "https://github.com/acme/official")),
            WorkflowPluginCatalogEntry(
                id: "popular", title: "Popular", detail: "Search", installed: false,
                category: "memory", repo: URL(string: "https://github.com/acme/popular")),
            WorkflowPluginCatalogEntry(id: "local", title: "Local", detail: "", installed: false, category: "local"),
            WorkflowPluginCatalogEntry(id: "installed", title: "Installed", detail: "", installed: true),
        ]
        let index = WorkflowPluginCatalogIndex(
            catalog: catalog + [catalog[0]], installed: ["local"],
            stars: ["acme/official": 2, "acme/popular": 100])
        #expect(index.categories == ["memory"])
        #expect(index.matches("").map(\.id) == ["official", "popular"])
        #expect(index.matches("", byStars: true).map(\.id) == ["popular", "official"])
        #expect(index.matches("RECALL", category: "memory").map(\.id) == ["official"])
        #expect(index.matches("", category: "other").isEmpty)
        #expect(index.matches("", limit: 1).count == 1)
    }

    @Test func catalogIndexTracksAuthoritativePluginChanges() {
        let model = WorkflowIntegrationModel(client: WorkflowFixture(), profileID: nil)
        model.catalog = [WorkflowPluginCatalogEntry(id: "memory", title: "Memory", detail: "", installed: false)]
        #expect(model.catalogIndex.matches("").count == 1)
        model.plugins = [
            WorkflowPlugin(
                id: "memory", name: "memory", detail: "", enabled: true,
                removable: true, desktopHalf: false)
        ]
        #expect(model.catalogIndex.matches("").isEmpty)
        model.plugins = []
        #expect(model.catalogIndex.matches("").count == 1)
    }

    @Test func skillQuickViewLoadsWhileOtherInventoriesAreBusy() async {
        let client = WorkflowFixture()
        client.replies["skills.manage"] = ["info": ["skill_md_preview": "# Example skill"]]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        model.busy = true
        await model.perform("Inspect", item: WorkflowIntegrationItem(id: "example", detail: ""))
        #expect(model.preview == "# Example skill")
        #expect(model.busy)
    }

    @Test func pluginsLoadWhileSkillsAndMCPArePending() async {
        let client = WorkflowFixture()
        client.blockedMethods = ["profiles.describe", "mcp.catalog"]
        client.replies["plugins.manage"] = [
            "plugins": [
                [
                    "name": "memory", "key": "memory", "status": "enabled", "version": "1.2.3",
                    "source": "user", "catalog_version": "1.3.0", "pinned_sha": "abcdef",
                ]
            ]
        ]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        let refresh = Task { await model.refresh() }
        for _ in 0..<200 {
            if model.plugins.count == 1 && client.pendingRequests.count == 2 { break }
            await Task.yield()
        }
        #expect(model.plugins.first?.version == "1.2.3")
        #expect(model.plugins.first?.source == "user")
        #expect(model.plugins.first?.catalogVersion == "1.3.0")
        #expect(model.plugins.first?.pinnedRevision == "abcdef")
        #expect(model.busy)
        client.blockedMethods = []
        for continuation in client.pendingRequests.values { continuation.resume() }
        await refresh.value
        #expect(!model.busy)
        #expect(model.status.contains("Skills:") && model.status.contains("MCP:"))
    }

    @Test func catalogFinishesLoadingBeforeOptionalStars() async {
        let client = WorkflowFixture()
        client.replies["GET"] = ["entries": [["name": "memory", "repo": "https://github.com/acme/memory"]]]
        var starsContinuation: CheckedContinuation<Void, Never>?
        let model = WorkflowIntegrationModel(client: client, profileID: nil) { _ in
            await withCheckedContinuation { starsContinuation = $0 }
            return [:]
        }
        let load = Task { await model.loadCatalog() }
        for _ in 0..<200 {
            if starsContinuation != nil { break }
            await Task.yield()
        }
        #expect(model.catalog.map(\.id) == ["memory"])
        #expect(!model.catalogLoading)
        starsContinuation?.resume()
        await load.value
    }

    @Test func mcpCatalogPreservesTransportAndRequiredKeyNames() async throws {
        let client = WorkflowFixture()
        client.replies["mcp.catalog"] = [
            "servers": [
                [
                    "name": "docs", "installed": true, "enabled": false,
                    "transport": "stdio", "requires": ["DOCS_API_KEY"],
                ]
            ]
        ]
        let servers = try await HermesWorkflowRPC(client: client, profileID: "research").mcpCatalog()
        #expect(servers.first?.transport == "stdio")
        #expect(servers.first?.requiredKeys == ["DOCS_API_KEY"])
        #expect(servers.first?.enabled == false)
    }

    @Test func builtinMarksComeOnlyFromHermesProvenance() async throws {
        let client = WorkflowFixture()
        client.replies["profiles.describe"] = [
            "name": "research", "skills": [["name": "plan", "enabled": true], ["name": "mine", "enabled": true]],
        ]
        client.replies["GET"] = [
            "items": [["name": "plan", "provenance": "bundled"], ["name": "mine", "provenance": "agent"]]
        ]
        client.replies["mcp.catalog"] = [
            "servers": [["name": "docs", "installed": true, "enabled": true]]
        ]
        client.replies["mcp.servers.list"] = ["servers": [["name": "custom", "transport": "http"]]]
        let service = HermesWorkflowRPC(client: client, profileID: "research")
        let skills = try await service.skills()
        #expect(skills.map(\.builtin) == [true, false])
        let servers = try await service.mcpCatalog()
        #expect(servers.map(\.id) == ["docs", "custom"])
        #expect(servers.map(\.builtin) == [true, false])

        client.replies["GET"] = nil
        #expect(try await service.skills().allSatisfy { !$0.builtin })
    }

    @Test func pluginCatalogKeepsCategoryTierAndGitHubSlug() async throws {
        let client = WorkflowFixture()
        client.replies["GET"] = [
            "entries": [
                ["name": "mem", "category": "memory", "tier": "official", "repo": "https://github.com/acme/mem.git"],
                ["name": "web", "repo": "https://gitlab.com/acme/web"],
                ["name": "panel", "category": "desktop"],
            ]
        ]
        let catalog = try await HermesWorkflowRPC(client: client, profileID: nil).pluginCatalog()
        #expect(catalog.map(\.id) == ["mem", "web"])
        #expect(catalog[0].category == "memory" && catalog[0].official && catalog[0].githubSlug == "acme/mem")
        #expect(catalog[1].category == "general" && !catalog[1].official && catalog[1].githubSlug == nil)
    }

    @Test func pluginSettingsSendOnlyChangedTypedValuesAndNeverSecrets() throws {
        let settings = [
            ["key": "on", "type": "boolean", "value": false],
            ["key": "n", "type": "number", "value": 3],
            ["key": "r", "type": "number", "value": 1],
            ["key": "s", "type": "string", "value": "same"],
            ["key": "k", "type": "secret", "env": "API_KEY", "has_value": true],
        ].compactMap(HermesWorkflowRPC.pluginSetting)
        #expect(settings[0].value == "false" && settings[4].env == "API_KEY" && settings[4].hasValue)
        let values = HermesWorkflowRPC.pluginSettingValues(
            settings, drafts: ["on": "true", "n": "4", "r": "0.5", "s": "same", "k": "secret"])
        #expect(values["on"] as? Bool == true && values["n"] as? Int == 4)
        #expect(values["r"] as? Double == 0.5 && values["s"] == nil && values["k"] == nil)
        #expect(HermesWorkflowRPC.validConnectorAlias("work-2"))
        #expect(!HermesWorkflowRPC.validConnectorAlias("-work") && !HermesWorkflowRPC.validConnectorAlias("Work"))
    }

    @Test func sessionCapacityIgnoresSeparateRPCQuota() throws {
        let account: [String: Any] = [
            "id": "account-a", "state": "limited",
            "windows": [
                ["scope": "account", "used_percent": 80, "resets_at": "tomorrow"],
                ["scope": "model", "used_percent": 99],
            ],
        ]
        let single = try SessionCapacitySnapshot.parse(
            session: owner, runtimeID: "runtime", running: false, result: options(accounts: [account]))
        #expect(single.modelID != nil)
        for accounts in [
            [], [account, account], [["state": "ready", "windows": [["used_percent": 90]]]],
        ] {
            let unknown = try SessionCapacitySnapshot.parse(
                session: owner, runtimeID: "runtime", running: false, result: options(accounts: accounts))
            #expect(unknown.modelID == single.modelID)
            #expect(unknown.options == single.options)
        }
    }
    @Test func modelChoiceRequiresIdleConfiguredAcknowledgedSessionScope() async throws {
        let choice = HermesModelOption(provider: "codex", model: "configured")
        for acknowledgment: [String: Any] in [
            [:], ["key": "model", "value": "configured", "scope": "global"],
            ["key": "model", "value": "configured", "scope": "session", "deferred": true],
        ] {
            let client = WorkflowFixture()
            client.replies["model.options"] = options()
            client.replies["config.set"] = acknowledgment
            await refusing {
                try await HermesWorkflowRPC(client: client, profileID: "research").setSessionModel(
                    owner, option: choice)
            }
        }
        let client = WorkflowFixture()
        client.replies["model.options"] = options()
        client.replies["config.set"] = ["key": "model", "scope": "session", "value": "configured"]
        try await HermesWorkflowRPC(client: client, profileID: "research").setSessionModel(
            owner, option: choice)
        let mutation = try #require(client.calls.last)
        #expect(mutation.1["session_id"] as? String == "runtime")
        #expect(mutation.1["profile"] as? String == "research")
    }
    @Test func busySessionAndUnconfiguredModelNeverReachConfigSet() async {
        let client = WorkflowFixture()
        client.replies["session.resume"] = [
            "session_id": "runtime", "stored_session_id": "owner", "profile": "research", "running": true,
        ]
        await refusing {
            try await HermesWorkflowRPC(client: client, profileID: "research").setSessionModel(
                owner, option: HermesModelOption(provider: "x", model: "y"))
        }
        #expect(!client.calls.contains { $0.0 == "config.set" })
        client.replies["session.resume"] = nil
        client.replies["model.options"] = options()
        await refusing {
            try await HermesWorkflowRPC(client: client, profileID: "research").setSessionModel(
                owner, option: HermesModelOption(provider: "x", model: "y"))
        }
        #expect(!client.calls.contains { $0.0 == "config.set" })
    }
    @Test func stoppingAndRoutinePauseRejectNegativeAcknowledgments() async {
        let client = WorkflowFixture()
        client.replies["session.interrupt"] = ["status": "not_interrupted"]
        let service = HermesWorkflowRPC(client: client, profileID: "research")
        await refusing { try await service.stopSession(owner) }
        client.replies["cron.manage"] = [
            "success": true, "job": ["job_id": "different", "enabled": false],
        ]
        await refusing { try await service.setRoutinePaused("job", paused: true) }
        #expect(client.calls.last?.1["profile"] as? String == "research")
    }
    @Test func repeatRoutineTriggersArePreventedAndOwnerIsCaptured() async {
        let client = WorkflowFixture()
        client.replies["cron.manage"] = [
            "scoped": "research",
            "jobs": [["job_id": "job", "name": "Daily", "enabled": true, "schedule": "daily"]],
        ]
        client.replies["POST"] = ["id": "job", "prompt": "Review", "schedule": "daily"]
        let control = ControlCenterModel(
            rpc: HermesControlRPC(client: client),
            capabilities: [
                CapabilityState(
                    id: "cron.runNow", title: "Run now", detail: "Available", isAvailable: true, recovery: nil
                )
            ])
        let reference = RoutineReference(
            profileID: "research",
            job: CronSummary(id: "job", name: "Daily", schedule: "daily", enabled: true, nextRun: nil),
            run: nil)
        async let first: Void = control.recoverRoutine(reference, run: true)
        async let second: Void = control.recoverRoutine(reference, run: true)
        _ = await (first, second)
        #expect(
            client.calls.filter {
                $0.0 == "POST /api/cron/jobs/job/trigger?profile=research"
            }.count == 1)
        #expect(!control.canTriggerRoutine(reference))
        await control.confirmRoutineReview(reference)
        #expect(control.canTriggerRoutine(reference))
        #expect(
            client.calls.filter { $0.0 == "cron.manage" }.allSatisfy {
                $0.1["profile"] as? String == "research"
            })
        #expect(
            !client.calls.contains { $0.0 == "shell.exec" })
    }
    @Test func routineWorkspaceNavigationRetainsOwnerUntilItsInventoryArrives() {
        let control = ControlCenterModel()
        let reference = RoutineReference(
            profileID: "research",
            job: CronSummary(id: "job", name: "Job", schedule: "daily", enabled: true, nextRun: nil),
            run: nil)
        control.requestAutomation(reference)
        #expect(control.requestedAutomationOwner?.profileID == "research")
        #expect(control.requestedAutomationJobID == "job")
        #expect(!control.requestedAutomationMatchesInventory())
        var launch = reference.job
        launch.owner = CronOwner(profileID: nil)
        control.requestAutomation(RoutineReference(profileID: nil, job: launch, run: nil))
        #expect(control.requestedAutomationMatchesInventory())
        #expect(control.profileForRoutine(launch) == nil)
    }
    @Test func routineListingRejectsUnscopedNamedInventory() async {
        let client = WorkflowFixture()
        client.replies["cron.manage"] = ["jobs": [], "scoped": "coding"]
        await refusing {
            _ = try await HermesWorkflowRPC(client: client, profileID: "research").routineJobs()
        }
    }
    @Test func executionAndDeliveryRemainIndependent() {
        let job = CronSummary(
            id: "job", name: "Job", schedule: "daily", enabled: true, nextRun: nil,
            lastRunAt: "2026-10-11T12:00:00Z", lastStatus: "ok",
            details: CronJobDetails(deliveryError: "delivery failed"))
        let reference = RoutineReference(profileID: "research", job: job, run: nil)
        #expect(reference.needsAttention)
        #expect(AutomationWorkspaceRowPresentation.make(job: job, latestRun: nil).result == .succeeded)
        #expect(reference.row.phase == .attention)
        #expect(reference.row.routine?.profileID == "research")
    }
    @Test func oauthCancellationCarriesCapturedProfileAndFlow() async throws {
        let client = WorkflowFixture()
        client.replies["mcp.servers.oauth.cancel"] = ["ok": true]
        try await HermesWorkflowRPC(client: client, profileID: "research").cancelOAuth(
            "docs", flow: "captured-flow")
        #expect(client.calls.last?.1["profile"] as? String == "research")
        #expect(client.calls.last?.1["session_id"] as? String == "captured-flow")
        client.replies["mcp.servers.oauth.start"] = [
            "ok": true, "session_id": "flow", "auth_url": "file:///tmp/credential",
        ]
        await refusing {
            _ = try await HermesWorkflowRPC(client: client, profileID: "research").startOAuth("docs")
        }
    }
    @Test func unsupportedIntegrationOperationDoesNotDisableOthers() async {
        let client = WorkflowFixture()
        client.failures.insert("skills.manage")
        client.replies["mcp.servers.test"] = ["ok": true, "oauth_needed": false, "tools": []]
        let model = WorkflowIntegrationModel(client: client, profileID: "research")
        await model.perform("Inspect", item: WorkflowIntegrationItem(id: "skill", detail: ""))
        #expect(model.unsupported.contains("Inspect"))
        await model.perform("Test", item: WorkflowIntegrationItem(id: "docs", detail: ""))
        #expect(model.status.contains("Connection confirmed"))
    }
    @Test func skillRemovalChecksReturnedProcessInsteadOfAssumingSuccess() async throws {
        let client = WorkflowFixture()
        client.replies["POST"] = ["ok": true, "pid": 123, "name": "skills-uninstall-example-abcd"]
        let service = HermesWorkflowRPC(client: client, profileID: "research")
        let removal = try await service.removeSkill("example")
        client.replies["GET"] = ["name": removal.name, "pid": 124, "running": false, "exit_code": 0]
        await refusing { _ = try await service.skillRemovalOutcome(removal) }
        client.replies["GET"] = ["name": removal.name, "pid": 123, "running": false, "exit_code": 1]
        #expect(try await service.skillRemovalOutcome(removal) == 1)
        #expect(client.calls.first?.1["profile"] as? String == "research")
    }
    @Test func customMCPSetupRejectsEmbeddedCredentials() async {
        let client = WorkflowFixture()
        await refusing {
            try await HermesWorkflowRPC(client: client, profileID: "research").addCustomMCP(
                name: "docs", url: "https://user:secret@example.com/mcp")
        }
        #expect(client.calls.isEmpty)
    }
    @Test func memoryEditingUsesFingerprintsAndNamedProfileHTTP() async throws {
        let client = WorkflowFixture()
        let id = "memory:memory:2:0123456789abcdef"
        client.replies["GET"] = ["ok": true, "id": id, "kind": "memory", "content": "An old decision"]
        let service = HermesWorkflowRPC(client: client, profileID: "research")
        #expect(try await service.memoryDetail(id) == "An old decision")
        try await service.correctMemory(id, content: "Corrected decision")
        #expect(
            client.calls.allSatisfy {
                $0.0.contains("/api/learning/node") && $0.0.contains("profile=research")
            })
        #expect(client.calls.last?.1["profile"] as? String == "research")
        #expect(client.calls.last?.1["id"] as? String == id)
        let previous = client.calls.count
        await refusing {
            try await service.correctMemory("memory:memory:2", content: "Unsafe positional edit")
        }
        #expect(client.calls.count == previous)
    }
    @Test func memoryDetailNeverTruncatesAnEditableEntry() async {
        let client = WorkflowFixture()
        let id = "memory:profile:0:0123456789abcdef"
        client.replies["learning.detail"] = [
            "ok": true, "id": id, "kind": "memory", "content": String(repeating: "x", count: 64_001),
        ]
        await refusing {
            _ = try await HermesWorkflowRPC(client: client, profileID: nil).memoryDetail(id)
        }
    }
    @Test func subagentSteeringRemainsQueuedAndTargetsExactRuntime() async throws {
        let client = WorkflowFixture()
        client.replies["subagent.list"] = [
            "subagents": [
                [
                    "subagent_id": "child", "status": "running", "accepting_steer": true,
                    "goal": "Inspect sources",
                ], ["subagent_id": "finished", "status": "completed"],
            ]
        ]
        client.replies["subagent.steer"] = ["subagent_id": "child", "status": "queued"]
        let service = HermesWorkflowRPC(client: client, profileID: "research")
        let live = try await service.liveSubagents(owner)
        #expect(live.1.map(\.id) == ["child"])
        #expect(
            try await service.steer(sessionID: live.0, subagentID: "child", text: "Use primary sources")
                == .queued)
        #expect(client.calls.last?.1["session_id"] as? String == "runtime")
        #expect(client.calls.last?.1["profile"] as? String == "research")
        client.replies["subagent.steer"] = ["subagent_id": "different", "status": "queued"]
        await refusing {
            _ = try await service.steer(sessionID: live.0, subagentID: "child", text: "Correction")
        }
    }
    @Test func recallRejectsWrongProfileAndDiscardsLateResults() async throws {
        let client = WorkflowFixture()
        let model = EdgeRecallModel()
        client.replies["search"] = [
            "results": [["session_id": "other", "profile": "coding", "snippet": "wrong"]]
        ]
        await model.search("decision", profileID: "research", client: client)
        #expect(model.hits.isEmpty && model.error != nil)
        client.replies["search"] = nil
        client.searchDelay = true
        let old = Task { await model.search("older", profileID: "research", client: client) }
        try await Task.sleep(for: .milliseconds(320))
        await model.search("newer", profileID: "research", client: client)
        await old.value
        #expect(model.hits.map(\.session.id) == ["newer"])
        #expect(
            client.calls.contains { $0.0.contains("profile=research") && $0.0.contains("limit=20") })
    }
    @Test func savedReferencesRetainOriginsButDiscardRuntimeAliases() throws {
        let name = "workflow-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CommandCenterPreferencesStore(defaults: defaults)
        let destination = QuickDestination(
            profileID: "research", sessionID: "owner", runtimeID: "ephemeral", title: "Research",
            projectPath: "/tmp/worktree")
        preferences.pinSource(
            origin: destination, url: "https://example.com/paper", label: "Primary source")
        preferences.pinSource(origin: destination, url: "file:///tmp/private")
        let restored = CommandCenterPreferencesStore(defaults: defaults)
        #expect(restored.sourcePins.first?.origin.runtimeID == nil)
        #expect(
            restored.sourcePins.count == 1 && restored.sourcePins.first?.origin.sessionID == "owner")
    }
    @Test func recallInsertionAndPreviewNavigationPreserveRecipientAndDraft() {
        let state = EdgeNotchState()
        state.selectQuickTarget(owner)
        state.quickDraft = "Existing correction"
        state.insertRecall(
            RecallHit(
                session: HermesSession(
                    id: "source", profileID: "coding", title: "Source", preview: "", startedAt: nil,
                    messageCount: 0, source: "herm"), snippet: "A past decision"))
        #expect(state.captureRecord().destination.sessionID == "owner")
        #expect(state.quickSources.contains("Source conversation: coding/source"))
        state.capacityTarget = owner
        state.steeringTarget = owner
        state.showingRecall = true
        state.clearPreviewDetails()
        #expect(!state.isReadingDetail)
        #expect(state.quickDraft.contains("Existing correction"))
    }
    @Test func isolatedSessionFailureRetainsWorktreeAndReturnedSession() async {
        let client = WorkflowFixture()
        client.replies["session.create"] = ["session_id": "runtime", "stored_session_id": "owner"]
        let result = await HermesWorkflowRPC(client: client, profileID: "research")
            .createIsolatedSession(path: "/tmp/different-worktree", text: "Build this", id: UUID())
        #expect(result.draft.destination.projectPath == "/tmp/different-worktree")
        #expect(result.draft.destination.sessionID == "owner")
        #expect(result.draft.delivery == .needsReview)
        #expect(result.error != nil)
        #expect(!client.calls.contains { $0.0 == "prompt.submit" })
        #expect(client.calls.first?.1["cwd_explicit"] as? Bool == true)
    }
    @Test func baselineRequiresAcknowledgedObservedTurnAndRejectsLateAcknowledgments() {
        let developer = DeveloperWorkflowModel()
        let origin = QuickDestination(profileID: "research", sessionID: "owner")
        let attempt = UUID()
        developer.turnBaselines[origin.sessionKey] = TurnRepositoryBaseline(
            origin: origin, path: "/tmp/worktree", head: "abcdef", clean: true, capturedAt: .now,
            attemptID: attempt)
        developer.observeTurnBaseline(origin: origin, started: true)
        #expect(developer.turnBaselines[origin.sessionKey]?.eligible == false)
        developer.acknowledgeTurnBaseline(origin: origin, attemptID: UUID())
        #expect(developer.turnBaselines[origin.sessionKey]?.acknowledged == false)
        developer.acknowledgeTurnBaseline(origin: origin, attemptID: attempt)
        developer.observeTurnBaseline(origin: origin, completed: true)
        #expect(developer.turnBaselines[origin.sessionKey]?.eligible == true)
        developer.observeTurnBaseline(origin: origin, started: true)
        #expect(developer.turnBaselines[origin.sessionKey] == nil)
    }
    @Test func missingStartAndFailedSubmissionCannotLabelChangesSinceTurnStarted() {
        let developer = DeveloperWorkflowModel()
        let origin = QuickDestination(profileID: "research", sessionID: "owner")
        developer.turnBaselines[origin.sessionKey] = TurnRepositoryBaseline(
            origin: origin, path: "/tmp/worktree", head: "abcdef", clean: true, capturedAt: .now)
        developer.observeTurnBaseline(origin: origin, completed: true)
        #expect(developer.turnBaselines[origin.sessionKey] == nil)
        developer.turnBaselines[origin.sessionKey] = TurnRepositoryBaseline(
            origin: origin, path: "/tmp/worktree", head: "abcdef", clean: true, capturedAt: .now)
        developer.observeTurnBaseline(origin: origin, started: true, failed: true)
        #expect(developer.turnBaselines[origin.sessionKey] == nil)
    }
    @Test func realGitBaselineAndIsolatedWorktreeStayWithinTheFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "herm-workflow-git-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try git(["init", "--quiet"])
        let file = root.appendingPathComponent("decision.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "decision.txt"])
        try git([
            "-c", "user.name=Workflow Fixture", "-c", "user.email=fixture@example.invalid", "commit",
            "--quiet", "-m", "Fixture",
        ])
        let origin = QuickDestination(profileID: "research", sessionID: "owner")
        let developer = DeveloperWorkflowModel()
        await developer.captureTurnBaseline(origin: origin, path: root.path)
        let baseline = try #require(developer.turnBaselines[origin.sessionKey])
        #expect(baseline.clean)
        let head = try #require(baseline.head)
        try "updated".write(to: file, atomically: true, encoding: .utf8)
        #expect(
            try await RepositoryService.changesSince(path: root.path, head: head) == ["decision.txt"])
        #expect(
            try await RepositoryService.diffSince(path: root.path, head: head, file: "decision.txt")
                .contains("+updated"))
        await developer.captureTurnBaseline(origin: origin, path: root.path)
        #expect(developer.turnBaselines[origin.sessionKey]?.clean == false)
        let storage = root.appendingPathComponent("isolated")
        let worktree = try await RepositoryService.createTaskWorktree(
            path: root.path, id: UUID(), storage: storage)
        #expect(worktree.hasPrefix(storage.path))
        #expect(
            try String(
                contentsOf: URL(fileURLWithPath: worktree).appendingPathComponent("decision.txt"),
                encoding: .utf8) == "original")
        #expect(try String(contentsOf: file, encoding: .utf8) == "updated")
        await refusing {
            _ = try await RepositoryService.diffSince(path: root.path, head: head, file: "../outside")
        }
        try git(["worktree", "remove", worktree])
    }
    @Test func renderNewPreviewStatesAtTheFixedGeometry() async throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_DIR"] else { return }
        let client = WorkflowFixture()
        client.replies["model.options"] = options(accounts: [
            ["id": "account-a", "state": "limited", "windows": [["used_percent": 90]]]
        ])
        client.replies["subagent.list"] = [
            "subagents": [
                [
                    "subagent_id": "child", "status": "running", "accepting_steer": true,
                    "goal": "Inspect primary sources",
                ]
            ]
        ]
        let service = HermesWorkflowRPC(client: client, profileID: "research")
        let state = EdgeNotchState()
        state.selectQuickTarget(owner)
        let model = DockModel(initialSessionID: "workspace", rpcClient: client)
        let name = "workflow-render-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = CommandCenterPreferencesStore(defaults: defaults)
        let job = CronSummary(
            id: "job", name: "Daily research", schedule: "daily", enabled: true, nextRun: nil,
            lastStatus: "error", lastError: "Provider unavailable",
            details: CronJobDetails(deliveryError: "Delivery failed separately"))
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        let views: [(String, AnyView)] = [
            (
                "capacity",
                AnyView(EdgeSessionCapacity(destination: owner, control: control, service: service, back: {}, open: {}))
            ),
            (
                "steering",
                AnyView(EdgeSubagentSteering(origin: owner, service: service, back: {}, open: {}))
            ),
            (
                "recall-empty",
                AnyView(
                    EdgeRecallView(
                        profileID: "research", client: client, back: {}, open: { _ in }, insert: { _ in }))
            ),
            (
                "routine-failure",
                AnyView(
                    EdgeRoutinePreview(
                        reference: RoutineReference(profileID: "research", job: job, run: nil),
                        control: control, preferences: preferences, back: {}, openAutomation: {}))
            ),
        ]
        for (name, view) in views {
            let host = NSHostingView(
                rootView: view.background(Color.dockCanvas).dockThemedRoot().frame(width: 368, height: 308)
            )
            host.frame = NSRect(x: 0, y: 0, width: 368, height: 308)
            let window = NSPanel(
                contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(host.frame.size == CGSize(width: 368, height: 308))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("workflow-\(name).png"))
        }
    }
    @Test func routineDigestReconcilesWithoutCopyingReports() {
        let coordinator = HermInterruptionCoordinator()
        coordinator.start()
        let first = HermNotice(
            kind: .completion, source: .routine, profileID: "research", sourceID: "job", eventID: "run-a")
        let next = HermNotice(
            kind: .completion, source: .routine, profileID: "research", sourceID: "job", eventID: "run-b")
        #expect(!coordinator.admit(first, channel: .notch))
        #expect(!coordinator.admit(first, channel: .system))
        #expect(!coordinator.admit(next, channel: .notch))
        #expect(coordinator.entries.count == 2)
        coordinator.reconcileRoutines(profileID: "research", jobIDs: [])
        #expect(coordinator.entries.allSatisfy { $0.unavailable })
        coordinator.reconcileRoutines(profileID: "research", jobIDs: ["job"])
        #expect(coordinator.entries.allSatisfy { !$0.unavailable })
        #expect(
            coordinator.admit(
                HermNotice(
                    kind: .failure, source: .routine, profileID: "research", sourceID: "job", eventID: "run-c"
                ), channel: .notch))
    }
}
