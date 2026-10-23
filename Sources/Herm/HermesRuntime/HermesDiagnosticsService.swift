import Foundation

@MainActor
final class HermesDiagnosticsService {
    func read(client: HermesRPCClientProtocol) async -> [HermesDiagnostic] {
        let commands: [(String, String)] = [
            ("diagnostics.status", "hermes status --all"),
            ("diagnostics.monitoring", "hermes monitoring status"),
            ("diagnostics.checkpoints", "hermes checkpoints status --limit 10"),
            ("diagnostics.hooks", "hermes hooks list"),
        ]

        var diagnostics: [HermesDiagnostic] = []
        for (id, command) in commands {
            do {
                let result = try await client.request(
                    HermesFeatureIDs.ID.shellExec.rawValue, params: ["command": command])
                let succeeded = HermesCapabilityService.shellResultSucceeded(result)
                let output = Self.safeSummary((result["stdout"] as? String) ?? (result["stderr"] as? String) ?? "")
                diagnostics.append(
                    HermesDiagnostic(
                        id: id,
                        title: Self.title(for: id),
                        detail: output.isEmpty ? (succeeded ? "Available" : "Unavailable") : output,
                        isAvailable: succeeded
                    ))
            } catch {
                diagnostics.append(
                    HermesDiagnostic(
                        id: id,
                        title: Self.title(for: id),
                        detail: Self.safeSummary(error.localizedDescription),
                        isAvailable: false
                    ))
            }
        }
        return diagnostics
    }

    nonisolated static func safeSummary(_ output: String) -> String {
        var lines: [String] = []
        var remaining = output[...]
        while !remaining.isEmpty, lines.count < 3 {
            let end = remaining.firstIndex(of: "\n") ?? remaining.endIndex
            let raw = String(remaining[..<end])
            remaining = end == remaining.endIndex ? "" : remaining[remaining.index(after: end)...]
            let ansiFree = raw.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            let line = scrubHomePath(
                in: scrubSecrets(
                    in: scrubEndpointURL(
                        in:
                            ansiFree.trimmingCharacters(in: .whitespacesAndNewlines)
                    )))
            if !line.isEmpty, !line.contains("Auth file:"), !line.contains(".env") {
                lines.append(line)
            }
        }
        return String(lines.joined(separator: "  ·  ").prefix(1_000))
    }

    nonisolated private static func scrubEndpointURL(in line: String) -> String {
        replace(
            in: line,
            pattern: "\\b(?:https?|wss?)://[^\\s<>\\\"']+",
            options: [.caseInsensitive],
            template: "••••")
    }

    nonisolated private static func scrubSecrets(in line: String) -> String {
        var scrubbed = replace(
            in: line,
            pattern: "(token|password|passwd|secret|api[_-]?key|auth[_-]?token|access[_-]?key|bearer)\\s*[:=]\\s*\\S+",
            options: [.caseInsensitive],
            template: "$1: ••••")
        scrubbed = replace(
            in: scrubbed,
            pattern:
                "(?:sk-ant-|sk-|ghp_|gho_|github_pat_|xox[bpoa]-|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35})[A-Za-z0-9_-]+",
            options: [],
            template: "••••")
        return scrubbed
    }

    nonisolated private static func scrubHomePath(in line: String) -> String {
        var scrubbed = line
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty, home != "/" {
            scrubbed = scrubbed.replacingOccurrences(of: home, with: "••••")
        }
        for pattern in ["/Users/[^/\\s]+", "/home/[^/\\s]+"] {
            scrubbed = replace(in: scrubbed, pattern: pattern, options: [], template: "••••")
        }
        return scrubbed.replacingOccurrences(of: "~/", with: "••••/")
    }

    nonisolated private static func replace(
        in input: String, pattern: String, options: NSRegularExpression.Options, template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }

    private static func title(for id: String) -> String {
        switch id {
        case "diagnostics.status": "Hermes health"
        case "diagnostics.monitoring": "Gateway monitoring"
        case "diagnostics.checkpoints": "Checkpoint storage"
        case "diagnostics.hooks": "Shell hooks"
        default: "Hermes diagnostic"
        }
    }
}
