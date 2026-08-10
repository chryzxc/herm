import Foundation

@MainActor
final class HermesDiagnosticsService {
    func read(client: HermesRPCClientProtocol) async -> [HermesDiagnostic] {
        let commands: [(String, String)] = [
            ("diagnostics.status", "hermes status --all"),
            ("diagnostics.monitoring", "hermes monitoring status"),
            ("diagnostics.checkpoints", "hermes checkpoints status --limit 10"),
            ("diagnostics.hooks", "hermes hooks list")
        ]

        var diagnostics: [HermesDiagnostic] = []
        for (id, command) in commands {
            do {
                let result = try await client.request("shell.exec", params: ["command": command])
                let succeeded = HermesCapabilityService.shellResultSucceeded(result)
                let output = Self.safeSummary((result["stdout"] as? String) ?? (result["stderr"] as? String) ?? "")
                diagnostics.append(HermesDiagnostic(
                    id: id,
                    title: Self.title(for: id),
                    detail: output.isEmpty ? (succeeded ? "Available" : "Unavailable") : output,
                    isAvailable: succeeded
                ))
            } catch {
                diagnostics.append(HermesDiagnostic(
                    id: id,
                    title: Self.title(for: id),
                    detail: error.localizedDescription,
                    isAvailable: false
                ))
            }
        }
        return diagnostics
    }

    nonisolated static func safeSummary(_ output: String) -> String {
        let ansiFree = output.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let lines = ansiFree
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.contains("Auth file:")
                    && !line.contains(".env")
                    && !line.contains("/Users/")
                    && !line.contains("/home/")
                    && !line.contains("/var/")
            }
        return lines.prefix(3).joined(separator: "  ·  ")
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
