import Foundation

/// Codex quota for Hermes-managed accounts, read from the ChatGPT usage API.
enum CodexQuotaService {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private struct Auth { var access: String; var account: String? }

    /// Reads the Codex OAuth store managed by Hermes.
    ///
    /// Each entry of Hermes' `openai-codex` credential pool becomes its own
    /// snapshot, keyed by the pool entry id so nicknames and display order
    /// survive another account being added or removed. An account whose read
    /// fails still appears, with the failure as its detail, so it can be
    /// inspected or removed instead of hiding every other account.
    static func readHermes() async throws -> [String: Any] {
        let accounts = loadAllHermesAuth()
        guard !accounts.isEmpty else {
            throw CodexQuotaError.unavailable("No Hermes-managed Codex login was found.")
        }

        var snapshots: [[String: Any]] = []
        for (index, account) in accounts.enumerated() {
            snapshots.append(await readHermesAccount(account, index: index))
        }
        return ["_accounts": snapshots]
    }

    private static func readHermesAccount(_ account: HermesAccount, index: Int) async -> [String: Any] {
        let position = account.credential?.position ?? index + 1
        var snapshot: [String: Any]
        do {
            let response = try await request(account.auth)
            guard (200..<300).contains(response.status) else {
                throw CodexQuotaError.unavailable(response.status == 401 || response.status == 403
                    ? "Hermes rejected this Codex sign-in. Remove it, or run `hermes auth refresh openai-codex`."
                    : "Codex usage returned HTTP \(response.status).")
            }
            guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw CodexQuotaError.invalidResponse
            }
            snapshot = normalize(object, headers: response.headers)
        } catch {
            snapshot = [
                "updated_at": QuotaJSON.iso8601String(from: .now),
                "windows": [[String: Any]](),
                "safe_detail": (error as? LocalizedError)?.errorDescription ?? "Codex usage could not be read."
            ]
        }
        snapshot["provider"] = account.credential.map { "codex-hermes-\($0.id)" } ?? "codex-hermes-primary"
        snapshot["display_name"] = "Codex (Account \(position))"
        if let credential = account.credential {
            snapshot["hermes_credential"] = [
                "provider": credential.provider,
                "id": credential.id,
                "label": credential.label,
                "position": credential.position
            ] as [String: Any]
        }
        return snapshot
    }

    private static func request(_ auth: Auth) async throws -> (data: Data, status: Int, headers: [String: String]) {
        var request = URLRequest(url: usageURL); request.httpMethod = "GET"; request.timeoutInterval = 15
        request.setValue("Bearer \(auth.access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
        if let account = auth.account { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            (http?.allHeaderFields ?? [:]).forEach { key, value in if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value } }
            return (data, http?.statusCode ?? 0, headers)
        } catch { throw CodexQuotaError.unavailable("Codex usage could not be reached.") }
    }

    private struct HermesAccount {
        let auth: Auth
        let credential: HermesPooledCredential?
    }

    /// Hermes' credential pool is authoritative: it is what Hermes rotates
    /// through and what `hermes auth list` shows. The singleton
    /// `providers.openai-codex` login is only used when Hermes has no pool
    /// for Codex yet (older Hermes), since the pool otherwise already holds it.
    private static func loadAllHermesAuth() -> [HermesAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = ProcessInfo.processInfo.environment["HERMES_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".hermes", isDirectory: true)
        let file = root.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return hermesAccounts(fromAuthStore: json)
    }

    private static func hermesAccounts(fromAuthStore json: [String: Any]) -> [HermesAccount] {
        if let pool = json["credential_pool"] as? [String: Any],
           let entries = pool["openai-codex"] as? [[String: Any]] {
            let ordered = entries.enumerated().sorted {
                let lhs = ($0.element["priority"] as? Int) ?? Int.max
                let rhs = ($1.element["priority"] as? Int) ?? Int.max
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }
            return ordered.enumerated().compactMap { position, item -> HermesAccount? in
                let entry = item.element
                guard let id = entry["id"] as? String, !id.isEmpty,
                      let access = entry["access_token"] as? String, !access.isEmpty else { return nil }
                return HermesAccount(
                    auth: Auth(access: access, account: nil),
                    credential: HermesPooledCredential(
                        provider: "openai-codex",
                        id: id,
                        label: (entry["label"] as? String) ?? id,
                        position: position + 1
                    )
                )
            }
        }

        guard let providers = json["providers"] as? [String: Any],
              let provider = providers["openai-codex"] as? [String: Any],
              let tokens = provider["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty else { return [] }
        return [HermesAccount(
            auth: Auth(access: access, account: tokens["account_id"] as? String),
            credential: nil
        )]
    }

    /// Test seam for the pool/primary selection rules.
    static func hermesCredentials(fromAuthStore json: [String: Any]) -> [HermesPooledCredential?] {
        hermesAccounts(fromAuthStore: json).map(\.credential)
    }

    private static func normalize(_ object: [String: Any], headers: [String: String]) -> [String: Any] {
        let rate = object["rate_limit"] as? [String: Any] ?? object
        var windows: [[String: Any]] = []
        for (key, label, header) in [("primary_window", "Session", "x-codex-primary-used-percent"), ("secondary_window", "Weekly", "x-codex-secondary-used-percent")] {
            guard let raw = rate[key] as? [String: Any] else { continue }
            let used = QuotaJSON.number(raw["used_percent"]) ?? QuotaJSON.number(headers[header]) ?? 0
            var row: [String: Any] = ["id": key.replacingOccurrences(of: "_window", with: ""), "label": label, "remaining_percent": max(0, min(100, 100 - used))]
            if let reset = QuotaJSON.number(raw["reset_at"]) { row["resets_at"] = QuotaJSON.iso8601String(from: Date(timeIntervalSince1970: reset)) }
            else if let seconds = QuotaJSON.number(raw["reset_after_seconds"]) { row["resets_at"] = QuotaJSON.iso8601String(from: Date(timeIntervalSinceNow: seconds)) }
            windows.append(row)
        }
        var result: [String: Any] = ["updated_at": QuotaJSON.iso8601String(from: .now), "windows": windows]
        if let plan = object["plan_type"] as? String { result["safe_detail"] = "Plan: \(plan)" }; return result
    }
}

enum CodexQuotaError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    var errorDescription: String? { switch self { case .unavailable(let message): message; case .invalidResponse: "Codex returned an invalid quota snapshot." } }
}
