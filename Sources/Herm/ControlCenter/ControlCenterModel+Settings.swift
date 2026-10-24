import Combine
import Foundation

extension ControlCenterModel {
    func refreshCommandAllowlist() {
        guard let cli else { return }
        Task {
            do {
                let result = try await cli.configGetCommandAllowlist()
                commandAllowlistEntries = result.succeeded ? Self.parseCommandAllowlist(result.stdout) : nil
            } catch {
                commandAllowlistEntries = nil
            }
        }
    }

    nonisolated static func parseCommandAllowlist(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]", trimmed != "null" else { return [] }
        if let data = trimmed.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [String]
        {
            return array
        }
        return trimmed.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("- ") else { return nil }
            var entry = String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("'"), entry.hasSuffix("'"), entry.count >= 2 {
                entry = String(entry.dropFirst().dropLast())
            }
            return entry.isEmpty ? nil : entry
        }
    }

    func refreshAppearanceProjection(refreshGeneration: UInt64? = nil, clientIdentity: ObjectIdentifier? = nil) {
        guard let cli else { return }
        let resolvedClientIdentity = clientIdentity ?? dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let bindingGeneration = self.clientBindingGeneration
        guard isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration) else { return }
        let isCurrent: () -> Bool = {
            if let refreshGeneration {
                return self.isCurrentRefresh(refreshGeneration, clientIdentity: resolvedClientIdentity)
            }
            return self.isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration)
        }
        let generation = UUID()
        appearanceProjectionGeneration = generation
        Task {
            do {
                async let skins = cli.skinList()
                async let pets = cli.installedPetsList()
                let skinResult = try await skins
                let petResult = try await pets
                guard generation == appearanceProjectionGeneration, isCurrent() else { return }
                guard skinResult.succeeded, petResult.succeeded else {
                    appearanceProjectionAvailable = appearanceProjection != nil
                    return
                }
                appearanceProjection = AppearanceCLIProjection.inventory(
                    skinsOutput: skinResult.stdout,
                    petsOutput: petResult.stdout
                )
                appearanceProjectionAvailable = true
            } catch {
                guard generation == appearanceProjectionGeneration, isCurrent() else { return }
                appearanceProjectionAvailable = appearanceProjection != nil
            }
        }
    }

    func engageEmergencyStop(reason: String? = nil) {
        guard let cli else { return }
        let actionID = emergencyStopActionID
        guard beginAction(actionID) else { return }
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.emergencyStop(reason: reason)
                guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                guard result.succeeded else {
                    emergencyStopMessage =
                        HermesDiagnosticsService.safeSummary(result.stderr).isEmpty
                        ? "Hermes could not engage the emergency stop."
                        : HermesDiagnosticsService.safeSummary(result.stderr)
                    DockActionErrorCenter.shared.report("Could not pause dispatch", message: emergencyStopMessage ?? "")
                    return
                }
                emergencyStopActive = true
                emergencyStopMessage = "New Hermes work is paused. In-flight work continues."
            } catch {
                guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                emergencyStopMessage = HermesDiagnosticsService.safeSummary(error.localizedDescription)
                DockActionErrorCenter.shared.report("Could not pause dispatch", error: error)
            }
        }
    }

    func releaseEmergencyStop() {
        guard let cli else { return }
        let actionID = emergencyStopActionID
        guard beginAction(actionID) else { return }
        let bindingGeneration = clientBindingGeneration
        let clientIdentity = dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.resumeEmergencyStop()
                guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                guard result.succeeded else {
                    emergencyStopMessage =
                        HermesDiagnosticsService.safeSummary(result.stderr).isEmpty
                        ? "Hermes could not resume dispatch." : HermesDiagnosticsService.safeSummary(result.stderr)
                    DockActionErrorCenter.shared.report(
                        "Could not resume dispatch", message: emergencyStopMessage ?? "")
                    return
                }
                emergencyStopActive = false
                emergencyStopMessage = "Hermes dispatch resumed."
            } catch {
                guard self.isCurrentClient(clientIdentity, bindingGeneration: bindingGeneration) else { return }
                emergencyStopMessage = HermesDiagnosticsService.safeSummary(error.localizedDescription)
                DockActionErrorCenter.shared.report("Could not resume dispatch", error: error)
            }
        }
    }

    func refreshInsights(refreshGeneration: UInt64? = nil, clientIdentity: ObjectIdentifier? = nil) {
        guard let rpc else { return }
        let resolved = clientIdentity ?? dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let binding = clientBindingGeneration
        guard isCurrentClient(resolved, bindingGeneration: binding) else { return }
        Task {
            do {
                let result = try await rpc.insights(days: 30)
                guard
                    refreshGeneration.map({ self.isCurrentRefresh($0, clientIdentity: resolved) })
                        ?? self.isCurrentClient(resolved, bindingGeneration: binding)
                else { return }
                guard let days = result["days"] as? Int, let sessions = result["sessions"] as? Int,
                    let messages = result["messages"] as? Int,
                    (1...90).contains(days), sessions >= 0, messages >= 0
                else { return }
                insightsSummary = HermesInsightsSummary(days: days, sessions: sessions, messages: messages)
            } catch {
                return
            }
        }
    }

    func refreshMCPInventory(refreshGeneration: UInt64? = nil, clientIdentity: ObjectIdentifier? = nil) {
        guard let cli else { return }
        let resolvedClientIdentity = clientIdentity ?? dockModel.map { ObjectIdentifier($0.controlRPCClient) }
        let bindingGeneration = self.clientBindingGeneration
        guard isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration) else { return }
        let isCurrent: () -> Bool = {
            if let refreshGeneration {
                return self.isCurrentRefresh(refreshGeneration, clientIdentity: resolvedClientIdentity)
            }
            return self.isCurrentClient(resolvedClientIdentity, bindingGeneration: bindingGeneration)
        }
        beginProjectionRefresh("mcp.inventory")
        let generation = UUID()
        mcpInventoryGeneration = generation
        Task {
            do {
                let result = try await cli.mcpList()
                guard generation == mcpInventoryGeneration, isCurrent() else { return }
                mcpInventoryAvailable = result.succeeded
                guard mcpInventoryAvailable else {
                    let message =
                        Self.safeUserDiagnostic(result.stderr).isEmpty
                        ? "Hermes MCP inventory is temporarily unavailable." : Self.safeUserDiagnostic(result.stderr)
                    recordProjectionFailure("mcp.inventory", error: message)
                    lastError = message
                    return
                }
                mcpServers = Self.parseMCPServers(result.stdout)
                recordProjectionSuccess("mcp.inventory")
            } catch {
                guard generation == mcpInventoryGeneration, isCurrent() else { return }
                mcpInventoryAvailable = false
                let message = HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription))
                recordProjectionFailure("mcp.inventory", error: message)
                lastError = message
            }
        }
    }

    func testMCP(_ server: MCPServerSummary) {
        guard let cli, capabilityAvailable("mcp.test") else {
            mcpTestResults[server.id] = "MCP testing is unavailable through the installed Hermes CLI."
            return
        }
        let actionID = mcpTestActionID(server)
        guard beginAction(actionID) else { return }
        mcpTestResults[server.id] = "Testing connection…"
        Task {
            defer { finishAction(actionID) }
            do {
                let result = try await cli.mcpTest(name: server.name)
                let output = HermesDiagnosticsService.safeSummary(
                    result.succeeded ? result.stdout : Self.safeUserDiagnostic(result.stderr))
                mcpTestResults[server.id] =
                    result.succeeded
                    ? (output.isEmpty ? "Connection succeeded." : output)
                    : (output.isEmpty ? "Connection failed." : output)
            } catch {
                mcpTestResults[server.id] = Self.safeUserDiagnostic(error.localizedDescription)
            }
        }
    }

    func reloadMCP() {
        guard let rpc, let sessionID = dockModel?.sessionID else {
            reportActionError(
                "Could not reload MCP tools", message: "Open a Hermes session before reloading MCP tools.")
            return
        }
        guard beginAction(reloadMCPActionID) else { return }
        Task {
            defer { finishAction(reloadMCPActionID) }
            do {
                _ = try await rpc.reloadMCP(sessionID: sessionID)
                dockModel?.refreshRuntimeConfiguration(force: true)
            } catch {
                reportActionError(
                    "Could not reload MCP tools",
                    message: HermesDiagnosticsService.safeSummary(Self.safeUserDiagnostic(error.localizedDescription)))
            }
        }
    }
}
