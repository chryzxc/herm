import Foundation

/// Reads Z.ai/GLM Coding Plan quota from the provider subscription monitor.
enum GLMQuotaService {
    private static let usageURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    static func read() async throws -> [String: Any] {
        guard let key = loadAPIKey() else {
            throw GLMQuotaError.unavailable("No Z.ai/GLM Coding Plan API key was found.")
        }
        let object: [String: Any]
        switch await QuotaHTTP.getJSON(
            url: usageURL,
            headers: [
                "Authorization": key
            ])
        {
        case .success(let value): object = value
        case .failure(.network): throw GLMQuotaError.unavailable("GLM Coding Plan quota could not be reached.")
        case .failure(.status(let code)):
            throw GLMQuotaError.unavailable(
                code == 401 || code == 403
                    ? "GLM Coding Plan authentication was rejected." : "GLM quota returned HTTP \(code).")
        case .failure(.invalidResponse): throw GLMQuotaError.invalidResponse
        }
        let normalized = normalize(object)
        guard let windows = normalized["windows"] as? [[String: Any]], !windows.isEmpty else {
            throw GLMQuotaError.unavailable("No active GLM Coding Plan quota was returned.")
        }
        return normalized
    }

    private static func loadAPIKey() -> String? {
        // Includes the key Settings → Providers saves into Hermes' .env.
        if let key = BalanceQuota.apiKey(
            storageKey: "glm", envNames: ["ZAI_API_KEY", "GLM_API_KEY", "ZHIPUAI_API_KEY"])
        {
            return key
        }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataHome =
            environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let candidates = [
            dataHome.appendingPathComponent("opencode/auth.json"),
            home.appendingPathComponent(".config/opencode/auth.json"),
            home.appendingPathComponent(".config/openusage/zai.json"),
            home.appendingPathComponent(".config/zai/key.json"),
        ]
        for file in candidates {
            guard let data = try? Data(contentsOf: file),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for provider in ["zai-coding-plan", "zhipu-coding-plan", "zai", "glm"] {
                if let entry = json[provider] as? [String: Any],
                    let key = (entry["key"] as? String ?? entry["apiKey"] as? String)?.trimmingCharacters(
                        in: .whitespacesAndNewlines), !key.isEmpty
                {
                    return key
                }
            }
            if let key = (json["key"] as? String ?? json["apiKey"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines), !key.isEmpty
            {
                return key
            }
        }
        return nil
    }

    static func normalize(_ object: [String: Any], now: Date = .now) -> [String: Any] {
        let data = object["data"] as? [String: Any] ?? object
        let limits = data["limits"] as? [[String: Any]] ?? []
        var windows: [[String: Any]] = []
        for limit in limits {
            let type = (limit["type"] as? String)?.uppercased() ?? ""
            guard type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" || type == "TIME_LIMIT",
                let used = QuotaJSON.number(limit["percentage"])
            else { continue }
            let remaining = max(0, min(100, 100 - used))
            let unit = QuotaJSON.number(limit["unit"]) ?? 0
            let numberValue = QuotaJSON.number(limit["number"]) ?? 1
            let id: String
            let label: String
            if type == "TIME_LIMIT" {
                id = "web-search"
                label = "Web searches"
            } else if unit == 3 && numberValue <= 24 {
                id = "session"
                label = "Session"
            } else {
                id = "weekly"
                label = "Weekly"
            }
            guard !windows.contains(where: { $0["id"] as? String == id }) else { continue }
            var row: [String: Any] = ["id": id, "label": label, "remaining_percent": remaining]
            if let reset = QuotaJSON.date(limit["nextResetTime"]) {
                row["resets_at"] = QuotaJSON.iso8601String(from: reset)
            }
            if type == "CREDIT_LIMIT" { row["limit_display"] = "Credits" }
            windows.append(row)
        }
        return [
            "provider": "glm", "display_name": "GLM Coding Plan", "model": "GLM",
            "updated_at": QuotaJSON.iso8601String(from: now), "windows": windows,
            "safe_detail": (data["level"] as? String).map { $0.uppercased() } ?? "Coding Plan",
        ]
    }
}

enum GLMQuotaError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidResponse: "GLM returned an invalid quota snapshot."
        }
    }
}
