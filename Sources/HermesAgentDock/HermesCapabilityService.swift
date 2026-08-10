import Foundation

@MainActor
final class HermesCapabilityService {
    private var cachedSnapshot: CapabilitySnapshot?
    private var cachedRemindersAvailability: Bool?

    func invalidate() {
        cachedSnapshot = nil
        cachedRemindersAvailability = nil
    }

    func probe(
        client: HermesRPCClientProtocol,
        remindersAvailable: Bool,
        sessionID: String? = nil,
        forceRefresh: Bool = false
    ) async -> [CapabilityState] {
        if !forceRefresh,
           let cachedSnapshot,
           cachedRemindersAvailability == remindersAvailable {
            return cachedSnapshot.states
        }

        let sessionRPC = await request(client, method: "session.active_list")
        let schedulingRPC = await request(client, method: "cron.manage", params: ["action": "list"])
        let activityRPC: [String: Any]?
        if let sessionID, !sessionID.isEmpty {
            activityRPC = await request(client, method: "process.list", params: ["session_id": sessionID])
        } else {
            activityRPC = nil
        }
        let projectsRPC = await request(client, method: "projects.tree")
        let toolResult = await request(client, method: "tools.list")
        let pluginResult = await request(client, method: "plugins.list")
        let configResult = await request(client, method: "config.show")
        let versionResult = await request(client, method: "shell.exec", params: ["command": "hermes --version"])
        let skillsResult = await request(client, method: "shell.exec", params: ["command": "hermes skills list --enabled-only"])
        let kanbanResult = await request(client, method: "shell.exec", params: ["command": "hermes kanban list --help"])
        let notesResult = await request(client, method: "shell.exec", params: ["command": "memo --version"])
        let emailResult = await request(client, method: "shell.exec", params: ["command": "himalaya --version"])
        let imessageResult = await request(client, method: "shell.exec", params: ["command": "imsg --version"])
        let mcpResult = await request(client, method: "shell.exec", params: ["command": "hermes mcp list"])
        let kanbanDetails = await request(client, method: "shell.exec", params: ["command": "hermes kanban show --help"])
        let kanbanRuns = await request(client, method: "shell.exec", params: ["command": "hermes kanban runs --help"])
        let kanbanStats = await request(client, method: "shell.exec", params: ["command": "hermes kanban stats --help"])
        let kanbanAssignees = await request(client, method: "shell.exec", params: ["command": "hermes kanban assignees --help"])
        let kanbanBoards = await request(client, method: "shell.exec", params: ["command": "hermes kanban boards list --help"])
        let kanbanCreate = await request(client, method: "shell.exec", params: ["command": "hermes kanban create --help"])
        let kanbanComplete = await request(client, method: "shell.exec", params: ["command": "hermes kanban complete --help"])
        let kanbanBlock = await request(client, method: "shell.exec", params: ["command": "hermes kanban block --help"])
        let kanbanUnblock = await request(client, method: "shell.exec", params: ["command": "hermes kanban unblock --help"])
        let kanbanArchive = await request(client, method: "shell.exec", params: ["command": "hermes kanban archive --help"])
        let kanbanComment = await request(client, method: "shell.exec", params: ["command": "hermes kanban comment --help"])
        let kanbanSchedule = await request(client, method: "shell.exec", params: ["command": "hermes kanban schedule --help"])
        let kanbanAssign = await request(client, method: "shell.exec", params: ["command": "hermes kanban assign --help"])
        let kanbanReassign = await request(client, method: "shell.exec", params: ["command": "hermes kanban reassign --help"])
        let kanbanPromote = await request(client, method: "shell.exec", params: ["command": "hermes kanban promote --help"])
        let kanbanReclaim = await request(client, method: "shell.exec", params: ["command": "hermes kanban reclaim --help"])
        let cronRunNow = await request(client, method: "shell.exec", params: ["command": "hermes cron run --help"])
        let cronEdit = await request(client, method: "shell.exec", params: ["command": "hermes cron edit --help"])
        let mcpTest = await request(client, method: "shell.exec", params: ["command": "hermes mcp test --help"])
        let diagnosticsStatus = await request(client, method: "shell.exec", params: ["command": "hermes status --help"])
        let monitoringStatus = await request(client, method: "shell.exec", params: ["command": "hermes monitoring status --help"])
        let checkpointStatus = await request(client, method: "shell.exec", params: ["command": "hermes checkpoints status --help"])
        let hooksList = await request(client, method: "shell.exec", params: ["command": "hermes hooks list --help"])
        let journey = await request(client, method: "shell.exec", params: ["command": "hermes journey --help"])
        let sessionStats = await request(client, method: "shell.exec", params: ["command": "hermes sessions stats --help"])
        let memoryStatus = await request(client, method: "shell.exec", params: ["command": "hermes memory status --help"])
        let notesAvailable = Self.shellResultSucceeded(notesResult)
        let skillsAvailable = Self.shellResultSucceeded(skillsResult)
        let versionOutput = (versionResult?["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailAvailable = Self.shellResultSucceeded(emailResult)
        let messagingAvailable = Self.shellResultSucceeded(imessageResult)
        let mcpAvailable = Self.shellResultSucceeded(mcpResult)
        let kanbanAvailable = Self.shellResultSucceeded(kanbanResult)
            && ((kanbanResult?["stdout"] as? String)?.localizedCaseInsensitiveContains("--json") == true)
        let mcpOutput = (mcpResult?["stdout"] as? String) ?? ""
        let hasMCPServers = mcpAvailable && !mcpOutput.localizedCaseInsensitiveContains("No MCP servers configured")
        let version = (configResult?["version"] as? String)
            ?? (configResult?["hermes_version"] as? String)
            ?? (Self.shellResultSucceeded(versionResult) ? versionOutput : nil)

        let states: [CapabilityState] = [
            CapabilityState(
                id: "gateway",
                title: "Hermes gateway",
                detail: configResult == nil ? "Gateway health is unavailable" : "Gateway is responding",
                isAvailable: configResult != nil,
                recovery: configResult == nil ? "Reconnect Hermes and refresh Core." : nil,
                recoveryCommand: configResult == nil ? "hermes gateway start" : nil
            ),
            CapabilityState(
                id: "hermes-version",
                title: "Hermes version",
                detail: version ?? "Version information is unavailable",
                isAvailable: version != nil,
                recovery: version == nil ? "Update Hermes manually if a newer version is required." : nil,
                recoveryCommand: version == nil ? "hermes update" : nil,
                source: .cli,
                access: .externalSetup
            ),
            CapabilityState(
                id: "rpc-sessions",
                title: "Session control",
                detail: sessionRPC == nil ? "session.active_list is unsupported or unavailable" : "Session listing and activation RPCs are available",
                isAvailable: sessionRPC != nil,
                recovery: sessionRPC == nil ? "Upgrade Hermes or use Ask to manage sessions through the agent." : nil
            ),
            CapabilityState(
                id: "rpc-scheduling",
                title: "Cron control",
                detail: schedulingRPC == nil ? "cron.manage is unsupported or unavailable" : "Cron listing and controls are available",
                isAvailable: schedulingRPC != nil,
                recovery: schedulingRPC == nil ? "Upgrade Hermes or manage scheduled work through the Hermes CLI." : nil
            ),
            CapabilityState(
                id: "rpc-activity",
                title: "Activity inspection",
                detail: activityRPC == nil ? "process.list is unsupported or unavailable" : "Process and activity inspection is available",
                isAvailable: activityRPC != nil,
                recovery: activityRPC == nil ? "Upgrade Hermes to expose process activity to the Dock." : nil
            ),
            CapabilityState(
                id: "rpc-projects",
                title: "Project control",
                detail: projectsRPC == nil ? "projects.tree is unsupported or unavailable" : "Project and repository context is available",
                isAvailable: projectsRPC != nil,
                recovery: projectsRPC == nil ? "Upgrade Hermes or open project context through Ask." : nil
            ),
            CapabilityState(
                id: "reminders",
                title: "Apple Reminders",
                detail: remindersAvailable ? "Connected through remindctl" : "remindctl is unavailable or unauthorized",
                isAvailable: remindersAvailable,
                recovery: remindersAvailable ? nil : "Install remindctl and authorize Reminders access.",
                source: .external,
                access: .externalSetup,
                availability: remindersAvailable ? .available : .unavailable
            ),
            CapabilityState(
                id: "notes",
                title: "Apple Notes",
                detail: notesAvailable ? "Available through memo and the Hermes apple-notes skill" : "memo is unavailable or unauthorized",
                isAvailable: notesAvailable,
                recovery: notesAvailable ? nil : "Install memo and authorize Notes access.",
                recoveryCommand: notesAvailable ? nil : "brew tap antoniorodr/memo && brew install antoniorodr/memo/memo",
                source: .external,
                access: .externalSetup,
                availability: notesAvailable ? .available : .unavailable
            ),
            CapabilityState(
                id: "tools",
                title: "Hermes tools",
                detail: toolResult == nil ? "Tool catalogue is unavailable" : "Tool catalogue available",
                isAvailable: toolResult != nil,
                recovery: toolResult == nil ? "This Hermes version may not support tools.list." : nil
            ),
            CapabilityState(
                id: "plugins",
                title: "Hermes plugins",
                detail: pluginResult == nil ? "Plugin catalogue is unavailable" : "Plugin catalogue available",
                isAvailable: pluginResult != nil,
                recovery: pluginResult == nil ? "This Hermes version may not support plugins.list." : nil
            ),
            CapabilityState(
                id: "skills",
                title: "Hermes skills",
                detail: skillsAvailable ? "Enabled skills catalogue available" : "Skills catalogue is unavailable",
                isAvailable: skillsAvailable,
                recovery: skillsAvailable ? nil : "This Hermes installation may not support skills listing.",
                source: .cli
            ),
            CapabilityState(
                id: "calendar",
                title: "Calendar",
                detail: "No Hermes Calendar provider is configured",
                isAvailable: false,
                recovery: "Calendar integration is planned for a future provider.",
                source: .external,
                access: .externalSetup,
                availability: .unavailable
            ),
            CapabilityState(
                id: "messaging",
                title: "Messaging",
                detail: messagingAvailable ? "iMessage CLI is available through Hermes" : "imsg is unavailable or unauthorized",
                isAvailable: messagingAvailable,
                recovery: messagingAvailable ? nil : "Install imsg and grant Messages access.",
                recoveryCommand: messagingAvailable ? nil : "brew install steipete/tap/imsg",
                source: .external,
                access: .externalSetup,
                availability: messagingAvailable ? .available : .unavailable
            ),
            CapabilityState(
                id: "email",
                title: "Email",
                detail: emailAvailable ? "Email CLI is available through Hermes" : "himalaya is unavailable or unconfigured",
                isAvailable: emailAvailable,
                recovery: emailAvailable ? nil : "Install and configure himalaya before enabling email actions.",
                recoveryCommand: emailAvailable ? nil : "brew install himalaya",
                source: .external,
                access: .externalSetup,
                availability: emailAvailable ? .available : .unavailable
            ),
            CapabilityState(
                id: "kanban",
                title: "Hermes Kanban",
                detail: kanbanAvailable ? "Kanban CLI is available through Hermes shell; desktop RPC is unavailable" : "Kanban CLI is unavailable",
                isAvailable: kanbanAvailable,
                recovery: kanbanAvailable ? "Use Hermes Kanban prompts for actions; the Dock does not duplicate the board." : "Install or enable Hermes Kanban before using Kanban actions.",
                source: .cli,
                access: .confirmedMutation
            ),
            CapabilityState(
                id: "mcp",
                title: "Third-party MCP",
                detail: !mcpAvailable ? "MCP configuration is unavailable" : (hasMCPServers ? "Configured MCP servers are available through Hermes" : "No MCP servers are configured"),
                isAvailable: hasMCPServers,
                recovery: !mcpAvailable ? "Reconnect Hermes and configure MCP servers there." : (hasMCPServers ? nil : "Configure an MCP server in Hermes before using third-party actions."),
                source: .external,
                access: .externalSetup,
                availability: !mcpAvailable || !hasMCPServers ? .unavailable : .available
            ),
            cliCapability(
                id: "kanban.taskDetails",
                title: "Kanban task details",
                commandResult: kanbanDetails,
                recovery: "This Hermes version does not expose JSON Kanban task details.",
                access: .readOnly
            ),
            cliCapability(
                id: "kanban.taskRuns",
                title: "Kanban task runs",
                commandResult: kanbanRuns,
                recovery: "This Hermes version does not expose Kanban run history.",
                access: .readOnly
            ),
            cliCapability(
                id: "kanban.stats",
                title: "Kanban statistics",
                commandResult: kanbanStats,
                recovery: "This Hermes version does not expose Kanban statistics.",
                access: .readOnly
            ),
            cliCapability(
                id: "kanban.filters",
                title: "Kanban list filters",
                commandResult: kanbanResult,
                recovery: "This Hermes version does not expose the filters used by the Dock.",
                access: .readOnly,
                requiredHelpTerms: ["--status", "--assignee", "--mine", "--session", "--sort", "--json"]
            ),
            cliCapability(
                id: "kanban.assignees",
                title: "Kanban assignee directory",
                commandResult: kanbanAssignees,
                recovery: "This Hermes version does not expose JSON Kanban assignees.",
                access: .readOnly,
                requiredHelpTerms: ["--json"]
            ),
            cliCapability(
                id: "kanban.boards",
                title: "Kanban board directory",
                commandResult: kanbanBoards,
                recovery: "This Hermes version does not expose JSON Kanban board listing.",
                access: .readOnly,
                requiredHelpTerms: ["list", "--json"]
            ),
            cliCapability(id: "kanban.create", title: "Create Kanban task", commandResult: kanbanCreate, recovery: "This Hermes version does not expose Kanban task creation.", access: .confirmedMutation, requiredHelpTerms: ["title"]),
            cliCapability(id: "kanban.complete", title: "Complete Kanban task", commandResult: kanbanComplete, recovery: "This Hermes version does not expose Kanban completion.", access: .confirmedMutation, requiredHelpTerms: ["task"]),
            cliCapability(id: "kanban.block", title: "Block Kanban task", commandResult: kanbanBlock, recovery: "This Hermes version does not expose Kanban blocking.", access: .confirmedMutation, requiredHelpTerms: ["task"]),
            cliCapability(id: "kanban.unblock", title: "Unblock Kanban task", commandResult: kanbanUnblock, recovery: "This Hermes version does not expose Kanban unblocking.", access: .confirmedMutation, requiredHelpTerms: ["task"]),
            cliCapability(id: "kanban.archive", title: "Archive Kanban task", commandResult: kanbanArchive, recovery: "This Hermes version does not expose Kanban archiving.", access: .confirmedMutation, requiredHelpTerms: ["task"]),
            cliCapability(id: "kanban.comment", title: "Comment on Kanban task", commandResult: kanbanComment, recovery: "This Hermes version does not expose Kanban comments.", access: .confirmedMutation, requiredHelpTerms: ["task_id", "text"]),
            cliCapability(id: "kanban.schedule", title: "Schedule Kanban task", commandResult: kanbanSchedule, recovery: "This Hermes version does not expose Kanban scheduling.", access: .confirmedMutation, requiredHelpTerms: ["task_id", "reason"]),
            cliCapability(id: "kanban.assign", title: "Assign Kanban task", commandResult: kanbanAssign, recovery: "This Hermes version does not expose Kanban assignment.", access: .confirmedMutation, requiredHelpTerms: ["task_id", "profile"]),
            cliCapability(id: "kanban.reassign", title: "Reassign Kanban task", commandResult: kanbanReassign, recovery: "This Hermes version does not expose Kanban reassignment.", access: .confirmedMutation, requiredHelpTerms: ["task_id", "profile", "--reclaim"]),
            cliCapability(id: "kanban.promote", title: "Promote Kanban task", commandResult: kanbanPromote, recovery: "This Hermes version does not expose Kanban promotion.", access: .confirmedMutation, requiredHelpTerms: ["task_id", "reason"]),
            cliCapability(id: "kanban.reclaim", title: "Reclaim Kanban task", commandResult: kanbanReclaim, recovery: "This Hermes version does not expose Kanban reclaim.", access: .confirmedMutation, requiredHelpTerms: ["task_id", "--reason"]),
            cliCapability(
                id: "cron.runNow",
                title: "Run scheduled job now",
                commandResult: cronRunNow,
                recovery: "This Hermes version does not expose confirmed cron run-now support.",
                access: .confirmedMutation,
                requiredHelpTerms: ["job_id"]
            ),
            cliCapability(
                id: "cron.edit",
                title: "Edit scheduled job",
                commandResult: cronEdit,
                recovery: "This Hermes version does not expose scheduled-job editing.",
                access: .confirmedMutation,
                requiredHelpTerms: ["job_id", "--schedule", "--prompt", "--name"]
            ),
            cliCapability(
                id: "mcp.test",
                title: "Test MCP connection",
                commandResult: mcpTest,
                recovery: "This Hermes version does not expose MCP connection testing.",
                access: .readOnly
            ),
            cliCapability(
                id: "diagnostics.status",
                title: "Hermes health diagnostics",
                commandResult: diagnosticsStatus,
                recovery: "This Hermes version does not expose status diagnostics.",
                access: .readOnly
            ),
            cliCapability(
                id: "diagnostics.monitoring",
                title: "Gateway monitoring status",
                commandResult: monitoringStatus,
                recovery: "This Hermes version does not expose monitoring status.",
                access: .readOnly
            ),
            cliCapability(
                id: "diagnostics.checkpoints",
                title: "Checkpoint storage status",
                commandResult: checkpointStatus,
                recovery: "This Hermes version does not expose checkpoint status.",
                access: .readOnly
            ),
            cliCapability(
                id: "diagnostics.hooks",
                title: "Shell hook status",
                commandResult: hooksList,
                recovery: "This Hermes version does not expose shell hook status.",
                access: .readOnly
            ),
            cliCapability(
                id: "journey.timeline",
                title: "Hermes journey timeline",
                commandResult: journey,
                recovery: "This Hermes version does not expose the Journey timeline.",
                access: .readOnly,
                requiredHelpTerms: ["--json"]
            ),
            cliCapability(
                id: "sessions.stats",
                title: "Session store statistics",
                commandResult: sessionStats,
                recovery: "This Hermes version does not expose session-store statistics.",
                access: .readOnly
            ),
            cliCapability(
                id: "memory.status",
                title: "Memory health",
                commandResult: memoryStatus,
                recovery: "This Hermes version does not expose memory health status.",
                access: .readOnly
            )
        ]

        let snapshot = CapabilitySnapshot(states: states, generatedAt: Date())
        cachedSnapshot = snapshot
        cachedRemindersAvailability = remindersAvailable
        return states
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
        let available = Self.shellResultSucceeded(commandResult)
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

    private func request(_ client: HermesRPCClientProtocol, method: String, params: [String: Any] = [:]) async -> [String: Any]? {
        try? await client.request(method, params: params)
    }

    static func shellResultSucceeded(_ result: [String: Any]?) -> Bool {
        guard let result else { return false }
        return AppleRemindersAdapter.shellResultSucceeded(result)
    }
}
