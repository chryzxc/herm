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
    /// Hermes' own label for a desktop front end's sessions. It is a Hermes
    /// vocabulary value, not the app name: Hermes hands it to the session's
    /// tools as `HERMES_SESSION_SOURCE`, and only labels it knows (`desktop`)
    /// are cleared for nested `hermes chat -Q` runs; others fail `invalid_params`.
    static let sessionSource = "desktop"

    enum ID: String, CaseIterable, Sendable {
        case petInfo = "pet.info"
        case petInfoMeta = "pet.info.meta"
        case petGallery = "pet.gallery"
        case petThumb = "pet.thumb"
        case petSelect = "pet.select"
        case petDisable = "pet.disable"
        case petScale = "pet.scale"
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
        case sessionSetHidden = "session.set_hidden"
        case sessionClose = "session.close"
        case sessionResume = "session.resume"
        case sessionMessages = "session.messages"
        case sessionEventsSince = "session.events.since"
        case sessionInterrupt = "session.interrupt"
        case sessionUsage = "session.usage"
        case sessionContextBreakdown = "session.context_breakdown"
        case sessionCreate = "session.create"
        case sessionCwdSet = "session.cwd.set"
        case projectFacts = "project.facts"
        case verificationStatus = "verification.status"
        case promptSubmit = "prompt.submit"
        case completeSlash = "complete.slash"
        case completePath = "complete.path"
        case commandsCatalog = "commands.catalog"
        case slashExec = "slash.exec"
        case commandDispatch = "command.dispatch"
        case botRelayDeliver = "bot_relay.deliver"
        case groupsCapabilities = "groups.capabilities"
        case groupsList = "groups.list"
        case groupsCreate = "groups.create"
        case groupsState = "groups.state"
        case groupsSend = "groups.send"
        case groupsAttachmentUpload = "groups.attachment.upload"
        case groupsAttachmentDownload = "groups.attachment.download"
        case groupsLog = "groups.log"
        case groupsRename = "groups.rename"
        case groupsStop = "groups.stop"
        case groupsDisband = "groups.disband"
        case groupsApprove = "groups.approve"
        case groupsRetry = "groups.retry"
        case groupsPeerInvite = "groups.peer.invite"
        case groupsPeerRegister = "groups.peer.register"
        case promptBackground = "prompt.background"
        case promptBtw = "prompt.btw"
        case sessionTitle = "session.title"
        case sessionSteer = "session.steer"
        case sessionBranch = "session.branch"
        case sessionCompress = "session.compress"
        case sessionUndo = "session.undo"
        case sessionRedirect = "session.redirect"
        case sessionControlRead = "session.control.read"
        case delegationPause = "delegation.pause"
        case subagentInterrupt = "subagent.interrupt"
        case processKill = "process.kill"
        case approvalRespond = "approval.respond"
        case approvalPending = "approval.pending"
        case clarifyRespond = "request.answer"
        case clarifyLock = "clarify.lock"
        case delegationStatus = "delegation.status"
        case cronManage = "cron.manage"
        case reloadMCP = "reload.mcp"
        case processList = "process.list"
        case toolsList = "tools.list"
        case pluginsList = "plugins.list"
        case configShow = "config.show"
        case projectsTree = "projects.tree"
        case projectsProjectSessions = "projects.project_sessions"
        case projectsCreate = "projects.create"
        case projectsArchive = "projects.archive"
        case projectsDelete = "projects.delete"
        case projectsSetActive = "projects.set_active"
        case projectsAddFolder = "projects.add_folder"
        case voiceToggle = "voice.toggle"
        case voiceRecord = "voice.record"
        case voiceTTS = "voice.tts"
        case configGet = "config.get"
        case configSet = "config.set"
        case modelOptions = "model.options"
        case modelSaveKey = "model.save_key"
        case modelDisconnect = "model.disconnect"
        case shellExec = "shell.exec"
        case imageAttachBytes = "image.attach_bytes"
        case fileAttach = "file.attach"
        case gatewayCapabilities = "gateway.capabilities"
        case imageDetach = "image.detach"
        case pdfAttach = "pdf.attach"
        case profilesList = "profiles.list"
        case profilesDescribe = "profiles.describe"
        case profilesCreate = "profiles.create"
        case profilesConfigure = "profiles.configure"
        case profilesSetAsset = "profiles.set_asset"
        case profilesGetAsset = "profiles.get_asset"
        case imageGenerate = "image.generate"
        case insightsGet = "insights.get"
        case rollbackList = "rollback.list"
        case rollbackDiff = "rollback.diff"
        case rollbackRestore = "rollback.restore"
        case skillsManage = "skills.manage"
        case pluginsManage = "plugins.manage"
        case connectorsList = "connectors.list"
        case connectorsCatalog = "connectors.catalog"
        case connectorsConnect = "connectors.connect"
        case connectorsOperationStatus = "connectors.operation.status"
        case connectorsAccounts = "connectors.accounts"
        case connectorsAccountsRemove = "connectors.accounts.remove"
        case connectorsAccountsRename = "connectors.accounts.rename"
        case connectorsPolicyGet = "connectors.policy.get"
        case connectorsPolicySet = "connectors.policy.set"
        case mcpCatalog = "mcp.catalog"
        case mcpServersList = "mcp.servers.list"
        case mcpServersAdd = "mcp.servers.add"
        case mcpServersKey = "mcp.servers.set_api_key"
        case mcpServersTest = "mcp.servers.test"
        case mcpServersRemove = "mcp.servers.remove"
        case mcpOAuthStart = "mcp.servers.oauth.start"
        case mcpOAuthPoll = "mcp.servers.oauth.poll"
        case mcpOAuthCancel = "mcp.servers.oauth.cancel"
        case agentsList = "agents.list"
        case subagentList = "subagent.list"
        case subagentSteer = "subagent.steer"
        case learningDetail = "learning.detail"
        case learningEdit = "learning.edit"
        case learningDelete = "learning.delete"
        case browserManage = "browser.manage"
        case vaultList = "vault.list"
        case vaultAdd = "vault.add"
        case vaultRemove = "vault.remove"
        case vaultSources = "vault.sources"
        case vaultSourceSet = "vault.source.set"
        case vaultUnlock = "vault.unlock"
        case vaultLock = "vault.lock"
        case bots
    }

    static let transportIDs: [String] = [
        "vault.list", "vault.add", "vault.remove", "vault.sources", "vault.source.set", "vault.unlock", "vault.lock",
        "pet.info", "pet.info.meta", "pet.gallery", "pet.thumb", "pet.select", "pet.disable", "pet.scale",
        "session.list", "session.active_list", "session.activate", "session.delete", "session.resume",
        "session.interrupt", "session.messages", "session.usage", "session.context_breakdown", "session.create",
        "session.cwd.set", "session.close", "session.set_hidden", "session.events.since", "project.facts",
        "verification.status", "prompt.submit", "complete.slash", "complete.path", "commands.catalog", "slash.exec",
        "command.dispatch", "bot_relay.deliver",
        "groups.capabilities", "groups.list", "groups.create", "groups.state", "groups.send",
        "groups.attachment.upload", "groups.attachment.download", "groups.log",
        "groups.rename", "groups.stop", "groups.disband", "groups.approve", "groups.retry", "groups.peer.invite",
        "groups.peer.register", "prompt.background", "prompt.btw", "session.title", "session.steer", "session.branch",
        "session.compress", "session.undo", "session.redirect", "session.control.read", "delegation.pause",
        "subagent.interrupt",
        "process.kill",
        "approval.respond", "approval.pending", "request.answer", "clarify.lock", "delegation.status", "cron.manage",
        "reload.mcp", "process.list", "tools.list",
        "plugins.list", "config.show", "projects.tree", "projects.project_sessions", "voice.toggle", "voice.record",
        "voice.tts", "config.get",
        "config.set", "model.options", "shell.exec", "image.attach_bytes", "image.detach", "pdf.attach",
        "profiles.list", "profiles.describe", "profiles.create", "profiles.configure", "profiles.set_asset",
        "profiles.get_asset", "image.generate", "insights.get", "rollback.list", "rollback.diff", "rollback.restore",
        "file.attach", "gateway.capabilities",
        "projects.create", "projects.archive", "projects.delete", "projects.set_active", "projects.add_folder",
        "skills.manage", "plugins.manage", "connectors.list", "connectors.catalog", "connectors.connect",
        "connectors.operation.status", "connectors.accounts", "connectors.accounts.remove",
        "connectors.accounts.rename", "connectors.policy.get", "connectors.policy.set", "mcp.catalog",
        "mcp.servers.list", "mcp.servers.add", "mcp.servers.set_api_key", "mcp.servers.test", "mcp.servers.remove",
        "mcp.servers.oauth.start", "mcp.servers.oauth.poll", "mcp.servers.oauth.cancel", "subagent.list",
        "subagent.steer", "learning.detail", "learning.edit", "learning.delete", "browser.manage", "agents.list",
    ]
    static let all = ID.allCases.map(\.rawValue)
    static let capabilityIDs = ID.allCases.filter { !transportIDs.contains($0.rawValue) }.map(\.rawValue)

    static func lookup(_ rawValue: String) -> ID? { ID(rawValue: rawValue) }
}

enum HermesFeatureContract {
    /// Display-only CLI fallback; lifecycle controls use the named workflow adapter
    /// and validate installed-runtime responses independently.
    static let enabledSkillsCommand = HermesCLICommand(["hermes", "skills", "list", "--enabled-only"])
}
