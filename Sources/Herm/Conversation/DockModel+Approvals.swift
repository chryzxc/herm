import AppKit
import Combine
import Foundation
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    func respondToApproval(_ choice: String) {
        guard sessionActionsReady, let sessionID else { return }
        guard !isRespondingToApproval else { return }
        if let request = sessionAttention[sessionID]?.responseTarget,
            attentionAnswers[request]?.blocksSubmission == true
        {
            return
        }
        let responseGeneration = sessionResumeGeneration
        let requestID = approvalDetails?.requestID
        isRespondingToApproval = true
        Task {
            defer {
                if self.sessionResumeGeneration == responseGeneration,
                    self.sessionID == sessionID
                {
                    self.isRespondingToApproval = false
                }
            }
            do {
                guard await ApprovalAuthGate.allows(choice) else { return }
                var params: [String: Any] = ["session_id": sessionID, "choice": choice]
                if let requestID { params["request_id"] = requestID }
                _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.approvalRespond.rawValue, params: params)
                guard self.sessionResumeGeneration == responseGeneration,
                    self.sessionID == sessionID
                else { return }
                resolveApproval(for: sessionID, requestID: requestID)
            } catch {
                DebugLog.write(
                    "model: approval response failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    /// The notch's one-tap answer for any session's approval or single clarify question.
    /// `freeText` lets a typed reply (notification quick-reply) answer a clarify question outside its listed choices.
    func answerAttention(_ request: AttentionRequest, choice: String, freeText: Bool = false) {
        guard let attention = sessionAttention[request.sessionID], attention.responseTarget == request,
            freeText ? attention.status == .needsClarification : attention.choices.contains(choice),
            attentionAnswers[request]?.blocksSubmission != true
        else { return }
        if currentSessionIDs.contains(request.sessionID) || rowSessionID(request.sessionID) == navigationSessionID {
            guard sessionActionsReady, !isRespondingToApproval, !isRespondingToClarification else { return }
        }
        attentionAnswers[request] = .sending(choice)
        let responseGeneration = sessionResumeGeneration
        Task {
            do {
                guard await ApprovalAuthGate.allows(choice) else {
                    attentionAnswers[request] = .failed(choice, "Authentication was cancelled.")
                    return
                }
                var params: [String: Any]
                let method: String
                if attention.status == .needsApproval {
                    method = HermesFeatureIDs.ID.approvalRespond.rawValue
                    params = ["session_id": request.sessionID, "request_id": request.requestID, "choice": choice]
                } else {
                    method = HermesFeatureIDs.ID.clarifyRespond.rawValue
                    params = ["id": request.requestID, "result": ["answer": choice]]
                }
                if let profile = request.profileID { params["profile"] = profile }
                let result = try await sessionRPCClient.request(method, params: params)
                guard sessionAttention[request.sessionID]?.responseTarget == request else { return }
                let expired: Bool
                if attention.status == .needsApproval {
                    guard let resolved = result["resolved"] as? Int, resolved >= 0 else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    expired = resolved == 0
                    resolveApproval(for: request.sessionID, requestID: request.requestID, resumesWork: !expired)
                } else {
                    guard let answerStatus = result["status"] as? String, ["ok", "expired"].contains(answerStatus)
                    else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    expired = answerStatus == "expired"
                    markClarificationResolved(request.requestID)
                    _ = removePendingClarification(for: request.sessionID, requestID: request.requestID)
                    guard sessionResumeGeneration == responseGeneration,
                        currentSessionIDs.contains(request.sessionID), clarificationRequestID == request.requestID
                    else { return }
                    showClarification(nil)
                    if !expired {
                        messages.append(ChatMessage(role: .user, text: choice))
                        isAwaitingClarificationResume = true
                        status = .working
                        isSending = true
                        conversationActivityPhase = .thinking
                        setInFlightBotActivityWorking(for: request.sessionID)
                    } else {
                        status = .idle
                        isSending = false
                        clarificationResponseError = "This question expired before Hermes received an answer."
                    }
                }
            } catch {
                guard sessionAttention[request.sessionID]?.responseTarget == request else { return }
                attentionAnswers[request] = .failure(error, choice: choice)
                DebugLog.write("model: notch answer failed: \(Self.safeUserDiagnostic(error.localizedDescription))")
            }
        }
    }

    /// Only a fresh authoritative pending-request read permits retry after a lost acknowledgment.
    func recheckAttention(_ request: AttentionRequest) {
        guard let attention = sessionAttention[request.sessionID], attention.responseTarget == request,
            let previous = attentionAnswers[request], case .uncertain = previous
        else { return }
        attentionAnswers[request] = .checking(previous.choice)
        let responseGeneration = sessionResumeGeneration
        Task {
            do {
                var params: [String: Any] = ["session_id": request.sessionID]
                if let profile = request.profileID { params["profile"] = profile }
                let isApproval = attention.status == .needsApproval
                if !isApproval { params["last_seen"] = 0 }
                let method = isApproval ? HermesFeatureIDs.ID.approvalPending : HermesFeatureIDs.ID.sessionEventsSince
                let result = try await sessionRPCClient.request(method.rawValue, params: params)
                guard sessionAttention[request.sessionID]?.responseTarget == request else { return }
                let stillPending: Bool
                if isApproval {
                    guard let pending = result["approvals"] as? [[String: Any]],
                        pending.allSatisfy({ ($0["request_id"] as? String)?.isEmpty == false })
                    else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    stillPending = pending.contains { $0["request_id"] as? String == request.requestID }
                } else {
                    guard let pending = result["open_requests"] as? [[String: Any]],
                        pending.allSatisfy({
                            ($0["id"] as? String)?.isEmpty == false && $0["method"] is String
                                && $0["params"] is [String: Any]
                        })
                    else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    stillPending = pending.contains {
                        $0["id"] as? String == request.requestID && $0["method"] as? String == "clarify"
                    }
                }
                if stillPending {
                    attentionAnswers.removeValue(forKey: request)
                } else if isApproval {
                    resolveApproval(for: request.sessionID, requestID: request.requestID, resumesWork: false)
                } else {
                    markClarificationResolved(request.requestID)
                    _ = removePendingClarification(for: request.sessionID, requestID: request.requestID)
                    guard sessionResumeGeneration == responseGeneration,
                        currentSessionIDs.contains(request.sessionID), clarificationRequestID == request.requestID
                    else { return }
                    showClarification(nil)
                    status = .idle
                    isSending = false
                    clarificationResponseError =
                        "This question is no longer pending. Open the session to review the result."
                }
            } catch {
                guard sessionAttention[request.sessionID]?.responseTarget == request else { return }
                attentionAnswers[request] = previous
            }
        }
    }

    func respondToClarification(_ response: String, displayText: String? = nil) {
        guard sessionActionsReady else { return }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard !trimmed.isEmpty || !images.isEmpty, !isRespondingToClarification else { return }
        guard let responseSessionID = sessionID, !responseSessionID.isEmpty else { return }
        if let request = sessionAttention[responseSessionID]?.responseTarget,
            attentionAnswers[request]?.blocksSubmission == true
        {
            return
        }
        let responseGeneration = sessionResumeGeneration
        guard let requestID = clarificationRequestID, !requestID.isEmpty else {
            clarificationResponseError = "Hermes did not provide an ID for this question. Please ask it again."
            return
        }
        let batchQuestion = activeClarification?.requestID == requestID ? activeClarification?.current : nil
        draft = ""
        pendingImages = []
        messages.append(ChatMessage(role: .user, text: displayText ?? trimmed, images: images.map(\.image)))
        if let batchQuestion, var batch = activeClarification, batch.remainingCount > 1 {
            // Earlier batch answers are locked one by one; the last lock resumes the turn.
            isRespondingToClarification = true
            clarificationResponseError = nil
            Task {
                defer {
                    if self.sessionResumeGeneration == responseGeneration,
                        self.sessionID == responseSessionID
                    {
                        self.isRespondingToClarification = false
                    }
                }
                do {
                    let answerText = try await clarificationAnswer(
                        trimmed, images: images, sessionID: responseSessionID)
                    let result = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.clarifyLock.rawValue,
                        params: [
                            "request_id": requestID, "question_id": batchQuestion.id, "answer": answerText,
                        ])
                    if result["status"] as? String == "expired" {
                        throw NSError(
                            domain: "Hermes", code: 410,
                            userInfo: [
                                NSLocalizedDescriptionKey: "This question expired before Hermes received an answer."
                            ])
                    }
                    cleanupImageAttachments(images)
                    batch.lockedAnswers[batchQuestion.id] = answerText
                    for alias in pendingClarificationAliasesBySessionID[responseSessionID] ?? [responseSessionID]
                    where pendingClarificationsBySessionID[alias]?.requestID == requestID {
                        pendingClarificationsBySessionID[alias] = batch
                    }
                    guard self.sessionResumeGeneration == responseGeneration,
                        self.sessionID == responseSessionID
                    else { return }
                    showClarification(batch)
                    messages.append(ChatMessage(role: .hermes, text: batch.transcriptText, modelName: currentModelName))
                } catch {
                    guard self.sessionResumeGeneration == responseGeneration,
                        self.sessionID == responseSessionID
                    else { return }
                    pendingImages.insert(contentsOf: images, at: 0)
                    let diagnostic = Self.safeUserDiagnostic(error.localizedDescription)
                    clarificationResponseError = diagnostic
                    DebugLog.write("model: clarification lock failed: \(diagnostic)")
                }
            }
            return
        }
        beginStreamingMessage()
        isAwaitingClarificationResume = true
        isRespondingToClarification = true
        clarificationResponseError = nil
        status = .working
        isSending = true
        conversationActivityPhase = .thinking
        Task {
            defer {
                if self.sessionResumeGeneration == responseGeneration,
                    self.sessionID == responseSessionID
                {
                    self.isRespondingToClarification = false
                }
            }
            do {
                let answerText = try await clarificationAnswer(trimmed, images: images, sessionID: responseSessionID)
                let answer: [String: Any]
                if let batchQuestion {
                    // The last batch lock resolves the whole request with every answer.
                    answer = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.clarifyLock.rawValue,
                        params: [
                            "request_id": requestID, "question_id": batchQuestion.id, "answer": answerText,
                        ])
                } else {
                    answer = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.clarifyRespond.rawValue,
                        params: [
                            "id": requestID,
                            "result": ["answer": answerText],
                        ])
                }
                if answer["status"] as? String == "expired" {
                    throw NSError(
                        domain: "Hermes", code: 410,
                        userInfo: [NSLocalizedDescriptionKey: "This question expired before Hermes received an answer."]
                    )
                }
                cleanupImageAttachments(images)
                markClarificationResolved(requestID)
                _ = removePendingClarification(for: responseSessionID, requestID: requestID)
                guard self.sessionResumeGeneration == responseGeneration,
                    self.sessionID == responseSessionID
                else { return }
                showClarification(nil)
                setInFlightBotActivityWorking(for: responseSessionID)
            } catch {
                guard self.sessionResumeGeneration == responseGeneration,
                    self.sessionID == responseSessionID
                else { return }
                removePendingClarificationResumeMessage()
                pendingImages.insert(contentsOf: images, at: 0)
                status = .needsClarification
                isSending = false
                conversationActivityPhase = .idle
                let diagnostic = Self.safeUserDiagnostic(error.localizedDescription)
                clarificationResponseError = diagnostic
                DebugLog.write("model: clarification response failed: \(diagnostic)")
            }
        }
    }

    /// A clarify answer is text only, so staged images are stored in Hermes'
    /// session images dir and referenced by path for `vision_analyze`. Each is
    /// detached again so it doesn't also ride along with the next prompt.
    func clarificationAnswer(_ text: String, images: [ImageAttachment], sessionID: String) async throws -> String {
        var lines = text.isEmpty ? [] : [text]
        for image in images {
            let base64 = try await AttachmentPayload.encoded(at: image.fileURL)
            let result = try await sessionRPCClient.request(
                HermesFeatureIDs.ID.imageAttachBytes.rawValue,
                params: scopedSessionParams([
                    "session_id": sessionID,
                    "content_base64": base64,
                    "filename": image.fileName,
                ])
            )
            guard result["attached"] as? Bool == true, let path = result["path"] as? String else {
                throw HermesGateway.GatewayError.imageAttachFailed(
                    (result["message"] as? String) ?? "Hermes could not attach the image."
                )
            }
            _ = try? await sessionRPCClient.request(
                HermesFeatureIDs.ID.imageDetach.rawValue,
                params: scopedSessionParams(["session_id": sessionID, "path": path])
            )
            lines.append("[User attached image: \(path) — view it with vision_analyze]")
        }
        return lines.joined(separator: "\n")
    }

    /// Answers the open sudo / secret / vault prompt; an empty value skips it.
    /// The value is never logged or kept after the request is sent.
    func respondToValuePrompt(_ value: String) {
        guard sessionActionsReady, let prompt = valuePrompt, !isRespondingToValuePrompt else { return }
        isRespondingToValuePrompt = true
        valuePromptError = nil
        Task {
            defer { self.isRespondingToValuePrompt = false }
            do {
                let result = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.clarifyRespond.rawValue,
                    params: [
                        "id": prompt.requestID, "result": ["value": value],
                    ])
                if valuePrompt?.requestID == prompt.requestID { valuePrompt = nil }
                if result["status"] as? String == "expired" {
                    DebugLog.write("model: value prompt expired before the answer arrived")
                }
            } catch {
                let diagnostic = Self.safeUserDiagnostic(error.localizedDescription)
                valuePromptError = diagnostic
                DebugLog.write("model: value prompt response failed: \(diagnostic)")
            }
        }
    }

    /// Reconciles an approval answered through another surface, such as Inbox.
    /// Responses for other sessions clear their retained request without
    /// altering the visible conversation.
    func resolveApproval(for resolvedSessionID: String, requestID: String? = nil, resumesWork: Bool = true) {
        if let requestID {
            guard let pending = pendingApprovalsBySessionID[resolvedSessionID],
                pending.presentation.requestID == requestID || pending.serverRequestID == requestID
            else { return }
        }
        // A direct Bot relay can pause in its own Bot Chat session while the
        // foreground conversation remains selected. Resolve that activity by
        // its exact event session before applying the foreground approval UI.
        setInFlightBotActivityWorking(for: resolvedSessionID)
        let activeSessionIDs = Set([sessionID, sessionStorageID, kanbanAttributionSessionID].compactMap { $0 })
        let resolvedAliases = removePendingApproval(for: resolvedSessionID)
        guard !activeSessionIDs.isDisjoint(with: resolvedAliases) else { return }
        for activeSessionID in activeSessionIDs {
            _ = removePendingApproval(for: activeSessionID)
        }
        approvalTitle = nil
        approvalText = nil
        approvalDetails = nil
        if status == .needsApproval {
            status = resumesWork ? .working : .idle
            setInFlightBotActivityWorking(for: resolvedSessionID)
            setInFlightBotActivityWorking(for: sessionID)
        }
    }
}

/// Opt-in biometric check before broad approvals ("for session" / "always"). One-time approvals and denials never prompt.
enum ApprovalAuthGate {
    static let key = "herm.requireAuthForBroadApprovals.v1"

    static func requiresAuth(_ choice: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key) && [ApprovalChoice.always, ApprovalChoice.session].contains(choice)
    }

    @MainActor
    static func allows(_ choice: String) async -> Bool {
        guard requiresAuth(choice) else { return true }
        let context = LAContext()
        var policyError: NSError?
        // No biometrics or password configured: fail closed rather than silently skipping the check.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else { return false }
        return
            (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "Allow Herm to run this without asking again")) == true
    }
}
