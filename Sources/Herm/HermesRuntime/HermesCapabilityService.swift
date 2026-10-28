import Foundation

private final class CapabilityProbeResultBox: @unchecked Sendable {
    enum Outcome: Sendable {
        case completed([CapabilityState])
        case timedOut
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var result: Outcome?
    private var started = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startContinuation = continuation
                lock.unlock()
            }
        }
    }

    func wait() async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func finish(_ result: Outcome) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
        return true
    }

    var hasTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .timedOut? = result { return true }
        return false
    }
}

@MainActor
final class HermesCapabilityService {
    private let probeTimeout: Duration

    private struct CacheKey: Hashable {
        let clientID: ObjectIdentifier
        let remindersAvailable: Bool
        let sessionID: String?
    }

    private struct ProbeSpec: @unchecked Sendable {
        let key: String
        let method: HermesFeatureIDs.ID
        let params: [String: Any]
    }

    private struct ProbeResponse: @unchecked Sendable {
        let value: [String: Any]?
    }

    private struct ClientBox: @unchecked Sendable {
        let client: HermesRPCClientProtocol
    }

    private struct CachedSnapshot {
        let client: HermesRPCClientProtocol
        let snapshot: CapabilitySnapshot
    }

    private var cachedSnapshots: [CacheKey: CachedSnapshot] = [:]
    private var latestPublishedSnapshots: [ObjectIdentifier: CachedSnapshot] = [:]
    private var probeGeneration = 0
    private var timedOutGenerations: Set<Int> = []
    private var activeProbe: Task<[CapabilityState], Never>?

    init(probeTimeout: Duration = .seconds(10)) {
        self.probeTimeout = probeTimeout
    }

    func invalidate() {
        activeProbe?.cancel()
        activeProbe = nil
        cachedSnapshots.removeAll()
        latestPublishedSnapshots.removeAll()
        timedOutGenerations.removeAll()
        probeGeneration += 1
    }

    func probe(
        client: HermesRPCClientProtocol,
        remindersAvailable: Bool,
        sessionID: String? = nil,
        forceRefresh: Bool = false
    ) async -> [CapabilityState] {
        let clientID = ObjectIdentifier(client)
        let activeSessionID = Self.normalizedSessionID(sessionID)
        let cacheKey = CacheKey(clientID: clientID, remindersAvailable: remindersAvailable, sessionID: activeSessionID)
        if !forceRefresh,
            let cached = cachedSnapshots[cacheKey],
            cached.client === client
        {
            return cached.snapshot.states
        }

        activeProbe?.cancel()
        probeGeneration += 1
        let generation = probeGeneration
        let timeout = probeTimeout
        // Do not race structured child tasks here: a task group waits for all
        // children before returning, so a transport that ignores cancellation
        // would make the timeout path wait forever. The protocol has no
        // cancellation API; cancellation is best-effort at the task boundary.
        let resultBox = CapabilityProbeResultBox()
        let worker = Task { @MainActor [weak self] in
            guard let self else {
                resultBox.finish(.completed([]))
                return [CapabilityState]()
            }
            let states = await self.probeBounded(
                client: client,
                remindersAvailable: remindersAvailable,
                sessionID: activeSessionID,
                cacheKey: cacheKey,
                generation: generation,
                resultBox: resultBox
            )
            resultBox.finish(.completed(states))
            return states
        }
        activeProbe = worker
        let timeoutTask = Task.detached { [resultBox, worker] in
            await resultBox.waitUntilStarted()
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard resultBox.finish(.timedOut) else { return }
            worker.cancel()
        }
        let outcome = await resultBox.wait()
        timeoutTask.cancel()
        switch outcome {
        case .timedOut:
            timedOutGenerations.insert(generation)
            worker.cancel()
            guard generation == probeGeneration else {
                return latestPublishedSnapshots[clientID]?.client === client
                    ? latestPublishedSnapshots[clientID]!.snapshot.states
                    : []
            }
            probeGeneration += 1
            let stale =
                cachedSnapshots[cacheKey]?.client === client
                ? Self.markStale(cachedSnapshots[cacheKey]!.snapshot.states)
                : []
            return stale
        case .completed(let states):
            if activeProbe == worker { activeProbe = nil }
            return states
        }
    }

    private static func normalizedSessionID(_ sessionID: String?) -> String? {
        let normalized = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func markStale(_ states: [CapabilityState]) -> [CapabilityState] {
        states.map { state in
            CapabilityState(
                id: state.id,
                title: state.title,
                detail: "Probe timed out; showing the last successful snapshot. \(state.detail)",
                isAvailable: state.isAvailable,
                recovery: state.recovery ?? "Reconnect Hermes and refresh Core.",
                recoveryCommand: state.recoveryCommand,
                source: state.source,
                access: state.access,
                availability: state.availability,
                category: state.category,
                provenance: state.provenance,
                probeState: state.probeState,
                accessClassification: state.accessClassification,
                isStale: true
            )
        }
    }

    private func probeBounded(
        client: HermesRPCClientProtocol,
        remindersAvailable: Bool,
        sessionID: String?,
        cacheKey: CacheKey,
        generation: Int,
        resultBox: CapabilityProbeResultBox
    ) async -> [CapabilityState] {
        guard generation == probeGeneration, !timedOutGenerations.contains(generation), !Task.isCancelled else {
            resultBox.markStarted()
            return []
        }
        let specs: [(String, HermesFeatureIDs.ID, [String: Any])] =
            [
                ("session", HermesFeatureIDs.ID.sessionActiveList, [:]),
                // The roster RPC is fast and read-only; probing it before the
                // slow shell.exec probes keeps it inside the batch's bounded
                // timeout instead of starving at the end of the serial queue.
                // Kanban backs the primary Control/Activity projection. Probe it
                // before the long tail of optional shell integrations so the
                // bounded capability pass cannot time out before reaching it.
                ("kanban", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban list --help"]),
                ("profiles", HermesFeatureIDs.ID.profilesList, ["limit": 100]),
                ("scheduling", HermesFeatureIDs.ID.cronManage, ["action": "list"]),
                ("projects", HermesFeatureIDs.ID.projectsTree, [:]), ("tools", HermesFeatureIDs.ID.toolsList, [:]),
                ("plugins", HermesFeatureIDs.ID.pluginsList, [:]), ("config", HermesFeatureIDs.ID.configShow, [:]),
                ("version", HermesFeatureIDs.ID.shellExec, ["command": "hermes --version"]),
                ("skills", HermesFeatureIDs.ID.shellExec, ["command": "hermes skills list --enabled-only"]),
                ("notes", HermesFeatureIDs.ID.shellExec, ["command": "memo --version"]),
                ("email", HermesFeatureIDs.ID.shellExec, ["command": "himalaya --version"]),
                ("messaging", HermesFeatureIDs.ID.shellExec, ["command": "imsg --version"]),
                ("mcp", HermesFeatureIDs.ID.shellExec, ["command": "hermes mcp list"]),
                ("kanbanDetails", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban show --help"]),
                ("kanbanRuns", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban runs --help"]),
                ("kanbanStats", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban stats --help"]),
                ("kanbanAssignees", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban assignees --help"]),
                ("kanbanBoards", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban boards list --help"]),
                ("kanbanCreate", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban create --help"]),
                ("kanbanComplete", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban complete --help"]),
                ("kanbanBlock", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban block --help"]),
                ("kanbanUnblock", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban unblock --help"]),
                ("kanbanArchive", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban archive --help"]),
                ("kanbanComment", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban comment --help"]),
                ("kanbanSchedule", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban schedule --help"]),
                ("kanbanAssign", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban assign --help"]),
                ("kanbanReassign", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban reassign --help"]),
                ("kanbanPromote", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban promote --help"]),
                ("kanbanReclaim", HermesFeatureIDs.ID.shellExec, ["command": "hermes kanban reclaim --help"]),
                ("cronRunNow", HermesFeatureIDs.ID.shellExec, ["command": "hermes cron run --help"]),
                ("cronEdit", HermesFeatureIDs.ID.shellExec, ["command": "hermes cron edit --help"]),
                ("mcpTest", HermesFeatureIDs.ID.shellExec, ["command": "hermes mcp test --help"]),
                ("diagnosticsStatus", HermesFeatureIDs.ID.shellExec, ["command": "hermes status --help"]),
                ("monitoringStatus", HermesFeatureIDs.ID.shellExec, ["command": "hermes monitoring status --help"]),
                ("checkpointStatus", HermesFeatureIDs.ID.shellExec, ["command": "hermes checkpoints status --help"]),
                ("hooksList", HermesFeatureIDs.ID.shellExec, ["command": "hermes hooks list --help"]),
                ("journey", HermesFeatureIDs.ID.shellExec, ["command": "hermes journey --help"]),
                ("sessionStats", HermesFeatureIDs.ID.shellExec, ["command": "hermes sessions stats --help"]),
                ("memoryStatus", HermesFeatureIDs.ID.shellExec, ["command": "hermes memory status --help"]),
            ] + (sessionID.map { [("activity", HermesFeatureIDs.ID.processList, ["session_id": $0])] } ?? [])
        let results = await requestBatch(
            client,
            specs: specs.map { ProbeSpec(key: $0.0, method: $0.1, params: $0.2) },
            generation: generation,
            resultBox: resultBox,
            // Keep the sweep serial. A timed-out transport is allowed to
            // ignore cancellation, so parallel replacement requests would
            // let overlapping generations exceed the bounded request budget.
            limit: 1,
            onFirstRequest: { resultBox.markStarted() }
        )
        let sessionRPC = results["session"] ?? nil
        let schedulingRPC = results["scheduling"] ?? nil
        let activityRPC = results["activity"] ?? nil
        let projectsRPC = results["projects"] ?? nil
        let toolResult = results["tools"] ?? nil
        let pluginResult = results["plugins"] ?? nil
        HermPlugin.note(pluginResult)
        let configResult = results["config"] ?? nil
        let versionResult = results["version"] ?? nil
        let skillsResult = results["skills"] ?? nil
        let kanbanResult = results["kanban"] ?? nil
        let notesResult = results["notes"] ?? nil
        let emailResult = results["email"] ?? nil
        let imessageResult = results["messaging"] ?? nil
        let mcpResult = results["mcp"] ?? nil
        let kanbanDetails = results["kanbanDetails"] ?? nil
        let kanbanRuns = results["kanbanRuns"] ?? nil
        let kanbanStats = results["kanbanStats"] ?? nil
        let kanbanAssignees = results["kanbanAssignees"] ?? nil
        let kanbanBoards = results["kanbanBoards"] ?? nil
        let kanbanCreate = results["kanbanCreate"] ?? nil
        let kanbanComplete = results["kanbanComplete"] ?? nil
        let kanbanBlock = results["kanbanBlock"] ?? nil
        let kanbanUnblock = results["kanbanUnblock"] ?? nil
        let kanbanArchive = results["kanbanArchive"] ?? nil
        let kanbanComment = results["kanbanComment"] ?? nil
        let kanbanSchedule = results["kanbanSchedule"] ?? nil
        let kanbanAssign = results["kanbanAssign"] ?? nil
        let kanbanReassign = results["kanbanReassign"] ?? nil
        let kanbanPromote = results["kanbanPromote"] ?? nil
        let kanbanReclaim = results["kanbanReclaim"] ?? nil
        let cronRunNow = results["cronRunNow"] ?? nil
        let cronEdit = results["cronEdit"] ?? nil
        let mcpTest = results["mcpTest"] ?? nil
        let diagnosticsStatus = results["diagnosticsStatus"] ?? nil
        let monitoringStatus = results["monitoringStatus"] ?? nil
        let checkpointStatus = results["checkpointStatus"] ?? nil
        let hooksList = results["hooksList"] ?? nil
        let journey = results["journey"] ?? nil
        let sessionStats = results["sessionStats"] ?? nil
        let memoryStatus = results["memoryStatus"] ?? nil
        let profilesResult = results["profiles"] ?? nil
        let notesAvailable = Self.shellResultSucceeded(notesResult)
        let skillsAvailable = Self.shellResultSucceeded(skillsResult)
        let versionOutput = (versionResult?["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailAvailable = Self.shellResultSucceeded(emailResult)
        let messagingAvailable = Self.shellResultSucceeded(imessageResult)
        let mcpAvailable = Self.shellResultSucceeded(mcpResult)
        let kanbanAvailable =
            Self.shellResultSucceeded(kanbanResult)
            && ((kanbanResult?["stdout"] as? String)?.localizedCaseInsensitiveContains("--json") == true)
        let mcpOutput = (mcpResult?["stdout"] as? String) ?? ""
        let hasMCPServers = mcpAvailable && !mcpOutput.localizedCaseInsensitiveContains("No MCP servers configured")
        let version =
            (configResult?["version"] as? String)
            ?? (configResult?["hermes_version"] as? String)
            ?? (Self.shellResultSucceeded(versionResult) ? versionOutput : nil)

        let rawStates: [CapabilityState] = [
            CapabilityState(
                id: HermesFeatureIDs.ID.gateway.rawValue,
                title: "Hermes gateway",
                detail: configResult == nil ? "Gateway health is unavailable" : "Gateway is responding",
                isAvailable: configResult != nil,
                recovery: configResult == nil ? "Reconnect Hermes and refresh Core." : nil,
                recoveryCommand: configResult == nil ? "hermes gateway start" : nil
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.bots.rawValue,
                title: "Hermes Bots",
                detail: profilesResult == nil
                    ? "profiles.list is unsupported or unavailable" : "Hermes profile roster is available",
                isAvailable: profilesResult != nil,
                recovery: profilesResult == nil ? "Upgrade Hermes to enable Bot Mode." : nil
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.hermesVersion.rawValue,
                title: "Hermes version",
                detail: version ?? "Version information is unavailable",
                isAvailable: version != nil,
                recovery: version == nil ? "Update Hermes manually if a newer version is required." : nil,
                recoveryCommand: version == nil ? "hermes update" : nil,
                source: .cli,
                access: .externalSetup
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.rpcSessions.rawValue,
                title: "Session control",
                detail: sessionRPC == nil
                    ? "session.active_list is unsupported or unavailable"
                    : "Session listing and activation RPCs are available",
                isAvailable: sessionRPC != nil,
                recovery: sessionRPC == nil ? "Upgrade Hermes or use Ask to manage sessions through the agent." : nil
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.rpcScheduling.rawValue,
                title: "Cron control",
                detail: schedulingRPC == nil
                    ? "cron.manage is unsupported or unavailable" : "Cron listing and controls are available",
                isAvailable: schedulingRPC != nil,
                recovery: schedulingRPC == nil ? "Upgrade Hermes or manage scheduled work through the Hermes CLI." : nil
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.rpcActivity.rawValue,
                title: "Activity inspection",
                detail: activityRPC == nil
                    ? "process.list is unsupported or unavailable" : "Process and activity inspection is available",
                isAvailable: activityRPC != nil,
                recovery: activityRPC == nil ? "Upgrade Hermes to expose process activity to Herm." : nil
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.rpcProjects.rawValue,
                title: "Project control",
                detail: projectsRPC == nil
                    ? "projects.tree is unsupported or unavailable" : "Project and repository context is available",
                isAvailable: projectsRPC != nil,
                recovery: projectsRPC == nil ? "Upgrade Hermes or open project context through Ask." : nil
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.reminders.rawValue,
                title: "Apple Reminders",
                detail: remindersAvailable ? "Connected through remindctl" : "remindctl is unavailable or unauthorized",
                isAvailable: remindersAvailable,
                recovery: remindersAvailable ? nil : "Install remindctl and authorize Reminders access.",
                source: .external,
                access: .externalSetup,
                availability: remindersAvailable ? .available : .unavailable
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.notes.rawValue,
                title: "Apple Notes",
                detail: notesAvailable
                    ? "Available through memo and the Hermes apple-notes skill" : "memo is unavailable or unauthorized",
                isAvailable: notesAvailable,
                recovery: notesAvailable ? nil : "Install memo and authorize Notes access.",
                recoveryCommand: notesAvailable
                    ? nil : "brew tap antoniorodr/memo && brew install antoniorodr/memo/memo",
                source: .external,
                access: .externalSetup,
                availability: notesAvailable ? .available : .unavailable
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.tools.rawValue,
                title: "Hermes tools",
                detail: toolResult == nil ? "Tool catalogue is unavailable" : "Tool catalogue available",
                isAvailable: toolResult != nil,
                recovery: toolResult == nil ? "This Hermes version may not support tools.list." : nil
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.plugins.rawValue,
                title: "Hermes plugins",
                detail: pluginResult == nil ? "Plugin catalogue is unavailable" : "Plugin catalogue available",
                isAvailable: pluginResult != nil,
                recovery: pluginResult == nil ? "This Hermes version may not support plugins.list." : nil
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.skills.rawValue,
                title: "Hermes skills",
                detail: skillsAvailable ? "Enabled skills catalogue available" : "Skills catalogue is unavailable",
                isAvailable: skillsAvailable,
                recovery: skillsAvailable ? nil : "This Hermes installation may not support skills listing.",
                source: .cli
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.calendar.rawValue,
                title: "Calendar",
                detail: "No Hermes Calendar provider is configured",
                isAvailable: false,
                recovery: "Calendar integration is planned for a future provider.",
                source: .external,
                access: .externalSetup,
                availability: .unavailable
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.messaging.rawValue,
                title: "Messaging",
                detail: messagingAvailable
                    ? "iMessage CLI is available through Hermes" : "imsg is unavailable or unauthorized",
                isAvailable: messagingAvailable,
                recovery: messagingAvailable ? nil : "Install imsg and grant Messages access.",
                recoveryCommand: messagingAvailable ? nil : "brew install steipete/tap/imsg",
                source: .external,
                access: .externalSetup,
                availability: messagingAvailable ? .available : .unavailable
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.email.rawValue,
                title: "Email",
                detail: emailAvailable
                    ? "Email CLI is available through Hermes" : "himalaya is unavailable or unconfigured",
                isAvailable: emailAvailable,
                recovery: emailAvailable ? nil : "Install and configure himalaya before enabling email actions.",
                recoveryCommand: emailAvailable ? nil : "brew install himalaya",
                source: .external,
                access: .externalSetup,
                availability: emailAvailable ? .available : .unavailable
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.kanban.rawValue,
                title: "Hermes Kanban",
                detail: kanbanAvailable
                    ? "Kanban CLI is available through Hermes shell; desktop RPC is unavailable"
                    : "Kanban CLI is unavailable",
                isAvailable: kanbanAvailable,
                recovery: kanbanAvailable
                    ? "Use Hermes Kanban prompts for actions; Herm does not duplicate the board."
                    : "Install or enable Hermes Kanban before using Kanban actions.",
                source: .cli,
                access: .confirmedMutation
            ),
            CapabilityState(
                id: HermesFeatureIDs.ID.mcp.rawValue,
                title: "Third-party MCP",
                detail: !mcpAvailable
                    ? "MCP configuration is unavailable"
                    : (hasMCPServers
                        ? "Configured MCP servers are available through Hermes" : "No MCP servers are configured"),
                isAvailable: hasMCPServers,
                recovery: !mcpAvailable
                    ? "Reconnect Hermes and configure MCP servers there."
                    : (hasMCPServers ? nil : "Configure an MCP server in Hermes before using third-party actions."),
                source: .external,
                access: .externalSetup,
                availability: !mcpAvailable || !hasMCPServers ? .unavailable : .available
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanTaskDetails.rawValue,
                title: "Kanban task details",
                commandResult: kanbanDetails,
                recovery: "This Hermes version does not expose JSON Kanban task details.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanTaskRuns.rawValue,
                title: "Kanban task runs",
                commandResult: kanbanRuns,
                recovery: "This Hermes version does not expose Kanban run history.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanStats.rawValue,
                title: "Kanban statistics",
                commandResult: kanbanStats,
                recovery: "This Hermes version does not expose Kanban statistics.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanFilters.rawValue,
                title: "Kanban list filters",
                commandResult: kanbanResult,
                recovery: "This Hermes version does not expose the filters used by Herm.",
                access: .readOnly,
                requiredHelpTerms: ["--status", "--assignee", "--mine", "--session", "--sort", "--json"]
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanAssignees.rawValue,
                title: "Kanban assignee directory",
                commandResult: kanbanAssignees,
                recovery: "This Hermes version does not expose JSON Kanban assignees.",
                access: .readOnly,
                requiredHelpTerms: ["--json"]
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanBoards.rawValue,
                title: "Kanban board directory",
                commandResult: kanbanBoards,
                recovery: "This Hermes version does not expose JSON Kanban board listing.",
                access: .readOnly,
                requiredHelpTerms: ["list", "--json"]
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanCreate.rawValue, title: "Create Kanban task", commandResult: kanbanCreate,
                recovery: "This Hermes version does not expose Kanban task creation.", access: .confirmedMutation,
                requiredHelpTerms: ["title"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanComplete.rawValue, title: "Complete Kanban task",
                commandResult: kanbanComplete, recovery: "This Hermes version does not expose Kanban completion.",
                access: .confirmedMutation, requiredHelpTerms: ["task"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanBlock.rawValue, title: "Block Kanban task", commandResult: kanbanBlock,
                recovery: "This Hermes version does not expose Kanban blocking.", access: .confirmedMutation,
                requiredHelpTerms: ["task"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanUnblock.rawValue, title: "Unblock Kanban task",
                commandResult: kanbanUnblock, recovery: "This Hermes version does not expose Kanban unblocking.",
                access: .confirmedMutation, requiredHelpTerms: ["task"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanArchive.rawValue, title: "Archive Kanban task",
                commandResult: kanbanArchive, recovery: "This Hermes version does not expose Kanban archiving.",
                access: .confirmedMutation, requiredHelpTerms: ["task"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanComment.rawValue, title: "Comment on Kanban task",
                commandResult: kanbanComment, recovery: "This Hermes version does not expose Kanban comments.",
                access: .confirmedMutation, requiredHelpTerms: ["task_id", "text"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanSchedule.rawValue, title: "Schedule Kanban task",
                commandResult: kanbanSchedule, recovery: "This Hermes version does not expose Kanban scheduling.",
                access: .confirmedMutation, requiredHelpTerms: ["task_id", "reason"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanAssign.rawValue, title: "Assign Kanban task", commandResult: kanbanAssign,
                recovery: "This Hermes version does not expose Kanban assignment.", access: .confirmedMutation,
                requiredHelpTerms: ["task_id", "profile"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanReassign.rawValue, title: "Reassign Kanban task",
                commandResult: kanbanReassign, recovery: "This Hermes version does not expose Kanban reassignment.",
                access: .confirmedMutation, requiredHelpTerms: ["task_id", "profile", "--reclaim"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanPromote.rawValue, title: "Promote Kanban task",
                commandResult: kanbanPromote, recovery: "This Hermes version does not expose Kanban promotion.",
                access: .confirmedMutation, requiredHelpTerms: ["task_id", "reason"]),
            cliCapability(
                id: HermesFeatureIDs.ID.kanbanReclaim.rawValue, title: "Reclaim Kanban task",
                commandResult: kanbanReclaim, recovery: "This Hermes version does not expose Kanban reclaim.",
                access: .confirmedMutation, requiredHelpTerms: ["task_id", "--reason"]),
            cliCapability(
                id: HermesFeatureIDs.ID.cronRunNow.rawValue,
                title: "Run scheduled job now",
                commandResult: cronRunNow,
                recovery: "This Hermes version does not expose confirmed cron run-now support.",
                access: .confirmedMutation,
                requiredHelpTerms: ["job_id"]
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.cronEdit.rawValue,
                title: "Edit scheduled job",
                commandResult: cronEdit,
                recovery: "This Hermes version does not expose scheduled-job editing.",
                access: .confirmedMutation,
                requiredHelpTerms: ["job_id", "--schedule", "--prompt", "--name"]
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.mcpTest.rawValue,
                title: "Test MCP connection",
                commandResult: mcpTest,
                recovery: "This Hermes version does not expose MCP connection testing.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.diagnosticsStatus.rawValue,
                title: "Hermes health diagnostics",
                commandResult: diagnosticsStatus,
                recovery: "This Hermes version does not expose status diagnostics.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.diagnosticsMonitoring.rawValue,
                title: "Gateway monitoring status",
                commandResult: monitoringStatus,
                recovery: "This Hermes version does not expose monitoring status.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.diagnosticsCheckpoints.rawValue,
                title: "Checkpoint storage status",
                commandResult: checkpointStatus,
                recovery: "This Hermes version does not expose checkpoint status.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.diagnosticsHooks.rawValue,
                title: "Shell hook status",
                commandResult: hooksList,
                recovery: "This Hermes version does not expose shell hook status.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.journeyTimeline.rawValue,
                title: "Hermes journey timeline",
                commandResult: journey,
                recovery: "This Hermes version does not expose the Journey timeline.",
                access: .readOnly,
                requiredHelpTerms: ["--json"]
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.sessionsStats.rawValue,
                title: "Session store statistics",
                commandResult: sessionStats,
                recovery: "This Hermes version does not expose session-store statistics.",
                access: .readOnly
            ),
            cliCapability(
                id: HermesFeatureIDs.ID.memoryStatus.rawValue,
                title: "Memory health",
                commandResult: memoryStatus,
                recovery: "This Hermes version does not expose memory health status.",
                access: .readOnly
            ),
        ]

        let states = rawStates.map(Self.productionMetadata)
        guard generation == probeGeneration, !timedOutGenerations.contains(generation), !Task.isCancelled else {
            return latestPublishedSnapshots[ObjectIdentifier(client)]?.client === client
                ? latestPublishedSnapshots[ObjectIdentifier(client)]!.snapshot.states
                : []
        }
        let snapshot = CapabilitySnapshot(states: states, generatedAt: Date())
        let cachedSnapshot = CachedSnapshot(client: client, snapshot: snapshot)
        cachedSnapshots[cacheKey] = cachedSnapshot
        latestPublishedSnapshots[ObjectIdentifier(client)] = cachedSnapshot
        return states
    }

    private func requestBatch(
        _ client: HermesRPCClientProtocol,
        specs: [ProbeSpec],
        generation: Int,
        resultBox: CapabilityProbeResultBox,
        limit: Int,
        onFirstRequest: @escaping @MainActor () -> Void
    ) async -> [String: [String: Any]?] {
        await withTaskGroup(of: (String, ProbeResponse).self, returning: [String: [String: Any]?].self) { group in
            let boxedClient = ClientBox(client: client)
            var iterator = specs.makeIterator()
            var results: [String: [String: Any]?] = [:]
            var inFlight = 0
            func add(_ spec: ProbeSpec) {
                inFlight += 1
                group.addTask {
                    guard !Task.isCancelled else { return (spec.key, ProbeResponse(value: nil)) }
                    await onFirstRequest()
                    let response = await self.requestResponse(boxedClient.client, spec: spec)
                    return (spec.key, response)
                }
            }
            // Start exactly one request. Besides avoiding an unnecessary
            // burst when a transport is unavailable, this lets a newer probe
            // supersede a stalled one before it schedules the remainder.
            if let spec = iterator.next() { add(spec) }
            while let result = await group.next() {
                inFlight -= 1
                results[result.0] = result.1.value
                // A timeout cancels the parent probe while a non-cooperative
                // transport may still be completing its current request. Do
                // not start the remainder of the serial capability sweep
                // after that cancellation; it would starve the next refresh
                // and could later overwrite its cache boundary.
                guard generation == probeGeneration,
                    !timedOutGenerations.contains(generation),
                    !resultBox.hasTimedOut,
                    !Task.isCancelled
                else {
                    group.cancelAll()
                    break
                }
                // Once the first request has completed, maintain the bounded
                // pipeline for the remaining low-cost capability probes.
                while inFlight < limit {
                    if let spec = iterator.next() { add(spec) } else { break }
                }
            }
            return results
        }
    }

    /// Verify the canonical plugin keys and statuses through the installed RPC contract.
    /// A missing or malformed inventory must never enable onboarding mutations.
    func probeOnboardingPlugins(client: HermesRPCClientProtocol) async throws -> [WorkflowPlugin] {
        try await HermesWorkflowRPC(client: client, profileID: nil).plugins()
    }

    func probeProfileDeletion(client: HermesRPCClientProtocol) async -> Bool {
        let result = try? await HermesCLIAdapter(rpc: HermesControlRPC(client: client)).profileDeleteHelp()
        return cliCapability(
            id: "profiles.delete", title: "Delete Bot",
            commandResult: result.map { ["stdout": $0.stdout, "code": $0.succeeded ? 0 : 1] },
            recovery: "Bot deletion requires Hermes profile delete support.",
            access: .confirmedMutation, requiredHelpTerms: ["profile_name", "--yes", "delete"]
        ).isAvailable
    }

    private func cliCapability(
        id: String,
        title: String,
        commandResult: [String: Any]?,
        recovery: String,
        access: CapabilityAccess,
        requiredHelpTerms: [String] = []
    ) -> CapabilityState {
        let help = (commandResult?["stdout"] as? String)?.lowercased() ?? ""
        let available =
            Self.shellResultSucceeded(commandResult)
            && requiredHelpTerms.allSatisfy { help.contains($0.lowercased()) }
        return CapabilityState(
            id: id,
            title: title,
            detail: available ? "Supported by the installed Hermes CLI" : recovery,
            isAvailable: available,
            recovery: available ? nil : recovery,
            source: .cli,
            access: access,
            availability: available ? .available : .unsupported
        )
    }

    @MainActor
    private func requestResponse(_ client: HermesRPCClientProtocol, spec: ProbeSpec) async -> ProbeResponse {
        guard let rawValue = try? await client.request(spec.method.rawValue, params: spec.params) else {
            return ProbeResponse(value: nil)
        }
        let value =
            spec.method == .shellExec
            ? HermesControlRPC.normalizedShellResult(rawValue)
            : rawValue
        guard
            !Task.isCancelled,
            !value.isEmpty,
            value["error"] == nil
        else { return ProbeResponse(value: nil) }
        return ProbeResponse(value: value)
    }

    private func request(_ client: HermesRPCClientProtocol, method: String, params: [String: Any] = [:]) async
        -> [String: Any]?
    {
        guard !Task.isCancelled else { return nil }
        guard let result = try? await client.request(method, params: params),
            !Task.isCancelled,
            !result.isEmpty,
            result["error"] == nil
        else { return nil }
        return result
    }

    private static func productionMetadata(_ state: CapabilityState) -> CapabilityState {
        CapabilityState(
            id: state.id,
            title: state.title,
            detail: state.detail,
            isAvailable: state.isAvailable,
            recovery: state.recovery,
            recoveryCommand: state.recoveryCommand,
            source: state.source,
            access: state.access,
            availability: state.availability,
            category: state.category,
            probeState: state.isAvailable ? .verified : state.probeState,
            isStale: state.isStale
        )
    }

    static func shellResultSucceeded(_ result: [String: Any]?) -> Bool {
        guard let result else { return false }
        return AppleRemindersAdapter.shellResultSucceeded(result)
    }
}
