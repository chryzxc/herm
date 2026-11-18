import SwiftUI

@MainActor
final class WorkflowIntegrationModel: ObservableObject {
    @Published private(set) var service: HermesWorkflowRPC
    let client: HermesRPCClientProtocol
    private let starReader: @MainActor ([String]) async -> [String: Int]
    @Published var skills: [WorkflowIntegrationItem] = []
    @Published var servers: [WorkflowIntegrationItem] = []
    @Published var plugins: [WorkflowPlugin] = [] { didSet { rebuildCatalogIndex() } }
    @Published private(set) var pluginsLoading = true
    /// `hermes skills check` result for hub-installed skills; nil until a check finishes.
    @Published private(set) var skillUpdates: [String: String]?
    @Published private(set) var checkingSkillUpdates = false
    /// Skill or plugin id Hermes is updating right now; drives the inline progress.
    @Published private(set) var updatingItem: String?
    /// Catalog name Hermes is installing right now; drives the inline progress.
    @Published private(set) var installingItem: String?
    /// Installed plugin key to reveal once an install lands; the view clears it after selecting it.
    @Published var justInstalled: String?
    /// Plugin id whose last update was refused pending the user's approval of a wider capability set.
    @Published var pluginUpdateConsent: String?
    @Published var connectors: [WorkflowConnector] = []
    @Published var catalog: [WorkflowPluginCatalogEntry] = [] {
        didSet {
            catalogByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rebuildCatalogIndex()
        }
    }
    /// `catalog` by listing id, so each card's lookup does not rescan the catalog.
    private(set) var catalogByID: [String: WorkflowPluginCatalogEntry] = [:]
    private var catalogLoaded = false
    private var starsLoaded = false
    private var catalogTask: Task<Void, Never>?
    @Published private(set) var catalogIndex = WorkflowPluginCatalogIndex()
    @Published private(set) var catalogLoading = false
    @Published private(set) var catalogIsStale = false
    /// `owner/name` → GitHub stars; empty without a launch GitHub token.
    @Published private(set) var stars: [String: Int] = [:] { didSet { rebuildCatalogIndex() } }
    @Published var toolsets: [WorkflowToolset] = []
    @Published var hub: [WorkflowIntegrationItem] = []
    private var connectTask: Task<Void, Never>?
    @Published var status = ""
    @Published var busy = false
    @Published private(set) var staleSections = Set<WorkflowIntegrationSection>()
    @Published private(set) var lastActionSucceeded = false
    @Published private(set) var loadedSections = Set<WorkflowIntegrationSection>()
    private var refreshGeneration = UUID()
    private var refreshOwnsBusy = false
    private var searchOwnsBusy = false
    private var pluginReadGeneration = UUID()
    private var inspectGeneration = UUID()
    var activeSection: WorkflowIntegrationSection?
    @Published private(set) var inspecting = false
    @Published var preview: String?
    @Published var oauth: WorkflowOAuthFlow?
    private var removalTasks: [String: Task<Void, Never>] = [:]
    private var removalProcesses: [String: WorkflowSkillRemoval] = [:]
    @Published private(set) var pendingRemovals = Set<String>()
    private var oauthName: String?
    private var oauthTask: Task<Void, Never>?
    @Published var unsupported = Set<String>()
    init(
        client: HermesRPCClientProtocol, profileID: String?,
        starReader: @escaping @MainActor ([String]) async -> [String: Int] = WorkflowIntegrationModel.cachedGitHubStars
    ) {
        self.client = client
        self.starReader = starReader
        service = HermesWorkflowRPC(client: client, profileID: profileID)
    }
    /// Capabilities' "Configuring:" picker: drop the old profile's inventory, then reload.
    func useProfile(_ profileID: String?, section: WorkflowIntegrationSection? = nil) async {
        guard profileID != service.profileID, !busy else { return }
        resetProfile(profileID)
        await refresh(section: section)
    }
    func resetProfile(_ profileID: String?) {
        cancelActiveReads()
        service = HermesWorkflowRPC(client: client, profileID: profileID)
        (skills, servers, plugins, connectors, toolsets, hub, preview) = ([], [], [], [], [], [], nil)
        skillUpdates = nil
        loadedSections = []
        staleSections = []
        unsupported = []
        status = ""
    }
    /// Asks Hermes which hub skills have upstream changes. A failed check leaves the last answer, never guesses.
    func checkSkillUpdates() async {
        guard !checkingSkillUpdates else { return }
        checkingSkillUpdates = true
        defer { checkingSkillUpdates = false }
        do {
            skillUpdates = try await service.skillUpdates()
        } catch {
            guard !Task.isCancelled else { return }
            status = "Skill update check failed. \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }
    func skillHasUpdate(_ name: String) -> Bool { skillUpdates?[name] == "update_available" }
    func searchHub(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !query.isEmpty else { return }
        let generation = refreshGeneration
        let scope = service
        busy = true
        searchOwnsBusy = true
        defer {
            if generation == refreshGeneration {
                busy = false
                searchOwnsBusy = false
            }
        }
        do {
            let result = try await scope.skills(query: query)
            guard !Task.isCancelled, generation == refreshGeneration, scope === service else { return }
            hub = result
            status = status.split(separator: "\n").filter { !$0.hasPrefix("Skills Hub:") }.joined(separator: "\n")
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration, scope === service else { return }
            hub = []
            status = "Skills Hub: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }
    func load(_ section: WorkflowIntegrationSection?) async {
        if let section, loadedSections.contains(section) {
            // Cached tabs must not wait for a cancelled read in another tab.
            if refreshOwnsBusy {
                refreshGeneration = UUID()
                refreshOwnsBusy = false
                busy = false
            }
            return
        }
        await refresh(section: section)
    }
    func refresh(query: String? = nil, section: WorkflowIntegrationSection? = nil) async {
        let generation = UUID()
        refreshGeneration = generation
        refreshOwnsBusy = refreshOwnsBusy || !busy
        busy = true
        defer {
            if generation == refreshGeneration {
                if refreshOwnsBusy { busy = false }
                refreshOwnsBusy = false
            }
        }
        if let section {
            status = status.split(separator: "\n").filter { !$0.hasPrefix(section.rawValue + ":") }.joined(
                separator: "\n")
            switch section {
            case .skills: await refreshSkills(query: query)
            case .tools: await refreshToolsets()
            case .connectors: await refreshConnectors()
            case .plugins: await refreshPlugins()
            case .mcp: await refreshServers()
            }
            return
        }
        status = ""
        async let skillsRead: Void = refreshSkills(query: query)
        async let serversRead: Void = refreshServers()
        if query == nil {
            async let pluginsRead: Void = refreshPlugins()
            async let connectorsRead: Void = refreshConnectors()
            async let toolsRead: Void = refreshToolsets()
            _ = await (pluginsRead, connectorsRead, toolsRead)
        }
        _ = await (skillsRead, serversRead)
    }
    private func refreshSkills(query: String?) async {
        let requestGeneration = refreshGeneration
        do {
            let result = try await service.skills(query: query)
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            skills = result
            if query == nil {
                staleSections.remove(.skills)
                loadedSections.insert(.skills)
            }
            if query == nil {
                for (id, process) in removalProcesses {
                    if let outcome = try? await service.skillRemovalOutcome(process) {
                        pendingRemovals.remove(id)
                        removalProcesses.removeValue(forKey: id)
                        status +=
                            outcome == 0
                            ? "\nSkills: Removal acknowledged. Inventory refreshed."
                            : "\nSkills: Hermes refused or failed the removal."
                    }
                }
                if !pendingRemovals.isEmpty {
                    status +=
                        "\nSkills: Removal outcomes remain uncertain. Inspect Hermes activity or refresh again before retrying."
                }
            }
        } catch {
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            staleSections.insert(.skills)
            status += "\nSkills: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }
    private func refreshServers() async {
        let requestGeneration = refreshGeneration
        do {
            let result = try await service.mcpCatalog()
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            servers = result
            staleSections.remove(.mcp)
            loadedSections.insert(.mcp)
        } catch {
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            staleSections.insert(.mcp)
            status += "\nMCP: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }
    private func refreshPlugins() async {
        let requestGeneration = refreshGeneration
        let generation = UUID()
        pluginReadGeneration = generation
        pluginsLoading = true
        defer { if pluginReadGeneration == generation { pluginsLoading = false } }
        do {
            let result = try await service.plugins()
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            if result != plugins { loadedSections = [] }
            plugins = result
            staleSections.remove(.plugins)
            loadedSections.insert(.plugins)
        } catch {
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            staleSections.insert(.plugins)
            status += "\nPlugins: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }
    private func refreshConnectors() async {
        let requestGeneration = refreshGeneration
        do {
            let result = try await service.connectors()
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            connectors = result
            staleSections.remove(.connectors)
            loadedSections.insert(.connectors)
        } catch {
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            staleSections.insert(.connectors)
            status +=
                "\nConnectors: Refresh failed; displayed data may be stale. \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }
    private func refreshToolsets() async {
        let requestGeneration = refreshGeneration
        do {
            let result = try await service.toolsets()
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            toolsets = result
            staleSections.remove(.tools)
            loadedSections.insert(.tools)
        } catch {
            guard !Task.isCancelled, requestGeneration == refreshGeneration else { return }
            staleSections.insert(.tools)
            status +=
                "\nTools: Refresh failed; displayed data may be stale. \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
    }
    func perform(
        _ action: String, item: WorkflowIntegrationItem, credentialKey: String = "",
        credential: String = ""
    ) async {
        if action == "Inspect" {
            guard !unsupported.contains(action) else { return }
            let scope = service
            let generation = UUID()
            inspectGeneration = generation
            inspecting = true
            defer { if generation == inspectGeneration { inspecting = false } }
            do {
                let result = try await scope.inspectSkill(item.id)
                guard !Task.isCancelled, scope === service, generation == inspectGeneration else { return }
                preview = result
            } catch {
                guard !Task.isCancelled, scope === service, generation == inspectGeneration else { return }
                if BotService.isUnsupportedMethod(error) { unsupported.insert(action) }
                status += "\nSkills: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
            }
            return
        }
        guard !busy, !unsupported.contains(action) else { return }
        lastActionSucceeded = false
        busy = true
        defer { busy = false }
        do {
            switch action {
            case "Install skill": try await service.installSkill(item.id)
            case "Enable skill", "Disable skill":
                try await service.toggleSkill(item.id, enabled: action == "Enable skill")
            case "Update skill":
                updatingItem = item.id
                defer { updatingItem = nil }
                try await service.updateSkill(item.id)
                await refresh(section: activeSection == nil ? nil : .skills)
                await checkSkillUpdates()
                status =
                    skillUpdates?[item.id] == "update_available"
                    ? "Hermes could not confirm the update for \(item.id). Review it before retrying."
                    : "\(item.id) updated. New sessions use the new version."
                return
            case "Remove skill":
                guard !pendingRemovals.contains(item.id) else { return }
                let removal = try await service.removeSkill(item.id)
                pendingRemovals.insert(item.id)
                status = "Removal started. Waiting for Hermes' recorded outcome."
                removalProcesses[item.id] = removal
                removalTasks[item.id] = Task { [weak self] in
                    guard let self else { return }
                    defer { removalTasks.removeValue(forKey: item.id) }
                    for _ in 0..<30 {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            if let code = try await service.skillRemovalOutcome(removal) {
                                pendingRemovals.remove(item.id)
                                removalProcesses.removeValue(forKey: item.id)
                                await refresh(section: activeSection == nil ? nil : .skills)
                                status =
                                    code == 0
                                    ? "Removal acknowledged. Inventory refreshed."
                                    : "Hermes refused or failed the removal. Review the installed skill before retrying."
                                return
                            }
                        } catch {
                            if !Task.isCancelled {
                                status = "Removal outcome is uncertain. Refresh installed skills before retrying."
                            }
                            return
                        }
                    }
                    status = "Removal is still unconfirmed. Refresh installed skills before retrying."
                }
                return
            case "Enable plugin", "Disable plugin":
                let restart = try await service.togglePlugin(item.id, enabled: action == "Enable plugin")
                status = ""
                loadedSections = []
                await refreshPlugins()
                guard status.isEmpty else { return }
                status =
                    restart
                    ? "Change saved. Restart the Hermes gateway to apply it."
                    : "Change acknowledged. New sessions use the updated plugin set."
                return
            case "Update plugin", "Check for update", "Accept changes and update plugin":
                updatingItem = item.id
                defer { updatingItem = nil }
                let outcome = try await service.updatePlugin(
                    item.detail, acceptCapabilities: action == "Accept changes and update plugin")
                status = ""
                loadedSections = []
                pluginUpdateConsent = nil
                switch outcome {
                case .needsConsent(let delta):
                    pluginUpdateConsent = item.id
                    status = "\(item.detail) update needs approval. It adds:\n\(delta)"
                    return
                case .blocked(let reason):
                    status = HermesDiagnosticsService.safeSummary(reason)
                    return
                case .unchanged:
                    // The update badge may have been stale; read the list again so it clears.
                    await refresh(section: .plugins)
                    status = "\(item.detail) is already up to date."
                    return
                case .updated(let restart):
                    // A fresh generation, so no read that started before the update can overwrite it.
                    await refresh(section: .plugins)
                    guard status.isEmpty else { return }
                    if catalogLoaded { await loadCatalog(force: true) }
                    status =
                        restart
                        ? "\(item.detail) updated. Restart the Hermes gateway to apply it."
                        : "\(item.detail) updated. New sessions use the new version."
                }
                return
            case "Enable toolset", "Disable toolset":
                try await service.setToolset(item.id, enabled: action == "Enable toolset")
                await refresh(section: activeSection == nil ? nil : .tools)
                status =
                    "\(item.detail) \(action == "Enable toolset" ? "enabled" : "disabled"). Changes apply to new sessions."
                return
            case "Install plugin":
                installingItem = item.id
                defer { installingItem = nil }
                try await service.installPlugin(catalogName: item.id)
                status = ""
                loadedSections = []
                await refreshPlugins()
                guard status.isEmpty else { return }
                justInstalled = plugins.first { $0.catalogName == item.id || $0.name == item.id }?.id
                status = "\(item.detail) installed. New sessions can use it."
                if catalogLoaded { await loadCatalog(force: true) }
                return
            case "Remove plugin":
                try await service.removePlugin(item.detail)
                status = ""
                loadedSections = []
                await refreshPlugins()
                guard status.isEmpty else { return }
                if catalogLoaded { await loadCatalog(force: true) }
                if status.isEmpty { status = "Change acknowledged. New sessions use the updated plugin set." }
                return
            case "Enable connector", "Disable connector":
                try await service.setConnectorAllowed(item.id, enabled: action == "Enable connector")
            case "Rename account": try await service.renameConnectorAccount(item.id, alias: item.detail)
            case "Disconnect": try await service.removeConnectorAccount(item.id)
            case "Connect", "Reconnect":
                let started = try await service.connectConnector(item.id, reconnect: action == "Reconnect")
                status = "Waiting for authorization…"
                connectTask?.cancel()
                connectTask = Task { [weak self] in
                    guard let self else { return }
                    var operation = started
                    var opened = false
                    // ponytail: 5-minute poll ceiling; Hermes' own deadline settles the operation sooner.
                    for _ in 0..<150 {
                        if !opened, let url = operation.url {
                            ExternalOpen.open(url)
                            opened = true
                        }
                        if operation.settled { break }
                        do {
                            try await Task.sleep(for: .seconds(2))
                            operation = try await service.connectorOperation(operation.id)
                        } catch {
                            if !Task.isCancelled {
                                status = "Authorization could not be confirmed. Refresh before retrying."
                            }
                            return
                        }
                    }
                    guard !Task.isCancelled else { return }
                    await refresh(section: activeSection == nil ? nil : .connectors)
                    status =
                        operation.connected
                        ? "\(item.detail) connected."
                        : operation.settled
                            ? "Authorization did not complete. Try again when ready."
                            : "Authorization is still pending. Refresh to check."
                }
                return
            case "Reload live sessions": try await service.reloadMCP()
            case "Custom server": try await service.addCustomMCP(name: item.id, url: item.detail)
            case "Add server": try await service.addMCP(item.id)
            case "Remove server": try await service.removeMCP(item.id)
            case "Save credential":
                try await service.setMCPCredential(item.id, key: credentialKey, value: credential)
            case "Test":
                status = try await service.testMCP(item.id)
                return
            case "Authorize":
                let flow = try await service.startOAuth(item.id)
                oauth = flow
                oauthName = item.id
                ExternalOpen.open(flow.url)
                oauthTask = Task { [weak self] in
                    guard let self else { return }
                    for _ in 0..<120 {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            let result = try await service.pollOAuth(item.id, flow: flow.id)
                            if result != .pending {
                                oauth = nil
                                oauthName = nil
                                await refresh(section: activeSection == nil ? nil : .mcp)
                                status =
                                    result == .approved
                                    ? "Authorization confirmed. Test the connection."
                                    : "Authorization failed. Try again when ready."
                                return
                            }
                        } catch {
                            if !Task.isCancelled {
                                status = "Authorization could not be confirmed. Cancel or check the provider."
                            }
                            return
                        }
                    }
                    await cancelOAuth()
                }
                status = "Waiting for authorization…"
                return
            default: return
            }
            await refresh(section: activeSection)
            lastActionSucceeded = true
            let readStatus = status
            status =
                "Change acknowledged. New sessions use the updated configuration; an explicit runtime reload may be needed for existing sessions."
            if !readStatus.isEmpty { status += "\n" + readStatus }
        } catch {
            if BotService.isUnsupportedMethod(error) { unsupported.insert(action) }
            status =
                action == "Save credential"
                ? "Credential change could not be confirmed. Review configuration before retrying."
                : HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }
    private func rebuildCatalogIndex() {
        catalogIndex = WorkflowPluginCatalogIndex(catalog: catalog, installed: Set(plugins.map(\.name)), stars: stars)
    }
    /// GitHub stars outlive one Capabilities visit: one fetch per hour for the same repositories.
    /// A partial answer (rate limit, a repository GitHub no longer has) is kept for two minutes only.
    private static var starCache: (slugs: Set<String>, stars: [String: Int], expires: Date)?
    static func cachedGitHubStars(_ slugs: [String]) async -> [String: Int] {
        if let cache = starCache, Date() < cache.expires, cache.slugs.isSuperset(of: slugs) { return cache.stars }
        let stars = await HermesWorkflowRPC.githubStars(slugs)
        if !stars.isEmpty {
            let complete = Set(slugs).isSubset(of: stars.keys)
            starCache = (Set(slugs), stars, Date().addingTimeInterval(complete ? 3600 : 120))
        }
        return stars
    }
    /// Several views ask for the catalog at once (the Plugins list, Installed cards, the
    /// catalog disclosure). They all join one model-owned fetch, so a caller whose view is
    /// torn down mid-load cannot discard the answer the others are waiting for.
    func loadCatalog(force: Bool = false) async {
        if catalogTask == nil, !catalogLoaded || force || !starsLoaded {
            let fetchCatalog = !catalogLoaded || force
            catalogTask = Task { [weak self] in
                await self?.fetchCatalog(includingList: fetchCatalog)
                self?.catalogTask = nil
            }
        }
        await catalogTask?.value
    }
    private func fetchCatalog(includingList: Bool) async {
        if includingList {
            catalogLoading = true
            defer { catalogLoading = false }
            status = status.split(separator: "\n").filter { !$0.hasPrefix("Plugin catalog:") }.joined(separator: "\n")
            do {
                catalog = try await service.pluginCatalog()
                catalogLoaded = true
                catalogIsStale = false
            } catch {
                catalogIsStale = true
                status += "\nPlugin catalog: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
                return
            }
        }
        guard !starsLoaded else { return }
        let slugs = catalog.compactMap(\.githubSlug)
        guard !slugs.isEmpty else {
            starsLoaded = true
            return
        }
        stars = await starReader(slugs)
        starsLoaded = true
    }
    /// Plain fields go through `plugins.manage settings`; secrets through Hermes' env store.
    @discardableResult
    func saveSettings(_ plugin: WorkflowPlugin, drafts: [String: String]) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let values = HermesWorkflowRPC.pluginSettingValues(plugin.settings, drafts: drafts)
            if !values.isEmpty { try await service.savePluginSettings(plugin.id, values: values) }
            for setting in plugin.settings where setting.kind == "secret" {
                guard let env = setting.env, let secret = drafts[setting.id], !secret.isEmpty else { continue }
                try await service.setPluginSecret(env: env, value: secret)
            }
            status = ""
            loadedSections = []
            await refreshPlugins()
            guard status.isEmpty else { return false }
            status = "\(plugin.name) settings saved. Restart the Hermes gateway if the plugin reads them at startup."
            return true
        } catch {
            status = HermesDiagnosticsService.safeSummary(error.localizedDescription)
            return false
        }
    }
    /// Load errors are tagged by kind ("Connectors: …"); show a tab only its own, plus untagged results.
    func sectionStatus(_ section: WorkflowIntegrationSection) -> String {
        let tags = ["Skills", "Skills Hub", "Tools", "Connectors", "Plugins", "Plugin catalog", "MCP"]
        let own: Set<String> =
            switch section {
            case .skills: ["Skills", "Skills Hub"]
            case .plugins: ["Plugins", "Plugin catalog"]
            default: [section.rawValue]
            }
        return status.split(separator: "\n").filter { line in
            guard let tag = line.split(separator: ":").first.map(String.init), tags.contains(tag) else { return true }
            return own.contains(tag)
        }.joined(separator: "\n")
    }
    func cancelActiveReads() {
        refreshGeneration = UUID()
        pluginReadGeneration = UUID()
        inspectGeneration = UUID()
        inspecting = false
        if refreshOwnsBusy || searchOwnsBusy {
            busy = false
            refreshOwnsBusy = false
            searchOwnsBusy = false
        }

        for task in removalTasks.values { task.cancel() }
        removalTasks = [:]
        connectTask?.cancel()
    }
    func cancelOAuth() async {
        oauthTask?.cancel()
        guard let flow = oauth, let name = oauthName else { return }
        do {
            try await service.cancelOAuth(name, flow: flow.id)
            oauth = nil
            oauthName = nil
            status = "Authorization cancelled."
        } catch {
            status = "Cancellation could not be confirmed. Close the provider authorization page."
        }
    }
}

struct WorkflowIntegrationView: View {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    /// Mirrors Hermes Desktop's Capabilities tabs, plus MCP servers which Desktop keeps elsewhere.
    typealias Section = WorkflowIntegrationSection
    /// One master-list row on the Capabilities page.
    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        var badge: (DockStatusTone, String)?
        /// Enablement is a row status; mutations belong to the inspector.
        var on: Bool?
        /// Discover-only: list section header, GitHub stars, curated-tier mark.
        var group = ""
        var stars: Int?
        var official = false
        /// Hermes reports the item as shipped with the agent; never inferred.
        var builtin = false
        /// Hermes reports a newer version upstream.
        var update = false
        var logoURL: URL?
        /// Installed plugins: Hermes' category, when it reports one.
        var category: String?
        /// Plugins tab: whether the plugin's Hermes Desktop page opens in Herm.
        var tag: String?
    }
    let destination: IntegrationDestination
    let workspace: IntegrationsWorkspaceState?
    /// Non-nil renders the full-page Capabilities surface with tabs instead of the modal.
    var pageSection: Binding<Section>?
    @StateObject private var model: WorkflowIntegrationModel
    @ObservedObject private var desktopPlugins = DesktopPluginStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Cards built so far. Hermes returns whole inventories, so paging bounds the views built at once.
    @State private var shownCount = Self.pageSize
    private static let pageSize = 30
    @State private var request: (String, WorkflowIntegrationItem)?
    @State private var selectedServer: WorkflowIntegrationItem?
    @State private var customName = ""
    @State private var customURL = ""
    @State private var credentialKey = ""
    @State private var credential = ""
    @State private var pluginQuery = ""
    @State private var editingPlugin: String?
    @State private var pluginDrafts: [String: String] = [:]
    @State private var renaming: String?
    @State private var alias = ""
    @State private var localBrowsing = IntegrationsBrowsingState()
    @State private var showsCustomServer = false
    private var browsing: IntegrationsBrowsingState {
        get { workspace?.currentBrowsing ?? localBrowsing }
        nonmutating set {
            if let workspace { workspace.currentBrowsing = newValue } else { localBrowsing = newValue }
        }
    }
    private var selection: String? {
        get { browsing.selection }
        nonmutating set { browsing.selection = newValue }
    }
    private var filter: String {
        get { browsing.search }
        nonmutating set { browsing.search = newValue }
    }
    private var discover: Bool {
        get { browsing.discover }
        nonmutating set { browsing.discover = newValue }
    }
    private var category: String {
        get { browsing.pluginCategory }
        nonmutating set { browsing.pluginCategory = newValue }
    }
    private var byStars: Bool {
        get { browsing.byStars }
        nonmutating set { browsing.byStars = newValue }
    }

    init(
        destination: IntegrationDestination, client: HermesRPCClientProtocol,
        pageSection: Binding<Section>? = nil
    ) {
        self.destination = destination
        self.workspace = nil
        self.pageSection = pageSection
        _model = StateObject(
            wrappedValue: WorkflowIntegrationModel(client: client, profileID: destination.profileID))
    }
    init(workspace: IntegrationsWorkspaceState, section: Section) {
        self.destination = IntegrationDestination(profileID: workspace.profileID)
        self.workspace = workspace
        self.pageSection = .constant(section)
        _model = StateObject(wrappedValue: workspace.workflow)
    }
    private var hasPendingEdits: Bool {
        !credential.isEmpty || !customName.isEmpty || !customURL.isEmpty || !alias.isEmpty
            || model.plugins.contains { plugin in
                !HermesWorkflowRPC.pluginSettingValues(plugin.settings, drafts: pluginDrafts).isEmpty
                    || plugin.settings.contains { $0.kind == "secret" && !(pluginDrafts[$0.id] ?? "").isEmpty }
            }
    }
    private func discardEditors() {
        credential = ""
        customName = ""
        customURL = ""
        alias = ""
        renaming = nil
        selectedServer = nil
        pluginDrafts = [:]
        showsCustomServer = false
    }
    var body: some View {
        Group {
            if let pageSection {
                page(pageSection)
            } else {
                DockModal(
                    title: "Integrations", subtitle: "Profile: \(destination.profileID ?? "Launch profile")",
                    width: 520, contentPadding: 0
                ) {
                    ScrollView { sections }.frame(height: 440)
                } footer: {
                    HStack {
                        if model.busy { ProgressView() }
                        Spacer()
                        Button("Done") { dismiss() }.buttonStyle(.dockSecondary)
                    }
                }
            }
        }
        .task(id: pageSection?.wrappedValue) {
            model.activeSection = pageSection?.wrappedValue
            if workspace == nil { await model.load(pageSection?.wrappedValue) }
        }
        .task(id: pageSection?.wrappedValue == .plugins) { await desktopPlugins.refresh() }
        .onChange(of: hasPendingEdits) { _, value in
            workspace?.isDirty = value
            if value { browsing.showsDetail = true }
        }
        .onChange(of: workspace?.discardRevision) { discardEditors() }
        .dockSheet(isPresented: $showsCustomServer) {
            DockModal(
                title: "Add custom server", subtitle: "Profile: \(profileName(model.service.profileID))", width: 400
            ) {
                customServerCard
            } footer: {
                Button("Cancel") {
                    discardEditors()
                    workspace?.isDirty = false
                }.buttonStyle(.dockSecondary).disabled(model.busy)
            }
            .interactiveDismissDisabled(hasPendingEdits || model.busy)
            .confirmationDialog(
                "Add custom server?",
                isPresented: Binding(
                    get: { request?.0 == "Custom server" }, set: { if !$0 { request = nil } }
                )
            ) {
                Button("Add server", action: confirmRequestedAction)
                Button("Keep editing", role: .cancel) { request = nil }
            } message: {
                Text(confirmationMessage)
            }
        }
        .onDisappear {
            credential = ""
            pluginDrafts = [:]
            model.cancelActiveReads()
            Task { await model.cancelOAuth() }
        }
        .confirmationDialog(
            "\(request?.0 ?? "Change integration")?",
            isPresented: Binding(get: { request != nil && !showsCustomServer }, set: { if !$0 { request = nil } })
        ) {
            Button(request?.0 ?? "Confirm", action: confirmRequestedAction)
            Button("Cancel", role: .cancel) {
                request = nil
                credential = ""
            }
        } message: {
            Text(confirmationMessage)
        }
    }
    private func confirmRequestedAction() {
        guard let (action, item) = request else { return }
        request = nil
        let value = credential
        let key = credentialKey
        Task {
            await model.perform(action, item: item, credentialKey: key, credential: value)
            if model.lastActionSucceeded {
                credential = ""
                if action == "Custom server" { discardEditors() }
            }
        }
    }
    static func isAccountAction(_ action: String) -> Bool {
        ["Connect", "Reconnect", "Disconnect", "Rename account", "Enable connector", "Disable connector"].contains(
            action)
    }
    private var confirmationMessage: String {
        if Self.isAccountAction(request?.0 ?? "") {
            return
                "\(request?.0 ?? "Change connection"): \(request?.1.detail ?? "Connection"). This changes your account connection or member access policy, not only this profile."
        }
        return
            "\(request?.0 == "Reload live sessions" ? "Reload affects all live sessions connected to this Hermes runtime. " : "")\((request?.0.hasSuffix(" plugin") == true || request?.0.hasSuffix(" connector") == true || ["Disconnect", "Reconnect"].contains(request?.0) ? request?.1.detail : request?.1.id) ?? "Integration") in profile \(model.service.profileID ?? "Launch profile"). Hermes performs its own installation and authorization checks."
    }
    private var sections: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Connectors", count: model.connectors.count) {
                ForEach(model.connectors) { connector in connectorRow(connector) }
            }
            Group {
                group("Plugins", count: model.plugins.count) {
                    ForEach(model.plugins) { plugin in pluginRow(plugin) }
                }
                DisclosureGroup("Install from the plugin catalog") {
                    VStack(alignment: .leading, spacing: 8) {
                        DockTextField("Search plugins", text: $pluginQuery).textFieldStyle(.dockGlass)
                        Text("Plugins that only extend Hermes Desktop, or don't run on macOS, are hidden.")
                            .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        card {
                            ForEach(catalogMatches(pluginQuery, limit: 20)) { entry in
                                row(entry.title, entry.detail) {
                                    action("Install plugin", WorkflowIntegrationItem(id: entry.id, detail: entry.title))
                                }
                            }
                        }
                    }.dockPadding(.top, 8)
                }.dockFont(.body).task { await model.loadCatalog() }
                    .disclosureGroupStyle(DockDisclosureGroupStyle())
            }
            Group {
                HStack {
                    DockTextField("Search skill hub", text: $query).textFieldStyle(.dockGlass)
                        .onSubmit { Task { await model.refresh(query: query.isEmpty ? nil : query) } }
                    DockAsyncButton("Search") { await model.refresh(query: query.isEmpty ? nil : query) }
                        .buttonStyle(.dockSecondary)
                    if !query.isEmpty {
                        Button("Installed") {
                            query = ""
                            Task { await model.refresh() }
                        }.buttonStyle(.dockCompact)
                    }
                }.disabled(model.busy)
                group("Skills", count: model.skills.count) {
                    ForEach(model.skills) { item in
                        row(item.id, item.detail) {
                            if item.installed {
                                toggle(item.enabled, enable: "Enable skill", disable: "Disable skill", item)
                            } else {
                                action("Install skill", item)
                            }
                            moreMenu {
                                Button("Inspect") { Task { await model.perform("Inspect", item: item) } }
                                if item.installed {
                                    Button("Remove skill…", role: .destructive) { request = ("Remove skill", item) }
                                        .disabled(model.pendingRemovals.contains(item.id))
                                }
                            }
                        }
                    }
                }
                if let preview = model.preview {
                    Text(preview).dockFont(.body).textSelection(.enabled)
                        .dockPadding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .dockWell(radius: 10)
                }
                MemoryCorrectionView(service: model.service)
                group("MCP servers", count: model.servers.count) {
                    ForEach(model.servers) { item in
                        row(item.id, item.detail) {
                            if item.installed {
                                action("Test", item, confirm: false)
                                moreMenu {
                                    Button("Authorize…") { request = ("Authorize", item) }.disabled(model.oauth != nil)
                                    if !item.requiredKeys.isEmpty {
                                        Button("Credential…") {
                                            selectedServer = item
                                            credentialKey = item.requiredKeys.first ?? ""
                                            credential = ""
                                        }
                                    }
                                    Divider()
                                    Button("Remove server…", role: .destructive) { request = ("Remove server", item) }
                                }
                            } else {
                                action("Add server", item)
                            }
                        }
                    }
                }
                if let item = selectedServer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Credential for \(item.id)").dockFont(.body, weight: .semibold)
                        DockOptionPicker(
                            label: "Required key", selection: $credentialKey,
                            options: item.requiredKeys.map { ($0, $0) })
                        SecureField("Credential", text: $credential).textFieldStyle(.dockGlass)
                        Button("Save credential…") { request = ("Save credential", item) }
                            .buttonStyle(.dockSecondary).disabled(credential.isEmpty)
                    }
                }
                DisclosureGroup("Add an HTTP MCP server") {
                    VStack(alignment: .leading, spacing: 8) {
                        DockTextField("Server name", text: $customName).textFieldStyle(.dockGlass)
                        DockTextField("HTTP or HTTPS URL", text: $customURL).textFieldStyle(.dockGlass)
                        Button("Add custom server…") {
                            request = ("Custom server", WorkflowIntegrationItem(id: customName, detail: customURL))
                        }.buttonStyle(.dockSecondary).disabled(
                            model.busy || customName.isEmpty || customURL.isEmpty)
                    }.dockPadding(.top, 8)
                }.dockFont(.body)
                    .disclosureGroupStyle(DockDisclosureGroupStyle())
                HStack {
                    Button("Reload live sessions…") {
                        request = (
                            "Reload live sessions", WorkflowIntegrationItem(id: "Live runtime sessions", detail: "")
                        )
                    }.buttonStyle(.dockSecondary).disabled(
                        model.busy || model.unsupported.contains("Reload live sessions"))
                    if model.oauth != nil {
                        Button("Cancel authorization") { Task { await model.cancelOAuth() } }
                            .buttonStyle(.dockSecondary)
                    }
                }
            }
            if !model.status.isEmpty {
                Text(model.status).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }
        }.dockPadding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
    // MARK: Capabilities page
    // One list per kind with an Installed / Discover scope, a themed inspector beside it.
    // Built from Dock tokens (dockListRow, dockCard, dockSwitch, DockTabBar) so every skin restyles it.

    private func page(_ tab: Binding<Section>) -> some View {
        let section = tab.wrappedValue
        let canDiscover = [.skills, .plugins, .mcp].contains(section)
        let inventory = visibleEntries(section, discovering: canDiscover && discover)
        let list = inventory.filter {
            browsing.statusFilter.includes(enabled: $0.on, tone: $0.badge?.0, update: $0.update)
        }
        let current = list.first { $0.id == selection } ?? list.first
        return IntegrationLibraryLayout(
            showsDetail: browsing.showsDetail,
            close: { if !hasPendingEdits { browsing.showsDetail = false } }
        ) {
            VStack(alignment: .leading, spacing: 20) {
                IntegrationLibraryHeader(
                    title: workspace?.category.title ?? section.rawValue, summary: summary(section, list: inventory),
                    symbol: workspace?.category.icon ?? .puzzlePiece,
                    purpose: workspace?.category.purpose ?? "")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { pageControls(section, canDiscover: canDiscover) }
                    VStack(alignment: .leading, spacing: 8) { pageControls(section, canDiscover: canDiscover) }
                }
            }
        } library: {
            let totals = Dictionary(grouping: list, by: \.group).mapValues(\.count)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(grouped(Array(list.prefix(shownCount))), id: \.0) { name, rows in
                        if !name.isEmpty {
                            DockSectionLabel(title: name.uppercased(), count: totals[name] ?? rows.count)
                                .dockPadding(.top, 6)
                        }
                        IntegrationInventoryList {
                            ForEach(rows) { entry in
                                card(entry, selected: browsing.showsDetail && entry.id == current?.id)
                            }
                        }
                    }
                    if list.count > shownCount {
                        HStack(spacing: 12) {
                            Button("Show \(min(Self.pageSize, list.count - shownCount)) more") {
                                shownCount += Self.pageSize
                            }.buttonStyle(.dockSecondary)
                            Text("Showing \(shownCount) of \(list.count)").dockFont(.metadata)
                                .foregroundStyle(Color.dockMetadataText).monospacedDigit()
                        }.dockPadding(.top, 8)
                    }
                    if list.isEmpty {
                        if browsing.statusFilter != .all && !inventory.isEmpty {
                            IntegrationFilterEmptyState { browsing.statusFilter = .all }
                        } else {
                            emptyList(section, loading: model.busy || (discover && model.catalogLoading))
                        }
                    }
                }.dockPadding(.bottom, 14)
            }
            .onChange(of: "\(section)|\(discover)|\(filter)|\(category)|\(browsing.statusFilter)|\(byStars)") {
                shownCount = Self.pageSize
            }
        } inspector: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let current {
                            inspector(section, current).disabled(
                                model.busy || model.staleSections.contains(section)
                                    || (discover && section == .plugins && model.catalogIsStale))
                        } else {
                            emptyList(section, loading: model.busy)
                        }
                    }.dockPadding(24).frame(maxWidth: 720, alignment: .leading).frame(
                        maxWidth: .infinity, alignment: .leading)
                }
                if hasPendingEdits {
                    HStack {
                        Text("Unsaved changes").dockFont(.body)
                        Spacer()
                        Button("Discard") {
                            discardEditors()
                            workspace?.isDirty = false
                        }.buttonStyle(.dockSecondary)
                    }.dockPadding(12)
                }
                Text(model.sectionStatus(section)).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(2).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).dockPadding(
                        .horizontal, 20)
            }
            .task(id: section == .skills && !discover ? [model.service.profileID, current?.id] : nil) {
                model.preview = nil
                guard section == .skills, !discover, let current else { return }
                await model.perform("Inspect", item: WorkflowIntegrationItem(id: current.id, detail: current.subtitle))
            }
        }
        .onChange(of: discover) {
            selection = nil
            browsing.statusFilter = .all
            browsing.showsDetail = false
        }
        .onChange(of: category) {
            selection = nil
            browsing.showsDetail = false
        }
        .onChange(of: list.map(\.id)) { _, ids in
            // An install moves its row from Discover to Installed; `justInstalled` reselects it there.
            if let selection, !ids.contains(selection), model.installingItem == nil {
                self.selection = nil
                browsing.showsDetail = false
            }
        }
        // Installed cards also read the catalog, for their category, tier and stars.
        .task(id: section == .plugins) { if section == .plugins { await model.loadCatalog() } }
        .onChange(of: model.justInstalled) { _, key in
            guard let key else { return }
            model.justInstalled = nil
            discover = false
            selection = key
            browsing.showsDetail = true
        }
        .task(id: section == .skills && model.loadedSections.contains(.skills) ? model.service.profileID ?? "" : nil) {
            if section == .skills, model.loadedSections.contains(.skills), model.skillUpdates == nil {
                await model.checkSkillUpdates()
            }
        }
        .dockButtonSize(.compact)
    }
    /// Scope, search and catalog filters; laid out as one toolbar row when the grid has room.
    @ViewBuilder
    private func pageControls(_ section: Section, canDiscover: Bool) -> some View {
        if canDiscover {
            DockTabBar(options: [false, true], selection: binding(\.discover)) { $0 ? "Discover" : "Installed" }
                .fixedSize().disabled(hasPendingEdits || model.busy)
        }
        DockTextField(
            discover && section == .skills ? "Search the Skills Hub" : "Search \(section.rawValue.lowercased())",
            text: binding(\.search)
        ).textFieldStyle(.dockGlass).frame(minWidth: 180, maxWidth: 320)
            .disabled(hasPendingEdits || model.busy)
            .onSubmit { if discover && section == .skills { Task { await model.searchHub(filter) } } }
        if discover && section == .skills {
            DockAsyncButton("Search Skills Hub") { await model.searchHub(filter) }
                .buttonStyle(.dockSecondary).fixedSize()
                .disabled(model.busy || filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if !discover && section != .mcp {
            IntegrationStatusPicker(
                selection: binding(\.statusFilter),
                options: section == .connectors
                    ? [.all, .needsSetup]
                    : section == .tools
                        ? [.all, .enabled, .disabled, .needsSetup]
                        : [.all, .enabled, .disabled, .updates]
            )
            .disabled(hasPendingEdits || model.busy)
        }
        if !filter.isEmpty {
            Button("Clear filter") { filter = "" }.buttonStyle(.dockSecondary).fixedSize().disabled(hasPendingEdits)
        }
        if discover && section == .plugins && !model.catalog.isEmpty {
            DockMenuPicker(
                title: category.isEmpty ? "All categories" : category.capitalized,
                selection: binding(\.pluginCategory)
            ) {
                DockMenuOption("All categories", value: "")
                ForEach(catalogCategories, id: \.self) { DockMenuOption($0.capitalized, value: $0) }
            }.fixedSize().disabled(hasPendingEdits)
            if !model.stars.isEmpty {
                DockSegmentedPicker(selection: binding(\.byStars), options: [(true, "Stars"), (false, "A–Z")])
                    .fixedSize()
            }
        }
        if section == .skills && !discover {
            DockAsyncButton(model.checkingSkillUpdates ? "Checking…" : "Check for updates") {
                await model.checkSkillUpdates()
            }
            .buttonStyle(.dockSecondary).fixedSize()
            .disabled(model.busy || model.checkingSkillUpdates)
        }
        if section == .mcp && discover {
            Button("Add custom server") { showsCustomServer = true }.buttonStyle(.dockSecondary).fixedSize()
                .disabled(hasPendingEdits || model.busy || model.staleSections.contains(section))
        }
    }
    private func binding<Value>(_ key: WritableKeyPath<IntegrationsBrowsingState, Value>) -> Binding<Value> {
        Binding(get: { browsing[keyPath: key] }, set: { browsing[keyPath: key] = $0 })
    }
    private func profileName(_ id: String?) -> String {
        guard let id else { return "Launch profile" }
        return workspace?.profiles.first { $0.id == id }?.name ?? id
    }
    private func summary(_ section: Section, list: [Entry]) -> String {
        if !discover && !model.loadedSections.contains(section) {
            return model.busy ? "Reading inventory…" : "Refresh to read inventory."
        }
        if discover && section == .plugins && model.catalogLoading { return "Fetching the catalog from Hermes…" }
        if discover && section == .skills && model.hub.isEmpty { return "Search to find skills to install." }
        if discover { return "\(list.count) available" }
        let switches = list.compactMap(\.on)
        let attention = list.filter { $0.badge?.0 == .attention }.count
        var parts = ["\(list.count) \(list.count == 1 ? "item" : "items")"]
        if !switches.isEmpty { parts.append("\(switches.filter { $0 }.count) enabled") }
        if attention > 0 { parts.append("\(attention) need attention") }
        let updates = list.filter(\.update).count
        if updates > 0 { parts.append("\(updates) \(updates == 1 ? "update" : "updates") available") }
        if section == .skills && model.checkingSkillUpdates { parts.append("checking for updates…") }
        return parts.joined(separator: " · ")
    }
    @ViewBuilder
    private func emptyList(_ section: Section, loading: Bool) -> some View {
        if loading {
            DockLoadingState(
                title: discover && section == .plugins
                    ? "Loading plugin catalog…" : "Loading \(section.rawValue.lowercased())…",
                minHeight: 160)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    model.staleSections.contains(section)
                        ? "\(section.rawValue) unavailable"
                        : filter.isEmpty
                            ? "No \(section.rawValue.lowercased()) to show"
                            : "No matching \(section.rawValue.lowercased())"
                )
                .dockFont(.body, weight: .semibold)
                Text(
                    discover && section == .skills
                        ? "Search the Skills Hub to find skills to install."
                        : !filter.isEmpty
                            ? "Clear the filter or try another name."
                            : discover
                                ? "Available additions will appear here."
                                : "Refresh the inventory or browse Discover where available."
                )
                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
            }.frame(maxWidth: .infinity, alignment: .leading).dockPadding(12)
        }
    }
    /// Installed rows for a tab; Discover swaps in hub, catalog, or not-yet-added MCP servers.
    private func visibleEntries(_ section: Section, discovering: Bool) -> [Entry] {
        var rows: [Entry]
        if discovering {
            switch section {
            case .skills:
                let installed = Set(model.skills.map(\.id))
                rows = model.hub.filter { !installed.contains($0.id) }.map {
                    Entry(id: $0.id, title: $0.id, subtitle: $0.detail)
                }
                return unique(rows)
            case .plugins:
                return model.catalogIndex.matches(filter, category: category, byStars: byStars).map {
                    Entry(
                        id: $0.id, title: $0.title, subtitle: $0.detail, group: category.isEmpty ? $0.category : "",
                        stars: $0.githubSlug.flatMap { model.stars[$0] }, official: $0.official,
                        category: WorkflowPlugin.categoryLabel($0.category))
                }
            default:
                rows = model.servers.filter { !$0.installed }.map {
                    Entry(id: $0.id, title: $0.id, subtitle: $0.detail, builtin: $0.builtin)
                }
            }
        } else {
            rows = entries(section).filter { section != .mcp || $0.badge != nil }
        }
        return unique(
            rows.filter {
                filter.isEmpty || "\($0.title) \($0.subtitle)".localizedCaseInsensitiveContains(filter)
            })
    }
    /// Consecutive runs of one `group`; rows arrive sorted by group, so each name appears once.
    private func grouped(_ rows: [Entry]) -> [(String, [Entry])] {
        var out: [(String, [Entry])] = []
        for row in rows {
            if out.last?.0 == row.group { out[out.count - 1].1.append(row) } else { out.append((row.group, [row])) }
        }
        return out
    }
    private var catalogCategories: [String] { model.catalogIndex.categories }
    /// The catalog listing an install came from; only known once the catalog has been fetched.
    private func catalogEntry(for plugin: WorkflowPlugin) -> WorkflowPluginCatalogEntry? {
        model.catalogByID[plugin.catalogName.isEmpty ? plugin.name : plugin.catalogName]
    }
    /// ForEach needs unique ids; Hermes can list a name twice (e.g. a skill in two categories).
    private func unique(_ rows: [Entry]) -> [Entry] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }
    private func entries(_ section: Section) -> [Entry] {
        switch section {
        case .skills:
            return model.skills.map {
                Entry(
                    id: $0.id, title: $0.id, subtitle: $0.detail, on: $0.enabled, builtin: $0.builtin,
                    update: model.skillHasUpdate($0.id))
            }
        case .tools:
            return model.toolsets.map {
                Entry(
                    id: $0.id, title: $0.label, subtitle: "\($0.tools.count) \($0.tools.count == 1 ? "tool" : "tools")",
                    badge: $0.configured ? nil : (.attention, "Setup"), on: $0.enabled)
            }
        case .connectors:
            return model.connectors.map {
                Entry(id: $0.id, title: $0.name, subtitle: $0.detail, badge: connectorBadge($0), logoURL: $0.logoURL)
            }
        case .plugins:
            let agent = model.plugins.map { plugin in
                let listing = catalogEntry(for: plugin)
                return Entry(
                    id: plugin.id, title: plugin.name, subtitle: plugin.detail, on: plugin.enabled,
                    stars: listing?.githubSlug.flatMap { model.stars[$0] }, official: listing?.official == true,
                    builtin: plugin.source == "bundled", update: plugin.hasCatalogUpdate,
                    category: plugin.keyCategory ?? listing.map { WorkflowPlugin.categoryLabel($0.category) },
                    tag: desktopPlugin(for: plugin).map(desktopTag))
            }
            // Desktop halves with no agent plugin row (installed straight into desktop-plugins/). Until the
            // agent inventory loads, those rows would pass for the whole installed list, so wait for it.
            guard model.loadedSections.contains(.plugins) else { return agent }
            let matched = Set(model.plugins.compactMap { desktopPlugin(for: $0)?.id })
            let desktopOnly = desktopPlugins.plugins.filter { !matched.contains($0.id) }.map {
                Entry(
                    id: Self.desktopEntryPrefix + $0.id, title: $0.name, subtitle: $0.description ?? "",
                    tag: desktopTag($0))
            }
            return agent + desktopOnly
        case .mcp:
            return model.servers.filter(\.installed).map {
                Entry(
                    id: $0.id, title: $0.id, subtitle: $0.detail, badge: (.complete, "Added"), builtin: $0.builtin)
            }
        }
    }
    private func connectorBadge(_ connector: WorkflowConnector) -> (DockStatusTone, String) {
        if !connector.allowed { return (.inactive, "Blocked") }
        if ["failed", "expired", "revoked"].contains(connector.status ?? "") { return (.attention, "Reconnect") }
        return connector.connected ? (.complete, "Connected") : (.queued, "Available")
    }
    private func artworkSymbol(_ entry: Entry) -> Ph {
        guard pageSection?.wrappedValue == .connectors else { return workspace?.category.icon ?? .puzzlePiece }
        switch entry.id.lowercased() {
        case "notion": return .notionLogo
        case "slack": return .slackLogo
        case "discord", "discordbot": return .discordLogo
        case "github": return .githubLogo
        default: return workspace?.category.icon ?? .plugsConnected
        }
    }
    private func card(_ entry: Entry, selected: Bool) -> some View {
        IntegrationInventoryRow(
            title: entry.title, detail: entry.subtitle == entry.title ? "" : entry.subtitle,
            status: model.updatingItem == entry.id
                ? (.working, "Updating…")
                : model.installingItem == entry.id && discover
                    ? (.working, "Installing…")
                    : entry.badge ?? entry.on.map { $0 ? (.complete, "Enabled") : (.inactive, "Disabled") },
            builtin: entry.builtin, official: entry.official, stars: entry.stars, update: entry.update,
            category: entry.category, tag: entry.tag, selected: selected,
            action: {
                selection = entry.id
                browsing.showsDetail = true
            }
        ) {
            IntegrationArtwork(url: entry.logoURL, symbol: artworkSymbol(entry), size: 36)
        }
        .disabled(hasPendingEdits)
    }
    /// Identity block shared by every tab: glyph, name, live state, scope, then Hermes' own description.
    private func inspectorHeader(_ entry: Entry, pills: [(DockStatusTone, String)], _ text: String) -> some View {
        IntegrationInspectorHeader(
            title: entry.title,
            category: workspace?.category.title ?? pageSection?.wrappedValue.rawValue ?? "Integration",
            scope: scopeLine, detail: text
        ) {
            IntegrationArtwork(url: entry.logoURL, symbol: artworkSymbol(entry), size: 48)
        } status: {
            DockChipFlow(spacing: 6) {
                ForEach(pills.indices, id: \.self) { DockStatusPill(tone: pills[$0].0, text: pills[$0].1) }
                if entry.builtin { IntegrationBuiltinPill() }
                if let category = entry.category {
                    Text(category).dockFont(.metadata).foregroundStyle(Color.dockSecondaryText).dockPill()
                }
                if let stars = entry.stars {
                    IntegrationStars(count: stars).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
            }
        }
    }
    /// Hermes reports no byte or step progress for installs or updates, so this stays indeterminate
    /// rather than invent a percentage.
    private func updateProgress(_ name: String, installing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DockIcon(installing ? .downloadSimple : .arrowCircleUp, size: 14, color: .dockAccent)
                Text("\(installing ? "Installing" : "Updating") \(name)…").dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Spacer(minLength: 0)
            }
            ProgressView().progressViewStyle(.linear).tint(Color.dockAccent)
            Text(
                installing
                    ? "Hermes is fetching, security-scanning and installing it. This can take a minute."
                    : "Hermes is fetching, security-scanning and installing the new version. This can take a minute."
            )
            .dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockCard(padding: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(installing ? "Installing" : "Updating") \(name)")
    }
    private func skillSource(_ name: String) -> String {
        guard let updates = model.skillUpdates else { return "" }
        return updates[name] == nil ? "Local" : "Skills Hub"
    }
    private func skillUpdateLabel(_ name: String) -> String {
        if model.checkingSkillUpdates { return "Checking…" }
        guard let updates = model.skillUpdates else { return "Not checked" }
        switch updates[name] {
        case "update_available": return "New version available"
        case "up_to_date": return "Up to date"
        case "unavailable": return "Source unreachable"
        case "orphaned", "invalid_install": return "Install is damaged"
        default: return "Not tracked by the Skills Hub"
        }
    }
    private var scopeLine: String {
        pageSection?.wrappedValue == .connectors
            ? "Account connection" : "Profile · \(profileName(model.service.profileID))"
    }
    /// Primary actions lead; the destructive one sits apart on the trailing edge.
    private func actionBar<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.dockBorderLight.frame(height: DockLayout.hairline)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    HStack(spacing: 8) { leading() }.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    trailing()
                }
                VStack(alignment: .leading, spacing: 12) {
                    DockChipFlow(spacing: 8) { leading() }
                    trailing()
                }
            }
            Color.dockBorderLight.frame(height: DockLayout.hairline)
        }
        .dockButtonSize(.standard)
    }
    private func panel<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DockSectionLabel(title: title.uppercased())
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func enabledPill(_ on: Bool) -> (DockStatusTone, String) {
        on ? (.complete, "Enabled") : (.inactive, "Disabled")
    }
    private var appliesNote: some View {
        Label("Changes apply to new sessions.", systemImage: "info.circle").dockFont(.metadata)
            .foregroundStyle(Color.dockMetadataText)
    }
    private func destructive(_ title: String, _ request: (String, WorkflowIntegrationItem)) -> some View {
        Button(title, role: .destructive) { self.request = request }
            .buttonStyle(.dockSecondary).foregroundStyle(Color.dockDestructive)
            .disabled(model.busy)
    }
    @ViewBuilder
    private func inspector(_ section: Section, _ entry: Entry) -> some View {
        if discover {
            inspectorHeader(
                entry, pills: [(.queued, "Not installed")] + (entry.official ? [(.review, "Official")] : []),
                entry.subtitle)
            switch section {
            case .skills: action("Install skill", WorkflowIntegrationItem(id: entry.id, detail: entry.subtitle))
            case .plugins:
                if model.installingItem == entry.id {
                    updateProgress(entry.title, installing: true)
                } else {
                    DockChipFlow(spacing: 8) {
                        action("Install plugin", WorkflowIntegrationItem(id: entry.id, detail: entry.title))
                        if let plugin = model.catalogByID[entry.id] { catalogLinks(plugin) }
                    }
                }
                if let plugin = model.catalogByID[entry.id] {
                    catalogDetails(plugin)
                }
            default:
                if let server = model.servers.first(where: { $0.id == entry.id }) { action("Add server", server) }
            }
            appliesNote
        } else {
            switch section {
            case .skills:
                if let skill = model.skills.first(where: { $0.id == entry.id }) {
                    inspectorHeader(
                        entry,
                        pills: [enabledPill(skill.enabled)]
                            + (model.skillHasUpdate(skill.id) ? [(.review, "Update available")] : []),
                        skill.detail)
                    if model.updatingItem == skill.id {
                        updateProgress(skill.id)
                    } else if model.skillHasUpdate(skill.id) {
                        DockCallout(
                            tone: .info, icon: .arrowCircleUp, title: "New version available",
                            message: "The Skills Hub has a newer \(skill.id). Hermes keeps your copy if you edited it."
                        ) {
                            Button("Update skill") { request = ("Update skill", skill) }
                                .buttonStyle(.dockPrimary)
                                .disabled(model.busy || model.unsupported.contains("Update skill"))
                        }
                    }
                    actionBar {
                        action(skill.enabled ? "Disable skill" : "Enable skill", skill, confirm: false)
                    } trailing: {
                        destructive("Remove…", ("Remove skill", skill))
                            .disabled(model.pendingRemovals.contains(skill.id))
                    }
                    quickDetails([
                        ("Skill", skill.id), ("Source", skill.builtin ? "Bundled with Hermes" : skillSource(skill.id)),
                        ("Updates", skillUpdateLabel(skill.id)),
                    ])
                    panel("SKILL.md") {
                        if let preview = model.preview {
                            MarkdownMessageView(
                                markdown: Self.withoutFrontmatter(preview), cacheKey: "skill:\(skill.id)"
                            )
                            .dockPadding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .dockWell(radius: DockLayout.paneRadius, role: .pane)
                        } else if model.inspecting {
                            DockLoadingState(title: "Loading skill instructions…", minHeight: 100)
                        } else {
                            Label("Skill preview unavailable. Refresh to try again.", systemImage: "doc.text")
                                .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                                .dockPadding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    appliesNote
                }
            case .tools:
                if let toolset = model.toolsets.first(where: { $0.id == entry.id }) {
                    inspectorHeader(
                        entry,
                        pills: [enabledPill(toolset.enabled)]
                            + (toolset.configured ? [] : [(.attention, "Needs setup")]),
                        toolset.detail)
                    actionBar {
                        action(
                            toolset.enabled ? "Disable toolset" : "Enable toolset",
                            WorkflowIntegrationItem(id: toolset.id, detail: toolset.label), confirm: false)
                    }
                    quickDetails([
                        ("Toolset", toolset.id), ("Configuration", toolset.configured ? "Configured" : "Needs setup"),
                        ("Tools", String(toolset.tools.count)),
                    ])
                    if !toolset.configured {
                        DockCallout(
                            tone: .warning, icon: .warning, title: "Needs setup",
                            message: "Add this toolset's provider keys in Hermes before enabling it."
                        ) { EmptyView() }
                    }
                    if !toolset.tools.isEmpty {
                        panel("\(toolset.tools.count) TOOLS") {
                            DockChipFlow(spacing: 6) {
                                ForEach(toolset.tools, id: \.self) { tool in
                                    Text(tool).dockFont(.metadata, design: .monospaced)
                                        .foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
                                        .dockPill()
                                }
                            }
                        }
                    }
                    appliesNote
                }
            case .connectors:
                if let connector = model.connectors.first(where: { $0.id == entry.id }) {
                    inspectorHeader(entry, pills: [connectorBadge(connector)], connector.detail)
                    quickDetails([
                        ("Connector", connector.id), ("Policy", connector.allowed ? "Allowed" : "Blocked"),
                        ("Connection", connector.status ?? (connector.connected ? "Connected" : "Not connected")),
                        ("Accounts", String(connector.accounts.count)),
                    ])
                    Text(
                        connector.policyWritable == true
                            ? "Member access rules are editable."
                            : connector.policyWritable == false
                                ? "Access rules are read-only for this account."
                                : "Access-rule availability could not be verified. Refresh to check."
                    )
                    .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    panel(connector.accounts.isEmpty ? "CONNECTION" : "ACCOUNTS") { connectorRow(connector) }
                }
            case .plugins:
                if let plugin = model.plugins.first(where: { $0.id == entry.id }) {
                    let item = WorkflowIntegrationItem(id: plugin.id, detail: plugin.name)
                    inspectorHeader(
                        entry,
                        pills: [enabledPill(plugin.enabled)]
                            + (plugin.hasCatalogUpdate ? [(.review, "Update available")] : []),
                        plugin.detail)
                    if let listing = catalogEntry(for: plugin) {
                        DockChipFlow(spacing: 12) { catalogLinks(listing) }
                    }
                    if model.updatingItem == plugin.id {
                        updateProgress(plugin.name)
                    } else if plugin.hasCatalogUpdate {
                        DockCallout(
                            tone: .info, icon: .arrowCircleUp, title: "New version available",
                            message: plugin.catalogVersion.isEmpty || plugin.catalogVersion == plugin.version
                                ? "Upstream has new commits for this plugin."
                                : "Version \(plugin.catalogVersion) is available; \(plugin.version) is installed."
                        ) {
                            Button(
                                plugin.catalogVersion.isEmpty || plugin.catalogVersion == plugin.version
                                    ? "Update plugin" : "Update to \(plugin.catalogVersion)"
                            ) { request = ("Update plugin", item) }
                            .buttonStyle(.dockPrimary).disabled(
                                model.busy || model.unsupported.contains("Update plugin"))
                        }
                    }
                    if model.pluginUpdateConsent == plugin.id {
                        DockCallout(
                            tone: .warning, icon: .warning, title: "Update needs approval",
                            message: "It widens what this plugin can do. Review the status message before accepting."
                        ) {
                            action("Accept changes and update plugin", item)
                        }
                    }
                    actionBar {
                        action(plugin.enabled ? "Disable plugin" : "Enable plugin", item, confirm: false)
                        if plugin.removable && !plugin.hasCatalogUpdate {
                            action("Check for update", item).help("Ask Hermes to pull or re-pin this plugin")
                        }
                    } trailing: {
                        if plugin.removable { destructive("Remove…", ("Remove plugin", item)) }
                    }
                    quickDetails([
                        ("Version", plugin.version),
                        ("Catalog version", plugin.catalogVersion == plugin.version ? "" : plugin.catalogVersion),
                        ("Source", plugin.source), ("Package", plugin.id),
                        ("Pinned revision", String(plugin.pinnedRevision.prefix(12))),
                    ])
                    if let page = desktopPlugin(for: plugin) {
                        desktopPagePanel(page)
                    } else if plugin.desktopHalf {
                        DockCallout(
                            tone: .info, icon: .info, title: "Desktop panel unavailable",
                            message: "Its Hermes Desktop panel can't run in Herm; the plugin's agent tools still load."
                        ) { EmptyView() }
                    }
                    if !plugin.settings.isEmpty { panel("SETTINGS") { settingsForm(plugin) } }
                } else if entry.id.hasPrefix(Self.desktopEntryPrefix),
                    let page = desktopPlugins.plugin(String(entry.id.dropFirst(Self.desktopEntryPrefix.count)))
                {
                    inspectorHeader(entry, pills: [], page.description ?? "A Hermes Desktop plugin.")
                    desktopPagePanel(page)
                }
            case .mcp:
                if let server = model.servers.first(where: { $0.id == entry.id }) {
                    inspectorHeader(entry, pills: [(.complete, "Added")], server.detail)
                    actionBar {
                        action("Test", server, confirm: false)
                        action("Authorize", server)
                        if !server.requiredKeys.isEmpty {
                            Button("Credential…") {
                                selectedServer = server
                                credentialKey = server.requiredKeys.first ?? ""
                                credential = ""
                            }.buttonStyle(.dockSecondary)
                        }
                    } trailing: {
                        destructive("Remove…", ("Remove server", server))
                    }
                    quickDetails([
                        ("Server", server.id), ("State", server.enabled ? "Enabled" : "Disabled"),
                        ("Transport", server.transport), ("Required keys", server.requiredKeys.joined(separator: ", ")),
                    ])
                    if let item = selectedServer, item.id == server.id {
                        panel("CREDENTIAL") {
                            DockOptionPicker(
                                label: "Required key", selection: $credentialKey,
                                options: item.requiredKeys.map { ($0, $0) })
                            SecureField("Credential", text: $credential).textFieldStyle(.dockGlass)
                            Button("Save credential…") { request = ("Save credential", item) }
                                .buttonStyle(.dockSecondary).disabled(credential.isEmpty)
                        }.dockFont(.body)
                    }
                    DockChipFlow(spacing: 8) {
                        Button("Reload live sessions…") {
                            request = (
                                "Reload live sessions", WorkflowIntegrationItem(id: "Live runtime sessions", detail: "")
                            )
                        }.buttonStyle(.dockCompact).disabled(
                            model.busy || model.unsupported.contains("Reload live sessions"))
                        if model.oauth != nil {
                            Button("Cancel authorization") { Task { await model.cancelOAuth() } }.buttonStyle(
                                .dockCompact)
                        }
                    }
                }
            }
        }
    }
    /// Source and docs links a catalog listing carries, for both Discover and Installed details.
    @ViewBuilder
    private func catalogLinks(_ plugin: WorkflowPluginCatalogEntry) -> some View {
        if let repo = plugin.repo {
            Button {
                ExternalOpen.open(repo)
            } label: {
                Label {
                    Text(plugin.githubSlug == nil ? "Source" : "GitHub")
                } icon: {
                    DockIcon(.githubLogo, size: 12)
                }
            }.buttonStyle(.dockLink)
        }
        if let docs = plugin.docs, docs != plugin.repo {
            Button {
                ExternalOpen.open(docs)
            } label: {
                Label {
                    Text("Docs")
                } icon: {
                    DockIcon(.bookOpen, size: 12)
                }
            }.buttonStyle(.dockLink)
        }
    }
    private func catalogDetails(_ plugin: WorkflowPluginCatalogEntry) -> some View {
        // Category and stars sit in the header pills.
        quickDetails([
            ("Tier", plugin.official ? "Official" : "Community"), ("Maintainer", plugin.maintainer),
            ("Version", plugin.version), ("Package", plugin.id),
        ])
    }
    /// SKILL.md opens with YAML frontmatter, which reads as noise once rendered.
    private static func withoutFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---\n"),
            let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func quickDetails(_ values: [(String, String)]) -> some View {
        let rows = values.filter { !$0.1.isEmpty }
        return panel("DETAILS") {
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(label).foregroundStyle(Color.dockMetadataText)
                            .frame(width: 96, alignment: .leading)
                        (label == "Pinned revision" && value.utf8.allSatisfy(DockCommitPresentation.isHex)
                            ? DockCommitPresentation.text(value, length: nil, scale: workspaceScale) : Text(value))
                            .foregroundStyle(Color.dockPrimaryText).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .dockFont(.body).dockPadding(.vertical, 10)
                    if label != rows.last?.0 {
                        Color.dockBorderLight.frame(height: DockLayout.hairline)
                    }
                }
            }
        }
    }
    private var customServerCard: some View {
        panel("CUSTOM HTTP SERVER") {
            DockTextField("Server name", text: $customName).textFieldStyle(.dockGlass)
            DockTextField("https://…", text: $customURL).textFieldStyle(.dockGlass)
            Button("Add server…") {
                request = ("Custom server", WorkflowIntegrationItem(id: customName, detail: customURL))
            }.buttonStyle(.dockSecondary).disabled(
                model.busy || customName.isEmpty || customURL.isEmpty)
            Text(model.sectionStatus(.mcp)).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                .lineLimit(3).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        }
    }
    private func connectorRow(_ connector: WorkflowConnector) -> some View {
        let item = WorkflowIntegrationItem(id: connector.id, detail: connector.name)
        let broken = ["failed", "expired", "revoked"].contains(connector.status ?? "")
        return VStack(alignment: .leading, spacing: 0) {
            row(connector.name, connector.detail) {
                if !connector.allowed {
                    DockStatusPill(tone: .inactive, text: "Blocked")
                } else if broken {
                    DockStatusPill(tone: .attention, text: "Needs reconnect")
                    action("Reconnect", item)
                } else if connector.connected {
                    DockStatusPill(tone: .complete, text: "Connected")
                } else {
                    action("Connect", item)
                }
                moreMenu {
                    if connector.allowed {
                        Button("Disable connector…") { request = ("Disable connector", item) }
                            .disabled(connector.policyWritable != true)
                    } else {
                        Button("Enable connector…") { request = ("Enable connector", item) }
                            .disabled(connector.policyWritable != true)
                    }
                }
            }
            ForEach(connector.accounts) { account in
                HStack(spacing: 8) {
                    DockIcon(.user, size: 11, color: .dockMetadataText)
                    if renaming == account.id {
                        DockTextField("account-name", text: $alias).textFieldStyle(.dockGlass)
                            .onSubmit { saveAlias(account.id) }
                        Button("Save") { saveAlias(account.id) }.buttonStyle(.dockSecondary)
                            .disabled(model.busy || !HermesWorkflowRPC.validConnectorAlias(alias))
                        Button("Cancel") { renaming = nil }.buttonStyle(.dockCompact)
                    } else {
                        Text(account.label).dockFont(.body)
                        Text(account.status).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                        Spacer()
                        moreMenu {
                            Button("Rename…") {
                                renaming = account.id
                                alias = ""
                            }
                            Button("Disconnect…", role: .destructive) {
                                request = ("Disconnect", WorkflowIntegrationItem(id: account.id, detail: account.label))
                            }
                        }
                    }
                }.dockPadding(.leading, 12).dockPadding(.bottom, 8)
            }
        }
    }
    private static let desktopEntryPrefix = "desktop-plugin:"
    /// The Desktop half of an agent plugin; Desktop names its folder after the package id or name.
    private func desktopPlugin(for plugin: WorkflowPlugin) -> HermesDesktopPlugin? {
        desktopPlugins.plugin(matching: plugin.id) ?? desktopPlugins.plugin(matching: plugin.name)
    }
    private func desktopTag(_ plugin: HermesDesktopPlugin) -> String {
        switch plugin.compatibility {
        case .runsInHerm: "Page in Herm"
        case .needs: "Needs a newer Herm"
        case .desktopOnly: "Desktop-only"
        case .unknown: "Not checked"
        case .hostMissing: "Page unavailable"
        }
    }
    /// Why a plugin's Hermes Desktop page can't open in Herm; a page that can is already in More destinations.
    @ViewBuilder private func desktopPagePanel(_ page: HermesDesktopPlugin) -> some View {
        switch page.compatibility {
        case .runsInHerm:
            EmptyView()
        case .needs(let names):
            DockCallout(
                tone: .warning, icon: .warning, title: "Page can't open in Herm yet",
                message: "It uses Hermes Desktop features Herm doesn't provide: \(names.joined(separator: ", "))."
            ) { EmptyView() }
        case .desktopOnly:
            DockCallout(
                tone: .info, icon: .info, title: "No page to open",
                message:
                    "It only changes Hermes Desktop itself, such as panes or themes, so there is nothing to show in Herm."
            ) { EmptyView() }
        case .unknown:
            DockCallout(
                tone: .info, icon: .info, title: "Not checked",
                message: "Herm couldn't read which Hermes Desktop features this plugin uses."
            ) { EmptyView() }
        case .hostMissing:
            DockCallout(
                tone: .warning, icon: .warning, title: "Page unavailable in this build",
                message: "This build of Herm doesn't include the Hermes Desktop plugin host, so the page can't open."
            ) { EmptyView() }
        }
    }
    private func pluginRow(_ plugin: WorkflowPlugin) -> some View {
        let item = WorkflowIntegrationItem(id: plugin.id, detail: plugin.name)
        return VStack(alignment: .leading, spacing: 0) {
            row(
                plugin.name, plugin.detail,
                note: plugin.desktopHalf && desktopPlugin(for: plugin)?.compatibility != .runsInHerm
                    ? "Its Hermes Desktop panel isn't available in Herm; agent tools still load." : nil
            ) {
                if !plugin.settings.isEmpty {
                    Button(editingPlugin == plugin.id ? "Done" : "Settings") {
                        editingPlugin = editingPlugin == plugin.id ? nil : plugin.id
                        pluginDrafts = [:]
                    }.buttonStyle(.dockSecondary)
                }
                toggle(plugin.enabled, enable: "Enable plugin", disable: "Disable plugin", item)
                if plugin.removable {
                    moreMenu {
                        Button("Remove plugin…", role: .destructive) { request = ("Remove plugin", item) }
                    }
                }
            }
            if editingPlugin == plugin.id { settingsForm(plugin) }
        }
    }
    private func saveAlias(_ id: String) {
        guard HermesWorkflowRPC.validConnectorAlias(alias) else { return }
        let value = alias
        Task {
            await model.perform("Rename account", item: WorkflowIntegrationItem(id: id, detail: value))
            if model.lastActionSucceeded {
                renaming = nil
                alias = ""
            }
        }
    }
    private func group<Content: View>(_ title: String, count: Int, @ViewBuilder _ content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            DockSectionLabel(title: title, count: count)
            if count == 0 {
                Text(model.busy ? "Loading…" : "Nothing here yet.").dockFont(.body)
                    .foregroundStyle(Color.dockMetadataText)
            } else {
                card(content)
            }
        }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .dockPadding(.horizontal, 12)
            .dockWell(radius: 10)
    }
    /// One line per item: name (plus a description only when it adds something), controls trailing.
    private func row<Trailing: View>(
        _ title: String, _ detail: String, note: String? = nil, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).dockFont(.navigation, weight: .medium).foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                if !detail.isEmpty, detail != title {
                    Text(detail).dockFont(.body).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
                }
                if let note {
                    Text(note).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .dockPadding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dockBorderLight).frame(height: 0.5) }
    }
    /// Reversible on/off, so it applies directly rather than through the confirmation dialog.
    private func toggle(_ on: Bool, enable: String, disable: String, _ item: WorkflowIntegrationItem)
        -> some View
    {
        Toggle(
            "",
            isOn: Binding(
                get: { on },
                set: { value in
                    Task { await model.perform(value ? enable : disable, item: item) }
                })
        )
        .toggleStyle(.dockSwitch).labelsHidden()
        .disabled(model.busy || model.unsupported.contains(on ? disable : enable))
        .help(on ? disable : enable)
    }
    private func moreMenu<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        DockMenu(content: content) { DockIcon(.dotsThree, size: 14, color: .dockSecondaryText) }
            .frame(width: 26, height: 26).contentShape(Rectangle())
            .disabled(model.busy).help("More actions")
    }
    private func catalogMatches(_ query: String, limit: Int = .max) -> [WorkflowPluginCatalogEntry] {
        model.catalogIndex.matches(query, limit: limit)
    }
    private func settingsForm(_ plugin: WorkflowPlugin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(plugin.settings) { setting in
                let draft = Binding(
                    get: { pluginDrafts[setting.id] ?? (setting.kind == "secret" ? "" : setting.value) },
                    set: { pluginDrafts[setting.id] = $0 })
                VStack(alignment: .leading, spacing: 3) {
                    switch setting.kind {
                    case "boolean":
                        Toggle(
                            setting.label,
                            isOn: Binding(
                                get: { draft.wrappedValue == "true" },
                                set: { draft.wrappedValue = $0 ? "true" : "false" }))
                    case "enum":
                        DockOptionPicker(
                            label: setting.label, selection: draft, options: setting.choices.map { ($0, $0) })
                    case "secret":
                        Text(setting.label).dockFont(.body)
                        SecureField(setting.hasValue ? "Saved — leave blank to keep" : "Not set", text: draft)
                            .textFieldStyle(.dockGlass)
                    default:
                        Text(setting.label).dockFont(.body)
                        DockTextField(setting.label, text: draft).textFieldStyle(.dockGlass)
                    }
                    if !setting.detail.isEmpty {
                        Text(setting.detail).dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                    }
                }
            }
            Button("Save settings") {
                let drafts = pluginDrafts
                Task {
                    if await model.saveSettings(plugin, drafts: drafts) {
                        pluginDrafts = [:]
                        editingPlugin = nil
                    }
                }
            }.buttonStyle(.dockSecondary).disabled(model.busy || !hasPendingEdits)
        }.dockFont(.body).dockPadding(10)
    }
    private func action(_ action: String, _ item: WorkflowIntegrationItem, confirm: Bool = true)
        -> some View
    {
        Button(action) {
            if confirm {
                request = (action, item)
            } else {
                Task { await model.perform(action, item: item) }
            }
        }.buttonStyle(.dockSecondary).disabled(
            model.busy || model.unsupported.contains(action)
                || (action == "Remove skill" && model.pendingRemovals.contains(item.id))
                || (action == "Authorize" && model.oauth != nil)
        )
        .help(
            model.unsupported.contains(action)
                ? "This installed runtime does not support this operation." : action)
    }
}
