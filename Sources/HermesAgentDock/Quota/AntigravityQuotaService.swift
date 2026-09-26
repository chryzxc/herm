import Foundation

/// Reads Antigravity's shared Gemini/non-Gemini quota pools from the local
/// language server of a running Antigravity app or `agy` CLI — the same
/// credential-free strategy OpenUsage uses. The loopback RPC is authorized by
/// the CSRF token the language server itself carries in its argv, so no
/// Keychain credential is read, no OAuth refresh is performed, and no remote
/// Google endpoint is called. When neither Antigravity nor `agy` is running,
/// quota is explicitly unavailable.
///
/// The quota summary RPC is authoritative (merged pools plus weekly windows).
/// Builds without it fall back to the legacy per-model endpoints, which only
/// know the rolling 5-hour windows; per-model fractions there are pooled into
/// the shared Gemini and "Claude & GPT" meters, keeping
/// each pool's worst remaining fraction. Antigravity's quota API is
/// undocumented, so parsing accepts only known bucket IDs and model pools and
/// ignores malformed or future buckets rather than fabricating values.
enum AntigravityQuotaService {
    private static let summaryMethod = "RetrieveUserQuotaSummary"
    private static let userStatusMethod = "GetUserStatus"
    private static let commandConfigsMethod = "GetCommandModelConfigs"

    private struct LanguageServerProbe {
        var processName: String
        var markers: [String]
        var csrfFlag: String?
        var portFlag: String?

        static let antigravityApp = LanguageServerProbe(
            processName: "language_server",
            markers: ["antigravity", "antigravity-ide"],
            csrfFlag: "--csrf_token",
            portFlag: "--extension_server_port"
        )
        static let agyCLI = LanguageServerProbe(processName: "agy", markers: [], csrfFlag: nil, portFlag: nil)
    }

    struct LanguageServer: Sendable, Equatable {
        var pid: Int32
        var csrf: String
        var ports: [Int]
        var extensionPort: Int?
    }

    struct ModelQuota: Sendable, Equatable {
        var label: String
        var modelID: String?
        var remainingFraction: Double
        var resetTime: Date?
    }

    static func read() async throws -> [String: Any] {
        var sawLanguageServer = false
        for probe in [LanguageServerProbe.antigravityApp, .agyCLI] {
            guard let server = await discoverLanguageServer(probe) else { continue }
            sawLanguageServer = true
            if let result = await readQuota(from: server) { return result }
        }
        throw AntigravityQuotaError.unavailable(
            sawLanguageServer
                ? "Antigravity is running, but its local quota service could not be reached. Use Antigravity once, then refresh."
                : "Antigravity is not running. Open Antigravity or start agy, then refresh."
        )
    }

    // MARK: - Language server probing

    private static func readQuota(from server: LanguageServer) async -> [String: Any]? {
        var endpoints: [(scheme: String, port: Int)] = []
        for port in server.ports {
            endpoints.append(("https", port))
            endpoints.append(("http", port))
        }
        if let extensionPort = server.extensionPort {
            endpoints.append(("http", extensionPort))
        }
        for endpoint in endpoints {
            if let result = await readQuota(from: server, endpoint: endpoint) { return result }
        }
        return nil
    }

    private static func readQuota(from server: LanguageServer, endpoint: (scheme: String, port: Int)) async -> [String: Any]? {
        // The quota summary is authoritative. A parseable summary — even with no
        // usable buckets — must never fall through to the legacy endpoints,
        // which fabricate fully-used pools from missing quota info.
        if let summary = await LanguageServerRPC.shared.call(scheme: endpoint.scheme, port: endpoint.port, csrf: server.csrf, method: summaryMethod),
           (200..<300).contains(summary.statusCode),
           let json = decodedObject(summary.body),
           hasQuotaSummaryGroups(json) {
            var result = normalize(json)
            if let plan = await planName(from: server, endpoint: endpoint) {
                result["safe_detail"] = plan
            }
            return result
        }

        if let status = await LanguageServerRPC.shared.call(scheme: endpoint.scheme, port: endpoint.port, csrf: server.csrf, method: userStatusMethod),
           (200..<300).contains(status.statusCode),
           let json = decodedObject(status.body),
           let parsed = parseUserStatus(json) {
            let windows = legacyWindows(parsed.configs)
            if !windows.isEmpty { return snapshot(windows: windows, safeDetail: parsed.plan) }
        }

        if let fallback = await LanguageServerRPC.shared.call(scheme: endpoint.scheme, port: endpoint.port, csrf: server.csrf, method: commandConfigsMethod),
           (200..<300).contains(fallback.statusCode),
           let json = decodedObject(fallback.body),
           let configs = parseCommandModelConfigs(json) {
            let windows = legacyWindows(configs)
            if !windows.isEmpty { return snapshot(windows: windows, safeDetail: nil) }
        }
        return nil
    }

    private static func planName(from server: LanguageServer, endpoint: (scheme: String, port: Int)) async -> String? {
        guard let status = await LanguageServerRPC.shared.call(scheme: endpoint.scheme, port: endpoint.port, csrf: server.csrf, method: userStatusMethod),
              (200..<300).contains(status.statusCode),
              let json = decodedObject(status.body),
              let parsed = parseUserStatus(json) else { return nil }
        return parsed.plan
    }

    private static func snapshot(windows: [[String: Any]], safeDetail: String?) -> [String: Any] {
        [
            "provider": "antigravity",
            "display_name": "Antigravity",
            "updated_at": QuotaJSON.iso8601String(from: .now),
            "windows": windows,
            "safe_detail": safeDetail ?? "Google AI"
        ]
    }

    private static func decodedObject(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Language server discovery

    private static func discoverLanguageServer(_ probe: LanguageServerProbe) async -> LanguageServer? {
        guard let psOutput = await processOutput(executable: "/bin/ps", arguments: ["-ax", "-o", "pid=,command="]) else { return nil }
        let candidates = languageServerCandidates(psOutput: psOutput, processName: probe.processName, markers: probe.markers)
        guard !candidates.isEmpty else { return nil }
        let lsofPath = await lsofExecutable()
        for candidate in candidates {
            let csrf: String
            if let csrfFlag = probe.csrfFlag, !csrfFlag.isEmpty {
                guard let value = flagValue(command: candidate.command, flag: csrfFlag) else { continue }
                csrf = value
            } else {
                csrf = ""
            }
            let extensionPort = probe.portFlag
                .flatMap { flagValue(command: candidate.command, flag: $0) }
                .flatMap(Int.init)
            var ports: [Int] = []
            if let lsofPath,
               let output = await processOutput(executable: lsofPath, arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(candidate.pid)]) {
                ports = listeningPorts(output)
            }
            guard !ports.isEmpty || extensionPort != nil else { continue }
            return LanguageServer(pid: candidate.pid, csrf: csrf, ports: ports, extensionPort: extensionPort)
        }
        return nil
    }

    static func languageServerCandidates(psOutput: String, processName: String, markers: [String]) -> [(pid: Int32, command: String)] {
        let processNameLower = processName.lowercased()
        let markersLower = markers
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        var ranked: [(rank: Int, pid: Int32, command: String)] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" })
            else { continue }
            let pidString = String(line[..<separator])
            let command = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidString),
                  matchesProcessName(command: command, processNameLower: processNameLower),
                  let rank = markerRank(command: command, markersLower: markersLower)
            else { continue }
            ranked.append((rank, pid, command))
        }
        return ranked
            .sorted { $0.rank < $1.rank }
            .map { (pid: $0.pid, command: $0.command) }
    }

    static func flagValue(command: String, flag: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let flagEquals = flag + "="
        for (index, part) in parts.enumerated() {
            if part == flag {
                guard index + 1 < parts.count else { return nil }
                return parts[index + 1]
            }
            if part.hasPrefix(flagEquals) {
                return String(part.dropFirst(flagEquals.count))
            }
        }
        return nil
    }

    /// Exact marker matches on `--ide_name` / `--override_ide_name` /
    /// `--app_data_dir` outrank path-substring matches; a command that carries
    /// any of those flags without a marker match is excluded so `antigravity`
    /// never matches `antigravity-next` or other IDEs' servers.
    static func markerRank(command: String, markersLower: [String]) -> Int? {
        if markersLower.isEmpty { return 0 }
        let ideName = flagValue(command: command, flag: "--ide_name")?.lowercased()
        let overrideIdeName = flagValue(command: command, flag: "--override_ide_name")?.lowercased()
        let appDataDir = flagValue(command: command, flag: "--app_data_dir")?.lowercased()
        if ideName != nil || overrideIdeName != nil || appDataDir != nil {
            return markersLower.contains { ideName == $0 || overrideIdeName == $0 || appDataDir == $0 } ? 0 : nil
        }
        let commandLower = command.lowercased()
        return markersLower.contains { commandLower.contains("/\($0)/") } ? 1 : nil
    }

    static func argvExecutable(command: String) -> String {
        let trimmed = command.drop { $0 == " " || $0 == "\t" }
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        }
        let rest = trimmed.dropFirst()
        if let end = rest.firstIndex(of: quote) {
            return String(rest[..<end])
        }
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    static func matchesProcessName(command: String, processNameLower: String) -> Bool {
        guard !processNameLower.isEmpty else { return false }
        let executableName = (argvExecutable(command: command) as NSString).lastPathComponent.lowercased()
        if executableName == processNameLower { return true }
        let commandLower = command.lowercased()
        if processNameLower.count >= 8 {
            return executableName.hasPrefix("\(processNameLower)_") || commandLower.contains(processNameLower)
        }
        return commandLower.hasSuffix("/\(processNameLower)")
            || commandLower.contains("/\(processNameLower) ")
            || commandLower.contains("/\(processNameLower)\t")
    }

    static func listeningPorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains("LISTEN") else { continue }
            for token in line.split(separator: " ").reversed() {
                if let colon = token.lastIndex(of: ":"),
                   let port = Int(token[token.index(after: colon)...]),
                   (0..<65_536).contains(port) {
                    ports.insert(port)
                    break
                }
            }
        }
        return ports.sorted()
    }

    // MARK: - Legacy per-model payload parsing

    static let internalModelIDs: Set<String> = [
        "MODEL_CHAT_20706", "MODEL_CHAT_23310",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
        "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12"
    ]

    static func parseUserStatus(_ json: [String: Any]) -> (plan: String?, configs: [ModelQuota])? {
        guard let status = json["userStatus"] as? [String: Any] else { return nil }
        let tierName = (status["userTier"] as? [String: Any])?["name"] as? String
            ?? ((status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        let configs = ((status["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]] ?? [])
            .compactMap(modelQuota)
        return (formatPlan(tierName), configs)
    }

    static func parseCommandModelConfigs(_ json: [String: Any]) -> [ModelQuota]? {
        guard let configs = json["clientModelConfigs"] as? [[String: Any]] else { return nil }
        return configs.compactMap(modelQuota)
    }

    private static func modelQuota(_ model: [String: Any]) -> ModelQuota? {
        guard let label = (model["label"] as? String)?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        let modelID = (model["modelOrAlias"] as? [String: Any])?["model"] as? String
        let quotaInfo = model["quotaInfo"] as? [String: Any]
        return ModelQuota(
            label: label,
            modelID: modelID,
            remainingFraction: quotaInfo.flatMap { QuotaJSON.number($0["remainingFraction"]) } ?? 0,
            resetTime: quotaInfo.flatMap { QuotaJSON.date($0["resetTime"]) }
        )
    }

    // MARK: - Legacy pool merging

    /// Collapses per-model quotas into the two shared 5-hour pool meters,
    /// keeping the worst remaining fraction in each pool. A model without
    /// quota info is treated as depleted, so a depleted variant always beats a
    /// healthy sibling and the pool reads fully used instead of optimistic.
    static func legacyWindows(_ configs: [ModelQuota], now: Date = .now) -> [[String: Any]] {
        var pooled: [String: (fraction: Double, resetTime: Date?)] = [:]
        for config in configs {
            let label = normalizedModelLabel(config.label)
            guard !label.isEmpty else { continue }
            if let modelID = config.modelID, internalModelIDs.contains(modelID) { continue }
            let id = label.lowercased().contains("gemini") ? "gemini-5h" : "3p-5h"
            if let existing = pooled[id], config.remainingFraction >= existing.fraction { continue }
            pooled[id] = (config.remainingFraction, config.resetTime)
        }
        return [("gemini-5h", "Gemini Session"), ("3p-5h", "Claude & GPT Session")].compactMap { id, label in
            guard let entry = pooled[id] else { return nil }
            var row: [String: Any] = [
                "id": id,
                "label": label,
                "remaining_percent": max(0, min(1, entry.fraction)) * 100
            ]
            if let resetTime = entry.resetTime, resetTime > now {
                row["resets_at"] = QuotaJSON.iso8601String(from: resetTime)
            }
            return row
        }
    }

    static func normalizedModelLabel(_ label: String) -> String {
        guard let range = label.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) else {
            return label.trimmingCharacters(in: .whitespaces)
        }
        return String(label[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Short plan label from Antigravity's tier names: the language server's
    /// `userTier` ("Google AI Pro") is preferred over the Windsurf-inherited
    /// `planName`, which reads "Pro" for every paid tier.
    static func formatPlan(_ raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("Google AI ") { trimmed = String(trimmed.dropFirst("Google AI ".count)) }
        for keyword in ["Ultra", "Pro", "Free"] where trimmed.lowercased().contains(keyword.lowercased()) { return keyword }
        return trimmed
    }

    static func hasQuotaSummaryGroups(_ json: [String: Any]) -> Bool {
        if let response = json["response"] as? [String: Any], response["groups"] is [[String: Any]] { return true }
        return json["groups"] is [[String: Any]]
    }

    // MARK: - Subprocess helpers

    static func processOutput(executable: String, arguments: [String]) async -> String? {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: executable) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            // Drain the pipe while the child runs: reading before waitUntilExit
            // keeps outputs larger than the pipe buffer (ps -ax is ~180KB) from
            // deadlocking the child on a full pipe.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    private static func lsofExecutable() async -> String? {
        await Task.detached(priority: .utility) {
            ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.fileExists(atPath: $0) }
        }.value
    }

    // MARK: - Quota summary normalization

    static func normalize(_ object: [String: Any], now: Date = .now) -> [String: Any] {
        let groups = ((object["response"] as? [String: Any])?["groups"] as? [[String: Any]]) ?? (object["groups"] as? [[String: Any]]) ?? []
        let specs: [(String, String)] = [("gemini-5h", "Gemini Session"), ("gemini-weekly", "Gemini Weekly"), ("3p-5h", "Claude & GPT Session"), ("3p-weekly", "Claude & GPT Weekly")]
        var windows: [[String: Any]] = []
        for (id, label) in specs {
            for group in groups {
                guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
                guard let bucket = buckets.first(where: { ($0["bucketId"] as? String) == id }),
                      let fraction = QuotaJSON.number(bucket["remainingFraction"]),
                      fraction.isFinite, (0...1).contains(fraction) else { continue }
                var row: [String: Any] = ["id": id, "label": label, "remaining_percent": fraction * 100]
                if let reset = firstDate(bucket["resetTime"]), reset > now { row["resets_at"] = QuotaJSON.iso8601String(from: reset) }
                windows.append(row)
                break
            }
        }
        return ["provider": "antigravity", "display_name": "Antigravity", "updated_at": QuotaJSON.iso8601String(from: now), "windows": windows, "safe_detail": "Google AI"]
    }

    private static func firstDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue) }
        guard let string = value as? String else { return nil }
        if let number = Double(string) { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }
        return QuotaJSON.date(string)
    }
}

/// Loopback Connect-RPC client for the Antigravity language server.
private actor LanguageServerRPC {
    static let shared = LanguageServerRPC()

    private static let service = "exa.language_server_pb.LanguageServerService"
    private static let metadata = ["ideName": "antigravity", "extensionName": "antigravity", "ideVersion": "unknown", "locale": "en"]

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration, delegate: LoopbackTrustDelegate(), delegateQueue: nil)
    }

    /// Returns nil on any transport failure (wrong port, server gone); callers
    /// treat that as "try the next endpoint", not an error.
    func call(scheme: String, port: Int, csrf: String, method: String) async -> (statusCode: Int, body: Data)? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.service)/\(method)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !csrf.isEmpty {
            request.setValue(csrf, forHTTPHeaderField: "x-codeium-csrf-token")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": Self.metadata])
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}

/// The language server serves loopback HTTPS with a self-signed certificate;
/// trust is bypassed for 127.0.0.1 only and every other host keeps full
/// default validation.
private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.host == "127.0.0.1"
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

enum AntigravityQuotaError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return "Antigravity quota is unavailable." }
}
