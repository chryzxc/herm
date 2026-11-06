import Foundation

/// Metadata only. Secret payloads never become part of the settings projection.
struct HermesVaultItem: Identifiable, Hashable {
    let id: String
    let kind: String
    let label: String
    let origin: String
    let identifier: String
    let backend: String

    init(_ row: [String: Any]) throws {
        guard let id = row["id"] as? String, !id.isEmpty,
            let kind = row["kind"] as? String, ["login", "payment", "address"].contains(kind),
            let label = row["label"] as? String, !label.isEmpty
        else { throw HermesVaultError.invalidResponse }
        self.id = id
        self.kind = kind
        self.label = label
        origin = row["origin"] as? String ?? ""
        identifier = row["identifier"] as? String ?? ""
        backend = row["backend"] as? String ?? "local"
    }
}

struct HermesVaultSource: Identifiable, Equatable {
    let id: String
    let name: String
    let enabled: Bool
    let installed: Bool
    let unlocked: Bool
    let needsUnlock: Bool

    init(_ row: [String: Any]) throws {
        guard let id = row["name"] as? String, !id.isEmpty,
            let name = row["display_name"] as? String, !name.isEmpty,
            let enabled = row["enabled"] as? Bool, let installed = row["installed"] as? Bool,
            let unlocked = row["unlocked"] as? Bool, let needsUnlock = row["needs_unlock"] as? Bool
        else { throw HermesVaultError.invalidResponse }
        self.id = id
        self.name = name
        self.enabled = enabled
        self.installed = installed
        self.unlocked = unlocked
        self.needsUnlock = needsUnlock
    }
}

enum HermesVaultError: Error { case invalidResponse, unavailable, invalidInput }

@MainActor
struct HermesVaultService {
    let client: HermesRPCClientProtocol
    let profile: String?

    private func request(_ method: HermesFeatureIDs.ID, _ input: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        var params = input
        if let profile { params["profile"] = profile }
        let result = try await client.request(method.rawValue, params: params)
        guard result["error"] == nil, result["ok"] as? Bool != false else {
            throw HermesVaultError.invalidResponse
        }
        return result
    }

    func inventory() async throws -> (items: [HermesVaultItem], sources: [HermesVaultSource]) {
        let inventory = try await request(.vaultList)
        let status = try await request(.vaultSources)
        guard let rows = inventory["items"] as? [[String: Any]],
            let sources = status["sources"] as? [[String: Any]]
        else { throw HermesVaultError.invalidResponse }
        let items = try rows.map(HermesVaultItem.init)
        let managers = try sources.map(HermesVaultSource.init)
        guard Set(items.map { $0.backend + ":" + $0.id }).count == items.count,
            Set(managers.map(\.id)).count == managers.count,
            managers.contains(where: { $0.id == "local" && $0.enabled && $0.installed })
        else { throw HermesVaultError.invalidResponse }
        return (items, managers)
    }

    nonisolated static func validOrigin(_ text: String) -> Bool {
        guard let url = URLComponents(string: text),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { return false }
        return true
    }

    func addLogin(label: String, origin: String, identifier: String, type: String, password: String, otp: String)
        async throws
    {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            Self.validOrigin(origin), !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            ["email", "username", "phone"].contains(type), !password.isEmpty
        else { throw HermesVaultError.invalidInput }
        var secret = ["identifier_type": type, "identifier": identifier, "password": password]
        if !otp.isEmpty { secret["otp_secret"] = otp }
        let result = try await request(
            .vaultAdd, ["kind": "login", "label": label, "origin": origin, "secret": secret])
        guard let id = result["id"] as? String, !id.isEmpty else { throw HermesVaultError.invalidResponse }
    }

    func remove(_ item: HermesVaultItem) async throws {
        guard item.backend == "local" else { throw HermesVaultError.invalidInput }
        guard try await request(.vaultRemove, ["id": item.id])["removed"] as? Bool == true else {
            throw HermesVaultError.invalidResponse
        }
    }

    func setEnabled(_ source: HermesVaultSource, enabled: Bool) async throws {
        guard source.id != "local", source.installed else { throw HermesVaultError.invalidInput }
        let result = try await request(.vaultSourceSet, ["name": source.id, "enabled": enabled])
        guard result["name"] as? String == source.id, result["enabled"] as? Bool == enabled else {
            throw HermesVaultError.invalidResponse
        }
    }

    func unlock(_ source: HermesVaultSource, password: String) async throws {
        guard source.enabled, source.installed, source.needsUnlock, !password.isEmpty else {
            throw HermesVaultError.invalidInput
        }
        let result = try await request(.vaultUnlock, ["name": source.id, "password": password])
        guard result["name"] as? String == source.id, result["unlocked"] as? Bool == true else {
            throw HermesVaultError.invalidResponse
        }
    }

    func lock(_ source: HermesVaultSource) async throws {
        guard source.id != "local" else { throw HermesVaultError.invalidInput }
        guard try await request(.vaultLock, ["name": source.id])["locked"] as? Bool == true else {
            throw HermesVaultError.invalidResponse
        }
    }
}
