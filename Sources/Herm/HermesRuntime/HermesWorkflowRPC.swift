import Foundation

struct WorkflowIntegrationItem: Identifiable, Equatable {
    let id: String
    let detail: String
    var installed = false
    var enabled = false
    var requiredKeys: [String] = []
    var transport = ""
}
struct WorkflowPlugin: Identifiable, Equatable {
    /// Canonical registry key; toggles address this, removal addresses `name`.
    let id: String
    let name: String
    let detail: String
    let enabled: Bool
    let removable: Bool
    /// The package also ships a Hermes Desktop UI half, which Herm cannot host.
    let desktopHalf: Bool
    var settings: [WorkflowPluginSetting] = []
    var version = ""
    var source = ""
    var status = ""
    var catalogVersion = ""
    var pinnedRevision = ""
}
struct WorkflowPluginSetting: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    /// string, number, boolean, enum or secret.
    let kind: String
    let value: String
    let choices: [String]
    /// Secret fields name an env var instead of carrying a value.
    let env: String?
    let hasValue: Bool
}
struct WorkflowPluginCatalogEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let installed: Bool
    var category = "general"
    var official = false
    var maintainer = ""
    var version = ""
    var repo: URL?
    var docs: URL?
    /// `owner/name` when the repo lives on GitHub, the key for star counts.
    var githubSlug: String? {
        guard let repo, repo.host == "github.com" else { return nil }
        let parts = repo.path.split(separator: "/").prefix(2)
        guard parts.count == 2 else { return nil }
        return parts.joined(separator: "/").replacingOccurrences(of: ".git", with: "")
    }
}
struct WorkflowToolset: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let enabled: Bool
    let configured: Bool
    let tools: [String]
}
struct WorkflowConnectorAccount: Identifiable, Equatable {
    let id: String
    let label: String
    let status: String
}
struct WorkflowConnector: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    /// False when connector policy blocks it.
    let allowed: Bool
    let connected: Bool
    let status: String?
    let accounts: [WorkflowConnectorAccount]
    /// Nil means the policy read was unavailable; only a verified member revision enables edits.
    var policyWritable: Bool? = nil
}
struct WorkflowConnectorOperation: Equatable {
    let id: String
    let url: URL?
    let settled: Bool
    let connected: Bool
}
struct WorkflowSkillRemoval {
    let name: String
    let pid: Int
}
struct WorkflowOAuthFlow: Equatable {
    let id: String
    let url: URL
}
struct WorkflowMemoryEntry: Identifiable {
    let id: String
    let label: String
}
struct WorkflowSubagent: Identifiable {
    let id: String
    let goal: String
    let accepting: Bool
}
enum WorkflowSteeringOutcome: String { case queued, rejected }
enum WorkflowOAuthStatus: Equatable { case pending, approved, failed }

/// One Mixture of Agents provider/model slot (`moa.presets.<name>.reference_models[]` or `.aggregator`).
struct HermesMoASlot: Equatable {
    var provider: String
    var model: String
    var enabled = true
    var reasoningEffort: String?

    init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
    init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any], let provider = raw["provider"] as? String,
            let model = raw["model"] as? String, !provider.isEmpty, !model.isEmpty
        else { return nil }
        self.provider = provider
        self.model = model
        enabled = raw["enabled"] as? Bool ?? true
        reasoningEffort = raw["reasoning_effort"] as? String
    }
    var dictionary: [String: Any] {
        var result: [String: Any] = ["provider": provider, "model": model, "enabled": enabled]
        if let reasoningEffort { result["reasoning_effort"] = reasoningEffort }
        return result
    }
}

/// Hermes' normalized `moa` section from `/api/model/moa`. Edits replace only the fields the editor
/// shows, so a PUT round-trip keeps fan-out, temperatures and timeouts Herm doesn't surface.
struct HermesMoAConfig {
    private(set) var raw: [String: Any]

    init(_ result: [String: Any]) throws {
        guard let presets = result["presets"] as? [String: Any], !presets.isEmpty else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        raw = result.filter { $0.key != "ok" }
    }
    private var presets: [String: [String: Any]] { raw["presets"] as? [String: [String: Any]] ?? [:] }
    var defaultPreset: String { raw["default_preset"] as? String ?? presetNames.first ?? "default" }
    var presetNames: [String] { presets.keys.sorted() }
    func references(_ preset: String) -> [HermesMoASlot] {
        (presets[preset]?["reference_models"] as? [Any] ?? []).compactMap(HermesMoASlot.init)
    }
    func aggregator(_ preset: String) -> HermesMoASlot? { HermesMoASlot(presets[preset]?["aggregator"]) }
    func isEnabled(_ preset: String) -> Bool { presets[preset]?["enabled"] as? Bool ?? true }

    mutating func update(
        _ preset: String, references: [HermesMoASlot]? = nil, aggregator: HermesMoASlot? = nil,
        enabled: Bool? = nil
    ) {
        var all = presets
        guard var entry = all[preset] else { return }
        if let references { entry["reference_models"] = references.map(\.dictionary) }
        if let aggregator { entry["aggregator"] = aggregator.dictionary }
        if let enabled { entry["enabled"] = enabled }
        all[preset] = entry
        raw["presets"] = all
    }
}

/// Only verified named lifecycle operations; transport dictionaries stay outside views.
@MainActor
final class HermesWorkflowRPC {
    private let client: HermesRPCClientProtocol
    let profileID: String?
    init(client: HermesRPCClientProtocol, profileID: String?) {
        self.client = client
        self.profileID = profileID
    }
    private func scoped(_ input: [String: Any]) -> [String: Any] {
        var params = input
        if let profileID { params["profile"] = profileID }
        return params
    }
    private func request(_ method: HermesFeatureIDs.ID, _ params: [String: Any]) async throws
        -> [String: Any]
    {
        try await client.request(method.rawValue, params: scoped(params))
    }
    private func acknowledged(_ result: [String: Any]) throws {
        guard result["ok"] as? Bool == true else { throw HermesGateway.GatewayError.malformedResponse }
    }
    func skills(query: String? = nil) async throws -> [WorkflowIntegrationItem] {
        if query == nil {
            let profileID = profileID ?? "default"
            let detail = try await BotService(client: client).profileDetail(profileID: profileID)
            guard detail.id == profileID else { throw HermesGateway.GatewayError.malformedResponse }
            return detail.skills.map {
                WorkflowIntegrationItem(id: $0.id, detail: $0.label, installed: true, enabled: $0.enabled)
            }
        }
        let result = try await request(.skillsManage, ["action": "search", "query": query ?? ""])
        guard let rows = result["results"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return try rows.prefix(20).map {
            guard let name = $0["name"] as? String, !name.isEmpty else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            return WorkflowIntegrationItem(
                id: name, detail: String(($0["description"] as? String ?? "").prefix(300)))
        }
    }

    func inspectSkill(_ id: String) async throws -> String {
        let result = try await request(.skillsManage, ["action": "inspect", "query": id])
        guard let info = result["info"] as? [String: Any] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return String(
            (info["skill_md_preview"] as? String ?? info["description"] as? String
                ?? "No preview returned.").prefix(12_000))
    }
    func installSkill(_ id: String) async throws {
        let result = try await request(.skillsManage, ["action": "install", "query": id])
        guard result["installed"] as? Bool == true else {
            throw HermesGateway.GatewayError.malformedResponse
        }
    }
    func toggleSkill(_ id: String, enabled: Bool) async throws {
        let result = try await client.sendHTTP(
            "PUT", path: "/api/skills/toggle", body: scoped(["name": id, "enabled": enabled]))
        try acknowledged(result)
        guard result["name"] as? String == id, result["enabled"] as? Bool == enabled else {
            throw HermesGateway.GatewayError.malformedResponse
        }
    }
    func removeSkill(_ id: String) async throws -> WorkflowSkillRemoval {
        let result = try await client.sendHTTP(
            "POST", path: "/api/skills/hub/uninstall", body: scoped(["name": id]))
        try acknowledged(result)
        guard let pid = result["pid"] as? Int, pid > 0, let name = result["name"] as? String,
            name.hasPrefix("skills-uninstall-"),
            name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { throw HermesGateway.GatewayError.malformedResponse }
        return WorkflowSkillRemoval(name: name, pid: pid)
    }
    func skillRemovalOutcome(_ removal: WorkflowSkillRemoval) async throws -> Int? {
        let result = try await client.fetchHTTP("/api/actions/\(removal.name)/status?lines=1")
        guard result["name"] as? String == removal.name, result["pid"] as? Int == removal.pid,
            let running = result["running"] as? Bool
        else { throw HermesGateway.GatewayError.malformedResponse }
        if running { return nil }
        guard let code = result["exit_code"] as? Int else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return code
    }
    func addCustomMCP(name: String, url: String) async throws {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
            let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? ""),
            parsed.host != nil,
            parsed.user == nil, parsed.password == nil
        else {
            throw QuickDraftError.message(
                "Enter a server name and an HTTP or HTTPS URL without embedded credentials.")
        }
        let result = try await request(.mcpServersAdd, ["name": name, "config": ["url": url]])
        try acknowledged(result)
        guard result["name"] as? String == name else {
            throw HermesGateway.GatewayError.malformedResponse
        }
    }
    func reloadMCP() async throws {
        let result = try await request(.reloadMCP, ["confirm": true])
        guard result["status"] as? String == "reloaded" else {
            throw QuickDraftError.message(
                "The runtime reload was not acknowledged. Reconnect and inspect the configuration.")
        }
    }
    func mcpCatalog() async throws -> [WorkflowIntegrationItem] {
        let result = try await request(.mcpCatalog, [:])
        guard let rows = result["servers"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        var items = try rows.map {
            guard let name = $0["name"] as? String, let installed = $0["installed"] as? Bool,
                let enabled = $0["enabled"] as? Bool
            else { throw HermesGateway.GatewayError.malformedResponse }
            return WorkflowIntegrationItem(
                id: name, detail: String(($0["description"] as? String ?? "").prefix(300)),
                installed: installed, enabled: enabled, requiredKeys: $0["requires"] as? [String] ?? [],
                transport: $0["transport"] as? String ?? "")
        }
        if let configured = try? await request(.mcpServersList, [:]),
            let servers = configured["servers"] as? [[String: Any]]
        {
            for row in servers {
                guard let name = row["name"] as? String, !items.contains(where: { $0.id == name }) else {
                    continue
                }
                items.append(
                    WorkflowIntegrationItem(
                        id: name, detail: "Configured \(row["transport"] as? String ?? "MCP") server",
                        installed: true, enabled: row["enabled"] as? Bool ?? false,
                        requiredKeys: row["env"] as? [String] ?? [], transport: row["transport"] as? String ?? ""))
            }
        }
        return items
    }
    func addMCP(_ name: String) async throws {
        let result = try await request(.mcpServersAdd, ["name": name, "preset": name])
        try acknowledged(result)
        guard result["name"] as? String == name else {
            throw HermesGateway.GatewayError.malformedResponse
        }
    }
    func setMCPCredential(_ name: String, key: String, value: String) async throws {
        try acknowledged(
            try await request(.mcpServersKey, ["name": name, "env_var": key, "value": value]))
    }
    func removeMCP(_ name: String) async throws {
        let result = try await request(.mcpServersRemove, ["name": name])
        try acknowledged(result)
        guard result["removed"] as? Bool == true else {
            throw HermesGateway.GatewayError.malformedResponse
        }
    }
    func testMCP(_ name: String) async throws -> String {
        let result = try await request(.mcpServersTest, ["name": name])
        guard let ok = result["ok"] as? Bool, let oauth = result["oauth_needed"] as? Bool else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        if oauth { return "Authorization required. Choose Authorize." }
        return ok
            ? "Connection confirmed. \((result["tools"] as? [Any])?.count ?? 0) tools available."
            : HermesDiagnosticsService.safeSummary(result["error"] as? String ?? "Connection failed.")
    }
    func startOAuth(_ name: String) async throws -> WorkflowOAuthFlow {
        let result = try await request(.mcpOAuthStart, ["name": name])
        try acknowledged(result)
        guard let id = result["session_id"] as? String, !id.isEmpty,
            let value = result["auth_url"] as? String,
            let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), url.host != nil
        else { throw HermesGateway.GatewayError.malformedResponse }
        return WorkflowOAuthFlow(id: id, url: url)
    }
    func pollOAuth(_ name: String, flow: String) async throws -> WorkflowOAuthStatus {
        let result = try await request(.mcpOAuthPoll, ["name": name, "session_id": flow])
        try acknowledged(result)
        switch result["status"] as? String {
        case "pending": return .pending
        case "approved": return .approved
        case "error": return .failed
        default: throw HermesGateway.GatewayError.malformedResponse
        }
    }
    func cancelOAuth(_ name: String, flow: String) async throws {
        try acknowledged(try await request(.mcpOAuthCancel, ["name": name, "session_id": flow]))
    }
    func plugins() async throws -> [WorkflowPlugin] {
        let result = try await request(.pluginsManage, ["action": "list"])
        guard let rows = result["plugins"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return try rows.map {
            guard let name = $0["name"] as? String, let key = $0["key"] as? String, !key.isEmpty,
                let status = $0["status"] as? String
            else { throw HermesGateway.GatewayError.malformedResponse }
            return WorkflowPlugin(
                id: key, name: name, detail: String(($0["description"] as? String ?? "").prefix(300)),
                enabled: status == "enabled", removable: $0["source"] as? String != "bundled",
                desktopHalf: $0["has_desktop_half"] as? Bool == true,
                settings: ($0["settings_schema"] as? [[String: Any]] ?? []).compactMap(Self.pluginSetting),
                version: $0["version"] as? String ?? "", source: $0["source"] as? String ?? "",
                status: status, catalogVersion: $0["catalog_version"] as? String ?? "",
                pinnedRevision: $0["pinned_sha"] as? String ?? "")
        }
    }
    static func pluginSetting(_ row: [String: Any]) -> WorkflowPluginSetting? {
        guard let key = row["key"] as? String, let kind = row["type"] as? String else { return nil }
        let value: String
        switch row["value"] {
        case let flag as Bool: value = flag ? "true" : "false"
        case let number as NSNumber: value = number.stringValue
        case let text as String: value = text
        default: value = ""
        }
        return WorkflowPluginSetting(
            id: key, label: row["label"] as? String ?? key, detail: row["description"] as? String ?? "",
            kind: kind, value: value, choices: row["choices"] as? [String] ?? [],
            env: row["env"] as? String, hasValue: row["has_value"] as? Bool == true)
    }
    /// Typed values for `plugins.manage settings`; secrets go through `/api/env` instead.
    static func pluginSettingValues(_ settings: [WorkflowPluginSetting], drafts: [String: String])
        -> [String: Any]
    {
        var values: [String: Any] = [:]
        for setting in settings where setting.kind != "secret" {
            guard let draft = drafts[setting.id], draft != setting.value else { continue }
            switch setting.kind {
            case "boolean": values[setting.id] = draft == "true"
            case "number": values[setting.id] = Int(draft).map { $0 as Any } ?? Double(draft) ?? draft
            default: values[setting.id] = draft
            }
        }
        return values
    }
    func savePluginSettings(_ key: String, values: [String: Any]) async throws {
        try acknowledged(
            try await request(.pluginsManage, ["action": "settings", "key": key, "values": values]))
    }
    func setPluginSecret(env: String, value: String) async throws {
        try acknowledged(
            try await client.sendHTTP("PUT", path: "/api/env", body: scoped(["key": env, "value": value])))
    }
    /// The curated catalog, minus entries Herm cannot run: other OSes, and Hermes Desktop-only
    /// packages (category `desktop` with no agent tools, hooks or middleware).
    func pluginCatalog() async throws -> [WorkflowPluginCatalogEntry] {
        let result = try await client.fetchHTTP("/api/dashboard/plugins/catalog")
        guard let rows = result["entries"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let platforms = row["platforms"] as? [String] ?? []
            guard platforms.isEmpty || platforms.contains("macos") else { return nil }
            let caps = row["capabilities"] as? [String: Any] ?? [:]
            let agentHalf = ["provides_tools", "provides_hooks", "provides_middleware"].contains {
                !(caps[$0] as? [Any] ?? []).isEmpty
            }
            guard row["category"] as? String != "desktop" || agentHalf else { return nil }
            return WorkflowPluginCatalogEntry(
                id: name, title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                detail: String((row["description"] as? String ?? "").prefix(300)),
                installed: row["installed"] as? Bool == true,
                category: (row["category"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "general",
                official: row["tier"] as? String == "official",
                maintainer: row["maintainer"] as? String ?? "", version: row["version"] as? String ?? "",
                repo: (row["repo"] as? String).flatMap(URL.init(string:)),
                docs: (row["docs_url"] as? String).flatMap(URL.init(string:)))
        }
    }
    /// GitHub stars for catalog repos, batched 100 aliases per GraphQL query. Hermes' catalog has no
    /// popularity data, so this reads GitHub directly with the launch token; no token, no stars.
    static func githubStars(_ slugs: [String]) async -> [String: Int] {
        guard !slugs.isEmpty, !Task.isCancelled else { return [:] }
        guard let token = await GitHubCodeHostService.localGitHubToken(), !token.isEmpty else { return [:] }
        return await githubStars(slugs, token: token) { try await URLSession.shared.data(for: $0) }
    }
    static func githubStars(
        _ slugs: [String], token: String,
        fetch: @MainActor (URLRequest) async throws -> (Data, URLResponse)
    ) async -> [String: Int] {
        var stars: [String: Int] = [:]
        let unique = Array(Set(slugs)).sorted()
        for start in stride(from: 0, to: unique.count, by: 100) {
            guard !Task.isCancelled else { break }
            let chunk = Array(unique[start..<min(start + 100, unique.count)])
            let fields = chunk.enumerated().compactMap { index, slug -> String? in
                let parts = slug.split(separator: "/")
                let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
                guard parts.count == 2, parts.allSatisfy({ $0.unicodeScalars.allSatisfy(safe.contains) }) else {
                    return nil
                }
                return "r\(index): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { stargazerCount }"
            }
            var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
            request.httpMethod = "POST"
            request.timeoutInterval = GitHubCodeHostService.requestTimeout
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "query": "{ \(fields.joined(separator: " ")) }"
            ])
            // Missing repos come back as null aliases plus an `errors` list; keep whatever resolved.
            guard let (data, response) = try? await fetch(request),
                (response as? HTTPURLResponse)?.statusCode == 200
            else { break }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rows = json["data"] as? [String: Any]
            else { continue }
            for (index, slug) in chunk.enumerated() {
                if let count = (rows["r\(index)"] as? [String: Any])?["stargazerCount"] as? Int { stars[slug] = count }
            }
        }
        return stars
    }
    func moaConfig() async throws -> HermesMoAConfig {
        try HermesMoAConfig(try await client.fetchHTTP("/api/model/moa" + query([:])))
    }
    /// Hermes validates the whole section and rejects incomplete slots (422) instead of repairing them.
    func saveMoAConfig(_ config: HermesMoAConfig) async throws -> HermesMoAConfig {
        let result = try await client.sendHTTP("PUT", path: "/api/model/moa" + query([:]), body: config.raw)
        try acknowledged(result)
        return try HermesMoAConfig(result)
    }
    /// Toolsets Hermes Desktop also hides: platform adapters and internals with no user switch.
    static let hiddenToolsets: Set<String> = ["discord", "discord_admin", "yuanbao", "context_engine", "moa"]
    func toolsets() async throws -> [WorkflowToolset] {
        let result = try await client.fetchHTTP("/api/tools/toolsets" + query([:]))
        guard let rows = result["items"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty, !Self.hiddenToolsets.contains(name) else {
                return nil
            }
            return WorkflowToolset(
                id: name, label: (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                detail: row["description"] as? String ?? "", enabled: row["enabled"] as? Bool == true,
                configured: row["configured"] as? Bool != false, tools: row["tools"] as? [String] ?? [])
        }
    }
    func setToolset(_ name: String, enabled: Bool) async throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let result = try await client.sendHTTP(
            "PUT", path: "/api/tools/toolsets/\(encoded)" + query([:]), body: ["enabled": enabled])
        try acknowledged(result)
        guard result["enabled"] as? Bool == enabled else { throw HermesGateway.GatewayError.malformedResponse }
    }
    func installPlugin(catalogName: String) async throws {
        try acknowledged(
            try await request(.pluginsManage, ["action": "install", "catalog_name": catalogName, "enable": true]))
    }
    /// Returns true when Hermes says the change needs a gateway restart to take effect.
    func togglePlugin(_ key: String, enabled: Bool) async throws -> Bool {
        let result = try await request(.pluginsManage, ["action": "toggle", "key": key, "enable": enabled])
        try acknowledged(result)
        return result["restart_required"] as? Bool == true
    }
    func removePlugin(_ name: String) async throws {
        try acknowledged(try await request(.pluginsManage, ["action": "remove", "name": name]))
    }
    private static let accountOwner = ["type": "account"]
    func connectors() async throws -> [WorkflowConnector] {
        let result = try await request(.connectorsList, ["owner": Self.accountOwner])
        guard result["available"] as? Bool == true else {
            throw QuickDraftError.message("Connectors are unavailable. Sign in with `hermes login` to use them.")
        }
        guard let rows = result["connectors"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        // Names and accounts are presentation extras; the list alone is enough to connect.
        let catalog = (try? await request(.connectorsCatalog, [:]))?["connectors"] as? [[String: Any]] ?? []
        let accounts = (try? await request(.connectorsAccounts, [:]))?["accounts"] as? [[String: Any]] ?? []
        let policy = try? await request(.connectorsPolicyGet, [:])
        let layers = policy?["layers"] as? [[String: Any]]
        let policyWritable = layers.map { layers in
            layers.contains { $0["kind"] as? String == "member" && $0["revision"] is String }
        }
        return try rows.map { row in
            guard let slug = row["connector"] as? String, !slug.isEmpty else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            let entry = catalog.first { $0["slug"] as? String == slug }
            return WorkflowConnector(
                id: slug, name: entry?["name"] as? String ?? slug,
                detail: String((entry?["description"] as? String ?? "").prefix(300)),
                allowed: row["enabled"] as? Bool ?? true, connected: row["connected"] as? Bool == true,
                status: row["connection_status"] as? String,
                accounts: accounts.compactMap {
                    guard $0["connector"] as? String == slug, let id = $0["connection_id"] as? String else {
                        return nil
                    }
                    return WorkflowConnectorAccount(
                        id: id, label: $0["alias"] as? String ?? $0["label"] as? String ?? id,
                        status: $0["status"] as? String ?? "")
                }, policyWritable: policyWritable)
        }
    }
    func connectConnector(_ slug: String, reconnect: Bool) async throws -> WorkflowConnectorOperation {
        try Self.connectorOperation(
            try await request(
                .connectorsConnect,
                ["owner": Self.accountOwner, "connectors": [slug], "reconnect": reconnect]))
    }
    func connectorOperation(_ id: String) async throws -> WorkflowConnectorOperation {
        try Self.connectorOperation(
            try await request(.connectorsOperationStatus, ["owner": Self.accountOwner, "op_id": id]))
    }
    static func connectorOperation(_ result: [String: Any]) throws -> WorkflowConnectorOperation {
        guard let id = result["op_id"] as? String, !id.isEmpty,
            let targets = result["targets"] as? [[String: Any]]
        else { throw HermesGateway.GatewayError.malformedResponse }
        let url = targets.lazy.compactMap { ($0["connect_url"] as? String).flatMap(URL.init(string:)) }
            .first { $0.scheme == "https" && $0.host != nil }
        let states = targets.compactMap { $0["state"] as? String }
        return WorkflowConnectorOperation(
            id: id, url: url, settled: result["settled"] as? Bool == true,
            connected: !states.isEmpty && states.allSatisfy { $0 == "connected" })
    }
    func removeConnectorAccount(_ connectionID: String) async throws {
        let result = try await request(.connectorsAccountsRemove, ["connection_id": connectionID])
        guard result["connection_id"] as? String == connectionID else {
            throw HermesGateway.GatewayError.malformedResponse
        }
    }
    /// Hermes connector aliases: lowercase letters, digits and dashes, starting alphanumeric.
    static func validConnectorAlias(_ alias: String) -> Bool {
        alias.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }
    func renameConnectorAccount(_ connectionID: String, alias: String) async throws {
        guard Self.validConnectorAlias(alias) else {
            throw QuickDraftError.message(
                "Use up to 32 lowercase letters, digits or dashes, starting with a letter or digit.")
        }
        let result = try await request(
            .connectorsAccountsRename, ["connection_id": connectionID, "alias": alias])
        guard result["connection_id"] as? String == connectionID else {
            throw HermesGateway.GatewayError.malformedResponse
        }
    }
    /// Writes the member policy layer, guarded by its revision like Hermes Desktop.
    func setConnectorAllowed(_ slug: String, enabled: Bool) async throws {
        let policy = try await request(.connectorsPolicyGet, [:])
        let layers = policy["layers"] as? [[String: Any]] ?? []
        guard let revision = layers.first(where: { $0["kind"] as? String == "member" })?["revision"] as? String
        else { throw QuickDraftError.message("Connector rules are read-only for this account.") }
        let result = try await request(
            .connectorsPolicySet,
            ["change": ["type": "connector", "connector": slug, "enabled": enabled], "expected_revision": revision])
        guard result["revision"] is String else { throw HermesGateway.GatewayError.malformedResponse }
    }
    func setRoutinePaused(_ id: String, paused: Bool) async throws {
        let result = try await request(
            .cronManage, ["action": paused ? "pause" : "resume", "name": id])
        guard result["success"] as? Bool == true, let job = result["job"] as? [String: Any],
            job["job_id"] as? String == id, job["enabled"] as? Bool == !paused
        else { throw HermesGateway.GatewayError.malformedResponse }
    }
    func routineJobs() async throws -> [CronSummary] {
        let result = try await request(.cronManage, ["action": "list", "include_disabled": true])
        if let profileID, result["scoped"] as? String != profileID {
            throw HermesGateway.GatewayError.malformedResponse
        }
        guard result["jobs"] is [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return ControlCenterModel.parseCronJobs(result).map { job in
            var job = job
            job.owner = CronOwner(profileID: profileID)
            return job
        }
    }
    func runRoutine(_ id: String) async throws {
        try await HermesControlRPC(client: client).triggerCron(jobID: id, profileID: profileID)
    }
    func steer(sessionID: String, subagentID: String, text: String) async throws
        -> WorkflowSteeringOutcome
    {
        let result = try await request(
            .subagentSteer, ["session_id": sessionID, "subagent_id": subagentID, "text": text])
        guard result["subagent_id"] as? String == subagentID, let status = result["status"] as? String,
            let outcome = WorkflowSteeringOutcome(rawValue: status)
        else { throw HermesGateway.GatewayError.malformedResponse }
        return outcome
    }
    private func ownedResume(_ session: HermesSession) async throws -> [String: Any] {
        guard session.profileID == profileID else { throw HermesGateway.GatewayError.malformedResponse }
        let result = try await client.request(
            HermesFeatureIDs.ID.sessionResume.rawValue,
            params: scoped(["session_id": session.id, "omit_messages": true, "source": HermesFeatureIDs.sessionSource]))
        let runtime = result["session_id"] as? String ?? session.id
        let info = result["info"] as? [String: Any] ?? [:]
        guard
            DockModel.resumeResponseProvesSessionOwnership(
                requestedSessionID: session.id, resolvedSessionID: runtime, result: result)
        else { throw HermesGateway.GatewayError.malformedResponse }
        let returnedProfile = result["profile"] as? String ?? info["profile_name"] as? String
        if profileID != nil, returnedProfile == nil {
            throw QuickDraftError.message(
                "Hermes did not confirm the session's owner profile. Open its workspace to review compatibility."
            )
        }
        if profileID != nil || returnedProfile != nil, returnedProfile != (profileID ?? "default") {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return result
    }
    func resumeOwned(_ session: HermesSession) async throws -> (String, Bool) {
        let result = try await ownedResume(session)
        let info = result["info"] as? [String: Any] ?? [:]
        guard let running = result["running"] as? Bool ?? info["running"] as? Bool else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return (result["session_id"] as? String ?? session.id, running)
    }
    func modelOptions(_ runtime: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.modelOptions.rawValue,
            params: scoped(["session_id": runtime, "explicit_only": true]))
    }
    func setSessionModel(_ session: HermesSession, option: HermesModelOption) async throws {
        let (runtime, running) = try await resumeOwned(session)
        guard !running else {
            throw QuickDraftError.message("The destination is busy. Change its model when idle.")
        }
        let available = try DockModel.runtimeModelOptions(from: await modelOptions(runtime))
        guard available.contains(option) else {
            throw QuickDraftError.message("That model is no longer configured.")
        }
        let params = DockModel.sessionRuntimeModelSwitchRequest(option: option, sessionID: runtime)
            .parameters
        let result = try await client.request(
            HermesFeatureIDs.ID.configSet.rawValue, params: scoped(params))
        guard result["key"] as? String == "model", result["scope"] as? String == "session",
            let value = result["value"] as? String, !value.isEmpty,
            result["confirm_required"] as? Bool != true, result["deferred"] as? Bool != true
        else {
            throw QuickDraftError.message(
                "The model change was not confirmed. Refresh the session before retrying.")
        }
    }
    func stopSession(_ session: HermesSession) async throws {
        let (runtime, _) = try await resumeOwned(session)
        let result = try await client.request(
            HermesFeatureIDs.ID.sessionInterrupt.rawValue, params: scoped(["session_id": runtime]))
        guard result["status"] as? String == "interrupted", result["interrupted"] as? Bool != false
        else {
            throw QuickDraftError.message("Hermes did not confirm stopping this turn. Refresh its state.")
        }
    }
    func sessionDirectory(_ session: HermesSession) async throws -> String {
        let result = try await ownedResume(session)
        let info = result["info"] as? [String: Any] ?? [:]
        let runtime = result["session_id"] as? String ?? session.id
        guard
            DockModel.resumeResponseProvesSessionOwnership(
                requestedSessionID: session.id, resolvedSessionID: runtime, result: result),
            let path = result["cwd"] as? String ?? info["cwd"] as? String, path.hasPrefix("/")
        else { throw HermesGateway.GatewayError.malformedResponse }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    func createSession(directory: String, idempotencyKey: String) async throws -> [String: Any] {
        try await client.request(
            HermesFeatureIDs.ID.sessionCreate.rawValue,
            params: scoped([
                "cwd": directory, "cwd_explicit": true, "source": HermesFeatureIDs.sessionSource,
                "idempotency_key": idempotencyKey,
            ]))
    }
    private func query(_ values: [String: String]) -> String {
        var components = URLComponents()
        var values = values
        if let profileID { values["profile"] = profileID }
        components.queryItems = values.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.percentEncodedQuery.map { "?" + $0 } ?? ""
    }
    func memoryEntries() async throws -> [WorkflowMemoryEntry] {
        let result = try await client.fetchHTTP("/api/learning/graph" + query([:]))
        guard let nodes = result["nodes"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return Array(
            nodes.compactMap { node -> WorkflowMemoryEntry? in
                guard node["kind"] as? String == "memory", let id = node["id"] as? String, validMemoryID(id)
                else { return nil }
                return WorkflowMemoryEntry(
                    id: id, label: String((node["label"] as? String ?? id).prefix(120)))
            }.prefix(100))
    }
    private func validMemoryID(_ id: String) -> Bool {
        let parts = id.split(separator: ":")
        return parts.count == 4 && parts[0] == "memory"
            && ["memory", "profile"].contains(String(parts[1]))
            && Int(parts[2]) != nil && parts[3].count >= 8 && parts[3].allSatisfy(\.isHexDigit)
    }
    func memoryDetail(_ id: String) async throws -> String {
        guard validMemoryID(id) else {
            throw QuickDraftError.message("This runtime did not provide a stable memory-entry identity.")
        }
        let result: [String: Any]
        if profileID == nil {
            result = try await request(.learningDetail, ["id": id])
        } else {
            result = try await client.fetchHTTP("/api/learning/node" + query(["id": id]))
        }
        try acknowledged(result)
        guard result["id"] as? String == id, result["kind"] as? String == "memory",
            let content = result["content"] as? String,
            content.utf8.count <= 64_000
        else { throw HermesGateway.GatewayError.malformedResponse }
        return content
    }
    func correctMemory(_ id: String, content: String?) async throws {
        guard validMemoryID(id) else {
            throw QuickDraftError.message("Refresh memory entries before editing.")
        }
        var params: [String: Any] = ["id": id]
        if let content { params["content"] = content }
        let result: [String: Any]
        if profileID == nil {
            result = try await request(content == nil ? .learningDelete : .learningEdit, params)
        } else {
            result = try await client.sendHTTP(
                content == nil ? "DELETE" : "PUT", path: "/api/learning/node" + query([:]),
                body: scoped(params))
        }
        try acknowledged(result)
    }
    func liveSubagents(_ session: HermesSession) async throws -> (String, [WorkflowSubagent]) {
        let (runtime, _) = try await resumeOwned(session)
        let result = try await request(.subagentList, ["session_id": runtime])
        guard let rows = result["subagents"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        return (
            runtime,
            rows.compactMap {
                guard let id = $0["subagent_id"] as? String, !id.isEmpty,
                    ["running", "active"].contains($0["status"] as? String ?? "")
                else { return nil }
                return WorkflowSubagent(
                    id: id, goal: String(($0["goal"] as? String ?? id).prefix(300)),
                    accepting: $0["accepting_steer"] as? Bool == true)
            }
        )
    }
}
