import Foundation

// MARK: - Mission Control

enum ReadinessState: String, Equatable {
    case ready = "Ready"
    case needsReview = "Needs review"
    case blocked = "Blocked"
    case notApplicable = "Not applicable"
}

struct ReadinessSummary: Equatable {
    let state: ReadinessState
    let detail: String
    let verificationScope: String?
}

struct MissionControlFocus: Equatable {
    let sessionTitle: String?
    let branch: String?
    let model: String?
    let contextPercent: Double?
    let changedFiles: Int?
    let runningCount: Int
}

enum MissionControlSection: String, CaseIterable, Identifiable {
    case needsMe = "Needs Me"
    case runningNow = "Running Now"
    case changed = "Changed"
    case readiness = "Readiness"

    var id: String { rawValue }
}

struct MissionControlWorkItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case attention(AttentionItem)
        case session(SessionSummary)
        case agent(AgentSummary)
        case process(ProcessSummary)
        case background(HermesBackgroundTask)
        case activity(AgentActivity)
        case cron(CronRunSummary)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let isUrgent: Bool
}

struct MissionControlSnapshot: Equatable {
    let focus: MissionControlFocus
    let needsMe: [MissionControlWorkItem]
    let runningNow: [MissionControlWorkItem]
    let changed: [MissionControlWorkItem]
    let readiness: ReadinessSummary
}

enum WorkspaceOverviewMetrics {
    /// Counts all currently active work represented by the global overview.
    /// `activeSessions` comes from Hermes' active-session projection; agents,
    /// processes, and background tasks are additional running work items.
    static func runningCount(
        activeSessions: [SessionSummary],
        agents: [AgentSummary],
        processes: [ProcessSummary],
        backgroundTasks: [HermesBackgroundTask]
    ) -> Int {
        activeSessions.count
            + agents.count
            + processes.count
            + backgroundTasks.filter { $0.status == .running }.count
    }
}

enum MissionControlSnapshotBuilder {
    static func make(
        sessionTitle: String?,
        repository: RepositorySnapshot?,
        model: String?,
        context: SessionContextSummary?,
        attention: [AttentionItem],
        sessions: [SessionSummary],
        activeSessionID: String?,
        agents: [AgentSummary],
        processes: [ProcessSummary],
        backgroundTasks: [HermesBackgroundTask],
        activities: [AgentActivity],
        cronRuns: [CronRunSummary],
        verification: VerificationSummary?
    ) -> MissionControlSnapshot {
        let openAttention = attention.filter { $0.state == .open }.sorted { priority($0.kind) < priority($1.kind) }
        let needsMe = openAttention.map {
            MissionControlWorkItem(
                id: "attention:\($0.id)", kind: .attention($0), title: $0.title, detail: $0.detail,
                isUrgent: isUrgent($0.kind))
        }
        let otherSessions = sessions.filter { $0.id != activeSessionID }
        let running =
            agents.map {
                MissionControlWorkItem(
                    id: "agent:\($0.id)", kind: .agent($0), title: $0.name, detail: $0.state.uppercased(),
                    isUrgent: false)
            }
            + processes.map {
                MissionControlWorkItem(
                    id: "process:\($0.id)", kind: .process($0), title: $0.name, detail: $0.state.uppercased(),
                    isUrgent: false)
            }
            + backgroundTasks.filter { $0.status == .running }.map {
                MissionControlWorkItem(
                    id: "background:\($0.id)", kind: .background($0), title: $0.prompt, detail: "BACKGROUND TASK",
                    isUrgent: false)
            }
            + otherSessions.map {
                MissionControlWorkItem(
                    id: "session:\($0.id)", kind: .session($0), title: $0.title, detail: $0.state.uppercased(),
                    isUrgent: false)
            }
        let changed =
            activities.suffix(4).reversed().map {
                MissionControlWorkItem(
                    id: "activity:\($0.id.uuidString)", kind: .activity($0),
                    title: $0.kind.replacingOccurrences(of: "subagent.", with: "").uppercased(), detail: $0.text,
                    isUrgent: false)
            }
            + cronRuns.prefix(3).map {
                MissionControlWorkItem(
                    id: "cron:\($0.id)", kind: .cron($0), title: "AUTOMATION · \($0.status.uppercased())",
                    detail: $0.jobID ?? "Scheduled job", isUrgent: $0.status.lowercased().contains("fail"))
            }
        let readiness = readiness(
            repository: repository, attention: openAttention, verification: verification, context: context)
        return MissionControlSnapshot(
            focus: MissionControlFocus(
                sessionTitle: sessionTitle, branch: repository?.isGitRepository == true ? repository?.branch : nil,
                model: model, contextPercent: context?.contextPercent,
                changedFiles: repository?.isGitRepository == true ? repository?.changedFiles : nil,
                runningCount: running.count),
            needsMe: needsMe,
            runningNow: running,
            changed: Array(changed),
            readiness: readiness
        )
    }

    private static func priority(_ kind: AttentionKind) -> Int {
        switch kind {
        case .approval: 0
        case .clarification: 1
        case .failure: 2
        case .reminder: 3
        case .completed: 4
        }
    }

    private static func isUrgent(_ kind: AttentionKind) -> Bool {
        kind == .approval || kind == .clarification || kind == .failure
    }

    private static func readiness(
        repository: RepositorySnapshot?, attention: [AttentionItem], verification: VerificationSummary?,
        context: SessionContextSummary?
    ) -> ReadinessSummary {
        guard let repository, repository.isGitRepository else {
            return ReadinessSummary(state: .notApplicable, detail: "No active repository", verificationScope: nil)
        }
        if verification?.state == .failed || attention.contains(where: { $0.kind == .failure }) {
            return ReadinessSummary(
                state: .blocked, detail: "Resolve failures before shipping",
                verificationScope: verification?.evidence?.scope)
        }
        let scope = verification?.evidence?.scope?.lowercased()
        if repository.changedFiles > 0 || verification?.state != .passed || scope == "targeted"
            || (context?.contextPercent ?? 0) >= 80
        {
            let detail =
                scope == "targeted"
                ? "Targeted verification needs broader review" : "Review repository state and verification"
            return ReadinessSummary(
                state: .needsReview, detail: detail, verificationScope: verification?.evidence?.scope)
        }
        return ReadinessSummary(
            state: .ready, detail: "Clean tree with repository-wide verification",
            verificationScope: verification?.evidence?.scope)
    }
}

// MARK: - Workflows and command actions

enum WorkflowRecipe: String, CaseIterable, Identifiable {
    case preflight, prReady, bugTriage, reviewChanges, endOfDay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .preflight: "Preflight"
        case .prReady: "PR Ready"
        case .bugTriage: "Bug Triage"
        case .reviewChanges: "Review Changes"
        case .endOfDay: "End-of-Day Review"
        }
    }
    var explanation: String {
        switch self {
        case .preflight: "Inspect the change, run exact available checks, and report blockers."
        case .prReady: "Verify the current change and produce a concise review-ready summary."
        case .bugTriage: "Reproduce, isolate likely code, and propose a safe next step."
        case .reviewChanges: "Review the current working tree without editing files."
        case .endOfDay: "Summarize live work, unfinished tasks, and outstanding attention."
        }
    }
    var requiresRepository: Bool { self != .endOfDay }
    var prompt: String {
        switch self {
        case .preflight:
            "Inspect the current repository changes. Run only Hermes-provided verification commands that apply. Do not edit files. Report exact evidence, scope, and blockers."
        case .prReady:
            "Review the current repository change for pull-request readiness. Run applicable Hermes-provided verification commands. Do not edit files or create a PR. Report a concise summary, risks, and verification evidence."
        case .bugTriage:
            "Triage the reported issue in the current repository. Reproduce or inspect safely, identify likely code, and propose a plan. Do not edit files."
        case .reviewChanges:
            "Review the current working-tree changes. Do not edit files. Report correctness risks, missing tests, and a concise change summary."
        case .endOfDay:
            "Summarize the current Hermes work, completed work, open attention, and next available actions. Do not edit files."
        }
    }
}

enum DockAction: Hashable, Identifiable {
    case tab(ControlTab)
    case captureWindow, newChat, focusComposer, stop, voice, refresh, artifacts, restartDock
    case workflow(WorkflowRecipe)

    var id: String {
        switch self {
        case .tab(let tab): "tab.\(tab.rawValue)"
        case .captureWindow: "capture-window"
        case .newChat: "new-chat"
        case .focusComposer: "focus-composer"
        case .stop: "stop"
        case .voice: "voice"
        case .refresh: "refresh"
        case .artifacts: "artifacts"
        case .restartDock: "restart-dock"
        case .workflow(let recipe): "workflow.\(recipe.rawValue)"
        }
    }
}

struct DockActionDescriptor: Identifiable, Equatable {
    let action: DockAction
    let title: String
    let subtitle: String
    let icon: Ph
    let category: String
    let keywords: [String]
    let isAvailable: Bool
    let unavailableReason: String?
    let requiresConfirmation: Bool
    var id: String { action.id }
}

enum DockActionRegistry {
    static func make(repositoryAvailable: Bool, isWorking: Bool) -> [DockActionDescriptor] {
        let tabs = ControlTab.allCases.map { tab in
            DockActionDescriptor(
                action: .tab(tab), title: "Open \(tab.tabLabel)", subtitle: "Navigate to \(tab.tabLabel)",
                icon: tab.icon, category: "Navigation", keywords: [tab.rawValue], isAvailable: true,
                unavailableReason: nil, requiresConfirmation: false)
        }
        let basics = [
            DockActionDescriptor(
                action: .captureWindow, title: "Capture window",
                subtitle: "Attach the last active app window to your draft", icon: .image, category: "Context",
                keywords: ["screenshot", "window", "capture"], isAvailable: true, unavailableReason: nil,
                requiresConfirmation: false),
            DockActionDescriptor(
                action: .newChat, title: "New chat", subtitle: "Start a Hermes session", icon: .notePencil,
                category: "Session", keywords: ["session", "chat"], isAvailable: true, unavailableReason: nil,
                requiresConfirmation: false),
            DockActionDescriptor(
                action: .focusComposer, title: "Focus composer", subtitle: "Return to Ask", icon: .cursorText,
                category: "Session", keywords: ["ask", "prompt"], isAvailable: true, unavailableReason: nil,
                requiresConfirmation: false),
            DockActionDescriptor(
                action: .stop, title: "Stop active request", subtitle: "Interrupt the active Hermes turn",
                icon: .stopCircle, category: "Session", keywords: ["interrupt", "cancel"], isAvailable: isWorking,
                unavailableReason: isWorking ? nil : "No active request", requiresConfirmation: false),
            DockActionDescriptor(
                action: .voice, title: "Start voice", subtitle: "Start a voice conversation", icon: .microphone,
                category: "Session", keywords: ["talk", "microphone"], isAvailable: true, unavailableReason: nil,
                requiresConfirmation: false),
            DockActionDescriptor(
                action: .refresh, title: "Refresh command center", subtitle: "Refresh live Hermes projections",
                icon: .arrowsClockwise, category: "Control", keywords: ["reload", "update"], isAvailable: true,
                unavailableReason: nil, requiresConfirmation: false),
            DockActionDescriptor(
                action: .restartDock, title: "Restart Herm",
                subtitle: "Reload Codex account credentials and restart Hermes", icon: .arrowClockwise,
                category: "System", keywords: ["restart", "relaunch", "account", "credentials", "codex"],
                isAvailable: true, unavailableReason: nil, requiresConfirmation: true),
            DockActionDescriptor(
                action: .artifacts, title: "Open artifacts",
                subtitle: "Browse generated images, files, and links from recent sessions", icon: .squaresFour,
                category: "Navigation", keywords: ["artifacts", "images", "files", "links", "outputs"],
                isAvailable: true, unavailableReason: nil, requiresConfirmation: false),
        ]
        let workflows = WorkflowRecipe.allCases.map { recipe in
            DockActionDescriptor(
                action: .workflow(recipe), title: recipe.title, subtitle: recipe.explanation, icon: .magicWand,
                category: "Workflow", keywords: ["recipe", "review", "verification"],
                isAvailable: !recipe.requiresRepository || repositoryAvailable,
                unavailableReason: recipe.requiresRepository && !repositoryAvailable
                    ? "Select a local folder for the active project session first" : nil, requiresConfirmation: false)
        }
        return tabs + basics + workflows
    }

    static func search(_ query: String, descriptors: [DockActionDescriptor], recentIDs: [String])
        -> [DockActionDescriptor]
    {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let scored = descriptors.compactMap { descriptor -> (DockActionDescriptor, Int)? in
            let haystack = ([descriptor.title, descriptor.subtitle, descriptor.category] + descriptor.keywords).joined(
                separator: " "
            ).lowercased()
            guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
            var score = descriptor.title.lowercased().hasPrefix(query.lowercased()) ? 100 : 0
            if descriptor.isAvailable { score += 20 }
            if let recentIndex = recentIDs.firstIndex(of: descriptor.id) { score += max(0, 10 - recentIndex) }
            return (descriptor, score)
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1 }.map(\.0)
    }
}
