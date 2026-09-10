import Foundation

/// Typed result for the optional machine-readable Hermes skills contract.
enum HermesSkillsInventory: Equatable, Sendable {
    case supported([String])
    case unavailable(HermesSkillsUnavailableReason)

    var names: [String] {
        if case .supported(let names) = self { return names }
        return []
    }
}

enum HermesSkillsUnavailableReason: Equatable, Sendable {
    case emptyOutput
    case unsupportedOutput
}

/// The single source of truth for feature identity shared by capability probes,
/// transport adapters, and presentation gates. Raw values are stable contract
/// identifiers; callers must not invent spelling variants at the call site.
enum HermesFeatureIDs {
    enum ID: String, CaseIterable, Sendable {
        case gateway
        case hermesVersion = "hermes-version"
        case rpcSessions = "rpc-sessions"
        case rpcScheduling = "rpc-scheduling"
        case rpcActivity = "rpc-activity"
        case rpcProjects = "rpc-projects"
        case reminders, notes, tools, plugins, skills, calendar, messaging, email, kanban, mcp
        case kanbanTaskDetails = "kanban.taskDetails"
        case kanbanTaskRuns = "kanban.taskRuns"
        case kanbanStats = "kanban.stats"
        case kanbanFilters = "kanban.filters"
        case kanbanAssignees = "kanban.assignees"
        case kanbanBoards = "kanban.boards"
        case kanbanCreate = "kanban.create"
        case kanbanComplete = "kanban.complete"
        case kanbanBlock = "kanban.block"
        case kanbanUnblock = "kanban.unblock"
        case kanbanArchive = "kanban.archive"
        case kanbanComment = "kanban.comment"
        case kanbanSchedule = "kanban.schedule"
        case kanbanAssign = "kanban.assign"
        case kanbanReassign = "kanban.reassign"
        case kanbanPromote = "kanban.promote"
        case kanbanReclaim = "kanban.reclaim"
        case cronRunNow = "cron.runNow"
        case cronEdit = "cron.edit"
        case mcpTest = "mcp.test"
        case diagnosticsStatus = "diagnostics.status"
        case diagnosticsMonitoring = "diagnostics.monitoring"
        case diagnosticsCheckpoints = "diagnostics.checkpoints"
        case diagnosticsHooks = "diagnostics.hooks"
        case journeyTimeline = "journey.timeline"
        case sessionsStats = "sessions.stats"
        case memoryStatus = "memory.status"
        case sessionList = "session.list"
        case sessionActiveList = "session.active_list"
        case sessionActivate = "session.activate"
        case sessionDelete = "session.delete"
        case sessionResume = "session.resume"
        case sessionMessages = "session.messages"
        case sessionInterrupt = "session.interrupt"
        case sessionUsage = "session.usage"
        case sessionContextBreakdown = "session.context_breakdown"
        case sessionCreate = "session.create"
        case projectFacts = "project.facts"
        case verificationStatus = "verification.status"
        case promptSubmit = "prompt.submit"
        case promptBackground = "prompt.background"
        case sessionTitle = "session.title"
        case sessionSteer = "session.steer"
        case sessionBranch = "session.branch"
        case sessionCompress = "session.compress"
        case sessionUndo = "session.undo"
        case sessionRedirect = "session.redirect"
        case delegationPause = "delegation.pause"
        case subagentInterrupt = "subagent.interrupt"
        case processKill = "process.kill"
        case approvalRespond = "approval.respond"
        case clarifyRespond = "clarify.respond"
        case delegationStatus = "delegation.status"
        case cronManage = "cron.manage"
        case reloadMCP = "reload.mcp"
        case processList = "process.list"
        case toolsList = "tools.list"
        case pluginsList = "plugins.list"
        case configShow = "config.show"
        case projectsTree = "projects.tree"
        case projectsProjectSessions = "projects.project_sessions"
        case voiceToggle = "voice.toggle"
        case voiceRecord = "voice.record"
        case configGet = "config.get"
        case configSet = "config.set"
        case modelOptions = "model.options"
        case shellExec = "shell.exec"
        case imageAttachBytes = "image.attach_bytes"
        case profilesList = "profiles.list"
        case profilesDescribe = "profiles.describe"
        case profilesCreate = "profiles.create"
        case profilesConfigure = "profiles.configure"
        case profilesSetAsset = "profiles.set_asset"
        case profilesGetAsset = "profiles.get_asset"
        case imageGenerate = "image.generate"
        case bots
    }

    static let transportIDs: [String] = [
        "session.list", "session.active_list", "session.activate", "session.delete", "session.resume",
        "session.interrupt", "session.messages", "session.usage", "session.context_breakdown", "session.create", "project.facts",
        "verification.status", "prompt.submit", "prompt.background", "session.title", "session.steer", "session.branch",
        "session.compress", "session.undo", "session.redirect", "delegation.pause", "subagent.interrupt", "process.kill",
        "approval.respond", "clarify.respond", "delegation.status", "cron.manage", "reload.mcp", "process.list", "tools.list",
        "plugins.list", "config.show", "projects.tree", "projects.project_sessions", "voice.toggle", "voice.record", "config.get",
        "config.set", "model.options", "shell.exec", "image.attach_bytes",
        "profiles.list", "profiles.describe", "profiles.create", "profiles.configure", "profiles.set_asset", "profiles.get_asset", "image.generate"
    ]
    static let all = ID.allCases.map(\.rawValue)
    static let capabilityIDs = ID.allCases.filter { !transportIDs.contains($0.rawValue) }.map(\.rawValue)

    static func lookup(_ rawValue: String) -> ID? { ID(rawValue: rawValue) }
}

enum HermesFeatureContract {
    /// Hermes 0.20.6 exposes no `--json` option for `skills list`; this command
    /// remains the explicit display-only fallback until a stable JSON contract
    /// is available upstream.
    static let enabledSkillsCommand = HermesCLICommand(["hermes", "skills", "list", "--enabled-only"])
}
