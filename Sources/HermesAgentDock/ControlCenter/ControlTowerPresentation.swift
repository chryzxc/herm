import Foundation

// MARK: - P3 Attention Inbox

enum AttentionPresentationGroup: String, CaseIterable, Identifiable {
    case requiresDecision = "Requires Decision"
    case blockedOrFailed = "Blocked / Failed"
    case waiting = "Waiting"
    case history = "History"
    var id: String { rawValue }
}

struct AttentionRowPresentation: Identifiable, Equatable {
    let item: AttentionItem
    let group: AttentionPresentationGroup
    let sourceLabel: String
    let isActionable: Bool
    var id: String { item.id }
}

enum AttentionPresentation {
    static func rows(_ items: [AttentionItem]) -> [AttentionRowPresentation] {
        items.map { item in
            AttentionRowPresentation(item: item, group: group(for: item), sourceLabel: sourceLabel(for: item), isActionable: item.state == .open && !item.actions.isEmpty)
        }.sorted { lhs, rhs in
            let l = rank(lhs.item) * 1_000_000 - Int(lhs.item.createdAt.timeIntervalSince1970)
            let r = rank(rhs.item) * 1_000_000 - Int(rhs.item.createdAt.timeIntervalSince1970)
            return l == r ? lhs.id < rhs.id : l < r
        }
    }

    static func grouped(_ items: [AttentionItem]) -> [AttentionPresentationGroup: [AttentionRowPresentation]] {
        Dictionary(grouping: rows(items), by: \.group)
    }

    private static func rank(_ item: AttentionItem) -> Int {
        guard item.state == .open else { return 7 }
        switch item.kind {
        case .approval: return 0
        case .clarification: return 1
        case .failure: return item.detail.localizedCaseInsensitiveContains("blocked") ? 3 : 2
        case .reminder: return 5
        case .completed: return 6
        }
    }

    private static func group(for item: AttentionItem) -> AttentionPresentationGroup {
        guard item.state == .open else { return .history }
        switch item.kind {
        case .approval, .clarification: return .requiresDecision
        case .failure: return item.detail.localizedCaseInsensitiveContains("blocked") ? .blockedOrFailed : .blockedOrFailed
        case .reminder: return .waiting
        case .completed: return .history
        }
    }

    private static func sourceLabel(for item: AttentionItem) -> String {
        switch item.reference.source {
        case .hermesSession, .hermesApproval, .hermesClarification, .hermesAgentRun: return "SESSION"
        case .hermesCronJob: return "AUTOMATION"
        case .appleReminder: return "REMINDER"
        case .hermesProject: return "PROJECT"
        }
    }
}

// MARK: - P4 Verification Evidence

enum DeliveryEvidenceState: String, Equatable {
    case blocked, stale, partial, targetedOnly, current, unavailable
}

struct VerificationEvidencePresentation: Equatable {
    let state: DeliveryEvidenceState
    let title: String
    let nextAction: String
    let scope: String?
    let command: String?
    let fingerprint: String?
    let adapter: String?
    let capturedAt: Date?
    let repositoryIdentity: String?
    let commitFingerprint: String?
    let targetFingerprint: String?
    let diffFingerprint: String?
    let rulesScopeDetail: String?
    let staleReason: String?

    static func make(verification: VerificationSummary?, currentFingerprint: String?, evidenceFingerprint: String?, currentRepositoryIdentity: String? = nil, currentCommitFingerprint: String? = nil, currentTargetFingerprint: String? = nil, currentDiffFingerprint: String? = nil, openFailureCount: Int, repositoryDirty: Bool) -> Self {
        guard let verification else { return Self(state: .unavailable, title: "Evidence unavailable", nextAction: "Run an observed verification through Hermes.", scope: nil, command: nil, fingerprint: currentFingerprint, adapter: nil, capturedAt: nil, repositoryIdentity: nil, commitFingerprint: nil, targetFingerprint: nil, diffFingerprint: nil, rulesScopeDetail: nil, staleReason: nil) }
        let evidence = verification.evidence
        let metadata = Self.metadata(evidence: evidence, fingerprint: evidenceFingerprint)
        let staleBySnapshot = (evidence?.repositoryIdentity != nil && currentRepositoryIdentity != nil && evidence?.repositoryIdentity != currentRepositoryIdentity)
            || (evidence?.commitFingerprint != nil && currentCommitFingerprint != nil && evidence?.commitFingerprint != currentCommitFingerprint)
            || (evidence?.targetFingerprint != nil && currentTargetFingerprint != nil && evidence?.targetFingerprint != currentTargetFingerprint)
            || (evidence?.diffFingerprint != nil && currentDiffFingerprint != nil && evidence?.diffFingerprint != currentDiffFingerprint)
        if openFailureCount > 0 || verification.state == .failed { return Self(state: .blocked, title: "Verification blocked", nextAction: "Resolve the reported failure, then run verification again.", scope: evidence?.scope, command: evidence?.canonicalCommand ?? evidence?.command, fingerprint: evidenceFingerprint, adapter: metadata.adapter, capturedAt: metadata.capturedAt, repositoryIdentity: metadata.repositoryIdentity, commitFingerprint: metadata.commitFingerprint, targetFingerprint: metadata.targetFingerprint, diffFingerprint: metadata.diffFingerprint, rulesScopeDetail: metadata.rulesScopeDetail, staleReason: metadata.staleReason) }
        if metadata.staleReason != nil || staleBySnapshot || (currentFingerprint != nil && evidenceFingerprint != nil && currentFingerprint != evidenceFingerprint) { return Self(state: .stale, title: "Evidence is stale", nextAction: metadata.staleReason ?? "Refresh verification against the current repository state.", scope: evidence?.scope, command: evidence?.canonicalCommand ?? evidence?.command, fingerprint: evidenceFingerprint, adapter: metadata.adapter, capturedAt: metadata.capturedAt, repositoryIdentity: metadata.repositoryIdentity, commitFingerprint: metadata.commitFingerprint, targetFingerprint: metadata.targetFingerprint, diffFingerprint: metadata.diffFingerprint, rulesScopeDetail: metadata.rulesScopeDetail, staleReason: metadata.staleReason) }
        let scope = evidence?.scope?.lowercased() ?? ""
        let common = (metadata.adapter, metadata.capturedAt, metadata.repositoryIdentity, metadata.commitFingerprint, metadata.targetFingerprint, metadata.diffFingerprint, metadata.rulesScopeDetail, metadata.staleReason)
        if scope.contains("target") || scope.contains("file") { return Self(state: .targetedOnly, title: "Targeted evidence only", nextAction: "Run the repository-wide checks before claiming readiness.", scope: evidence?.scope, command: evidence?.canonicalCommand ?? evidence?.command, fingerprint: evidenceFingerprint, adapter: common.0, capturedAt: common.1, repositoryIdentity: common.2, commitFingerprint: common.3, targetFingerprint: common.4, diffFingerprint: common.5, rulesScopeDetail: common.6, staleReason: common.7) }
        if verification.state == .passed && repositoryDirty { return Self(state: .partial, title: "Passed, but repository changed", nextAction: "Re-run verification after the latest changes.", scope: evidence?.scope, command: evidence?.canonicalCommand ?? evidence?.command, fingerprint: evidenceFingerprint, adapter: common.0, capturedAt: common.1, repositoryIdentity: common.2, commitFingerprint: common.3, targetFingerprint: common.4, diffFingerprint: common.5, rulesScopeDetail: common.6, staleReason: common.7) }
        guard verification.state == .passed else { return Self(state: .unavailable, title: "Evidence unavailable", nextAction: "Obtain a fresh observed verification result.", scope: evidence?.scope, command: evidence?.canonicalCommand ?? evidence?.command, fingerprint: evidenceFingerprint, adapter: common.0, capturedAt: common.1, repositoryIdentity: common.2, commitFingerprint: common.3, targetFingerprint: common.4, diffFingerprint: common.5, rulesScopeDetail: common.6, staleReason: common.7) }
        return Self(state: .current, title: "Evidence current", nextAction: "Review the exact command and scope before delivery.", scope: evidence?.scope, command: evidence?.canonicalCommand ?? evidence?.command, fingerprint: evidenceFingerprint, adapter: common.0, capturedAt: common.1, repositoryIdentity: common.2, commitFingerprint: common.3, targetFingerprint: common.4, diffFingerprint: common.5, rulesScopeDetail: common.6, staleReason: common.7)
    }

    private static func metadata(evidence: VerificationEvidenceSummary?, fingerprint: String?) -> (adapter: String?, capturedAt: Date?, repositoryIdentity: String?, commitFingerprint: String?, targetFingerprint: String?, diffFingerprint: String?, rulesScopeDetail: String?, staleReason: String?) {
        (VerificationEvidenceText.bounded(evidence?.adapter), evidence?.capturedAt, VerificationEvidenceText.bounded(evidence?.repositoryIdentity), VerificationEvidenceText.bounded(evidence?.commitFingerprint), VerificationEvidenceText.bounded(evidence?.targetFingerprint), VerificationEvidenceText.bounded(evidence?.diffFingerprint), VerificationEvidenceText.bounded(evidence?.rulesScopeDetail), VerificationEvidenceText.bounded(evidence?.staleReason))
    }
}

// MARK: - P5 Automation Health

enum AutomationHealthState: String, Equatable { case healthy, degraded, unknown, unavailable }
struct AutomationHealthPresentation: Identifiable, Equatable {
    let id: String
    let name: String
    let state: AutomationHealthState
    let detail: String
    let nextRun: String?

    static func make(job: CronSummary, runs: [CronRunSummary], capabilityAvailable: Bool, mcpErrorObserved: Bool) -> Self {
        guard capabilityAvailable else { return Self(id: job.id, name: job.name, state: .unavailable, detail: "Scheduling capability unavailable", nextRun: job.nextRun) }
        if mcpErrorObserved { return Self(id: job.id, name: job.name, state: .degraded, detail: "MCP health degraded", nextRun: job.nextRun) }
        let relevant = runs.filter { $0.jobID == job.id }
        guard let latest = relevant.first else { return Self(id: job.id, name: job.name, state: .unknown, detail: "No observed run history", nextRun: job.nextRun) }
        let failed = latest.status.localizedCaseInsensitiveContains("fail") || latest.error != nil
        if failed { return Self(id: job.id, name: job.name, state: .degraded, detail: latest.error ?? "Latest observed run failed", nextRun: job.nextRun) }
        guard job.enabled, job.nextRun != nil else { return Self(id: job.id, name: job.name, state: .unknown, detail: "Schedule is not fully known", nextRun: job.nextRun) }
        return Self(id: job.id, name: job.name, state: .healthy, detail: "Latest observed run succeeded", nextRun: job.nextRun)
    }
}

// MARK: - P6 Agent Operations

enum AgentOperationsState: String, Equatable {
    case running, pending, stalled, completed, failed, unknown, unverified

    var displayLabel: String {
        switch self {
        case .running: return "RUNNING"
        case .pending: return "PENDING"
        case .stalled: return "STALLED"
        case .completed: return "COMPLETED"
        case .failed: return "FAILED"
        case .unknown, .unverified: return "UNVERIFIED"
        }
    }
}
struct AgentOperationsRow: Identifiable, Equatable {
    let id: String
    let name: String
    let state: AgentOperationsState
    let model: String
    let latestActivity: String?
    let parentID: String?
}

enum AgentOperationsPresentation {
    static func rows(agents: [HermesSubagent], now: Date = .now, stallAfter: TimeInterval = 120) -> [AgentOperationsRow] {
        agents.map { agent in
            let normalized = agent.status.lowercased()
            let state: AgentOperationsState
            if ["completed", "complete", "done", "success", "succeeded"].contains(normalized) { state = .completed }
            else if ["failed", "error"].contains(normalized) { state = .failed }
            else if ["queued", "queue", "pending", "starting", "waiting"].contains(normalized) { state = .pending }
            else if ["running", "working", "active"].contains(normalized) {
                if let startedAt = agent.startedAt, now.timeIntervalSince(startedAt) > stallAfter, agent.latestActivity == nil { state = .stalled } else { state = .running }
            } else { state = .unverified }
            return AgentOperationsRow(id: agent.id, name: agent.name ?? agent.role ?? agent.id, state: state, model: agent.model ?? "unverified", latestActivity: agent.latestActivity, parentID: agent.parentID)
        }.sorted { $0.id < $1.id }
    }
}

// MARK: - P7 Provenance and capacity

struct ProvenancePresentation: Equatable {
    let sessionID: String?
    let projectID: String?
    let repositoryPath: String?
    let branch: String?
    let sourceLabel: String
    let verified: Bool
}

enum CapacityRunwayState: String, Equatable { case available, constrained, exhausted, unknown }
struct CapacityRunwayPresentation: Equatable {
    let state: CapacityRunwayState
    let usedPercent: Int?
    let detail: String

    static func make(usedPercent: Int?, hasQuotaData: Bool) -> Self {
        guard hasQuotaData, let usedPercent else { return Self(state: .unknown, usedPercent: nil, detail: "Capacity data unavailable") }
        if usedPercent >= 100 { return Self(state: .exhausted, usedPercent: usedPercent, detail: "Capacity exhausted") }
        if usedPercent >= 80 { return Self(state: .constrained, usedPercent: usedPercent, detail: "Capacity constrained") }
        return Self(state: .available, usedPercent: usedPercent, detail: "Capacity available")
    }
}
