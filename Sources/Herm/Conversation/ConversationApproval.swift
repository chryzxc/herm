import Foundation

struct ConversationApproval: Equatable, Identifiable {
    let id: UUID
    let approval: ApprovalPresentation
    let target: AttentionRequest?
    let serverRequestID: String?
    let profileID: String?
    var aliases: Set<String>
    var resolved: Bool
    var legacyAnswer: AttentionAnswerState? = nil
}

struct VoiceApproval: Equatable {
    let record: ConversationApproval
    let answer: AttentionAnswerState?
}

extension DockModel {
    var voiceApproval: VoiceApproval? {
        voiceApproval(records: conversationApprovals, answers: attentionAnswers)
    }

    func voiceApproval(
        records: [ConversationApproval], answers: [AttentionRequest: AttentionAnswerState]
    ) -> VoiceApproval? {
        let profile = sessionProfileID ?? profileScopeID
        guard
            let record = records.last(where: {
                $0.profileID == profile && !$0.aliases.isDisjoint(with: currentSessionIDs)
            }), !record.resolved
        else { return nil }
        return VoiceApproval(record: record, answer: record.target.flatMap { answers[$0] } ?? record.legacyAnswer)
    }

    var currentConversationApproval: ConversationApproval? {
        let profile = sessionProfileID ?? profileScopeID
        return conversationApprovals.last {
            $0.profileID == profile && !$0.aliases.isDisjoint(with: currentSessionIDs)
        }
    }

    func captureConversationApproval(_ pending: PendingApproval, sessionID: String, profileID: String?) -> Bool {
        let aliases = pendingApprovalAliasesBySessionID[sessionID] ?? [sessionID]
        let index = conversationApprovals.firstIndex {
            $0.profileID == profileID && !$0.aliases.isDisjoint(with: aliases)
        }
        if let index {
            let old = conversationApprovals[index]
            let same =
                pending.presentation.requestID != nil && old.approval.requestID == pending.presentation.requestID
                || pending.serverRequestID != nil && old.serverRequestID == pending.serverRequestID
            if same { return !old.resolved }
            conversationApprovals.remove(at: index)
        }
        conversationApprovals.append(
            ConversationApproval(
                id: UUID(), approval: pending.presentation, target: pending.responseTarget,
                serverRequestID: pending.serverRequestID, profileID: profileID, aliases: aliases, resolved: false))
        return true
    }

    func conversationApprovalID(sessionID: String, pending: PendingApproval) -> UUID? {
        conversationApprovals.first {
            $0.aliases.contains(sessionID) && $0.profileID == pending.profileID
                && $0.target == pending.responseTarget && $0.serverRequestID == pending.serverRequestID
                && $0.approval == pending.presentation && !$0.resolved
        }?.id
    }

    func resolveConversationApproval(sessionID: String, pending: PendingApproval, recordID: UUID? = nil) {
        guard let id = conversationApprovalID(sessionID: sessionID, pending: pending),
            recordID == nil || recordID == id,
            let index = conversationApprovals.firstIndex(where: { $0.id == id })
        else { return }
        conversationApprovals[index].resolved = true
    }

    func addConversationApprovalAliases(_ aliases: Set<String>, pending: PendingApproval) {
        guard
            let index = conversationApprovals.firstIndex(where: {
                $0.profileID == pending.profileID && $0.target == pending.responseTarget
                    && $0.serverRequestID == pending.serverRequestID && $0.approval == pending.presentation
                    && !$0.aliases.isDisjoint(with: aliases)
            })
        else { return }
        conversationApprovals[index].aliases.formUnion(aliases)
    }

    func addResolvedApprovalAliases(_ aliases: Set<String>) {
        let profile = sessionProfileID ?? profileScopeID
        guard
            let index = conversationApprovals.lastIndex(where: {
                $0.resolved && $0.profileID == profile && !$0.aliases.isDisjoint(with: aliases)
            })
        else { return }
        conversationApprovals[index].aliases.formUnion(aliases)
    }

    func setLegacyApprovalAnswer(_ answer: AttentionAnswerState?, id: UUID) {
        guard let index = conversationApprovals.firstIndex(where: { $0.id == id && !$0.resolved }) else { return }
        conversationApprovals[index].legacyAnswer = answer
    }

    func respondToLegacyApproval(_ record: ConversationApproval, sessionID: String, choice: String) {
        guard !record.resolved, record.target == nil, record.approval.choices.contains(choice),
            record.legacyAnswer?.blocksSubmission != true,
            currentConversationApproval?.id == record.id,
            let pending = pendingApprovalsBySessionID[sessionID], pending.responseTarget == nil,
            pending.serverRequestID == record.serverRequestID, pending.presentation == record.approval
        else { return }
        let generation = sessionResumeGeneration
        isRespondingToApproval = true
        setLegacyApprovalAnswer(.sending(choice), id: record.id)
        Task {
            defer {
                if self.sessionResumeGeneration == generation, self.sessionID == sessionID {
                    self.isRespondingToApproval = false
                }
            }
            do {
                guard await ApprovalAuthGate.allows(choice) else {
                    setLegacyApprovalAnswer(.failed(choice, "Authentication was cancelled."), id: record.id)
                    return
                }
                guard sessionResumeGeneration == generation, self.sessionID == sessionID,
                    (sessionProfileID ?? profileScopeID) == record.profileID,
                    currentConversationApproval?.id == record.id, currentConversationApproval?.resolved == false,
                    pendingApprovalsBySessionID[sessionID] == pending
                else {
                    setLegacyApprovalAnswer(
                        .failed(choice, "The session changed before the answer was sent."), id: record.id)
                    return
                }
                var params: [String: Any] = ["session_id": sessionID, "choice": choice]
                if let profile = record.profileID { params["profile"] = profile }
                let result = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.approvalRespond.rawValue, params: params)
                guard let resolved = result["resolved"] as? Int, resolved >= 0 else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                guard sessionResumeGeneration == generation, self.sessionID == sessionID,
                    (sessionProfileID ?? profileScopeID) == record.profileID,
                    currentConversationApproval?.id == record.id, currentConversationApproval?.resolved == false,
                    pendingApprovalsBySessionID[sessionID] == pending
                else {
                    setLegacyApprovalAnswer(
                        .uncertain(choice, "The session changed before the answer was confirmed."), id: record.id)
                    return
                }
                resolveApproval(for: sessionID, resumesWork: resolved > 0, recordID: record.id)
            } catch {
                setLegacyApprovalAnswer(.failure(error, choice: choice), id: record.id)
            }
        }
    }

    func recheckLegacyApproval(_ id: UUID) {
        guard let record = currentConversationApproval, record.id == id, !record.resolved,
            record.target == nil, let previous = record.legacyAnswer, case .uncertain = previous,
            let sessionID, sessionActionsReady,
            let active = pendingApprovalsBySessionID[sessionID], active.responseTarget == nil,
            active.serverRequestID == record.serverRequestID, active.presentation == record.approval
        else { return }
        let generation = sessionResumeGeneration
        setLegacyApprovalAnswer(.checking(previous.choice), id: id)
        Task {
            do {
                var params: [String: Any] = ["session_id": sessionID]
                if let profile = record.profileID { params["profile"] = profile }
                let result = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.approvalPending.rawValue, params: params)
                guard sessionResumeGeneration == generation, self.sessionID == sessionID,
                    (sessionProfileID ?? profileScopeID) == record.profileID,
                    currentConversationApproval?.id == id, currentConversationApproval?.resolved == false,
                    pendingApprovalsBySessionID[sessionID] == active,
                    let pending = result["approvals"] as? [[String: Any]]
                else { throw HermesGateway.GatewayError.malformedResponse }
                if pending.isEmpty {
                    resolveApproval(for: sessionID, resumesWork: false, recordID: id)
                } else if pending.count == 1 {
                    var approval = ApprovalPresentation.from(payload: pending[0])
                    approval.requestID = nil
                    guard approval == record.approval else { throw HermesGateway.GatewayError.malformedResponse }
                    setLegacyApprovalAnswer(nil, id: id)
                } else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
            } catch {
                setLegacyApprovalAnswer(previous, id: id)
            }
        }
    }
}
