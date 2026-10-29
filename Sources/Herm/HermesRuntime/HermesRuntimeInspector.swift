import Foundation

struct HermesRuntimeConfiguration: Sendable, Equatable {
    /// The display identity from Hermes' SOUL.md, when one is configured.
    let agentName: String?
    let model: String?
    let provider: String?
    let configPath: String?
    let maxTurns: String?
    let terminalTimeout: String?
    let skills: [String]
    let skillsInventory: HermesSkillsInventory
    let mcpServers: [String]
    let plugins: [String]
}

struct HermesRuntimeInspection: Sendable {
    let configuration: HermesRuntimeConfiguration
    let isComplete: Bool
    let initialSignature: String?

    init(configuration: HermesRuntimeConfiguration, isComplete: Bool, initialSignature: String? = nil) {
        self.configuration = configuration
        self.isComplete = isComplete
        self.initialSignature = initialSignature
    }
}

enum HermesRuntimeInspector {
    private static let commandTimeout: TimeInterval = 15

    /// Resolves just the menu-bar identity without waiting for the complete
    /// runtime inspection (skills, MCP servers, plugins, and model settings).
    static func readAgentName() -> String? {
        output(arguments: ["config", "path"]).flatMap { agentName(configPath: $0) }
    }

    static func read() -> HermesRuntimeConfiguration {
        inspect().configuration
    }

    static func inspect(
        runner: ([String]) -> String? = { output(arguments: $0) },
        identityReader: (String) -> String? = { agentName(configPath: $0) },
        signatureReader: (String) -> String? = { HermesRuntimeConfigurationRefresh.fileSignatureNow($0) },
        onIdentity: (String?) -> Void = { _ in }
    ) -> HermesRuntimeInspection {
        let configPath = nonEmpty(runner(["config", "path"]))
        // Capture metadata before SOUL or any configuration values are read.
        let initialSignature = configPath.flatMap(signatureReader)
        let name = configPath.flatMap(identityReader)
        onIdentity(name)
        let model = nonEmpty(runner(["config", "get", "model.default"]))
        let provider = nonEmpty(runner(["config", "get", "model.provider"]))
        let maxTurns = nonEmpty(runner(["config", "get", "agent.max_turns"]))
        let terminalTimeout = nonEmpty(runner(["config", "get", "terminal.timeout"]))
        // `runData` prepends `hermes`; the shared contract command already includes it.
        let skillsOutput = runner(Array(HermesFeatureContract.enabledSkillsCommand.words.dropFirst()))
        let mcpOutput = runner(["mcp", "list"])
        let pluginsOutput = runner(["plugins", "list", "--enabled", "--json"])
        let skills = parseEnabledSkills(skillsOutput ?? "")
        let mcpServers = parseMCPServers(mcpOutput ?? "")
        let plugins = parsePlugins(pluginsOutput ?? "")
        let validSkills: Bool
        if case .supported = skills { validSkills = true } else { validSkills = false }
        let validMCP =
            mcpOutput.map {
                $0.localizedCaseInsensitiveContains("No MCP servers configured") || !parseMCPServers($0).isEmpty
            } ?? false
        let validPlugins =
            pluginsOutput.flatMap { $0.data(using: .utf8) }.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
            }.map { rows in
                rows.allSatisfy {
                    ($0["name"] as? String)?.isEmpty == false
                        && ($0["status"] as? String)?.lowercased() == "enabled"
                }
            } ?? false
        let configuration = HermesRuntimeConfiguration(
            agentName: name,
            model: nonEmpty(model),
            provider: nonEmpty(provider),
            configPath: nonEmpty(configPath),
            maxTurns: nonEmpty(maxTurns),
            terminalTimeout: nonEmpty(terminalTimeout),
            skills: skills.names,
            skillsInventory: skills,
            mcpServers: mcpServers,
            plugins: plugins
        )
        return HermesRuntimeInspection(
            configuration: configuration,
            isComplete: [model, provider, configPath, maxTurns, terminalTimeout].allSatisfy { $0 != nil }
                && validSkills && validMCP && validPlugins,
            initialSignature: initialSignature)
    }

    /// Remote backends: the same projection from the backend's REST routes, since the local CLI
    /// would describe this Mac's Hermes and `shell.exec` truncates output. SOUL.md and the config
    /// path stay unknown (no file signature), so every refresh re-reads.
    @MainActor static func inspectRemote(fetch: (String) async throws -> [String: Any]) async -> HermesRuntimeInspection
    {
        func read(_ path: String) async -> [String: Any]? { try? await fetch(path) }
        let info = await read("/api/model/info")
        let config = await read("/api/config")
        let skillRows = await read("/api/skills")?["items"] as? [[String: Any]]
        let mcpRows = await read("/api/mcp/servers")?["servers"] as? [[String: Any]]
        let pluginRows = await read("/api/dashboard/plugins/hub")?["plugins"] as? [[String: Any]]
        func text(_ value: Any?) -> String? { value.flatMap { nonEmpty("\($0)") } }
        func setting(_ section: String, _ key: String) -> String? {
            text((config?[section] as? [String: Any])?[key])
        }
        let skills = (skillRows ?? []).compactMap { $0["enabled"] as? Bool == true ? $0["name"] as? String : nil }
        let model = text(info?["model"])
        let provider = text(info?["provider"])
        let maxTurns = setting("agent", "max_turns")
        let terminalTimeout = setting("terminal", "timeout")
        return HermesRuntimeInspection(
            configuration: HermesRuntimeConfiguration(
                agentName: nil, model: model, provider: provider, configPath: nil,
                maxTurns: maxTurns, terminalTimeout: terminalTimeout,
                skills: skills,
                skillsInventory: skillRows == nil ? .unavailable(.unsupportedOutput) : .supported(skills),
                mcpServers: (mcpRows ?? []).compactMap { $0["name"] as? String },
                plugins: (pluginRows ?? []).compactMap {
                    $0["runtime_status"] as? String == "enabled" ? $0["name"] as? String : nil
                }),
            isComplete: [model, provider, maxTurns, terminalTimeout].allSatisfy { $0 != nil }
                && skillRows != nil && mcpRows != nil && pluginRows != nil)
    }

    /// Hermes stores the primary agent identity in SOUL.md beside config.yaml.
    /// Keep this parser deliberately narrow: only a level-one Markdown heading
    /// in the first part of the file becomes UI identity text.
    static func parseAgentName(_ soul: String) -> String? {
        for line in soul.split(whereSeparator: \.isNewline).prefix(32) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("# ") else { continue }
            let heading = String(trimmed.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // SOUL.md headings can add a role after an em dash, for example
            // `# Nexus — Coordinator`. The menu bar should show the agent's
            // identity, not its descriptive role.
            let name =
                heading
                .split(separator: "—", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? heading
            guard !name.isEmpty, name.count <= 80 else { return nil }
            return name
        }
        return nil
    }

    private static func agentName(configPath: String) -> String? {
        let configURL = URL(fileURLWithPath: configPath)
        let soulURL = configURL.deletingLastPathComponent().appendingPathComponent("SOUL.md")
        guard let soul = try? String(contentsOf: soulURL, encoding: .utf8) else { return nil }
        return parseAgentName(soul)
    }

    private static func output(arguments: [String]) -> String? {
        guard let data = runData(arguments: arguments) else { return nil }
        return String(data: data, encoding: .utf8)
            .map(stripANSI)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func runData(arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["hermes"] + arguments
        var environment = HermesEnvironment.processEnvironment()
        // Rich tables default to 80 columns off a TTY and ellipsize skill names.
        environment["COLUMNS"] = "240"
        process.environment = environment
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

    static func parseEnabledSkills(_ output: String) -> HermesSkillsInventory {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable(.emptyOutput) }

        // Keep compatibility with complete machine-readable records when a
        // caller already has them, but do not infer a new CLI JSON contract.
        if let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        {
            let rows: [[String: Any]]
            let recognized: Bool
            if let array = object as? [[String: Any]] {
                rows = array
                recognized = true
            } else if let envelope = object as? [String: Any],
                let array = envelope["skills"] as? [[String: Any]]
            {
                rows = array
                recognized = true
            } else {
                rows = []
                recognized = false
            }
            if recognized {
                let names = rows.compactMap { row -> String? in
                    guard let name = row["name"] as? String,
                        let status = row["status"] as? String,
                        status.lowercased() == "enabled",
                        !name.isEmpty
                    else { return nil }
                    return name
                }
                return names.count == rows.count
                    ? .supported(names)
                    : .unavailable(.unsupportedOutput)
            }
        }

        // `hermes skills list` uses a Rich table when it is attached to a
        // non-interactive process. Names may be shortened with an ellipsis to
        // fit Rich's table width, but that should not make the whole inventory
        // disappear. Keep complete enabled names and ignore headers/borders
        // and shortened rows.
        let names = trimmed.split(separator: "\n").compactMap { line -> String? in
            let columns =
                line
                .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "│" || $0 == "┃" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let fields = columns.filter { !$0.isEmpty }
            guard fields.count >= 2 else { return nil }
            let name = fields[0]
            let status = fields.last?.lowercased() ?? ""
            guard !name.isEmpty,
                name.lowercased() != "name",
                status == "enabled",
                !name.contains("…"),
                !name.contains("...")
            else { return nil }
            return name
        }

        guard !names.isEmpty else { return .unavailable(.unsupportedOutput) }
        return .supported(names)
    }

    private static func parseMCPServers(_ output: String) -> [String] {
        guard !output.localizedCaseInsensitiveContains("No MCP servers configured") else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("─") else { return nil }

            // Current Hermes output is a whitespace-separated table:
            // name, transport, tools, status. Keep the transport flexible
            // because local paths and URLs may contain punctuation.
            let columns = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 4,
                columns[0].lowercased() != "name",
                let toolsIndex = columns.firstIndex(where: {
                    ["all", "selected", "excluded"].contains($0.lowercased())
                }),
                toolsIndex > 1,
                toolsIndex + 1 < columns.count
            else { return nil }
            return columns[0]
        }
    }

    private static func parsePlugins(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8),
            let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
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
