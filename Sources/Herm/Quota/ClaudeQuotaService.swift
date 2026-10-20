import Foundation

/// Reads the subscription usage windows used by Claude Code's `/usage` view.
/// API-key billing has no subscription quota, so this only uses Claude Code OAuth.
enum ClaudeQuotaService {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Keychain access can require the user to approve a system consent
    /// dialog. Caching the token in memory for the process lifetime avoids
    /// re-prompting on every periodic quota refresh; a cached token that
    /// turns out to be stale is dropped and re-read once.
    private static let tokenCache = TokenCache()

    private final class TokenCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func get() -> String? {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set(_ token: String?) {
            lock.lock(); defer { lock.unlock() }
            value = token
        }
    }

    static func read() async throws -> [String: Any] {
        guard let token = await loadAccessToken() else { throw ClaudeQuotaError.unavailable("No Claude Code OAuth login was found.") }
        let object: [String: Any]
        switch await QuotaHTTP.getJSON(url: usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20"
        ]) {
        case .success(let value): object = value
        case .failure(.network): throw ClaudeQuotaError.unavailable("Claude Code usage could not be reached.")
        case .failure(.status(429)): throw ClaudeQuotaError.unavailable("Claude usage is temporarily rate limited; try again later.")
        case .failure(.status(let code)):
            if code == 401 || code == 403 {
                // The cached token may be stale (e.g. after re-login); drop it
                // and retry once with a fresh Keychain/file read.
                if tokenCache.get() == token {
                    tokenCache.set(nil)
                    if let refreshed = await loadAccessToken(), refreshed != token {
                        return try await read()
                    }
                }
                throw ClaudeQuotaError.unavailable("Claude Code authentication was rejected.")
            }
            throw ClaudeQuotaError.unavailable("Claude usage returned HTTP \(code).")
        case .failure(.invalidResponse): throw ClaudeQuotaError.invalidResponse
        }
        let normalized = normalize(object)
        guard let windows = normalized["windows"] as? [[String: Any]], !windows.isEmpty else { throw ClaudeQuotaError.unavailable("Claude did not return any subscription quota windows.") }
        return normalized
    }

    private static func loadAccessToken() async -> String? {
        if let cached = tokenCache.get() { return cached }
        let environment = ProcessInfo.processInfo.environment
        if let token = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN"].compactMap({ environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
            tokenCache.set(token)
            return token
        }
        // On macOS, the Claude Code CLI stores its OAuth credentials in the login
        // Keychain (service "Claude Code-credentials"). Check it first: a leftover
        // dotfile from an older login holds a stale token that the usage endpoint
        // answers with a permanent 429.
        if let data = await loadKeychainCredentialsData(), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = token(fromCredentialsJSON: json) {
            tokenCache.set(token)
            return token
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [home.appendingPathComponent(".claude/.credentials.json"), home.appendingPathComponent(".config/claude-code/.credentials.json")]
        for file in files {
            guard let data = try? Data(contentsOf: file), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let token = token(fromCredentialsJSON: json) {
                tokenCache.set(token)
                return token
            }
        }
        return nil
    }

    private static func token(fromCredentialsJSON json: [String: Any]) -> String? {
        if let auth = json["claudeAiOauth"] as? [String: Any], let token = auth["accessToken"] as? String, !token.isEmpty { return token }
        if let token = json["accessToken"] as? String, !token.isEmpty { return token }
        return nil
    }

    private static func loadKeychainCredentialsData() async -> Data? {
        // Runs off the cooperative thread pool: `security` can block on a
        // Keychain consent dialog, and a blocking `waitUntilExit()` executed
        // directly inside a Task starves the small pool of worker threads
        // that MainActor work also depends on, producing the app-wide hangs.
        await Task.detached(priority: .utility) { () -> Data? in
            // Read through the system `security` CLI instead of calling
            // SecItemCopyMatching in-process. The Dock is an ad-hoc-signed debug
            // build whose code signature changes on every rebuild, so macOS
            // treats each rebuilt binary as a new, unrecognized requester and
            // re-prompts for Keychain consent forever. `/usr/bin/security` is a
            // stable Apple-signed binary: granting it "Always Allow" once
            // persists across Dock rebuilds and stops the repeated prompt.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-w", "-s", "Claude Code-credentials"]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            guard !output.isEmpty else { return nil }
            // `security -w` prints the secret followed by a trailing newline.
            var text = String(data: output, encoding: .utf8) ?? ""
            while text.hasSuffix("\n") { text.removeLast() }
            return text.data(using: .utf8)
        }.value
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
