import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    nonisolated static func safeUserDiagnostic(_ raw: String) -> String {
        HermesDiagnosticsService.safeSummary(raw)
    }

    /// Invalidate at the canonical array mutation boundary, not by hashing
    /// the entire history again on each scroll or live-tail layout update.
    var messageNavigatorSnapshot: MessageNavigatorSnapshot {
        let owner = sessionID ?? ""
        if !messageNavigatorNeedsRefresh, let cached = cachedMessageNavigatorItems, cached.sessionID == owner {
            return cached.snapshot
        }
        let items = MessageNavigator.items(
            messages: messages,
            earlierPrompts: unloadedTranscriptPrompts,
            sessionID: owner
        )
        // Metadata-only message edits must not invalidate navigator identity.
        let snapshot: MessageNavigatorSnapshot
        if let cached = cachedMessageNavigatorItems, cached.sessionID == owner, cached.snapshot.items == items {
            snapshot = cached.snapshot
        } else {
            snapshot = MessageNavigatorSnapshot(items: items)
        }
        cachedMessageNavigatorItems = (owner, snapshot)
        messageNavigatorNeedsRefresh = false
        return snapshot
    }

    var messageNavigatorItems: [MessageNavigatorItem] {
        messageNavigatorSnapshot.items
    }

    /// Compatibility accessor over the composer's draft so send, steering,
    /// clarification, and external writers (voice transcripts, quick prompts)
    /// read and clear the same text the composer edits.
    var draft: String {
        get { composer.text }
        set { composer.text = newValue }
    }

    struct RedirectingPrompt {
        let runtimeSessionID: String
        var completedTurns = 0
        var isQueuedByHermes = false
        var wasInterrupted = false
    }

    var hasQueuedOrRedirectingPrompt: Bool {
        !currentSessionQueuedPrompts.isEmpty
            || queuedPromptSessionID.map { redirectingPrompts[$0] != nil } == true
    }

    var currentSessionQueuedPrompts: [QueuedPrompt] {
        guard let queuedPromptSessionID else { return [] }
        return queuedPrompts.filter { $0.sessionID == queuedPromptSessionID }
    }

    /// Approval requests arrive on the shared gateway stream, including while
    /// another conversation is selected. Retain the latest unresolved request
    /// by Hermes session identity and project only the selected session here.
    /// This is intentionally process-local: Hermes remains the authority after
    /// a runtime restart, so stale approval payloads are never restored from disk.
    struct PendingApproval: Equatable {
        let title: String
        let detail: String
        let presentation: ApprovalPresentation
        let responseTarget: AttentionRequest?
        let serverRequestID: String?
    }

    struct PendingClarification: Equatable {
        let question: String
        let choices: [String]
        let requestID: String?
        var multiSelect = false
        /// Batch clarify: every question, and the answers Hermes has already locked.
        var batch: [ClarifyQuestion] = []
        var lockedAnswers: [String: String] = [:]
        var responseTarget: AttentionRequest? = nil

        var current: ClarifyQuestion? { batch.first { lockedAnswers[$0.id] == nil } }
        var remainingCount: Int { batch.filter { lockedAnswers[$0.id] == nil }.count }
        /// Choices live on the in-chat answer card, not in the transcript.
        var transcriptText: String { current?.question ?? question }
    }

    struct SessionAttention: Equatable {
        let status: HermesStatus
        let summary: String
        let requestID: String?
        /// Answers the notch can send without opening the chat; empty when it must open.
        var choices: [String] = []
        var responseTarget: AttentionRequest? = nil
    }

    func refreshSessionAttention() {
        var requests = pendingClarificationsBySessionID.mapValues {
            SessionAttention(
                status: .needsClarification, summary: String($0.transcriptText.prefix(180)), requestID: $0.requestID,
                choices: $0.batch.count > 1 || $0.multiSelect ? [] : $0.choices,
                responseTarget: $0.responseTarget)
        }
        for (id, approval) in pendingApprovalsBySessionID {
            let what = approval.detail.isEmpty ? approval.title : "\(approval.title): \(approval.detail)"
            requests[id] = SessionAttention(
                status: .needsApproval, summary: String(what.prefix(180)),
                requestID: approval.presentation.requestID,
                choices: [ApprovalChoice.once, ApprovalChoice.deny], responseTarget: approval.responseTarget)
        }
        let liveRequests = Set(requests.values.compactMap(\.responseTarget))
        let answers = attentionAnswers.filter { liveRequests.contains($0.key) }
        if answers != attentionAnswers { attentionAnswers = answers }
        if requests != sessionAttention { sessionAttention = requests }
    }

    var agentDisplayName: String {
        if let name = defaultBotName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let name = runtimeConfiguration?.agentName,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return name
        }
        return "Herm"
    }

    var workflowSession: HermesSession? {
        navigationSessionID.map {
            HermesSession(
                id: $0, profileID: sessionProfileID, title: currentSessionTitle ?? "Session", preview: "",
                startedAt: nil, messageCount: 0, source: HermesFeatureIDs.sessionSource)
        }
    }

    /// The rail subscribes only to fields it renders. Keeping this publisher
    /// separate from `objectWillChange` prevents transcript deltas and other
    /// workspace activity from invalidating the navigation projection.
    var sidebarPresentationChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            $sessionID.map { _ in () }.eraseToAnyPublisher(),
            $profileScopeID.map { _ in () }.eraseToAnyPublisher(),
            $runtimeConfiguration.map { _ in () }.eraseToAnyPublisher(),
            $status.map { _ in () }.eraseToAnyPublisher(),
            $isSending.map { _ in () }.eraseToAnyPublisher(),
            $sessions.map { _ in () }.eraseToAnyPublisher(),
            $sessionProjectionState.map { _ in () }.eraseToAnyPublisher(),
            $isLoadingSessions.map { _ in () }.eraseToAnyPublisher(),
            $deletingSessionID.map { _ in () }.eraseToAnyPublisher(),
            $renamingSessionID.map { _ in () }.eraseToAnyPublisher(),
            $updatingSessionVisibilityID.map { _ in () }.eraseToAnyPublisher(),
            $pinnedSessions.map { _ in () }.eraseToAnyPublisher(),
            $pinningSessionID.map { _ in () }.eraseToAnyPublisher(),
            $isCreatingSession.map { _ in () }.eraseToAnyPublisher(),
            $allBotSessionsState.map { _ in () }.eraseToAnyPublisher()
        ).eraseToAnyPublisher()
    }

    struct InFlightBotActivity: Equatable {
        let activityID: String
        let originSessionID: String
        let botID: String
        var botChatSessionID: String?
        var clarificationRequestID: String?
        var replyText = ""
        var submissionStarted = false
    }

    /// Every id the open chat answers to: runtime alias, stored row, and the
    /// id it was opened by.
    var currentSessionIDs: Set<String> {
        Set([sessionID, sessionStorageID, kanbanAttributionSessionID].compactMap { $0 })
    }

    /// Maps the open chat's runtime alias onto its stored row id.
    func rowSessionID(_ id: String) -> String {
        quickSessionOwners[id]?.sessionID
            ?? (id == sessionID ? (sessionStorageID ?? id) : storageIDsByRuntimeID[id] ?? id)
    }

    var kanbanSessionID: String? {
        Self.kanbanAttributionID(
            requestedSessionID: kanbanAttributionSessionID,
            runtimeID: sessionID,
            storageID: sessionStorageID
        )
    }

    /// Exact Kanban IDs observed in Hermes tool activity for this selected
    /// session. A worker can create a card without copying the originating
    /// session into the task row; the `kanban show <id>` command is still a
    /// definitive, session-scoped association and lets the UI recover it.
    var observedKanbanTaskIDs: [String] {
        let aliases = [sessionID, sessionStorageID, kanbanAttributionSessionID, kanbanSessionID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var ids = Set(aliases.flatMap { observedKanbanTaskIDsBySessionID[$0] ?? [] })
        // Exact references survive process restarts in the bounded activity
        // archive. They are identifiers only; prompts and tool results are
        // never needed to restore the session-to-card association.
        for alias in aliases {
            let references = botActivityBySessionID[alias, default: []].filter(\.isKanbanReference)
            // Older builds archived every ID a listing printed, all in the same
            // instant; a lone reference is the only exact one.
            let batchSizes = Dictionary(grouping: references) { Int($0.createdAt.timeIntervalSince1970) }.mapValues(
                \.count)
            ids.formUnion(
                references
                    .filter { batchSizes[Int($0.createdAt.timeIntervalSince1970)] == 1 }
                    .compactMap(\.linkedCardID)
                    // Older archives stored branch names like `t_ab12-plan-x`.
                    .compactMap { Self.kanbanCardReference(in: $0) }
            )
        }
        // `recentEvents` is the bounded, persisted activity history. Include
        // it so a completed terminal command observed before this view opens
        // can still recover its exact Kanban card after session restoration.
        let values =
            agentActivities.map(\.text)
            + activeToolCalls.map { $0.input + " " + $0.context }
            + recentEvents.map(\.detail)
        // These are truncated previews, so a cut-off listing can show one ID;
        // only a command naming its card counts.
        for value in values where value.localizedCaseInsensitiveContains("kanban") {
            ids.formUnion(Self.kanbanCommandReferences(in: value))
        }
        // Hermes notifies a chat only about cards it subscribed to, so a
        // notice in the transcript is an exact association too.
        ids.formUnion(messages.compactMap(\.kanbanNotice?.taskID))
        return ids.sorted()
    }

    var botActivitySessionIDs: [String?] {
        [sessionID, sessionStorageID, kanbanAttributionSessionID, kanbanSessionID]
    }

    /// Presentation-only union for the agent list and pipeline. Hermes'
    /// `delegation.status.active` owns liveness; cached agents are retained as
    /// completed history so a finished delegation remains inspectable without
    /// falsely animating as current work.
    var currentSessionBackgroundTasks: [HermesBackgroundTask] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        return backgroundTasks.filter { $0.parentSessionID == sessionID }
    }

    var displayedSubagents: [HermesSubagent] {
        let liveIDs = Set(activeSubagents.map(\.id))
        let historical =
            sessionAgents
            .filter { !liveIDs.contains($0.id) }
            .map { agent -> HermesSubagent in
                guard !Self.isTerminalAgentStatus(agent.status) else { return agent }
                var completed = agent
                completed.status = "complete"
                return completed
            }
        return activeSubagents + historical
    }

    var agentPresentationSnapshot: AgentPresentationSnapshot {
        let displayed = displayedSubagents
        let inputs = (displayed, agentActivities, activeToolCalls)
        if let cachedAgentSnapshot,
            let cachedAgentSnapshotInputs,
            cachedAgentSnapshotInputs.0 == inputs.0,
            cachedAgentSnapshotInputs.1 == inputs.1,
            cachedAgentSnapshotInputs.2 == inputs.2
        {
            return cachedAgentSnapshot
        }
        let pipeline = AgentActivityPresentation.pipeline(
            activities: agentActivities,
            toolCalls: activeToolCalls,
            subagents: displayed
        )
        var counts: [String: Int] = [:]
        for activity in agentActivities {
            if let agentID = activity.agentID { counts[agentID, default: 0] += 1 }
        }
        let snapshot = AgentPresentationSnapshot(
            displayedSubagents: displayed,
            pipeline: pipeline,
            activityCountsByAgentID: counts,
            activeAgentIDs: Set(
                activeSubagents.filter { AgentActivityPresentation.isActiveStatus($0.status) }.map(\.id)),
            revision: agentSnapshotRevision &+ 1
        )
        agentSnapshotRevision &+= 1
        cachedAgentSnapshotInputs = inputs
        cachedAgentSnapshot = snapshot
        return snapshot
    }
}
