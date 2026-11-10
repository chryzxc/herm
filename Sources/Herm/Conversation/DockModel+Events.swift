import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// The command center consumes the global Hermes stream, while the
    /// conversation handler below intentionally filters events to its active
    /// session. Own unread state at this shared boundary so attention from a
    /// different session cannot appear in Control without reaching the menu bar.
    func receiveGatewayEvent(_ type: String, params: [String: Any]) {
        guard acceptGatewayEvent(type: type, params: params) else { return }
        let noticePayload = params["payload"] as? [String: Any] ?? [:]
        if type == "message.complete" || type == "error",
            let owner = (params["session_id"] as? String) ?? (noticePayload["session_id"] as? String)
        {
            for (key, pending) in redirectingPrompts
            where key == rowSessionID(owner) || pending.runtimeSessionID == owner {
                var redirect = pending
                redirect.completedTurns += 1
                if interruptState == .requesting, currentSessionIDs.contains(owner) {
                    redirect.wasInterrupted = true
                }
                // Hermes owns one follow-up after the original turn.
                if redirect.isQueuedByHermes, redirect.completedTurns >= 2 || redirect.wasInterrupted {
                    redirectingPrompts.removeValue(forKey: key)
                } else {
                    redirectingPrompts[key] = redirect
                }
            }
        }
        let failed =
            type == "error" || type == "message.error"
            || (type == "message.complete" && (noticePayload["error"] as? String)?.isEmpty == false)
        if type == "message.start", let owner = params["session_id"] as? String {
            let reference = interruptionNotice(.information, owner: owner)
            interruptionCoordinator?.clearFailure(owner: reference.sourceID, profileID: reference.profileID)
        }
        if failed, let owner = params["session_id"] as? String {
            let identity =
                (params["seq"] as? NSNumber).map { "\(gatewayReplayEpoch ?? "legacy"):\($0.stringValue)" }
                ?? UUID().uuidString
            completionNoticeIDs[rowSessionID(owner)] = identity
            interruptionCoordinator?.recordFailure(interruptionNotice(.failure, owner: owner, eventID: identity))
        }
        if type == "message.complete", let owner = params["session_id"] as? String {
            let identity =
                (failed ? completionNoticeIDs[rowSessionID(owner)] : nil)
                ?? (params["seq"] as? NSNumber).map { "\(gatewayReplayEpoch ?? "legacy"):\($0.stringValue)" }
                ?? UUID().uuidString
            completionNoticeIDs[rowSessionID(owner)] = identity
            if completionNoticeIDs.count > 256 { completionNoticeIDs = [rowSessionID(owner): identity] }
            if !failed {
                _ = interruptionCoordinator?.admit(interruptionNotice(.completion, owner: owner), channel: .record)
            }
        }
        if let owner = params["session_id"] as? String, type == "message.start" || type == "message.complete" || failed
        {
            let origin = interruptionNotice(.information, owner: owner)
            let receipt = params["persisted_turn"] as? [String: Any]
            let completionRow =
                receipt?["complete"] as? Bool == true
                ? receipt.flatMap { TranscriptHistoryPaging.rowID($0, key: "final_assistant_row_id") } : nil
            DeveloperWorkflowModel.shared.observeTurnBaseline(
                origin: QuickDestination(profileID: origin.profileID, sessionID: origin.sourceID),
                started: type == "message.start", completed: type == "message.complete", failed: failed,
                completionRowID: completionRow)
        }
        captureObservedKanbanTaskIDs(type: type, params: params)
        eventRouter.route(type: type, params: params)
        reconcileDirectBotLifecycle(type: type, params: params)
        capturePendingApproval(type: type, params: params)
        capturePendingClarification(type: type, params: params)
        let eventPayload = params["payload"] as? [String: Any] ?? [:]
        let eventSessionID = (params["session_id"] as? String) ?? (eventPayload["session_id"] as? String)
        if type == "message.start" || type == "message.complete", let eventSessionID {
            let owner = interruptionNotice(.information, owner: eventSessionID)
            sessionTranscriptCache.remove(
                WorkspaceIdentity.session(profileID: owner.profileID, sessionID: rowSessionID(eventSessionID)))
        }
        if type == "approval.expire", let eventSessionID {
            let requestID = Self.nestedClarificationString(keys: ["request_id"], in: params)
            resolveApproval(for: eventSessionID, requestID: requestID)
        }
        if type == "message.start" || type == "message.complete" || type == "sessions.changed" {
            touchSession(
                sessionID: eventSessionID,
                at: dateValue(params["timestamp"]) ?? dateValue(eventPayload["timestamp"]) ?? Date())
        }
        if type == "message.start", let eventSessionID {
            updateSessionActivity(sessionID: eventSessionID, isWorking: true)
        }
        if let eventSessionID {
            updateSessionActivityLabel(sessionID: eventSessionID, type: type, payload: eventPayload)
        }
        // `sessions.changed` is a notification, not a new session snapshot.
        // Re-read the authoritative index after a turn completes so titles,
        // previews, and project membership in the left navigation are current.
        // Coalescing keeps a busy stream from issuing an index request for
        // every event.
        if type == "message.complete" || type == "sessions.changed" {
            refreshSessionIndexAfterActivity()
        }
        if type == "message.complete", !failed, let eventSessionID { nameSessionIfUntitled(eventSessionID) }
        if Self.isUnreadUpdateEvent(type) {
            markUnreadUpdate()
            if let eventSessionID {
                updateSessionActivity(sessionID: eventSessionID, isWorking: false, unread: eventSessionID != sessionID)
                // A reply that lands in the chat being watched is read as it arrives.
                if eventSessionID == sessionID, isPopoverVisible {
                    let rowID = rowSessionID(eventSessionID)
                    let profileID = sessions.first { $0.id == rowID }?.profileID ?? sessionProfileID ?? profileScopeID
                    SidebarSessionSeenStore.shared.markSeen(profileID: profileID, sessionID: rowID)
                }
            }
        }
        handleEvent(type, params: params)
        if type == "message.start" || type == "message.complete" || type == "error",
            let eventSessionID
        {
            let ownerID = rowSessionID(eventSessionID)
            let matchingOwners = sessionStopAttempts.keys.filter { $0.sessionID == ownerID }
            if matchingOwners.count == 1, let owner = matchingOwners.first,
                sessionStopAttempts[owner]?.outcome == .accepted
            {
                sessionStopAttempts[owner]?.tailPending = false
            }
        }
    }

    /// Hermes frequently clears completed terminal rows before the next
    /// session-Kanban polling pass. Capture an exact task ID at the gateway
    /// boundary, while the command/result still exists, so a task whose
    /// database row lacks `session_id` can remain visible to its owner.
    func captureObservedKanbanTaskIDs(type: String, params: [String: Any]) {
        guard
            type == "tool.call" || type == "tool.start" || type == "tool.use" || type == "tool_use"
                || type == "tool.result" || type == "tool_result" || type == "tool.complete" || type == "tool_complete",
            let currentSessionID = sessionID
        else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        let envelopeSessionID = params["session_id"] as? String
        let eventSessionID = envelopeSessionID ?? (payload["session_id"] as? String)
        guard
            Self.eventBelongsToSession(
                type: type,
                envelopeSessionID: envelopeSessionID,
                eventSessionID: eventSessionID,
                payload: payload,
                currentSessionID: currentSessionID,
                agents: sessionAgents + activeSubagents
            )
        else { return }

        let text = Self.eventText(payload)
        guard text.localizedCaseInsensitiveContains("kanban") else { return }
        guard let taskID = Self.kanbanCardReference(in: text) else { return }
        let taskIDs: Set<String> = [taskID]

        let aliases = [currentSessionID, sessionStorageID, kanbanAttributionSessionID, kanbanSessionID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for alias in aliases {
            let existing = observedKanbanTaskIDsBySessionID[alias, default: []]
            let merged = existing.union(taskIDs)
            if merged != existing {
                observedKanbanTaskIDsBySessionID[alias] = merged
            }
        }
        // Preserve the trusted card reference so a null `task.session_id`
        // remains recoverable after app restart. The hidden reference is not
        // presented as Bot work; `kanban show` remains the source of its
        // lifecycle, title, assignee, and heartbeat.
        let originSessionID = sessionStorageID ?? currentSessionID
        for taskID in taskIDs
        where !botActivityBySessionID[originSessionID, default: []].contains(where: {
            $0.isKanbanReference && $0.linkedCardID == taskID
        }) {
            insertBotActivity(
                BotActivityRecord(
                    id: "kanban-reference:\(originSessionID):\(taskID)",
                    originSessionID: originSessionID,
                    botID: "kanban-reference",
                    botName: "Hermes Kanban",
                    summary: "Exact Hermes card reference",
                    state: .queued,
                    linkedCardID: taskID
                ))
        }
        // Repeated references can carry status changes for an existing card.
        // Notify Activity for those as well as newly discovered IDs.
        observedKanbanTaskRevision &+= 1
        DebugLog.write("kanban: observed exact task reference in session activity")
    }

    /// Direct mentions bind to the recipient before submission; only that
    /// session's events may update their activity or supply the inline reply.
    func reconcileDirectBotLifecycle(type: String, params: [String: Any]) {
        let payload = params["payload"] as? [String: Any] ?? [:]
        let eventSessionID = (params["session_id"] as? String) ?? (payload["session_id"] as? String)
        guard let eventSessionID, !eventSessionID.isEmpty else { return }
        let mentions = inFlightBotActivities.values.filter {
            $0.submissionStarted && $0.botChatSessionID == eventSessionID
        }
        if !mentions.isEmpty, let step = Self.botMentionActivityTitle(type: type, payload: payload) {
            for activity in mentions {
                if botLiveSteps[activity.activityID] != step { botLiveSteps[activity.activityID] = step }
            }
        }
        switch type {
        case "approval.request":
            setInFlightBotActivityWaiting(for: eventSessionID)
        case "clarification.request", "clarify.request":
            let requestID = Self.nestedClarificationString(keys: ["request_id", "id"], in: params)
            setInFlightBotActivityWaiting(for: eventSessionID, requestID: requestID)
        case "clarify.expire", "clarification.expire":
            let requestID = Self.nestedClarificationString(keys: ["request_id", "id"], in: params)
            if let requestID {
                updateInFlightBotActivity(
                    for: requestID, state: .canceled, result: "This question expired before Hermes received an answer.")
            }
        case "message.start":
            setInFlightBotActivityWorking(for: eventSessionID)
        case "message.delta":
            for activity in Array(inFlightBotActivities.values) where activity.botChatSessionID == eventSessionID {
                inFlightBotActivities[activity.activityID]?.replyText +=
                    (payload["delta"] as? String) ?? (payload["text"] as? String) ?? ""
            }
        case "message.complete", "message.error", "error":
            let rawError =
                Self.messageCompletionError(from: payload)
                ?? (type == "message.complete" ? nil : Self.eventText(payload))
            let error = rawError.map(Self.safeUserDiagnostic)
            for activity in Array(inFlightBotActivities.values) where activity.botChatSessionID == eventSessionID {
                let completedText = Self.completedMessageText(from: payload).flatMap { $0.isEmpty ? nil : $0 }
                let reply = error ?? completedText ?? activity.replyText
                if currentSessionIDs.contains(activity.originSessionID), !currentSessionIDs.contains(eventSessionID),
                    !reply.isEmpty
                {
                    let name =
                        botActivityBySessionID[activity.originSessionID]?.first(where: { $0.id == activity.activityID }
                        )?.botName ?? activity.botID
                    messages.append(
                        ChatMessage(
                            role: .hermes, text: reply, isError: error != nil,
                            botProfileID: activity.botID, botDisplayName: name))
                }
                updateBotActivity(
                    id: activity.activityID, state: error == nil ? .completed : .failed,
                    result: reply.isEmpty ? nil : reply)
                inFlightBotActivities.removeValue(forKey: activity.activityID)
            }
            if !currentSessionIDs.contains(eventSessionID) { drainQueuedPromptIfIdle() }
        default:
            break
        }
    }

    /// Accept both current Hermes events (which carry `seq`) and older
    /// gateways (which do not). Replayed events use this same boundary so
    /// de-duplication and ownership remain centralized.
    func acceptGatewayEvent(type: String, params: [String: Any]) -> Bool {
        if type == "gateway.ready",
            let payload = params["payload"] as? [String: Any],
            let epoch = payload["replay_epoch"] as? String,
            !epoch.isEmpty,
            epoch != gatewayReplayEpoch
        {
            gatewayReplayEpoch = epoch
            processedGatewaySequencesBySessionID.removeAll()
            highestGatewaySequenceBySessionID.removeAll()
            sessionInfoSequencesBySessionID.removeAll()
            if sessionID != nil { refreshDelegationStatus() }
            return true
        }

        guard let sequence = (params["seq"] as? NSNumber)?.intValue ?? params["seq"] as? Int,
            let eventSessionID = (params["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !eventSessionID.isEmpty
        else {
            return true
        }

        var processed = processedGatewaySequencesBySessionID[eventSessionID, default: []]
        guard !processed.contains(sequence) else { return false }
        let previousHighest = highestGatewaySequenceBySessionID[eventSessionID] ?? 0
        processed.insert(sequence)
        if processed.count > 1024 {
            let floor = max(0, sequence - 512)
            processed = Set(processed.filter { $0 >= floor })
        }
        processedGatewaySequencesBySessionID[eventSessionID] = processed
        highestGatewaySequenceBySessionID[eventSessionID] = max(previousHighest, sequence)

        if previousHighest > 0, sequence > previousHighest + 1 {
            DebugLog.write("activity: gateway sequence gap detected")
            replayGatewayEvents(for: eventSessionID, after: previousHighest)
        }
        return true
    }

    func replayTrackedGatewayEvents() {
        gatewayReplayTask?.cancel()
        gatewayReplayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ids = Set(
                [
                    self.sessionID,
                    self.sessionStorageID,
                    self.kanbanAttributionSessionID,
                ].compactMap { $0 }.filter { !$0.isEmpty })
            for id in ids {
                guard !Task.isCancelled else { return }
                guard let last = self.highestGatewaySequenceBySessionID[id], last > 0 else { continue }
                self.replayGatewayEvents(for: id, after: last)
            }
        }
    }

    func replayGatewayEvents(for sessionID: String, after sequence: Int) {
        guard !gatewayReplayInFlight.contains(sessionID) else { return }
        gatewayReplayInFlight.insert(sessionID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.gatewayReplayInFlight.remove(sessionID) }
            do {
                let result = try await self.sessionRPCClient.request(
                    HermesFeatureIDs.ID.sessionEventsSince.rawValue,
                    params: ["session_id": sessionID, "last_seen": sequence]
                )
                if let epoch = result["epoch"] as? String, !epoch.isEmpty, epoch != self.gatewayReplayEpoch {
                    self.gatewayReplayEpoch = epoch
                    self.processedGatewaySequencesBySessionID.removeAll()
                    self.highestGatewaySequenceBySessionID.removeAll()
                    self.sessionInfoSequencesBySessionID.removeAll()
                }
                let frames = result["events"] as? [[String: Any]] ?? []
                for frame in frames.sorted(by: { lhs, rhs in
                    let left = (lhs["seq"] as? NSNumber)?.intValue ?? lhs["seq"] as? Int ?? 0
                    let right = (rhs["seq"] as? NSNumber)?.intValue ?? rhs["seq"] as? Int ?? 0
                    return left < right
                }) {
                    guard let type = frame["type"] as? String else { continue }
                    var replayed = frame
                    replayed["herm_trace_replayed"] = true
                    self.receiveGatewayEvent(type, params: replayed)
                }
                if (result["truncated"] as? Bool) == true {
                    self.refreshDelegationStatus()
                }
            } catch {
                DebugLog.write(
                    "activity: gateway replay unavailable: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    func capturePendingApproval(type: String, params: [String: Any]) {
        guard type == "approval.request" else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        guard
            let ownerSessionID = ((params["session_id"] as? String) ?? (payload["session_id"] as? String) ?? sessionID)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !ownerSessionID.isEmpty
        else { return }
        let approval = ApprovalPresentation.from(payload: payload)
        let pendingApproval = PendingApproval(
            title: approval.title,
            detail: approval.detail,
            presentation: approval,
            responseTarget: attentionTarget(sessionID: ownerSessionID, requestID: approval.requestID, params: params),
            serverRequestID: payload["server_request_id"] as? String
        )
        let aliases = pendingApprovalAliasesBySessionID[ownerSessionID] ?? [ownerSessionID]
        for alias in aliases {
            pendingApprovalsBySessionID[alias] = pendingApproval
        }
    }

    func restorePendingApproval(for sessionIDs: [String?]) {
        let identities =
            sessionIDs
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let approval = identities.compactMap({ pendingApprovalsBySessionID[$0] }).first else {
            approvalTitle = nil
            approvalText = nil
            approvalDetails = nil
            return
        }
        // A resume may reveal runtime and durable aliases for the same
        // conversation. Preserve that alias group so a response from another
        // surface clears the whole request even while this session is hidden.
        var aliases = Set(identities)
        for identity in identities {
            aliases.formUnion(pendingApprovalAliasesBySessionID[identity] ?? [])
        }
        for identity in aliases {
            pendingApprovalsBySessionID[identity] = approval
            pendingApprovalAliasesBySessionID[identity] = aliases
        }
        approvalTitle = approval.title
        approvalText = approval.detail
        approvalDetails = approval.presentation
        status = .needsApproval
    }

    @discardableResult
    func removePendingApproval(for sessionID: String) -> Set<String> {
        let aliases = pendingApprovalAliasesBySessionID[sessionID] ?? [sessionID]
        for alias in aliases {
            pendingApprovalsBySessionID.removeValue(forKey: alias)
            pendingApprovalAliasesBySessionID.removeValue(forKey: alias)
        }
        return aliases
    }

    func capturePendingClarification(type: String, params: [String: Any]) {
        guard
            type == "clarification.request" || type == "clarify.request"
                || type == "clarification.expire" || type == "clarify.expire"
        else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        guard
            let ownerSessionID = ((params["session_id"] as? String) ?? (payload["session_id"] as? String) ?? sessionID)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !ownerSessionID.isEmpty
        else { return }

        if type == "clarification.expire" || type == "clarify.expire" {
            let requestID = Self.nestedClarificationString(keys: ["request_id"], in: params)
            if let requestID { markClarificationResolved(requestID) }
            _ = removePendingClarification(for: ownerSessionID, requestID: requestID)
            return
        }

        var clarification = Self.pendingClarification(from: params)
        clarification.responseTarget = attentionTarget(
            sessionID: ownerSessionID, requestID: clarification.requestID, params: params)
        if let requestID = clarification.requestID,
            resolvedClarificationRequestIDs.contains(requestID)
        {
            return
        }
        let aliases = pendingClarificationAliasesBySessionID[ownerSessionID] ?? [ownerSessionID]
        for alias in aliases {
            pendingClarificationsBySessionID[alias] = clarification
        }
    }

    func restorePendingClarification(for sessionIDs: [String?]) {
        let identities =
            sessionIDs
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let clarification = identities.compactMap({ pendingClarificationsBySessionID[$0] }).first else {
            showClarification(nil)
            clarificationResponseError = nil
            return
        }
        var aliases = Set(identities)
        for identity in identities {
            aliases.formUnion(pendingClarificationAliasesBySessionID[identity] ?? [])
        }
        for identity in aliases {
            pendingClarificationsBySessionID[identity] = clarification
            pendingClarificationAliasesBySessionID[identity] = aliases
        }
        showClarification(clarification)
        clarificationResponseError = nil
        if messages.last?.role != .hermes || messages.last?.text != clarification.transcriptText {
            messages.append(ChatMessage(role: .hermes, text: clarification.transcriptText, modelName: currentModelName))
        }
        status = .needsClarification
    }

    @discardableResult
    func removePendingClarification(for sessionID: String, requestID: String? = nil) -> Set<String> {
        let aliases = pendingClarificationAliasesBySessionID[sessionID] ?? [sessionID]
        if let requestID,
            !aliases.compactMap({ pendingClarificationsBySessionID[$0]?.requestID }).contains(requestID)
        {
            return []
        }
        for alias in aliases {
            if requestID == nil || pendingClarificationsBySessionID[alias]?.requestID == requestID {
                pendingClarificationsBySessionID.removeValue(forKey: alias)
                pendingClarificationAliasesBySessionID.removeValue(forKey: alias)
            }
        }
        return aliases
    }

    func attentionTarget(sessionID: String, requestID: String?, params: [String: Any]) -> AttentionRequest? {
        guard let requestID, !requestID.isEmpty else { return nil }
        let payload = params["payload"] as? [String: Any] ?? [:]
        let profile =
            (params["profile"] as? String) ?? (payload["profile"] as? String) ?? quickSessionOwners[sessionID]?
            .profileID
            ?? sessions.first(where: { $0.id == sessionID })?.profileID
            ?? (currentSessionIDs.contains(sessionID) ? sessionProfileID ?? profileScopeID : nil)
        return AttentionRequest(sessionID: sessionID, profileID: profile, requestID: requestID)
    }

    static func pendingClarification(from params: [String: Any]) -> PendingClarification {
        let question =
            nestedClarificationString(keys: ["question", "prompt", "query"], in: params)
            ?? nestedClarificationString(keys: ["message", "description", "text", "detail"], in: params)
            ?? "Herm needs more information."
        let choices = nestedClarificationStrings(keys: ["choices", "options", "suggested_responses"], in: params)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let payload = params["payload"] as? [String: Any] ?? params
        return PendingClarification(
            question: question,
            choices: choices,
            requestID: nestedClarificationString(keys: ["request_id"], in: params),
            multiSelect: payload["multi_select"] as? Bool == true && !choices.isEmpty,
            batch: ClarifyQuestion.batch(from: payload),
            lockedAnswers: payload["answers"] as? [String: String] ?? [:]
        )
    }

    func showClarification(_ clarification: PendingClarification?) {
        activeClarification = clarification
        let current = clarification?.current
        clarificationQuestion = current?.question ?? clarification?.question
        // A batch question without its own choices falls back to the request's.
        clarificationChoices =
            current.map { $0.choices.isEmpty ? clarification?.choices ?? [] : $0.choices } ?? clarification?.choices
            ?? []
        clarificationMultiSelect =
            clarificationChoices.isEmpty ? false : current?.multiSelect ?? clarification?.multiSelect ?? false
        clarificationRequestID = clarification?.requestID
        if let clarification, let current, clarification.batch.count > 1,
            let index = clarification.batch.firstIndex(of: current)
        {
            clarificationProgress = "Question \(index + 1) of \(clarification.batch.count)"
        } else {
            clarificationProgress = nil
        }
    }

    func markClarificationResolved(_ requestID: String) {
        guard resolvedClarificationRequestIDs.insert(requestID).inserted else { return }
        resolvedClarificationRequestIDOrder.append(requestID)
        if resolvedClarificationRequestIDOrder.count > 256 {
            let expiredID = resolvedClarificationRequestIDOrder.removeFirst()
            resolvedClarificationRequestIDs.remove(expiredID)
        }
    }

    func handleEvent(_ type: String, params: [String: Any]) {
        let rawPayload = params["payload"] as? [String: Any] ?? [:]
        let envelopeSessionID = params["session_id"] as? String
        let payloadSessionID = rawPayload["session_id"] as? String
        let eventSessionID = envelopeSessionID ?? payloadSessionID
        if type == "message.reaction" {
            applyMessageReaction(payload: rawPayload, owner: eventSessionID)
            return
        }
        // Hermes uses one gateway stream for every session. Once a session is
        // selected, reject events that do not prove ownership by that session
        // before projecting activities, tool calls, or conversation state. The
        // previous code projected first and filtered later, which let a known
        // agent (or an event with a missing session ID) mutate the current
        // session before the later guard ran.
        guard let currentSessionID = sessionID,
            Self.eventBelongsToSession(
                type: type,
                envelopeSessionID: envelopeSessionID,
                eventSessionID: eventSessionID,
                payload: rawPayload,
                currentSessionID: currentSessionID,
                agents: sessionAgents + activeSubagents
            )
        else {
            if !Self.isHighFrequencyEvent(type) {
                DebugLog.write("model: ignoring event \(type) without current-session ownership")
            }
            return
        }
        // Hermes orders a stopped turn's terminal frame before the next turn's
        // `message.start`, so everything turn-shaped in between is its tail.
        if type == "message.start" {
            isDiscardingStoppedTurn = false
        } else if isDiscardingStoppedTurn, Self.isStoppedTurnTailEvent(type) {
            if type == "message.complete" || type == "error" { isDiscardingStoppedTurn = false }
            return
        }
        let activityProjection =
            Self.isHighFrequencyEvent(type)
            ? nil
            : Self.agentActivityProjection(
                type: type,
                params: params,
                currentSessionID: sessionID,
                agents: sessionAgents + activeSubagents
            )
        if let activityProjection {
            recordAgentActivity(activityProjection.kind, params: params, payload: activityProjection.payload)
            mergeAgentEvent(activityProjection.kind, payload: activityProjection.payload)
            cacheCurrentAgentState()
            if activityProjection.consumesParentEvent { return }
        }
        let payload = activityProjection?.payload ?? rawPayload
        let isRelevantSubagentEvent = activityProjection != nil && type.hasPrefix("subagent.")
        if let eventSessionID,
            !eventSessionID.isEmpty,
            let sessionID, sessionID != eventSessionID,
            !isRelevantSubagentEvent
        {
            if !Self.isHighFrequencyEvent(type) {
                DebugLog.write("model: ignoring event \(type) for other session \(eventSessionID)")
            }
            return
        }
        if !Self.isHighFrequencyEvent(type) { DebugLog.write("model: handling event \(type)") }
        if type == "message.start" {
            recentEvents.removeAll()
        }
        if !Self.isHighFrequencyEvent(type) {
            recordEvent(type, params: params)
        }
        // A turn that started before this session was attached (app relaunch,
        // reopening a busy session) never delivers its `message.start`. Its
        // first mid-turn event opens the live row so the transcript, status and
        // activity follow it like any other turn.
        if streamingMessageID == nil, Self.isMidTurnEvent(type) {
            activeToolCalls = []
            beginStreamingMessage()
            conversationActivityPhase = .responding
            isSending = true
            if status == .idle { status = .working }
        }
        switch type {
        case "session.control.update":
            applySessionControlEvent(payload, sessionID: currentSessionID)
        case "session.info":
            applyEffortSessionInfo(params, payload: payload, owner: eventSessionID)
        case "session.usage":
            guard let id = sessionID, let usage = payload["usage"] as? [String: Any] else { break }
            applyContextUsage(usage, sessionID: id)
        case "status.update":
            switch payload["kind"] as? String {
            case "compacting", "compressing":
                // Hermes re-tags any lifecycle line mentioning "compact"/"compress" as
                // `compacting`, including the stored compression-feasibility warning it
                // replays on a session's first turn. Only real progress lines count.
                let text = payload["text"] as? String ?? ""
                let isProgress = ["Compacting context", "Preflight compression", "— compacting ~"].contains {
                    text.contains($0)
                }
                guard payload["kind"] as? String == "compressing" || isProgress else { break }
                recordTurnCompaction(isComplete: false)
                compactingSessionID = sessionID
            case "compacted", "ready":
                if compactingSessionID != nil { recordTurnCompaction(isComplete: true) }
                compactingSessionID = nil
                refreshSessionTokenUsage()
            case "process":
                let text = payload["text"] as? String ?? ""
                completeBotDispatch(from: text)
                if let notices = Self.kanbanNotices(from: text) {
                    for notice in notices {
                        appendBelowLiveTurn(
                            ChatMessage(
                                role: .hermes, text: notice.body,
                                botProfileID: notice.profileID, botDisplayName: notice.displayName,
                                kanbanNotice: KanbanNotice(text: notice.body)))
                    }
                } else {
                    appendSystemEvent(.liveStatus(kind: "process"), text: text)
                }
            // Heartbeat pings fire every interval and carry no content.
            case "heartbeat", nil: break
            case let kind?:
                appendSystemEvent(.liveStatus(kind: kind), text: payload["text"] as? String ?? "")
            }
        case "notice":
            appendSystemEvent(SystemEvent(label: "Notice"), text: payload["message"] as? String ?? "")
        case "preview.open":
            // Hermes' desktop_preview tool: show the page in the Browser tab, or externally if that's off.
            guard params["herm_trace_replayed"] as? Bool != true, let raw = payload["url"] as? String,
                let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { break }
            if AgentBrowser.opensInHerm() { InAppBrowser.open(url) } else { ExternalOpen.open(url) }
        case "pane.reveal":
            // Hermes' focus_pane tool. Chat and sessions are already in view.
            guard params["herm_trace_replayed"] as? Bool != true,
                let section = SessionInspector.Section(agentTab: payload["pane"] as? String ?? "")
            else { break }
            NotificationCenter.default.post(name: .hermRevealInspector, object: section)
        case "notification.show":
            let level = payload["level"] as? String
            let event = SystemEvent(
                label: SystemEvent.humanized((payload["kind"] as? String) ?? level ?? "notification"),
                tone: level == "warning" || level == "error" ? .attention : .inactive)
            appendSystemEvent(event, text: payload["text"] as? String ?? "", key: payload["key"] as? String)
        case "message.interim":
            flushVoiceNarration()
            completeLiveReasoning()
            // Already-streamed commentary is in the live row; the rest would
            // otherwise only appear after a reload.
            if (payload["already_streamed"] as? Bool) != true,
                let text = payload["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                appendBelowLiveTurn(ChatMessage(role: .hermes, text: text))
            }
        case "background.complete", "btw.complete":
            let taskID = (payload["task_id"] as? String) ?? ""
            if slashSideTaskIDs.remove(taskID) != nil, let text = payload["text"] as? String {
                messages.append(ChatMessage(role: .hermes, text: text))
            }
            guard !taskID.isEmpty,
                let index = backgroundTasks.firstIndex(where: { $0.id == taskID })
            else { break }
            let wasCompleted = backgroundTasks[index].status == .completed
            backgroundTasks[index].status = .completed
            backgroundTasks[index].output = payload["text"] as? String
            backgroundTasks[index].completedAt = .now
            if !wasCompleted { announceVoiceBackgroundCompletion(backgroundTasks[index]) }
        case "voice.transcript":
            guard voiceState.isNativeConversationActive, !isVoiceMicMuted else { return }
            let transcript = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if (payload["stop_phrase"] as? Bool) == true {
                stopVoiceConversation()
                return
            }
            // A recorder tail cannot release a turn or cut off its speech.
            // A real barge-in first transfers ownership via voice.interrupted.
            guard !isSending, !nativeVoiceCapture.isAwaitingPlaybackDrain, voiceState != .paused else { return }
            nativeVoiceCapture.receivedTranscript(hasText: !transcript.isEmpty)
            if (payload["no_speech_limit"] as? Bool) == true {
                // Hermes gave up after consecutive silent captures. Re-arming
                // here looped forever (beeping) with a deaf or idle microphone.
                voiceState = .paused
                return
            }
            guard !transcript.isEmpty else {
                voiceState = .listening
                armNativeVoiceCapture()
                return
            }
            voiceTelemetry.receivedTranscript()
            submitNativeVoiceTranscript(transcript)
        case "voice.status":
            guard voiceState.isNativeConversationActive else { return }
            // The gateway's response boundary precedes the end of streamed
            // TTS. Ignore recorder status during that drain window: only the
            // playback-drain owner may reopen the ordinary capture path.
            guard !nativeVoiceCapture.isAwaitingPlaybackDrain, voiceState != .paused else { return }
            guard !isSending || isVoicePromptActive else { return }
            let state = payload["state"] as? String
            switch state {
            case "recording", "listening":
                voiceState = .listening
            case "transcribing":
                voiceState = .transcribing
            case "idle":
                voiceState = .listening
                if nativeVoiceCapture.receivedIdle() {
                    armNativeVoiceCapture()
                }
            default:
                voiceState = .thinking
            }
        case "voice.interrupted":
            guard voiceState == .thinking || voiceState == .speaking else { return }
            stopVoicePlayback()
            status = .idle
            isSending = false
            voiceTelemetry.markInterrupted()
            let interruptionGeneration = nativeVoiceCapture.beginInterruption()
            voiceState = .interrupted
            recoverNativeVoiceCaptureIfInterruptedTranscriptIsMissing(generation: interruptionGeneration)
        case "message.start":
            status = .working
            isSending = true
            if voiceState.isNativeConversationActive, !isVoicePromptActive, streamingMessageID == nil {
                stopVoicePlayback()
                nativeVoiceCapture.receivedTranscript(hasText: true)
                voiceState = .thinking
            }
            let model = (payload["model"] as? String) ?? (payload["model_name"] as? String)
            if let model {
                currentModelName = model
            }
            // Hermes may send `message.start` after its first resumed delta, or
            // repeat it while reconnecting. Until `message.complete` closes the
            // active stream, it belongs to the already-reserved assistant row.
            if streamingMessageID != nil {
                isAwaitingClarificationResume = false
            } else {
                beginStreamingMessage()
            }
            conversationActivityPhase = .responding
            streamingMessageIsVisionNotice = false
            reasoningState = nil
            reasoningFlushTask?.cancel()
            reasoningFlushTask = nil
            streamingReasoningBuffer = ""
            isShowingReasoning = false
            activeToolCalls = []
        case "message.delta":
            guard let delta = (payload["delta"] as? String) ?? (payload["text"] as? String), streamingMessageID != nil
            else { return }
            isAwaitingClarificationResume = false
            completeLiveReasoning()
            if streamingMessageIsVisionNotice { return }
            if voiceState.isNativeConversationActive {
                voiceTelemetry.receivedResponse()
            }
            streamingMessageBuffer.append(delta)
            streamingMessagePendingPresentationDelta.append(delta)
            scheduleStreamingMessageFlush()
            streamVoiceReply(delta)
        case "message.complete":
            isAwaitingClarificationResume = false
            let completedMessageIDForPin = streamingMessageID
            if let completedText = Self.completedMessageText(from: payload),
                !completedText.isEmpty
            {
                if streamingMessageID == nil {
                    beginStreamingMessage()
                }
                if !turnCommittedText.isEmpty, completedText.hasPrefix(turnCommittedText) {
                    streamingMessageBuffer = String(completedText.dropFirst(turnCommittedText.count))
                } else if turnCommittedText.isEmpty {
                    streamingMessageBuffer = completedText
                }
            }
            let voiceResponseText = turnCommittedText + streamingMessageBuffer
            var turnTokens: Int?
            compactingSessionID = nil
            if let id = sessionID, let usageDict = payload["usage"] as? [String: Any] {
                applyContextUsage(usageDict, sessionID: id)
            }
            if let id = sessionID, let usage = sessionTokenUsage, usage.sessionID == id {
                if let usageDict = payload["usage"] as? [String: Any],
                    case let total = ControlCenterModel.parseSessionUsage(usageDict).totalTokens, total > 0
                {
                    if total > usage.total { turnTokens = total - usage.total }
                    sessionTokenUsage = (id, total)
                } else {
                    let streamed = streamingMessageBuffer.utf8.count + streamingReasoningBuffer.utf8.count
                    sessionTokenUsage = (id, usage.total + Self.estimatedTokens(utf8Count: streamed))
                }
            }
            refreshSessionTokenUsage()
            let wasInterrupting = interruptState == .requesting
            interruptState = .idle
            if wasInterrupting { releaseStoppedTurnPrompts() }
            let completionError = Self.messageCompletionError(from: payload)
            if let error = completionError {
                discardStreamingMessage()
                let text = Self.safeUserDiagnostic(error)
                appendTerminalErrorMessage(text)
                updateInFlightBotActivity(for: eventSessionID, state: .failed, result: text)
                notify(
                    title: "Hermes could not complete the request", body: text,
                    identifier: "failure:\(sessionID ?? "hermes")")
            } else {
                commitStreamingMessage(tokenCount: turnTokens)
                applyMessagePinReceipt(
                    payload["persisted_turn"] as? [String: Any],
                    assistantMessageID: completedMessageIDForPin ?? messages.last?.id)
                Task { await refreshMessagePins() }
                let result = messages.last(where: { $0.role == .hermes })?.text
                updateInFlightBotActivity(
                    for: eventSessionID, state: wasInterrupting ? .canceled : .completed, result: result)
            }
            if wasInterrupting {
                updateInFlightBotActivity(for: eventSessionID, state: .canceled)
            }
            endLocalTurn(eventSessionID: eventSessionID)
            if completionNotificationsEnabled {
                let response =
                    messages.last(where: { $0.role == .hermes }).map(GenerativeUIIntegration.readableText)
                    ?? "Herm completed the active request."
                notify(title: "Herm completed work", body: response, identifier: "completed:\(sessionID ?? "hermes")")
            }
            if voiceState.isNativeConversationActive, completionError != nil, !wasInterrupting {
                stopVoicePlayback()
                skipNextVoicePlaybackDrain = false
                nativeVoiceCapture.reset()
                voiceState = .paused
            } else if voiceState.isNativeConversationActive, skipNextVoicePlaybackDrain || !voiceRepliesEnabled {
                skipNextVoicePlaybackDrain = false
                voiceTelemetry.completedResponse()
                resumeVoiceListening(force: true)
            } else if voiceState.isNativeConversationActive, voiceState != .preparing, voiceState != .paused {
                voiceTelemetry.completedResponse()
                finishStreamedVoiceReply(voiceResponseText)
            }
            if let sessionStorageID {
                cacheAgentState(for: sessionStorageID)
                Task { await agentStateWriter.flush() }
            }
            // A stopped turn keeps its queue; Enter on an empty composer sends it.
            if !wasInterrupting || sendQueuedPromptAfterInterrupt {
                if !isRedirectInFlight { sendQueuedPromptAfterInterrupt = false }
                drainQueuedPromptIfIdle()
            }
        case "approval.request":
            let approval = ApprovalPresentation.from(payload: payload)
            setInFlightBotActivityWaiting(for: eventSessionID)
            let isPresentingApproval = approvalText == nil
            approvalTitle = approval.title
            approvalText = approval.detail
            approvalDetails = approval
            status = .needsApproval
            if isPresentingApproval {
                playApprovalSound()
            }
            notify(
                title: approval.title, body: approval.detail, identifier: "approval:\(sessionID ?? "hermes")",
                approvalRequestID: approval.requestID)
        case "clarification.request", "clarify.request":
            // Hermes adapters have emitted clarification fields both inside
            // `payload` and alongside it in the event params. Prefer the
            // payload, but retain the top-level fields so the actual question
            // is not replaced by the generic fallback text.
            let clarification = Self.pendingClarification(from: params)
            let question = clarification.question
            let requestID = clarification.requestID
            if let requestID, resolvedClarificationRequestIDs.contains(requestID) {
                break
            }
            if let requestID, !requestID.isEmpty,
                !presentedClarificationRequestIDs.insert(requestID).inserted
            {
                // The gateway may replay a request after an answer has been
                // submitted. Its request ID already owns the transcript row.
                break
            }
            let messageText = clarification.transcriptText
            if messages.last?.role != .hermes || messages.last?.text != messageText {
                messages.append(ChatMessage(role: .hermes, text: messageText, modelName: currentModelName))
            }
            showClarification(clarification)
            clarificationResponseError = nil
            setInFlightBotActivityWaiting(for: eventSessionID, requestID: requestID)
            isSending = false
            status = .needsClarification
            conversationActivityPhase = .idle
            notify(
                title: "Herm needs clarification", body: question,
                identifier: "clarification:\(sessionID ?? "hermes")",
                replyRequestID: clarification.batch.count > 1 || clarification.multiSelect ? nil : requestID)
        case "prompt.request":
            guard let prompt = ValuePrompt.from(payload: payload) else { break }
            valuePrompt = prompt
            valuePromptError = nil
            notify(
                title: prompt.title, body: "Herm is waiting for your input.",
                identifier: "prompt:\(sessionID ?? "hermes")")
        case "prompt.expire":
            if payload["request_id"] as? String == valuePrompt?.requestID { valuePrompt = nil }
        case "clarify.expire", "clarification.expire":
            let expiredRequestID = Self.nestedClarificationString(keys: ["request_id"], in: params)
            guard expiredRequestID == nil || expiredRequestID == clarificationRequestID else { return }
            showClarification(nil)
            clarificationResponseError = "This question expired before Hermes received an answer."
            if let expiredRequestID {
                updateInFlightBotActivity(
                    for: expiredRequestID,
                    state: .canceled,
                    result: clarificationResponseError
                )
            } else {
                updateInFlightBotActivity(
                    for: eventSessionID,
                    state: .canceled,
                    result: clarificationResponseError
                )
            }
            isSending = false
            status = .idle
            conversationActivityPhase = .idle
            drainQueuedPromptIfIdle()
        case "error":
            commitStreamingMessage()
            // A turn stopped before its agent was ready ends with `error`, not
            // `message.complete`; that is the user's Stop, not a failure.
            let wasInterrupting = interruptState == .requesting
            interruptState = .idle
            if wasInterrupting { releaseStoppedTurnPrompts() }
            let raw = (payload["message"] as? String) ?? "Hermes reported an error."
            let text =
                Self.isVisionUnsupportedError(raw)
                ? Self.visionUnsupportedNotice
                : Self.safeUserDiagnostic(raw)
            if !wasInterrupting { appendTerminalErrorMessage(text) }
            status = .idle
            conversationActivityPhase = .idle
            streamingMessageID = nil
            streamingMessageSessionID = nil
            isSending = false
            if voiceState.isNativeConversationActive {
                stopVoicePlayback()
                skipNextVoicePlaybackDrain = false
                nativeVoiceCapture.reset()
                voiceState = wasInterrupting ? .listening : .paused
            }
            if wasInterrupting {
                updateInFlightBotActivity(for: eventSessionID, state: .canceled)
            } else {
                notify(title: "Hermes encountered an error", body: text, identifier: "failure:\(sessionID ?? "hermes")")
                updateInFlightBotActivity(for: eventSessionID, state: .failed, result: text)
            }
            // A stopped turn keeps its queue unless Send now asked for it.
            if !wasInterrupting || sendQueuedPromptAfterInterrupt {
                sendQueuedPromptAfterInterrupt = false
                drainQueuedPromptIfIdle()
            }
            if voiceState == .listening { armNativeVoiceCapture() }

        case "reasoning.start", "thinking":
            conversationActivityPhase = .thinking
            closeTurnThinking()
            reasoningState = ReasoningState(text: "", isComplete: false)
            isShowingReasoning = false
        case "reasoning.delta", "reasoning.available", "moa.reference", "moa.progress", "moa.phase":
            // Hermes never sends `reasoning.start`: the first delta opens the
            // block and the next tool call or reply text closes it.
            // `thinking.delta` is Hermes' wait/spinner notice, not reasoning.
            // MoA advisor output and fan-out progress share the block, as in Hermes Desktop.
            let delta =
                type.hasPrefix("moa.")
                ? Self.moaReasoningLine(type: type, payload: payload) ?? ""
                : (payload["delta"] as? String) ?? (payload["text"] as? String) ?? ""
            guard !delta.isEmpty else { return }
            if reasoningState?.isComplete != false {
                closeTurnThinking()
                streamingReasoningBuffer = ""
                reasoningState = ReasoningState(text: "", isComplete: false)
            } else if type == "reasoning.available", !streamingReasoningBuffer.isEmpty {
                // The end-of-call preview repeats reasoning already streamed.
                return
            }
            // Reasoning deltas arrive faster than any UI needs: publishing
            // reasoningState per delta re-rendered the whole popover at the
            // delta rate. Coalesce at the same cadence as message streaming.
            streamingReasoningBuffer += delta
            scheduleReasoningFlush()
            conversationActivityPhase = .thinking
        case "reasoning.complete", "thinking.stop", "thinking.complete":
            completeLiveReasoning()

        case "tool.call", "tool.start", "tool.use", "tool_use":
            flushVoiceNarration()
            completeLiveReasoning()
            let name =
                (payload["name"] as? String) ?? (payload["tool"] as? String) ?? (payload["tool_name"] as? String)
                ?? "unknown"
            let childSessionID =
                (payload["child_session_id"] as? String)
                ?? (params["child_session_id"] as? String)
            let eventAgentID = Self.agentID(
                explicitAgentID: (payload["subagent_id"] as? String)
                    ?? (params["subagent_id"] as? String)
                        ?? (payload["agent_id"] as? String)
                            ?? (params["agent_id"] as? String),
                eventSessionID: eventSessionID,
                childSessionID: childSessionID,
                goal: payload["goal"] as? String,
                taskIndex: (payload["task_index"] as? NSNumber)?.intValue,
                agents: sessionAgents + activeSubagents
            )
            let argsDict =
                (payload["arguments"] as? [String: Any])
                ?? (payload["input"] as? [String: Any])
                ?? (payload["args"] as? [String: Any])
                ?? Self.parseArgsDict(payload["args_text"])
                ?? [:]
            let input: String
            if let args = payload["arguments"] as? [String: Any] {
                input = args.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", ")
            } else if let args = payload["arguments"] as? String {
                input = args
            } else if let inputStr = payload["input"] as? [String: Any] {
                input = inputStr.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", ")
            } else if let inputString = payload["input"] as? String {
                input = inputString
            } else if let command = payload["command"] as? String {
                input = command
            } else {
                input = ""
            }
            let id =
                (payload["id"] as? String)
                ?? (payload["tool_id"] as? String)
                ?? (payload["tool_call_id"] as? String)
                ?? (payload["tool_use_id"] as? String)
                ?? (params["id"] as? String)
                ?? (params["tool_id"] as? String)
                ?? (params["tool_call_id"] as? String)
                ?? (params["tool_use_id"] as? String)
                ?? UUID().uuidString
            // A retried or duplicated tool.call event must not create a second
            // row with the same identity: ForEach diffing and the expand toggle
            // key on this id, and duplicates crash the activity list.
            guard !activeToolCalls.contains(where: { $0.id == id }) else { break }
            // Text streamed so far belongs above this call: close the row so
            // the call (and later text) renders below it, in timeline order.
            if streamingMessageID != nil, streamingMessageSessionID == sessionID,
                streamingMessageBuffer.contains(where: { !$0.isWhitespace })
            {
                splitLiveTurn()
            }
            activeToolCalls.append(
                ActiveToolCall(
                    id: id,
                    name: name,
                    input: Self.truncatedForPersistence(input),
                    context: payload["context"] as? String ?? "",
                    startedAt: dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date(),
                    result: nil,
                    isComplete: false,
                    agentID: eventAgentID,
                    parentAgentID: payload["parent_id"] as? String,
                    childSessionID: childSessionID,
                    args: Self.textArgs(argsDict),
                    traceTiming: (dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"])) != nil
                        ? .runtime : params["herm_trace_replayed"] as? Bool == true ? .unavailable : .observed
                ))
            if Self.isDelegationTool(name) {
                synthesizeSubagent(toolCallID: id, args: argsDict)
            }
            recordBotDispatch(toolCallID: id, toolName: name, args: argsDict)
        case "tool.result", "tool_result", "tool.complete", "tool_complete":
            let id =
                (payload["id"] as? String)
                ?? (payload["tool_id"] as? String)
                ?? (payload["tool_call_id"] as? String)
                ?? (payload["tool_use_id"] as? String)
                ?? (params["id"] as? String)
                ?? (params["tool_id"] as? String)
                ?? (params["tool_call_id"] as? String)
                ?? (params["tool_use_id"] as? String)
                ?? ""
            let result = Self.eventText(payload["result"] ?? payload["output"])
            let diffPreview = Self.diffPreview(from: payload)
            if Self.isVisionUnsupportedError(result) {
                activeToolCalls.removeAll { $0.name.lowercased().contains("vision") }
            } else if let index = activeToolCalls.firstIndex(where: { $0.id == id }) {
                if HermesSimulatorPreference.isEnabled(), !activeToolCalls[index].isComplete,
                    params["herm_trace_replayed"] as? Bool != true, eventSessionID == currentSessionID,
                    let receipt = SessionSimulatorLaunch.receipt(
                        tool: activeToolCalls[index].name, result: result,
                        isError: payload["is_error"] as? Bool == true, localHost: ProcessInfo.processInfo.hostName)
                {
                    SessionSimulatorLaunchStore.shared.present(
                        receipt, session: WorkspaceIdentity.session(self), callID: id)
                }
                if activeToolCalls[index].name == "herm_inspector", !activeToolCalls[index].isComplete,
                    params["herm_trace_replayed"] as? Bool != true, eventSessionID == currentSessionID,
                    payload["is_error"] as? Bool != true, let section = SessionInspector.Section.receipt(result)
                {
                    NotificationCenter.default.post(name: .hermRevealInspector, object: section)
                }
                let wasDelegation = Self.isDelegationTool(activeToolCalls[index].name)
                if wasDelegation, let args = payload["args"] as? [String: Any] {
                    refreshSynthesizedSubagents(toolCallID: id, args: args)
                }
                var call = activeToolCalls[index]
                call.result = result.isEmpty ? nil : Self.truncatedForPersistence(result)
                call.app = MCPApp.receiptID(tool: call.name, result: result)
                call.isComplete = true
                call.completedAt =
                    dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date()
                call.traceDuration = SessionTraceProjection.measuredDuration(payload["duration_s"])
                call.traceOutcome = SessionTraceProjection.outcome(
                    payload["result"] ?? payload["output"])
                if params["herm_trace_replayed"] as? Bool == true && dateValue(params["timestamp"]) == nil
                    && dateValue(payload["timestamp"]) == nil
                {
                    call.traceTiming = .unavailable
                }
                call.diffPreview = diffPreview
                if call.args == nil {
                    call.args = Self.textArgs(Self.parseArgsDict(payload["args"]))
                }
                activeToolCalls[index] = call
                if wasDelegation { completeSynthesizedSubagent(toolCallID: id, result: result, payload: payload) }
                bindBotDispatch(toolCallID: id, result: result)
            } else if !activeToolCalls.isEmpty, let last = activeToolCalls.lastIndex(where: { !$0.isComplete }) {
                let wasDelegation = Self.isDelegationTool(activeToolCalls[last].name)
                if wasDelegation, let args = payload["args"] as? [String: Any] {
                    refreshSynthesizedSubagents(toolCallID: activeToolCalls[last].id, args: args)
                }
                var call = activeToolCalls[last]
                call.result = result.isEmpty ? nil : Self.truncatedForPersistence(result)
                call.app = MCPApp.receiptID(tool: call.name, result: result)
                call.isComplete = true
                call.completedAt =
                    dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date()
                // The legacy completion fallback does not prove trace ownership.
                call.traceTiming = .unavailable
                call.diffPreview = diffPreview
                if call.args == nil {
                    call.args = Self.textArgs(Self.parseArgsDict(payload["args"]))
                }
                activeToolCalls[last] = call
                if wasDelegation {
                    completeSynthesizedSubagent(toolCallID: activeToolCalls[last].id, result: result, payload: payload)
                }
                bindBotDispatch(toolCallID: activeToolCalls[last].id, result: result)
            }
            if let todos = payload["todos"] as? [[String: Any]], let sessionID {
                applyTodos(todos, sessionID: sessionID, revision: payload["revision"] as? Int ?? 0)
            }
        case "todo.updated":
            if let todos = payload["todos"] as? [[String: Any]], let sessionID {
                applyTodos(todos, sessionID: sessionID, revision: payload["revision"] as? Int ?? 0)
            }

        default:
            DebugLog.write("model: unknown event type: \(type) params: \(params.keys.sorted().joined(separator: ", "))")
            break
        }
        if type == "sessions.changed" || type.hasPrefix("tool.") || type.hasPrefix("subagent.")
            || type == "message.start" || type == "message.complete"
        {
            refreshDelegationStatus()
            cacheCurrentAgentState()
        }
    }

    func appendTerminalErrorMessage(_ text: String) {
        guard !didAppendTerminalErrorForCurrentTurn else { return }
        didAppendTerminalErrorForCurrentTurn = true
        messages.append(
            ChatMessage(
                role: .hermes,
                text: text,
                modelName: currentModelName,
                isError: true
            ))
    }

    static func completedMessageText(from payload: [String: Any]) -> String? {
        if let text = payload["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let message = payload["message"] as? [String: Any] {
            return completedMessageText(from: message)
        }
        if let content = payload["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func beginStreamingMessage() {
        didAppendTerminalErrorForCurrentTurn = false
        let now = Date()
        var responseStartedAt = now
        if let sessionID {
            responseStartedAt = turnStartedAtBySession[sessionID] ?? now
            turnStartedAtBySession[sessionID] = responseStartedAt
        }
        messages.append(ChatMessage(role: .hermes, text: "", timestamp: now, modelName: currentModelName))
        streamingMessageID = messages.last?.id
        streamingMessageSessionID = sessionID
        streamingResponseStartedAt = responseStartedAt
        streamingMessageBuffer = ""
        streamingMessagePendingPresentationDelta = ""
        streamingMessagePublishedText = ""
        streamingTurnActivity = []
        splitOffCallIDs = []
        turnCommittedText = ""
        streamingText.clearPresentation()
        // A pending flush of the previous row would exit on the generation
        // check without clearing itself, latching every later flush off.
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        streamingMessageGeneration &+= 1
    }

    /// Appends a mid-turn row in time order: the live turn is split around it,
    /// so what already ran stays above and later activity lands below. Calls
    /// still running move to the new live row so their completion updates them.
    /// Places board-derived kanban notices by time, once each. Events older
    /// than the loaded history stay out so they do not pile up at the top.
    func insertKanbanBoardNotices(_ notices: [(key: String, profileID: String?, text: String, date: Date)]) {
        var known = Set(messages.compactMap(\.kanbanNotice?.eventKey))
        insertTimelineMessages(
            notices.compactMap { item in
                guard known.insert(item.key).inserted, var notice = KanbanNotice(text: item.text) else { return nil }
                notice.eventKey = item.key
                return ChatMessage(
                    role: .hermes, text: item.text, timestamp: item.date,
                    botProfileID: item.profileID ?? "kanban",
                    botDisplayName: item.profileID == nil ? "Kanban" : nil, kanbanNotice: notice)
            })
    }

    /// Places messages from outside the live stream (board events, pipeline
    /// feeds) at their timestamps, once each. Ones older than the loaded
    /// history are left for the sync that follows paging.
    func insertTimelineMessages(_ items: [ChatMessage]) {
        guard let floor = messages.first?.timestamp else { return }
        for message in items.sorted(by: { $0.timestamp < $1.timestamp }) where message.timestamp >= floor {
            guard !messages.contains(where: { $0.timestamp == message.timestamp && $0.text == message.text }) else {
                continue
            }
            if let index = messages.firstIndex(where: { $0.timestamp > message.timestamp }) {
                messages.insert(message, at: index)
            } else {
                appendBelowLiveTurn(message)
            }
        }
    }

    /// Hermes injects notes (task list, still-in-progress, compaction) into
    /// stored history without emitting live events, so a turn's live view
    /// lacked rows a reload shows. After each turn, pull the newest stored
    /// rows and place the system rows the live stream missed.
    func syncStoredSystemRows() {
        guard let storageID = sessionStorageID else { return }
        let generation = sessionResumeGeneration
        let profileID = sessionProfileID ?? profileScopeID
        Task { @MainActor in
            guard
                let loaded = try? await fetchEarlierTranscriptRows(
                    from: TranscriptHistoryCursor(storageSessionID: storageID, profileID: profileID),
                    limit: TranscriptHistoryPaging.pageRowLimit, minimumDisplayRows: 1, maximumPages: 1
                ), generation == sessionResumeGeneration, sessionStorageID == storageID
            else { return }
            insertTimelineMessages(
                Self.parseMessages(loaded.rows).messages.filter {
                    $0.systemEvent != nil && $0.systemEvent?.isFeed == false
                })
        }
    }

    func appendSystemEvent(_ event: SystemEvent, text: String, key: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = ChatMessage(role: .hermes, text: text, systemEvent: event)
        if let key, let id = systemEventMessageIDs[key], let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = ChatMessage(
                id: id, role: .hermes, text: text, timestamp: messages[index].timestamp, systemEvent: event)
            return
        }
        // A repeated status line (retries) doesn't stack identical cards.
        guard !messages.suffix(2).contains(where: { $0.systemEvent == event && $0.text == text }) else { return }
        if let key { systemEventMessageIDs[key] = message.id }
        // Above the live reply rather than splitting it: a split remounts the
        // streaming row and jolts the transcript mid-turn.
        if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages.insert(message, at: index)
        } else {
            messages.append(message)
        }
    }

    func appendBelowLiveTurn(_ message: ChatMessage) {
        guard let id = streamingMessageID, streamingMessageSessionID == sessionID,
            let index = messages.firstIndex(where: { $0.id == id })
        else {
            messages.append(message)
            return
        }
        if streamingMessageBuffer.isEmpty, streamingTurnActivity.isEmpty {
            messages.insert(message, at: index)
            return
        }
        splitLiveTurn { messages.append(message) }
    }

    /// Commits the live row (text above, its activity), runs `between`, and
    /// opens a fresh live row so later text and tool calls land below.
    func splitLiveTurn(between: () -> Void = {}) {
        let startedAt = streamingResponseStartedAt
        let running = streamingTurnActivity.filter { !$0.isComplete }
        streamingTurnActivity.removeAll { !$0.isComplete }
        let splitOff = splitOffCallIDs.union(streamingTurnActivity.map(\.id))
        let committed = turnCommittedText + streamingMessageBuffer
        commitStreamingMessage()
        between()
        beginStreamingMessage()
        turnCommittedText = committed
        streamingTurnActivity = running
        splitOffCallIDs = splitOff
        streamingResponseStartedAt = startedAt
    }

    /// Reopens the live row of a turn Hermes reports still running on resume,
    /// seeded with what it already streamed, so the turn's remaining deltas
    /// and tool events land in it instead of being dropped.
    func adoptRunningTurn(inflight: [String: Any]?, activity: [ActiveToolCall]) {
        // The running turn's prompt may not be in stored history yet.
        let prompt = (inflight?["user"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty, messages.last(where: { $0.role == .user })?.text != prompt {
            messages.append(ChatMessage(role: .user, text: prompt))
        }
        beginStreamingMessage()
        streamingTurnActivity = activity
        if let streamed = inflight?["assistant"] as? String, !streamed.isEmpty {
            streamingMessageBuffer = streamed
            streamingMessagePendingPresentationDelta = streamed
            scheduleStreamingMessageFlush()
        }
        conversationActivityPhase = .responding
        isSending = true
        status = .working
        if let sessionStorageID { updateSessionActivity(sessionID: sessionStorageID, isWorking: true) }
    }

    /// Thinking segments share the turn log with tool calls so they keep
    /// their place in the sequence; the text rides in `result`.
    func recordTurnThinking(_ state: ReasoningState) {
        guard streamingMessageID != nil else { return }
        if let index = streamingTurnActivity.lastIndex(where: { $0.name == ActiveToolCall.thinkingName }),
            !streamingTurnActivity[index].isComplete
        {
            // Live text goes to the open thought row only; writing it into the
            // step broke TurnActivityView's equality on every reasoning flush.
            if state.isComplete {
                streamingTurnActivity[index].result = state.text
                closeTurnThinking()
            }
        } else if !state.isComplete || !state.text.isEmpty {
            streamingTurnActivity.append(
                ActiveToolCall(
                    id: "thinking:\(UUID().uuidString)",
                    name: ActiveToolCall.thinkingName,
                    input: "",
                    context: "",
                    startedAt: Date(),
                    result: state.text,
                    isComplete: state.isComplete,
                    completedAt: state.isComplete ? Date() : nil,
                    // Herm watches this segment arrive, so its clock times it.
                    traceTiming: .observed
                ))
        }
        liveReasoning.text = state.text
    }

    /// Compaction rides in the turn log like thinking, so the transcript shows
    /// it live and keeps a "Compacted context" step once Hermes finishes.
    func recordTurnCompaction(isComplete: Bool) {
        guard streamingMessageID != nil else { return }
        if let index = streamingTurnActivity.lastIndex(where: { $0.name == ActiveToolCall.compactionName }),
            !streamingTurnActivity[index].isComplete
        {
            guard isComplete else { return }
            streamingTurnActivity[index].isComplete = true
            streamingTurnActivity[index].completedAt = Date()
        } else if !isComplete {
            streamingTurnActivity.append(
                ActiveToolCall(
                    id: "compaction:\(UUID().uuidString)",
                    name: ActiveToolCall.compactionName,
                    input: "",
                    context: "",
                    startedAt: Date(),
                    isComplete: false,
                    traceTiming: .observed
                ))
        }
    }

    /// Settles the open reasoning block so the step reads "Thought for …".
    func completeLiveReasoning() {
        guard var state = reasoningState, !state.isComplete else { return }
        reasoningFlushTask?.cancel()
        reasoningFlushTask = nil
        state.text = streamingReasoningBuffer
        streamingReasoningBuffer = ""
        state.isComplete = true
        reasoningState = state
        conversationActivityPhase = .responding
    }

    func closeTurnThinking() {
        for index in streamingTurnActivity.indices
        where streamingTurnActivity[index].name == ActiveToolCall.thinkingName
            && !streamingTurnActivity[index].isComplete
        {
            let text = streamingReasoningBuffer.isEmpty ? liveReasoning.text : streamingReasoningBuffer
            if !text.isEmpty { streamingTurnActivity[index].result = text }
            streamingTurnActivity[index].isComplete = true
            streamingTurnActivity[index].completedAt = Date()
        }
    }

    static func upsert(_ calls: [ActiveToolCall], into log: inout [ActiveToolCall]) {
        var indices: [String: Int] = [:]
        for (index, call) in log.enumerated() where indices[call.id] == nil {
            indices[call.id] = index
        }
        for call in calls {
            if let index = indices[call.id] {
                log[index] = call
            } else {
                indices[call.id] = log.count
                log.append(call)
            }
        }
    }

    func removePendingClarificationResumeMessage() {
        guard let streamingMessageID,
            let index = messages.firstIndex(where: { $0.id == streamingMessageID }),
            messages[index].role == .hermes,
            messages[index].text.isEmpty
        else { return }
        messages.remove(at: index)
        self.streamingMessageID = nil
        streamingMessageSessionID = nil
        streamingResponseStartedAt = nil
        streamingMessageBuffer = ""
        streamingMessagePendingPresentationDelta = ""
        streamingMessagePublishedText = ""
        streamingText.clearPresentation()
        isAwaitingClarificationResume = false
    }

    func discardStreamingMessage() {
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        if let id = streamingMessageID,
            let index = messages.firstIndex(where: { $0.id == id })
        {
            messages.remove(at: index)
        }
        streamingMessageID = nil
        streamingMessageSessionID = nil
        streamingResponseStartedAt = nil
        streamingMessageBuffer = ""
        streamingMessagePendingPresentationDelta = ""
        streamingMessagePublishedText = ""
        streamingText.clearPresentation()
        streamingMessageGeneration &+= 1
    }

    /// Completion failures are reported by Hermes inside the completion
    /// envelope, rather than as a separate `error` event. Accept both the
    /// plain string form and the structured error form used by the gateway.
    static func messageCompletionError(from payload: [String: Any]) -> String? {
        guard let rawError = payload["error"] else { return nil }
        if let message = rawError as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : message
        }
        if let message = nestedClarificationString(keys: ["message", "detail", "description"], in: rawError) {
            return message
        }
        let serialized = eventText(rawError)
        return serialized.isEmpty ? "Hermes reported an error while completing the request." : serialized
    }

    static func nestedClarificationString(keys: [String], in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let string = dictionary[key] as? String,
                    !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return string
                }
            }
            for child in dictionary.values {
                if let result = nestedClarificationString(keys: keys, in: child) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = nestedClarificationString(keys: keys, in: child) { return result }
            }
        } else if let string = value as? String,
            let data = string.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data)
        {
            return nestedClarificationString(keys: keys, in: decoded)
        }
        return nil
    }

    static func nestedClarificationStrings(keys: [String], in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let strings = dictionary[key] as? [String] { return strings }
                if let values = dictionary[key] as? [Any] {
                    let strings = values.compactMap { $0 as? String }
                    if !strings.isEmpty { return strings }
                }
            }
            for child in dictionary.values {
                let result = nestedClarificationStrings(keys: keys, in: child)
                if !result.isEmpty { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                let result = nestedClarificationStrings(keys: keys, in: child)
                if !result.isEmpty { return result }
            }
        } else if let string = value as? String,
            let data = string.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data)
        {
            return nestedClarificationStrings(keys: keys, in: decoded)
        }
        return []
    }

    static func isHighFrequencyEvent(_ type: String) -> Bool {
        HermesHighFrequencyEvent.includes(type)
    }

    /// Events only a running turn emits, so seeing one proves a turn is live.
    static func isStoppedTurnTailEvent(_ type: String) -> Bool {
        type == "error" || type.hasPrefix("message.") || type.hasPrefix("tool.") || type.hasPrefix("tool_")
            || type.hasPrefix("reasoning.") || type.hasPrefix("thinking")
    }

    /// Ends the turn Hermes acknowledged as stopped; streamed output stays.
    func settleStoppedTurn() {
        interruptState = .idle
        isDiscardingStoppedTurn = true
        // Hermes purged its server queue, so a redirect it queued will not run.
        if let owner = sessionID {
            for (key, pending) in redirectingPrompts
            where key == rowSessionID(owner) || pending.runtimeSessionID == owner {
                var redirect = pending
                redirect.wasInterrupted = true
                redirectingPrompts[key] = redirect.isQueuedByHermes ? nil : redirect
            }
        }
        releaseStoppedTurnPrompts()
        compactingSessionID = nil
        commitStreamingMessage()
        updateInFlightBotActivity(for: sessionID, state: .canceled)
        endLocalTurn(eventSessionID: sessionID)
        if voiceState.isNativeConversationActive {
            skipNextVoicePlaybackDrain = false
            resumeVoiceListening(force: true)
        }
        if let sessionStorageID { cacheAgentState(for: sessionStorageID) }
        // A stopped turn keeps its queue; Send now (or Enter on an empty composer) sends it.
        // An in-flight redirect blocks the drain; its reply sends it instead.
        if sendQueuedPromptAfterInterrupt, !isRedirectInFlight {
            sendQueuedPromptAfterInterrupt = false
            drainQueuedPromptIfIdle()
        }
    }

    func releaseStoppedTurnPrompts() {
        let activeSessionIDs = Set([sessionID, sessionStorageID, kanbanAttributionSessionID].compactMap { $0 })
        if let clarificationRequestID {
            markClarificationResolved(clarificationRequestID)
        }
        for activeSessionID in activeSessionIDs {
            _ = removePendingApproval(for: activeSessionID)
            _ = removePendingClarification(for: activeSessionID)
        }
        approvalTitle = nil
        approvalText = nil
        approvalDetails = nil
        showClarification(nil)
        clarificationResponseError = nil
        steeringError = nil
    }

    func endLocalTurn(eventSessionID: String?) {
        // A few Hermes adapters omit the final tool-result identifier. The
        // response boundary is authoritative, so do not leave those calls
        // displayed as running after the assistant has completed.
        for index in activeToolCalls.indices where !activeToolCalls[index].isComplete {
            activeToolCalls[index].isComplete = true
            activeToolCalls[index].completedAt = Date()
        }
        status = .idle
        conversationActivityPhase = .idle
        isSending = false
        streamingMessageID = nil
        streamingTurnActivity = []
        streamingResponseStartedAt = nil
        turnStartedAtBySession[eventSessionID ?? sessionID ?? ""] = nil
        syncStoredSystemRows()
    }

    static func isMidTurnEvent(_ type: String) -> Bool {
        switch type {
        case "tool.call", "tool.start", "tool.use", "tool_use",
            "reasoning.start", "reasoning.delta", "reasoning.available", "thinking", "thinking.delta",
            "moa.reference", "moa.progress", "moa.phase":
            true
        default:
            false
        }
    }

    /// One reasoning line per Mixture of Agents event; nil when the payload
    /// carries nothing to show.
    nonisolated static func moaReasoningLine(type: String, payload: [String: Any]) -> String? {
        let label = (payload["label"] as? String) ?? ""
        switch type {
        case "moa.reference":
            guard let text = payload["text"] as? String, !text.isEmpty else { return nil }
            return "◇ \(label.isEmpty ? "Reference" : label)\n\(text)\n"
        case "moa.progress":
            guard let done = (payload["refs_done"] as? NSNumber)?.intValue,
                let total = (payload["refs_total"] as? NSNumber)?.intValue
            else { return nil }
            return label.isEmpty ? "◇ MoA refs \(done)/\(total)\n" : "◇ MoA refs \(done)/\(total) — \(label)\n"
        case "moa.phase":
            return payload["phase"] as? String == "aggregator" ? "◇ MoA aggregating…\n" : nil
        default:
            return nil
        }
    }

    func scheduleActivityPresentation() {
        guard activityPresentationTask == nil else { return }
        activityPresentationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.activityPresentationTask = nil
            self.activityPresentationRevision &+= 1
        }
    }

    func scheduleStreamingMessageFlush() {
        guard streamingMessageFlushTask == nil else { return }
        let generation = streamingMessageGeneration
        streamingMessageFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Limit live layout invalidation to a comfortable cadence. As a
            // response grows, wrapping its entire live Text becomes more
            // expensive, so the presentation cadence backs off while the
            // transport buffer remains lossless.
            let interval =
                ConversationStreamingPresentationPolicy
                .flushIntervalMilliseconds(textLength: self.streamingMessageBuffer.utf8.count)
            try? await Task.sleep(for: .milliseconds(interval))
            guard !Task.isCancelled, self.streamingMessageGeneration == generation else { return }
            self.streamingMessageFlushTask = nil
            self.flushStreamingMessage()
        }
    }

    func scheduleReasoningFlush() {
        guard reasoningFlushTask == nil else { return }
        reasoningFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.reasoningFlushTask = nil
            guard var state = self.reasoningState else { return }
            state.text = self.streamingReasoningBuffer
            self.reasoningState = state
        }
    }

    func flushStreamingMessage() {
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        guard streamingMessageID != nil,
            streamingMessageSessionID == sessionID,
            let newText = pendingStreamingText()
        else { return }
        // Only the delta is new; the published tail catches a phrase split
        // across flushes. Commit re-checks the whole buffer.
        applyVisionNoticeDetectionIfNeeded(
            to: String(streamingMessagePublishedText.suffix(Self.visionUnsupportedPhrase.count - 1))
                + streamingMessagePendingPresentationDelta)
        let publishedText = streamingMessageIsVisionNotice ? Self.visionUnsupportedNotice : newText
        if streamingMessageIsVisionNotice {
            streamingText.replacePresentation(with: publishedText)
        } else {
            let delta = streamingMessagePendingPresentationDelta
            streamingMessagePendingPresentationDelta = ""
            streamingText.appendPresentation(delta)
        }
        streamingMessagePublishedText = publishedText
    }

    /// Commits the buffered stream into the transcript. Callers are response
    /// boundaries (complete, error, stop, chat switch) — the one place the
    /// messages array should change for the streamed response.
    func commitStreamingMessage(tokenCount: Int? = nil) {
        streamingMessageFlushTask?.cancel()
        streamingMessageFlushTask = nil
        guard let id = streamingMessageID,
            streamingMessageSessionID == sessionID,
            let index = messages.firstIndex(where: { $0.id == id })
        else {
            streamingText.clearPresentation()
            streamingResponseStartedAt = nil
            return
        }
        applyVisionNoticeDetectionIfNeeded(to: streamingMessageBuffer)
        let publishedText = streamingMessageIsVisionNotice ? Self.visionUnsupportedNotice : streamingMessageBuffer
        // Completion may arrive before the adaptive presentation timer flushes
        // its final delta. Reconcile the live projection first so the native
        // completion handoff can reuse every promoted section.
        streamingText.reconcilePresentation(with: publishedText)
        let message = messages[index]
        let attribution = Self.botAttribution(from: publishedText)
        let botProfileID = attribution?.profileID ?? activeBotProfileID
        let botDisplayName = attribution?.displayName ?? activeBotDisplayName
        closeTurnThinking()
        let reactions = message.reactions
        messages[index] = ChatMessage(
            id: id,
            role: .hermes,
            text: attribution?.body ?? publishedText,
            image: message.image,
            timestamp: message.timestamp,
            modelName: message.modelName,
            responseDuration: Date().timeIntervalSince(message.timestamp),
            tokenCount: tokenCount,
            botProfileID: botProfileID,
            botDisplayName: botDisplayName,
            // The response boundary is authoritative: nothing is still running.
            activity: streamingTurnActivity.map { call in
                var call = call
                call.isComplete = true
                return call
            }
        )
        messages[index].reactions = reactions
        streamingMessagePendingPresentationDelta = ""
        streamingText.retainCompletionPresentation(for: id)
        streamingText.clearLivePresentation()
        streamingResponseStartedAt = nil
    }

    func pendingStreamingText() -> String? {
        streamingMessageIsVisionNotice ? Self.visionUnsupportedNotice : streamingMessageBuffer
    }

    func applyVisionNoticeDetectionIfNeeded(to text: String) {
        if !streamingMessageIsVisionNotice, Self.isVisionUnsupportedError(text) {
            streamingMessageIsVisionNotice = true
            activeToolCalls.removeAll { $0.name.lowercased().contains("vision") }
        }
    }

    func recordEvent(_ type: String, params: [String: Any]) {
        // Tool results can embed very large payloads; serializing the whole
        // params dict on the main thread caused lag spikes during tool storms.
        // Bound the input before serializing.
        let detail: String
        if let data = try? JSONSerialization.data(
            withJSONObject: Self.boundedEventPayload(params), options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        {
            detail = String(json.prefix(500))
        } else {
            detail = String(String(describing: params).prefix(500))
        }
        // The gateway already logs one line per received event; a duplicate
        // here doubled the per-event logging cost during tool storms.
        recentEvents.append(
            AgentEvent(
                id: UUID(),
                type: type,
                detail: detail,
                timestamp: dateValue(params["timestamp"]) ?? Date()
            ))
        if recentEvents.count > 40 {
            recentEvents.removeFirst(recentEvents.count - 40)
        }
    }

    static func boundedEventPayload(_ params: [String: Any], depth: Int = 0) -> [String: Any] {
        var bounded: [String: Any] = [:]
        for (key, value) in params {
            bounded[key] = boundedEventValue(value, depth: depth)
        }
        return bounded
    }

    static func boundedEventValue(_ value: Any, depth: Int) -> Any {
        if let string = value as? String {
            // `count` walks every grapheme; a large tool payload made this
            // the main thread's hottest string work during replays.
            guard string.utf16.count > 240 else { return string }
            let head = string.prefix(240)
            return head.endIndex == string.endIndex ? string : String(head) + "…"
        }
        if let array = value as? [Any] {
            guard depth < 3 else { return "\(array.count) items" }
            return array.prefix(8).map { boundedEventValue($0, depth: depth + 1) }
        }
        if let dict = value as? [String: Any] {
            guard depth < 3 else { return "\(dict.count) keys" }
            return boundedEventPayload(dict, depth: depth + 1)
        }
        return value
    }

    static let visionUnsupportedPhrase = "does not support image"

    static func isVisionUnsupportedError(_ text: String) -> Bool {
        text.lowercased().contains(visionUnsupportedPhrase)
    }
}
