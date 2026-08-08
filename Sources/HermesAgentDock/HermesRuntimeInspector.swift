import Foundation

struct HermesRuntimeConfiguration: Sendable, Equatable {
    let model: String?
    let provider: String?
    let configPath: String?
    let maxTurns: String?
    let terminalTimeout: String?
    let skills: [String]
    let mcpServers: [String]
    let plugins: [String]
}

enum HermesRuntimeInspector {
    private static let commandTimeout: TimeInterval = 15

    static func read() -> HermesRuntimeConfiguration {
        let model = output(arguments: ["config", "get", "model.default"])
        let provider = output(arguments: ["config", "get", "model.provider"])
        let configPath = output(arguments: ["config", "path"])
        let maxTurns = output(arguments: ["config", "get", "agent.max_turns"])
        let terminalTimeout = output(arguments: ["config", "get", "terminal.timeout"])
        let skills = parseSkills(output(arguments: ["skills", "list", "--enabled-only"]) ?? "")
        let mcpServers = parseMCPServers(output(arguments: ["mcp", "list"]) ?? "")
        let plugins = parsePlugins(output(arguments: ["plugins", "list", "--enabled", "--json"]) ?? "")
        return HermesRuntimeConfiguration(
            model: nonEmpty(model),
            provider: nonEmpty(provider),
            configPath: nonEmpty(configPath),
            maxTurns: nonEmpty(maxTurns),
            terminalTimeout: nonEmpty(terminalTimeout),
            skills: skills,
            mcpServers: mcpServers,
            plugins: plugins
        )
    }

    static func setModel(_ model: String, provider: String) -> Bool {
        guard run(arguments: ["config", "set", "model.provider", provider]) else { return false }
        return run(arguments: ["config", "set", "model.default", model])
    }

    private static func output(arguments: [String]) -> String? {
        guard let data = runData(arguments: arguments) else { return nil }
        return String(data: data, encoding: .utf8)
            .map(stripANSI)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func run(arguments: [String]) -> Bool {
        runData(arguments: arguments) != nil
    }

    private static func runData(arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["hermes"] + arguments
        process.environment = HermesEnvironment.processEnvironment()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let timeout = DispatchWorkItem {
                guard process.isRunning else { return }
                process.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + commandTimeout,
                execute: timeout
            )
            // Drain before waiting: `skills list` can produce more output than a
            // pipe buffer, which otherwise blocks Hermes before it can exit.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func parseSkills(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "│", omittingEmptySubsequences: false)
            guard columns.count >= 6 else { return nil }
            let name = columns[1].trimmingCharacters(in: .whitespaces)
            let status = columns[5].trimmingCharacters(in: .whitespaces).lowercased()
            return !name.isEmpty && status == "enabled" ? name : nil
        }
    }

    private static func parseMCPServers(_ output: String) -> [String] {
        guard !output.localizedCaseInsensitiveContains("No MCP servers configured") else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let columns = line.split(separator: "│", omittingEmptySubsequences: false)
            guard columns.count > 2 else { return nil }
            let name = columns[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || name.lowercased() == "name" ? nil : name
        }
    }

    private static func parsePlugins(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let status = (row["status"] as? String)?.lowercased() ?? ""
            return status == "enabled" ? row["name"] as? String : nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func stripANSI(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
