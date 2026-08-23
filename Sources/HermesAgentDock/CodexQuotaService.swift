import Foundation

/// Codex quota is exposed by the authenticated ChatGPT usage API, not Hermes.
enum CodexQuotaService {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private struct Auth { var access: String; var refresh: String?; var account: String?; var file: URL? }

    static func read() async throws -> [String: Any] {
        guard var auth = loadAuth() else { throw CodexQuotaError.unavailable("No Codex login token was found.") }
        var response = try await request(auth)
        if response.status == 401 || response.status == 403 {
            guard let refreshToken = auth.refresh else { throw CodexQuotaError.unavailable("The Codex login token expired. Sign in to Codex, then refresh.") }
            auth = try await refresh(auth, token: refreshToken)
            response = try await request(auth)
        }
        guard (200..<300).contains(response.status) else { throw CodexQuotaError.unavailable("Codex usage returned HTTP \(response.status).") }
        guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { throw CodexQuotaError.invalidResponse }
        return normalize(object, headers: response.headers)
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

    private static func refresh(_ auth: Auth, token: String) async throws -> Auth {
        var request = URLRequest(url: refreshURL); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        request.httpBody = "grant_type=refresh_token&client_id=\(clientID)&refresh_token=\(escaped)".data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let access = json["access_token"] as? String, !access.isEmpty else { throw CodexQuotaError.unavailable("Codex login refresh was rejected. Sign in to Codex again.") }
            var updated = auth; updated.access = access; if let value = json["refresh_token"] as? String { updated.refresh = value }; persist(updated); return updated
        } catch let error as CodexQuotaError { throw error } catch { throw CodexQuotaError.unavailable("Codex login refresh failed. Sign in to Codex again.") }
    }

    private static func loadAuth() -> Auth? {
        let env = ProcessInfo.processInfo.environment
        if let access = env["CODEX_ACCESS_TOKEN"] ?? env["OPENAI_ACCESS_TOKEN"], !access.isEmpty { return Auth(access: access, refresh: nil, account: env["CHATGPT_ACCOUNT_ID"], file: nil) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let override = env["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let dirs = [override, home.appendingPathComponent(".config/codex"), home.appendingPathComponent(".codex")].compactMap { $0 }
        for directory in dirs {
            let file = directory.appendingPathComponent("auth.json")
            guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tokens = json["tokens"] as? [String: Any], let access = tokens["access_token"] as? String, !access.isEmpty else { continue }
            return Auth(access: access, refresh: tokens["refresh_token"] as? String, account: tokens["account_id"] as? String, file: file)
        }
        return nil
    }

    private static func persist(_ auth: Auth) {
        guard let file = auth.file, let data = try? Data(contentsOf: file), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var tokens = json["tokens"] as? [String: Any] else { return }
        tokens["access_token"] = auth.access; if let refresh = auth.refresh { tokens["refresh_token"] = refresh }; json["tokens"] = tokens
        if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? output.write(to: file, options: .atomic) }
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
        var result: [String: Any] = ["provider": "codex", "display_name": "Codex", "updated_at": QuotaJSON.iso8601String(from: .now), "windows": windows]
        if let plan = object["plan_type"] as? String { result["safe_detail"] = "Plan: \(plan)" }; return result
    }
}

enum CodexQuotaError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    var errorDescription: String? { switch self { case .unavailable(let message): message; case .invalidResponse: "Codex returned an invalid quota snapshot." } }
}
