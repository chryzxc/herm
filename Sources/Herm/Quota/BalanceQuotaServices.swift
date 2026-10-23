import Foundation

/// Pay-as-you-go API providers report an account balance instead of rolling
/// windows, so their snapshots carry the balance as text, not a percentage.
enum BalanceQuota {
    /// Herm's own pasted key first, then the process environment, then the
    /// key Hermes itself reads from `$HERMES_HOME/.env`.
    static func apiKey(storageKey: String, envNames: [String]) -> String? {
        if let stored = ProviderKeyStore().savedKey(storageKey) { return stored }
        let environment = ProcessInfo.processInfo.environment
        if let key = envNames.compactMap({ environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(
            where: { !$0.isEmpty })
        {
            return key
        }
        let root =
            environment["HERMES_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
        guard let text = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) else {
            return nil
        }
        return envNames.lazy.compactMap { envValue($0, in: text) }.first
    }

    static func envValue(_ name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix(name + "=") else { continue }
            let value = line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func money(_ amount: Double, currency: String = "USD") -> String {
        let symbol = currency == "USD" ? "$" : currency == "CNY" ? "¥" : "\(currency) "
        return "\(symbol)\(String(format: "%.2f", amount))"
    }

    static func fetch(_ url: URL, key: String, provider: String) async throws -> [String: Any] {
        switch await QuotaHTTP.getJSON(url: url, headers: ["Authorization": "Bearer \(key)"]) {
        case .success(let value): return value
        case .failure(.network): throw BalanceQuotaError.unavailable("\(provider) balance could not be reached.")
        case .failure(.status(let code)):
            throw BalanceQuotaError.unavailable(
                code == 401 || code == 403
                    ? "\(provider) authentication was rejected." : "\(provider) balance returned HTTP \(code).")
        case .failure(.invalidResponse):
            throw BalanceQuotaError.unavailable("\(provider) returned an invalid balance snapshot.")
        }
    }

    static func snapshot(provider: String, displayName: String, windows: [[String: Any]], detail: String, now: Date)
        -> [String: Any]
    {
        [
            "provider": provider, "display_name": displayName, "updated_at": QuotaJSON.iso8601String(from: now),
            "windows": windows, "safe_detail": detail,
        ]
    }

    static func requireWindows(_ snapshot: [String: Any], provider: String) throws -> [String: Any] {
        guard let windows = snapshot["windows"] as? [[String: Any]], !windows.isEmpty else {
            throw BalanceQuotaError.unavailable("No \(provider) balance was returned.")
        }
        return snapshot
    }
}

enum BalanceQuotaError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// DeepSeek API balance (`/user/balance`).
enum DeepSeekQuotaService {
    static func read() async throws -> [String: Any] {
        guard let key = BalanceQuota.apiKey(storageKey: "deepseek", envNames: ["DEEPSEEK_API_KEY"]) else {
            throw BalanceQuotaError.unavailable("No DeepSeek API key was found.")
        }
        let object = try await BalanceQuota.fetch(
            URL(string: "https://api.deepseek.com/user/balance")!, key: key, provider: "DeepSeek")
        return try BalanceQuota.requireWindows(normalize(object), provider: "DeepSeek")
    }

    static func normalize(_ object: [String: Any], now: Date = .now) -> [String: Any] {
        let available = object["is_available"] as? Bool ?? true
        let infos = object["balance_infos"] as? [[String: Any]] ?? []
        let windows: [[String: Any]] = infos.prefix(2).compactMap { info in
            guard let currency = info["currency"] as? String, let total = QuotaJSON.number(info["total_balance"]) else {
                return nil
            }
            var row: [String: Any] = [
                "id": "balance-\(currency.lowercased())", "label": "Balance",
                "remaining_display": BalanceQuota.money(total, currency: currency),
            ]
            let toppedUp = QuotaJSON.number(info["topped_up_balance"]) ?? total
            let granted = QuotaJSON.number(info["granted_balance"]) ?? 0
            row["limit_display"] =
                granted > 0
                ? "\(BalanceQuota.money(toppedUp, currency: currency)) topped up · \(BalanceQuota.money(granted, currency: currency)) granted"
                : "Topped up"
            if currency == "USD" { row["amount"] = total }
            // An unavailable account cannot make calls, so surface it as exhausted.
            if !available { row["remaining_percent"] = 0 }
            return row
        }
        return BalanceQuota.snapshot(
            provider: "deepseek", displayName: "DeepSeek", windows: windows, detail: "Pay-as-you-go", now: now)
    }
}

/// Kimi (Moonshot open platform) balance (`/v1/users/me/balance`).
// ponytail: international platform only; Kimi Code plan keys and api.moonshot.cn accounts aren't read.
enum KimiQuotaService {
    static func read() async throws -> [String: Any] {
        guard let key = BalanceQuota.apiKey(storageKey: "kimi", envNames: ["MOONSHOT_API_KEY", "KIMI_API_KEY"]) else {
            throw BalanceQuotaError.unavailable("No Kimi API key was found.")
        }
        let object = try await BalanceQuota.fetch(
            URL(string: "https://api.moonshot.ai/v1/users/me/balance")!, key: key, provider: "Kimi")
        return try BalanceQuota.requireWindows(normalize(object), provider: "Kimi")
    }

    static func normalize(_ object: [String: Any], now: Date = .now) -> [String: Any] {
        let data = object["data"] as? [String: Any] ?? object
        var windows: [[String: Any]] = []
        if let available = QuotaJSON.number(data["available_balance"]) {
            var row: [String: Any] = [
                "id": "balance", "label": "Balance", "remaining_display": BalanceQuota.money(available),
                "amount": available,
            ]
            if let voucher = QuotaJSON.number(data["voucher_balance"]), voucher > 0 {
                row["limit_display"] = "incl. \(BalanceQuota.money(voucher)) voucher"
            }
            // Moonshot rejects calls once the available balance is not positive.
            if available <= 0 { row["remaining_percent"] = 0 }
            windows.append(row)
        }
        return BalanceQuota.snapshot(
            provider: "kimi", displayName: "Kimi", windows: windows, detail: "Pay-as-you-go", now: now)
    }
}

/// OpenRouter account credits (`/api/v1/credits`) plus the key's own spend
/// limit (`/api/v1/key`) when one is set.
enum OpenRouterQuotaService {
    static func read() async throws -> [String: Any] {
        guard let key = BalanceQuota.apiKey(storageKey: "openrouter", envNames: ["OPENROUTER_API_KEY"]) else {
            throw BalanceQuotaError.unavailable("No OpenRouter API key was found.")
        }
        let credits = try? await BalanceQuota.fetch(
            URL(string: "https://openrouter.ai/api/v1/credits")!, key: key, provider: "OpenRouter")
        let keyInfo = try await BalanceQuota.fetch(
            URL(string: "https://openrouter.ai/api/v1/key")!, key: key, provider: "OpenRouter")
        return try BalanceQuota.requireWindows(normalize(credits: credits, key: keyInfo), provider: "OpenRouter")
    }

    static func normalize(credits: [String: Any]?, key: [String: Any], now: Date = .now) -> [String: Any] {
        var windows: [[String: Any]] = []
        let creditData = credits?["data"] as? [String: Any]
        if let total = QuotaJSON.number(creditData?["total_credits"]),
            let used = QuotaJSON.number(creditData?["total_usage"])
        {
            let left = max(0, total - used)
            var row: [String: Any] = [
                "id": "credits", "label": "Credits", "remaining_display": BalanceQuota.money(left),
                "limit_display": "of \(BalanceQuota.money(total))", "amount": left,
            ]
            if total > 0 { row["remaining_percent"] = min(100, left / total * 100) }
            windows.append(row)
        }
        let keyData = key["data"] as? [String: Any] ?? key
        if let limit = QuotaJSON.number(keyData["limit"]), limit > 0 {
            let left =
                QuotaJSON.number(keyData["limit_remaining"])
                ?? max(0, limit - (QuotaJSON.number(keyData["usage"]) ?? 0))
            windows.append([
                "id": "key-limit", "label": "Key limit", "remaining_percent": max(0, min(100, left / limit * 100)),
                "limit_display": "\(BalanceQuota.money(left)) of \(BalanceQuota.money(limit))",
            ])
        } else if windows.isEmpty, let usage = QuotaJSON.number(keyData["usage"]) {
            windows.append([
                "id": "usage", "label": "Key usage", "remaining_display": "\(BalanceQuota.money(usage)) spent",
            ])
        }
        let detail = (keyData["is_free_tier"] as? Bool) == true ? "Free tier" : "Pay-as-you-go"
        return BalanceQuota.snapshot(
            provider: "openrouter", displayName: "OpenRouter", windows: windows, detail: detail, now: now)
    }
}
