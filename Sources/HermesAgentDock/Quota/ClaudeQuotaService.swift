import Foundation

/// Reads the subscription usage windows used by Claude Code's `/usage` view.
/// API-key billing has no subscription quota, so this only uses Claude Code OAuth.
enum ClaudeQuotaService {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func read() async throws -> [String: Any] {
        guard let token = loadAccessToken() else { throw ClaudeQuotaError.unavailable("No Claude Code OAuth login was found.") }
        let object: [String: Any]
        switch await QuotaHTTP.getJSON(url: usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20"
        ]) {
        case .success(let value): object = value
        case .failure(.network): throw ClaudeQuotaError.unavailable("Claude Code usage could not be reached.")
        case .failure(.status(429)): throw ClaudeQuotaError.unavailable("Claude usage is temporarily rate limited; try again later.")
        case .failure(.status(let code)): throw ClaudeQuotaError.unavailable(code == 401 || code == 403 ? "Claude Code authentication was rejected." : "Claude usage returned HTTP \(code).")
        case .failure(.invalidResponse): throw ClaudeQuotaError.invalidResponse
        }
        let normalized = normalize(object)
        guard let windows = normalized["windows"] as? [[String: Any]], !windows.isEmpty else { throw ClaudeQuotaError.unavailable("Claude did not return any subscription quota windows.") }
        return normalized
    }

    private static func loadAccessToken() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let token = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN"].compactMap({ environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) { return token }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [home.appendingPathComponent(".claude/.credentials.json"), home.appendingPathComponent(".config/claude-code/.credentials.json")]
        for file in files {
            guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let auth = json["claudeAiOauth"] as? [String: Any], let token = auth["accessToken"] as? String, !token.isEmpty { return token }
            if let token = json["accessToken"] as? String, !token.isEmpty { return token }
        }
        return nil
    }

    static func normalize(_ object: [String: Any], now: Date = .now) -> [String: Any] {
        let rows: [(String, String)] = [("five_hour", "Session"), ("seven_day", "Weekly"), ("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet"), ("seven_day_fable", "Fable")]
        var windows: [[String: Any]] = []
        for (id, label) in rows {
            guard let raw = object[id] as? [String: Any], let used = QuotaJSON.number(raw["utilization"] ?? raw["used_percentage"] ?? raw["percentage"]) else { continue }
            var row: [String: Any] = ["id": id, "label": label, "remaining_percent": max(0, min(100, 100 - used))]
            if let reset = QuotaJSON.date(raw["resets_at"] ?? raw["reset_at"] ?? raw["resetsAt"]) { row["resets_at"] = QuotaJSON.iso8601String(from: reset) }
            windows.append(row)
        }
        return ["provider": "claude", "display_name": "Claude Code", "model": "Claude", "updated_at": QuotaJSON.iso8601String(from: now), "windows": windows, "safe_detail": "Subscription"]
    }
}

enum ClaudeQuotaError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    var errorDescription: String? { switch self { case .unavailable(let message): message; case .invalidResponse: "Claude returned an invalid quota snapshot." } }
}
