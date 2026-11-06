import Foundation

enum HermesSubagentError: Error { case invalidInput, unavailable }

struct HermesSubagentDefaults: Hashable {
    var provider: String
    var model: String
    var turns: Int
    var parallel: Int
    var timeout: Int
    var effort: String
    let directEndpoint: Bool

    init(_ config: [String: Any]) throws {
        guard let row = config["delegation"] as? [String: Any],
            let turns = row["max_iterations"] as? Int, turns > 0,
            let parallel = row["max_concurrent_children"] as? Int, parallel > 0,
            let timeout = row["child_timeout_seconds"] as? Int, timeout >= 0
        else { throw HermesGateway.GatewayError.malformedResponse }
        provider = row["provider"] as? String ?? ""
        model = row["model"] as? String ?? ""
        self.turns = turns
        self.parallel = parallel
        self.timeout = timeout
        effort = row["reasoning_effort"] as? String ?? ""
        directEndpoint = !(row["base_url"] as? String ?? "").isEmpty
    }

    var valid: Bool { turns > 0 && parallel > 0 && timeout >= 0 }

    func patch(from saved: Self) -> [String: Any] {
        var patch: [String: Any] = [:]
        if provider != saved.provider { patch["provider"] = provider }
        if model != saved.model { patch["model"] = model }
        if turns != saved.turns { patch["max_iterations"] = turns }
        if parallel != saved.parallel { patch["max_concurrent_children"] = parallel }
        if timeout != saved.timeout { patch["child_timeout_seconds"] = timeout }
        if effort != saved.effort { patch["reasoning_effort"] = effort }
        return patch
    }
}

struct HermesSubagentBackend: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let available: Bool
}

struct HermesSubagentRoute: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String
    var provider: String
    var model: String
    var directEndpoint: Bool
}

struct HermesSubagentRouting: Equatable {
    let configured: String
    let blocked: Bool
    let backends: [HermesSubagentBackend]
    let models: [HermesSubagentRoute]
    let profiles: [HermesSubagentRoute]
    let knownProfiles: [String]
    let defaultModel: String
    let defaultProfile: String

    init(_ raw: [String: Any]) throws {
        guard let configured = raw["configured"] as? String, !configured.isEmpty,
            let backends = raw["backends"] as? [[String: Any]],
            let modelMap = raw["model_map"] as? [String: Any],
            let models = modelMap["options"] as? [[String: Any]],
            let profileRoutes = raw["profile_routes"] as? [String: Any],
            let profiles = profileRoutes["profiles"] as? [[String: Any]],
            let known = raw["profiles"] as? [String]
        else { throw HermesGateway.GatewayError.malformedResponse }
        self.configured = configured
        blocked = !(raw["blocked_reason"] as? String ?? "").isEmpty
        self.backends = try backends.map {
            guard let id = $0["name"] as? String, !id.isEmpty, let available = $0["available"] as? Bool else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            return HermesSubagentBackend(
                id: id, label: $0["label"] as? String ?? id,
                detail: $0["description"] as? String ?? "", available: available)
        }
        self.models = try Self.routes(models)
        self.profiles = try Self.routes(profiles)
        knownProfiles = known
        defaultModel = modelMap["default"] as? String ?? ""
        defaultProfile = profileRoutes["default"] as? String ?? ""
        guard Set(self.backends.map(\.id)).count == self.backends.count,
            self.backends.contains(where: { $0.id == "default" })
        else { throw HermesGateway.GatewayError.malformedResponse }
    }

    private static func routes(_ rows: [[String: Any]]) throws -> [HermesSubagentRoute] {
        let routes = try rows.map { row in
            guard let name = row["name"] as? String, !name.isEmpty else {
                throw HermesGateway.GatewayError.malformedResponse
            }
            return HermesSubagentRoute(
                name: name, description: row["description"] as? String ?? "",
                provider: row["provider"] as? String ?? "", model: row["model"] as? String ?? "",
                directEndpoint: !(row["base_url"] as? String ?? "").isEmpty)
        }
        guard Set(routes.map(\.id)).count == routes.count else { throw HermesGateway.GatewayError.malformedResponse }
        return routes
    }
}

@MainActor
struct HermesSubagentService {
    let rpc: HermesControlRPC
    let profile: String

    private func path(_ path: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "profile", value: profile)]
        return path + "?" + (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    func defaults() async throws -> HermesSubagentDefaults {
        try HermesSubagentDefaults(await rpc.fetchHTTP(path("/api/config")))
    }

    func routing() async throws -> HermesSubagentRouting {
        try HermesSubagentRouting(await rpc.fetchHTTP(path("/api/delegation/routing")))
    }

    func routingPlugin() async throws -> WorkflowPluginCatalogEntry? {
        let raw = try await rpc.fetchHTTP(path("/api/dashboard/plugins/catalog"))
        guard let rows = raw["entries"] as? [[String: Any]] else { throw HermesGateway.GatewayError.malformedResponse }
        guard
            let row = rows.first(where: {
                $0["name"] as? String == "advanced-delegation" && $0["tier"] as? String == "official"
            })
        else { return nil }
        let platforms = row["platforms"] as? [String] ?? []
        guard platforms.isEmpty || platforms.contains("macos") else { return nil }
        return WorkflowPluginCatalogEntry(
            id: "advanced-delegation", title: "Advanced Delegation",
            detail: row["description"] as? String ?? "", installed: false, official: true)
    }

    func saveDefaults(_ draft: HermesSubagentDefaults, previous: HermesSubagentDefaults) async throws {
        guard draft.valid,
            !previous.directEndpoint || (draft.provider == previous.provider && draft.model == previous.model)
        else { throw HermesSubagentError.invalidInput }
        let result = try await rpc.sendHTTP(
            "PUT", path: path("/api/config"),
            body: ["config": ["delegation": draft.patch(from: previous)]])
        try acknowledged(result)
    }

    func selectBackend(_ id: String) async throws {
        let current = try await routing()
        guard current.backends.contains(where: { $0.id == id && $0.available }) else {
            throw HermesSubagentError.unavailable
        }
        let result = try await rpc.sendHTTP("PUT", path: path("/api/delegation/backend"), body: ["backend": id])
        try acknowledged(result)
        guard result["backend"] as? String == id else { throw HermesGateway.GatewayError.malformedResponse }
    }

    func saveModelRoute(_ route: HermesSubagentRoute?, originalName: String?, makeDefault: String? = nil) async throws {
        // Read the block again so unknown fields and redacted credential previews round-trip transiently.
        let raw = try await rpc.fetchHTTP(path("/api/delegation/routing"))
        _ = try HermesSubagentRouting(raw)
        guard var block = raw["model_map"] as? [String: Any], var options = block["options"] as? [[String: Any]] else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        if let route {
            guard !route.name.isEmpty, !route.description.isEmpty, !route.model.isEmpty,
                !route.provider.isEmpty || route.directEndpoint,
                !options.contains(where: { $0["name"] as? String == route.name && route.name != originalName })
            else { throw HermesSubagentError.invalidInput }
            var entry = originalName.flatMap { name in options.first { $0["name"] as? String == name } } ?? [:]
            if originalName != nil, entry.isEmpty { throw HermesSubagentError.invalidInput }
            entry["name"] = route.name
            entry["description"] = route.description
            entry["provider"] = route.provider
            entry["model"] = route.model
            if let originalName { entry["original_name"] = originalName }
            options.removeAll { $0["name"] as? String == originalName }
            options.append(entry)
            if let originalName, block["default"] as? String == originalName { block["default"] = route.name }
        } else if let originalName {
            options.removeAll { $0["name"] as? String == originalName }
            if block["default"] as? String == originalName { block["default"] = NSNull() }
        }
        if let makeDefault { block["default"] = makeDefault.isEmpty ? NSNull() : makeDefault as Any }
        block["options"] = options
        try acknowledged(await rpc.sendHTTP("PUT", path: path("/api/delegation/backends/model_map"), body: block))
    }

    func saveProfileRoutes(_ routes: [HermesSubagentRoute], defaultName: String) async throws {
        let current = try await routing()
        guard Set(routes.map(\.name)).count == routes.count,
            routes.allSatisfy({ current.knownProfiles.contains($0.name) }),
            defaultName.isEmpty || routes.contains(where: { $0.name == defaultName })
        else { throw HermesSubagentError.invalidInput }
        let body: [String: Any] = [
            "profiles": routes.map { ["name": $0.name, "description": $0.description] },
            "default": defaultName.isEmpty ? NSNull() : defaultName as Any,
        ]
        try acknowledged(await rpc.sendHTTP("PUT", path: path("/api/delegation/backends/profile_routes"), body: body))
    }

    private func acknowledged(_ result: [String: Any]) throws {
        guard result["ok"] as? Bool == true else { throw HermesGateway.GatewayError.malformedResponse }
    }
}
