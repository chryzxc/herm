import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// The app delegate owns terminal cleanup. Relying on `HermesGateway`'s
    /// deinitializer leaves its child `hermes serve` process running when
    /// AppKit tears down the application without releasing the model first.
    func shutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        streamingMessageFlushTask?.cancel()
        sessionLoadTask?.cancel()
        delegationRefreshTask?.cancel()
        delegationMonitoringTask?.cancel()
        gatewayReplayTask?.cancel()
        stopVoiceConversation()
        for key in Array(composerDrafts.keys) { discardComposerDraft(for: key) }
        for pending in pendingSessionSends { cleanupImageAttachments(pending.snapshot.images) }
        pendingSessionSends.removeAll()
        sessionStopAttempts.removeAll()
        gateway.close()
        detachInFlightBotActivities(as: .canceled)
        Task {
            await agentStateWriter.flush()
            await botActivityWriter.flush()
        }
        DebugLog.write("model: shutdown complete")
    }

    func quickMessageUnavailableReason(for target: HermesSession?) -> String? {
        if status == .offline { return "Hermes is offline. Reconnect in Herm to send a message." }
        if let target, currentSessionIDs.contains(target.id),
            target.profileID == nil || target.profileID == sessionProfileID
        {
            if isRestoringSession || isCreatingSession || isUpdatingSessionModel {
                return "Wait for the conversation to finish loading."
            }
            if isSending || status != .idle || hasQueuedOrRedirectingPrompt {
                return "This session is busy. Reply when its current turn finishes."
            }
        }
        return nil
    }

    func submitQuickDraft(_ draft: QuickDraftRecord, progress: (QuickDraftRecord) throws -> Void) async throws
        -> QuickDraftRecord
    {
        if let reason = quickMessageUnavailableReason(for: draft.destination.session) {
            throw QuickSubmissionFailure(message: reason, uncertain: false)
        }
        let submitted = try await QuickDraftSubmission.send(
            draft, client: sessionRPCClient,
            progress: { record in
                rememberQuickSession(record.destination)
                try progress(record)
            },
            beforeSubmit: { record, directory in
                await DeveloperWorkflowModel.shared.captureTurnBaseline(
                    origin: record.destination, path: directory, attemptID: record.revision)
            }, generationContext: generationContext(for: draft.destination))
        rememberQuickSession(submitted.destination)
        DeveloperWorkflowModel.shared.acknowledgeTurnBaseline(
            origin: submitted.destination, attemptID: submitted.revision)
        loadSessions()
        return submitted
    }

    func rememberQuickSession(_ destination: QuickDestination) {
        guard let runtime = destination.runtimeID, let owner = destination.sessionID else { return }
        quickSessionOwners[runtime] = destination
        quickSessionOwners[owner] = destination
        if quickSessionOwners.count > 256 {
            quickSessionOwners = [runtime: destination]
            quickSessionOwners[owner] = destination
        }
        let ids = Set([runtime, owner]).union(pendingApprovalAliasesBySessionID[owner] ?? [])
        for id in ids {
            pendingApprovalAliasesBySessionID[id] = ids
            pendingClarificationAliasesBySessionID[id] = ids
        }
    }

    func cleanupQuickDraftUploads(_ draft: QuickDraftRecord) async throws {
        try await QuickDraftSubmission.detach(draft, client: sessionRPCClient)
    }

    /// A nil target explicitly creates an independent session. Existing targets
    /// are captured by identity; neither path changes the workspace selection.
    func sendQuickMessage(
        _ text: String, to target: HermesSession? = nil, profileID: String? = nil,
        onCreated: @escaping (HermesSession) -> Void = { _ in },
        completion: @escaping (String?) -> Void
    ) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = quickMessageUnavailableReason(for: target) {
            completion(reason)
            return
        }
        guard !clean.isEmpty else {
            completion("Enter a message first.")
            return
        }
        guard !clean.hasPrefix("/") else {
            completion("Use Herm for slash commands.")
            return
        }
        if let target, currentSessionIDs.contains(target.id),
            target.profileID == nil || target.profileID == sessionProfileID
        {
            send(QueuedPrompt(sessionID: target.id, text: clean, images: [], pdfURL: nil), onSubmission: completion)
            return
        }
        let profile = target?.profileID ?? profileID ?? profileScopeID
        Task {
            do {
                try await sessionRPCClient.connect()
                var params: [String: Any] = [:]
                if let profile { params["profile"] = profile }
                let destination: HermesSession
                let runtimeID: String
                if let target {
                    var resumeParams = params
                    resumeParams["session_id"] = target.id
                    resumeParams["source"] = HermesFeatureIDs.sessionSource
                    resumeParams["omit_messages"] = true
                    let result = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.sessionResume.rawValue, params: resumeParams)
                    runtimeID = (result["session_id"] as? String) ?? target.id
                    guard
                        Self.resumeResponseProvesSessionOwnership(
                            requestedSessionID: target.id,
                            resolvedSessionID: runtimeID, result: result)
                    else {
                        completion("Hermes returned a different session. Refresh Activity and try again.")
                        return
                    }
                    guard (result["running"] as? Bool) != true else {
                        completion("This session is busy. Reply when its current turn finishes.")
                        return
                    }
                    destination = target
                } else {
                    var createParams = params
                    createParams["source"] = HermesFeatureIDs.sessionSource
                    let result = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.sessionCreate.rawValue, params: createParams)
                    guard let id = result["session_id"] as? String, !id.isEmpty else {
                        throw HermesGateway.GatewayError.malformedResponse
                    }
                    runtimeID = id
                    destination = HermesSession(
                        id: Self.stableSessionID(from: result) ?? id,
                        profileID: profile, title: result["title"] as? String ?? "", preview: clean,
                        startedAt: .now, messageCount: 0, source: HermesFeatureIDs.sessionSource)
                    // Retain the created identity even if prompt submission fails.
                    onCreated(destination)
                }
                params["session_id"] = runtimeID
                params["text"] = GenerativeUIIntegration.preparePrompt(
                    clean,
                    context: generationContext(
                        for: QuickDestination(
                            profileID: profile, sessionID: destination.id, title: destination.displayTitle)))
                _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.promptSubmit.rawValue, params: params)
                if !sessions.contains(where: { $0.scopedID == destination.scopedID }) {
                    sessions.insert(destination, at: 0)
                }
                updateSessionActivity(sessionID: destination.id, isWorking: true)
                touchSession(sessionID: destination.id, at: .now, preview: clean)
                completion(nil)
                loadSessions()
            } catch {
                completion(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Forwards text into a new session under `profileID`. Plain text rides
    /// `sendQuickMessage`; a slash command runs on the new session with that
    /// bot's own command set. `completion` gets (error, output): output is a
    /// command's result text, nil when a prompt was submitted instead.
    func forwardMessage(_ text: String, toProfile profileID: String, completion: @escaping (String?, String?) -> Void) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = quickMessageUnavailableReason(for: nil) {
            completion(reason, nil)
            return
        }
        guard !clean.isEmpty else {
            completion("Enter a message first.", nil)
            return
        }
        let command = ComposerSlashCommand(clean)
        Task {
            do {
                try await sessionRPCClient.connect()
                let created = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.sessionCreate.rawValue,
                    params: ["profile": profileID, "source": HermesFeatureIDs.sessionSource])
                guard let createdID = created["session_id"] as? String, !createdID.isEmpty else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                let storedID = Self.stableSessionID(from: created) ?? createdID
                let session = HermesSession(
                    id: storedID, profileID: profileID, title: created["title"] as? String ?? "",
                    preview: clean, startedAt: .now, messageCount: 0, source: HermesFeatureIDs.sessionSource)
                if !sessions.contains(where: { $0.scopedID == session.scopedID }) { sessions.insert(session, at: 0) }
                let runtimeID = createdID
                // The agent builds lazily; a turn submitted mid-build is refused
                // ("no agent attached") without an RPC error. Any session-scoped RPC
                // waits for the build, so block on a cheap one first.
                _ = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.approvalPending.rawValue, params: ["session_id": runtimeID])
                var scope: [String: Any] = ["session_id": runtimeID, "profile": profileID]
                guard let command else {
                    scope["text"] = GenerativeUIIntegration.preparePrompt(clean)
                    _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.promptSubmit.rawValue, params: scope)
                    updateSessionActivity(sessionID: session.id, isWorking: true)
                    touchSession(sessionID: session.id, at: .now, preview: clean)
                    completion(nil, nil)
                    loadSessions()
                    return
                }
                let payload: [String: Any]
                do {
                    let line = command.arg.isEmpty ? command.name : "\(command.name) \(command.arg)"
                    payload = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.slashExec.rawValue,
                        params: ["session_id": runtimeID, "command": line, "profile": profileID])
                } catch {
                    // Skills, bundles and pending-input builtins refuse slash.exec.
                    payload = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.commandDispatch.rawValue,
                        params: [
                            "session_id": runtimeID, "name": command.name, "arg": command.arg, "profile": profileID,
                        ])
                }
                switch payload["type"] as? String {
                case "send", "skill":
                    let message = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !message.isEmpty else {
                        completion("/\(command.name): empty message", nil)
                        return
                    }
                    scope["text"] = GenerativeUIIntegration.preparePrompt(message)
                    _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.promptSubmit.rawValue, params: scope)
                    updateSessionActivity(sessionID: session.id, isWorking: true)
                    completion(nil, nil)
                default:
                    completion(nil, (payload["output"] as? String) ?? (payload["message"] as? String) ?? "(no output)")
                }
                loadSessions()
            } catch {
                completion(Self.safeUserDiagnostic(error.localizedDescription), nil)
            }
        }
    }
}
