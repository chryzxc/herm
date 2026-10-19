import Foundation

/// Reads OpenCode Go's usage windows through its documented usage endpoint.
enum OpenCodeQuotaService {
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static func read() async throws -> [String: Any] {
        guard let key = loadAPIKey() else { throw OpenCodeQuotaError.unavailable("No OpenCode Go API key was found.") }
        let object: [String: Any]
        switch await QuotaHTTP.getJSON(url: usageURL, headers: [
            "Authorization": "Bearer \(key)"
        ]) {
        case .success(let value): object = value
        case .failure(.network): throw OpenCodeQuotaError.unavailable("OpenCode Go usage could not be reached.")
        case .failure(.status(let code)): throw OpenCodeQuotaError.unavailable(code == 401 || code == 403 ? "OpenCode Go authentication was rejected." : "OpenCode Go usage returned HTTP \(code).")
        case .failure(.invalidResponse): throw OpenCodeQuotaError.invalidResponse
        }
        return normalize(object)
    }

    private static func loadAPIKey() -> String? {
        // Includes the key Settings → Providers saves into Hermes' .env.
        if let key = BalanceQuota.apiKey(storageKey: "opencode-go", envNames: ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY", "ZEN_API_KEY"]) { return key }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataHome = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let candidates = [dataHome.appendingPathComponent("opencode/auth.json"), home.appendingPathComponent(".config/opencode/auth.json")]
        for file in candidates {
            guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for provider in ["opencode-go", "opencode"] {
                if let entry = json[provider] as? [String: Any], let key = entry["key"] as? String, !key.isEmpty { return key }
            }
        }
        return nil
    }

    private static func normalize(_ object: [String: Any]) -> [String: Any] {
        let usage = object["usage"] as? [String: Any] ?? object
        let windows: [[String: Any]] = [("rolling", "Session"), ("weekly", "Weekly"), ("monthly", "Monthly")].compactMap { id, label in
            guard let raw = usage[id] as? [String: Any], let consumed = QuotaJSON.number(raw["percent"]) else { return nil }
            var row: [String: Any] = ["id": id, "label": label, "remaining_percent": max(0, min(100, 100 - consumed))]
            if let reset = raw["resetsAt"] as? String { row["resets_at"] = reset }
            else if let seconds = QuotaJSON.number(raw["resetsInSeconds"]) { row["resets_at"] = QuotaJSON.iso8601String(from: Date(timeIntervalSinceNow: seconds)) }
            return row
        }
        return ["provider": "opencode", "display_name": "OpenCode Go", "updated_at": QuotaJSON.iso8601String(from: .now), "windows": windows, "safe_detail": "Go"]
    }
}

enum OpenCodeQuotaError: LocalizedError {
    case unavailable(String)
    case invalidResponse
    var errorDescription: String? { switch self { case .unavailable(let message): message; case .invalidResponse: "OpenCode Go returned an invalid quota snapshot." } }
}
