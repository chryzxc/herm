import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// Sends the composer draft, or a queued prompt without touching the draft.
    /// The optional callback reports RPC submission, not completion of the turn.
    func send(
        _ queued: QueuedPrompt? = nil, queueRuntimeID: String? = nil, onSubmission: ((String?) -> Void)? = nil
    ) {
        let queueOwner = queueRuntimeID.flatMap { _ in queued?.sessionID }
        let isForeground = queueRuntimeID == nil || queueRuntimeID == sessionID
        let originalText = queued?.text ?? draft
        let prompt = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedImages = queued?.images ?? pendingImages
        let attachedPDFs = queued == nil ? pendingPDFURLs : queued?.pdfURLs ?? []
        let contexts = queued == nil ? attachedContexts : queued?.contexts ?? []
        let botMentions = ComposerBotMention.rebasing(
            queued?.botMentions ?? composer.botMentions, from: originalText, to: prompt)
        guard !prompt.isEmpty || !attachedImages.isEmpty || !attachedPDFs.isEmpty || !contexts.isEmpty,
            !isForeground
                || (!isSending && sessionActionsReady && !isUpdatingSessionModel && !isUpdatingSessionFast
                    && !isRestoringSession
                    && (sessionID != nil || (newSessionCreationAuthorized && !isCreatingSession)))
        else { return }

        if queued == nil, hasQueuedOrRedirectingPrompt {
            queueDraft()
            return
        }

        if let queued, let bot = queued.botRecipient,
            let request = ComposerMentionPresentation.botRelayRequest(in: prompt, profileIDs: [bot.id])
        {
            sendDirectBotRequest(
                profileID: bot.id, displayName: bot.name, text: request.text,
                chatSessionID: bot.chat?.sessionID, quote: queued.replyQuote, originalText: prompt,
                botMentions: botMentions, clearsComposer: false)
            return
        }

        if attachedImages.isEmpty, attachedPDFs.isEmpty, contexts.isEmpty, let command = ComposerSlashCommand(prompt) {
            if queued == nil {
                draft = ""
                replyQuote = nil
                clearAttachmentErrors()
            }
            runSlashCommand(command, echo: prompt)
            return
        }

        let text: String
        let isAttachmentOnly = prompt.isEmpty && contexts.isEmpty
        if !isAttachmentOnly {
            let quote = queued == nil ? replyQuote : queued?.replyQuote
            let quoted = quote?.composing(prompt)
            text = ChatContext.prompt(ComposerCompletion.pathifyingBareRefs(quoted ?? prompt), contexts: contexts)
        } else if !attachedPDFs.isEmpty {
            text = attachedImages.isEmpty && attachedPDFs.count == 1 ? "[document]" : "[attachments]"
        } else {
            text = "[image]"
        }
        let isVoiceTurn = isForeground && voiceState.isNativeConversationActive && voiceSessionID == sessionID
        let capturedDestination = queueOwner.map {
            QuickDestination(
                profileID: queued?.profileID, sessionID: $0,
                title: (isForeground ? currentSessionTitle : nil) ?? "Session")
        }
        let richContext = generationContext(for: capturedDestination)
        let mentionProfiles = queueOwner == nil ? composerMentionProfiles : queued?.mentionProfiles ?? []
        let submittedText = GenerativeUIIntegration.preparePrompt(
            ComposerMentionPresentation.annotatedPrompt(text, profileIDs: mentionProfiles), context: richContext
        )
        let sessionBeforeSend = queueRuntimeID ?? sessionID
        let sendOwner =
            isForeground
            ? composerDraftKey : SessionComposerDraft.Key(profileID: queued?.profileID, sessionID: queueOwner)
        let profile = queueOwner == nil ? sessionProfileID ?? profileScopeID : queued?.profileID
        func scoped(_ params: [String: Any]) -> [String: Any] {
            guard let profile else { return params }
            return params.merging(["profile": profile]) { _, captured in captured }
        }

        let botActivityID = sessionBeforeSend.flatMap { eventSessionID in
            inFlightBotActivities.values.first { $0.botChatSessionID == eventSessionID }?.activityID
        }
        let sendGeneration = sessionResumeGeneration
        guard pendingSessionSends.count < 256 else {
            if let queued { queuedPrompts.insert(queued, at: 0) }
            let message = "Too many messages await confirmation. Check your conversations before sending."
            if isForeground {
                messages.append(ChatMessage(role: .hermes, text: message))
            } else {
                actionErrors.report("Could not send queued message", message: message)
            }
            onSubmission?(message)
            return
        }
        sessionStopAttempts[sendOwner] = nil
        let snapshot = SessionComposerDraft(
            text: originalText, images: attachedImages, pdfURLs: attachedPDFs, contexts: contexts,
            replyQuote: queued == nil ? replyQuote : queued?.replyQuote,
            attachmentError: queued == nil ? pendingAttachmentError : nil,
            pdfError: queued == nil ? pendingPDFError : nil, botMentions: botMentions)
        if queued == nil {
            draft = ""
            pendingImages = []
            pendingPDFURLs = []
            attachedContexts = []
            replyQuote = nil
            clearAttachmentErrors()
            restorePendingSendIfPossible(for: sendOwner)
        }
        let visibleContexts = contexts.filter { $0.attachmentURL == nil }
        let visibleText =
            isAttachmentOnly
            ? ""
            : ChatContext.prompt(
                ComposerCompletion.pathifyingBareRefs(snapshot.replyQuote?.composing(prompt) ?? prompt),
                contexts: visibleContexts)
        let attachmentLabels =
            contexts.compactMap { context in context.attachmentURL.map { "[File: \($0.lastPathComponent)]" } }
            + attachedPDFs.map { "[PDF: \($0.lastPathComponent)]" }
        let transcriptText = (attachmentLabels + [visibleText]).filter { !$0.isEmpty }.joined(separator: "\n")
        let sentMessage = ChatMessage(
            role: .user, text: transcriptText, images: attachedImages.map(\.image),
            botMentions: ComposerBotMention.rebasing(botMentions, from: prompt, to: transcriptText),
            attachmentURLs: contexts.compactMap(\.attachmentURL) + attachedPDFs)
        if isForeground { messages.append(sentMessage) }
        let sendID = UUID()
        if let queueOwner { queuedSubmissions[queueOwner] = sendID }
        pendingSessionSends.append(
            SessionPendingSend(
                id: sendID, owner: sendOwner, snapshot: snapshot, message: sentMessage,
                baselineRowID: isForeground ? transcriptMessageIDsByRowID.keys.max() ?? 0 : nil))

        if isForeground {
            status = .working
            isSending = true
            if let sessionID { turnStartedAtBySession[sessionID] = Date() }
            if voiceState.isNativeConversationActive, !isVoicePromptActive {
                nativeVoiceCapture.receivedTranscript(hasText: true)
                voiceState = .thinking
            }
        }
        DebugLog.write("model: send started (\(prompt.count) characters, images: \(attachedImages.count))")

        Task {
            @MainActor func ownsForeground(_ runtimeID: String?) -> Bool {
                self.sessionResumeGeneration == sendGeneration && self.sessionID == runtimeID
            }
            @MainActor func canSubmit(to runtimeID: String?) -> Bool {
                guard !hasShutDown else { return false }
                if let queueOwner { return queuedSubmissions[queueOwner] == sendID }
                return ownsForeground(runtimeID)
            }
            var submissionReported = false
            defer {
                if let queueOwner, queuedSubmissions[queueOwner] == sendID { queuedSubmissions[queueOwner] = nil }
                if !submissionReported {
                    if let pending = pendingSessionSends.first(where: { $0.id == sendID }), pending.phase == .preparing
                    {
                        recoverPendingSend(sendID)
                    }
                    onSubmission?("The selected conversation changed. Check Activity before retrying.")
                }
            }
            do {
                try await sessionRPCClient.connect()
                guard canSubmit(to: sessionBeforeSend) else { return }
                var targetSessionID = sessionBeforeSend
                if ownsForeground(sessionBeforeSend), sessionID == nil || pendingWorktreeDirectory != nil {
                    targetSessionID = try await createAuthorizedSession(source: HermesFeatureIDs.sessionSource)
                }
                guard let promptSessionID = targetSessionID else {
                    throw HermesGateway.GatewayError.malformedResponse
                }
                guard canSubmit(to: promptSessionID) else { return }
                if sessionBeforeSend == nil, let index = pendingSessionSends.firstIndex(where: { $0.id == sendID }) {
                    pendingSessionSends[index].owner = composerDraftKey
                }
                touchSession(sessionID: promptSessionID, at: Date(), preview: text)

                var fileReferences: [String] = []
                if !attachedPDFs.isEmpty || contexts.contains(where: { $0.attachmentURL != nil }) {
                    let capabilities = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.gatewayCapabilities.rawValue, params: [:])
                    guard capabilities["per_session_exclusive_submit"] as? Bool == true else {
                        throw QuickDraftError.message(
                            "This Hermes runtime cannot confirm protected file attachments. Your files are retained; text files can also be inserted using Paste as text."
                        )
                    }
                }
                for context in contexts {
                    guard let url = context.attachmentURL else { continue }
                    let encoded = try await AttachmentPayload.encoded(at: url, maximumBytes: 8 * 1024 * 1024)
                    guard canSubmit(to: promptSessionID) else { return }
                    let attached = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.fileAttach.rawValue,
                        params: scoped([
                            "session_id": promptSessionID,
                            "data_url": "data:application/octet-stream;base64," + encoded,
                            "name": url.lastPathComponent,
                        ]))
                    guard attached["attached"] as? Bool == true,
                        let reference = attached["ref_text"] as? String, reference.hasPrefix("@file:"),
                        !reference.contains("\n")
                    else {
                        throw QuickDraftError.message(
                            "Hermes could not attach the file. The draft context is retained for retry.")
                    }
                    fileReferences.append(reference)
                }
                for attachedPDF in attachedPDFs {
                    let encoded = try await AttachmentPayload.encoded(at: attachedPDF, maximumBytes: 25 * 1024 * 1024)
                    guard canSubmit(to: promptSessionID) else { return }
                    let result = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.fileAttach.rawValue,
                        params: scoped([
                            "session_id": promptSessionID,
                            "data_url": "data:application/pdf;base64," + encoded,
                            "name": attachedPDF.lastPathComponent,
                        ]))
                    guard result["attached"] as? Bool == true,
                        let reference = result["ref_text"] as? String, reference.hasPrefix("@file:"),
                        !reference.contains("\n")
                    else {
                        throw QuickDraftError.message(
                            "Hermes could not attach the PDF. The draft is retained for retry.")
                    }
                    fileReferences.append(reference)
                }
                let outgoingText =
                    fileReferences.isEmpty
                    ? submittedText
                    : GenerativeUIIntegration.preparePrompt(
                        ComposerMentionPresentation.annotatedPrompt(
                            text + "\n\n" + fileReferences.joined(separator: "\n"), profileIDs: mentionProfiles),
                        context: richContext
                    )
                for attachedImage in attachedImages {
                    let base64 = try await AttachmentPayload.encoded(at: attachedImage.fileURL)
                    guard canSubmit(to: promptSessionID) else { return }
                    let attachResult = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.imageAttachBytes.rawValue,
                        params: scoped([
                            "session_id": promptSessionID,
                            "content_base64": base64,
                            "filename": attachedImage.fileName,
                        ])
                    )
                    let attached = (attachResult["attached"] as? Bool) ?? false
                    guard attached else {
                        throw HermesGateway.GatewayError.imageAttachFailed(
                            (attachResult["message"] as? String) ?? "Hermes could not attach the image."
                        )
                    }
                    DebugLog.write("model: image attached")

                }

                guard canSubmit(to: promptSessionID) else { return }
                let baselineAttempt = UUID()
                let baselineOrigin =
                    capturedDestination
                    ?? QuickDestination(
                        profileID: sessionProfileID, sessionID: navigationSessionID ?? promptSessionID,
                        title: currentSessionTitle ?? "Session")
                var baselineDirectory =
                    (ownsForeground(promptSessionID) ? sessionWorkspace?.cwd : nil)
                    ?? createdSessionProjectPaths[promptSessionID]
                if baselineDirectory == nil {
                    let origin = HermesSession(
                        id: baselineOrigin.sessionID ?? promptSessionID, profileID: baselineOrigin.profileID,
                        title: baselineOrigin.title, preview: "", startedAt: nil, messageCount: 0,
                        source: HermesFeatureIDs.sessionSource)
                    baselineDirectory = try? await HermesWorkflowRPC(
                        client: controlRPCClient, profileID: baselineOrigin.profileID
                    ).sessionDirectory(origin)
                    guard canSubmit(to: promptSessionID) else { return }
                }
                if let directory = baselineDirectory {
                    await DeveloperWorkflowModel.shared.captureTurnBaseline(
                        origin: baselineOrigin, path: directory, attemptID: baselineAttempt)
                    guard canSubmit(to: promptSessionID) else { return }
                }
                if let index = pendingSessionSends.firstIndex(where: { $0.id == sendID }) {
                    pendingSessionSends[index].phase = .submitting
                    pendingSessionSends[index].submittedText =
                        isVoiceTurn ? VoicePrompts.conversationPrompt(outgoingText) : outgoingText
                }
                let acknowledgment = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.promptSubmit.rawValue,
                    params: scoped([
                        "session_id": promptSessionID,
                        "text": isVoiceTurn ? VoicePrompts.conversationPrompt(outgoingText) : outgoingText,
                        "voice_turn": isVoiceTurn, "queued": queued != nil,
                    ]))
                if acknowledgment["status"] as? String == "streaming" {
                    DeveloperWorkflowModel.shared.acknowledgeTurnBaseline(
                        origin: baselineOrigin, attemptID: baselineAttempt)
                }
                let accepted =
                    ["streaming", "queued", "redirected", "steered"].contains(acknowledgment["status"] as? String ?? "")
                    || acknowledgment["voice_stopped"] as? Bool == true
                if let index = pendingSessionSends.firstIndex(where: { $0.id == sendID }) {
                    pendingSessionSends[index].phase = accepted ? .acknowledged : .uncertain
                    pendingSessionSends[index].acceptedStatus = acknowledgment["status"] as? String
                    let owner = pendingSessionSends[index].owner
                    confirmPendingSend(sendID, owner: owner, receipt: acknowledgment)
                }
                if accepted { cleanupImageAttachments(attachedImages) }
                submissionReported = true
                onSubmission?(
                    accepted ? nil : "Herm could not confirm submission. Check the conversation before retrying.")
                guard ownsForeground(promptSessionID) else { return }

                if acknowledgment["voice_stopped"] as? Bool == true { finishVoiceStopSubmission() }
                DebugLog.write("model: prompt submitted")
            } catch {
                if sessionBeforeSend == nil, self.sessionResumeGeneration == sendGeneration, self.sessionID != nil,
                    let index = pendingSessionSends.firstIndex(where: { $0.id == sendID })
                {
                    pendingSessionSends[index].owner = composerDraftKey
                }
                if let index = pendingSessionSends.firstIndex(where: { $0.id == sendID }),
                    pendingSessionSends[index].phase == .submitting
                {
                    pendingSessionSends[index].phase = .uncertain
                } else {
                    recoverPendingSend(sendID)
                }
                // A request from a previous session must not publish its error
                // into whichever conversation the user opened meanwhile.
                guard self.sessionResumeGeneration == sendGeneration,
                    sessionBeforeSend == nil || self.sessionID == sessionBeforeSend
                else {
                    if queueOwner != nil { actionErrors.report("Could not send queued message", error: error) }
                    return
                }
                DebugLog.write("model: send failed: \(Self.safeUserDiagnostic(error.localizedDescription))")

                for context in contexts
                where context.attachmentURL != nil && !attachedContexts.contains(where: { $0.id == context.id }) {
                    var retained = context
                    retained.inlineToken = nil
                    attachedContexts.append(retained)
                }
                let transportFailure: Bool
                if let gatewayError = error as? HermesGateway.GatewayError {
                    switch gatewayError {
                    case .backendUnavailable, .disconnected, .httpError:
                        transportFailure = true
                    case .malformedResponse, .imageAttachFailed, .httpRefused:
                        transportFailure = false
                    }
                } else {
                    let nsError = error as NSError
                    transportFailure = nsError.domain == NSURLErrorDomain || nsError.domain == NSPOSIXErrorDomain
                }
                let message =
                    transportFailure
                    ? "I couldn’t connect to Hermes: \(Self.safeUserDiagnostic(error.localizedDescription))"
                    : "Hermes couldn’t process this request: \(Self.safeUserDiagnostic(error.localizedDescription))"
                if !pendingSessionSends.contains(where: { $0.id == sendID && $0.phase == .uncertain }) {
                    messages.append(ChatMessage(role: .hermes, text: message, modelName: currentModelName))
                }
                if let botActivityID {
                    markBotActivityFailed(id: botActivityID, result: message)
                }
                status = transportFailure ? .offline : .idle
                isSending = false
                submissionReported = true
                onSubmission?(message)
                if let queueOwner, queuedSubmissions[queueOwner] == sendID { queuedSubmissions[queueOwner] = nil }
                if !transportFailure { drainQueuedPromptIfIdle() }
            }
        }
    }

    /// Mid-turn input: plain text with no earlier queued input redirects the
    /// live turn (`session.redirect`) and lands in the transcript at once as an
    /// ordinary user message. Anything a redirect can't carry (attachments,
    /// slash commands, a turn parked on an approval) or a redirect Hermes
    /// refuses because the turn already ended goes to `queuedPrompts` instead.
    func steerDraft() {
        guard sessionActionsReady else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sessionID, !sessionID.isEmpty else { return }
        guard !hasQueuedOrRedirectingPrompt,
            pendingImages.isEmpty, pendingPDFURLs.isEmpty, attachedContexts.isEmpty, replyQuote == nil,
            !text.isEmpty, status == .working, ComposerSlashCommand(text) == nil
        else {
            queueDraft()
            return
        }
        draft = ""
        clearAttachmentErrors()
        redirectTurn(with: text, sessionID: sessionID)
    }

    /// Sends `text` into the running turn; if Hermes refuses, it becomes the next turn.
    func redirectTurn(with text: String, sessionID: String) {
        guard sessionActionsReady else { return }
        steeringError = nil
        let submittedText = ComposerMentionPresentation.annotatedPrompt(text, profileIDs: composerMentionProfiles)
        let steeringGeneration = sessionResumeGeneration
        let queueSessionID = queuedPromptSessionID ?? sessionID
        let queueProfile = Self.normalizedProfileID(sessionProfileID ?? profileScopeID)
        let mentionProfiles = composerMentionProfiles
        redirectingPrompts[queueSessionID] = RedirectingPrompt(runtimeSessionID: sessionID)
        // Redirect cancels the model request, so its completion can race the
        // RPC response: record the correction first, below what already
        // streamed, and let the resumed output continue in a fresh row under it.
        let hadLiveStream = streamingMessageID != nil
        let correction = ChatMessage(role: .user, text: text)
        if hadLiveStream, streamingMessageBuffer.isEmpty, streamingTurnActivity.isEmpty {
            discardStreamingMessage()
            messages.append(correction)
            beginStreamingMessage()
        } else if hadLiveStream {
            // Activity already shown stays above the correction; only calls
            // still running follow into the new row.
            splitLiveTurn { messages.append(correction) }
        } else {
            messages.append(correction)
        }
        let resumedRowID = hadLiveStream ? streamingMessageID : nil

        Task {
            let result = try? await sessionRPCClient.request(
                HermesFeatureIDs.ID.sessionRedirect.rawValue,
                params: ["session_id": sessionID, "text": submittedText]
            )
            var redirectStatus = (result?["status"] as? String)?.lowercased()
            var hermesHasNoLiveTurn = false
            // Redirect is refused between model requests (or on an agent without it)
            // while the turn is still live; steer lands on the next tool result.
            if redirectStatus != "redirected", redirectStatus != "queued",
                self.sessionResumeGeneration == steeringGeneration, self.sessionID == sessionID, self.status == .working
            {
                let steered = try? await sessionRPCClient.request(
                    HermesFeatureIDs.ID.sessionSteer.rawValue,
                    params: ["session_id": sessionID, "text": submittedText]
                )
                let steerStatus = (steered?["status"] as? String)?.lowercased()
                if steerStatus == "queued" { redirectStatus = "redirected" }
                // Hermes rejects steer only when no turn is running.
                hermesHasNoLiveTurn = steerStatus == "rejected"
            }
            var redirect = self.redirectingPrompts[queueSessionID] ?? RedirectingPrompt(runtimeSessionID: sessionID)
            if redirectStatus == "queued", redirect.completedTurns < 2, !redirect.wasInterrupted {
                redirect.isQueuedByHermes = true
                self.redirectingPrompts[queueSessionID] = redirect
            } else {
                self.redirectingPrompts.removeValue(forKey: queueSessionID)
            }
            let isForeground = self.sessionResumeGeneration == steeringGeneration && self.sessionID == sessionID
            if !isForeground {
                if redirectStatus != "redirected", redirectStatus != "queued" {
                    requeueRedirect(
                        text, sessionID: queueSessionID, profileID: queueProfile, mentionProfiles: mentionProfiles)
                }
                if redirect.completedTurns > 0, !redirect.wasInterrupted {
                    if queuedPromptSessionID == queueSessionID {
                        drainQueuedPromptIfIdle()
                    } else {
                        drainBackgroundQueuedPrompt(runtimeID: sessionID)
                    }
                }
                return
            }
            switch redirectStatus {
            case "redirected":
                DebugLog.write("model: turn redirected")
                drainQueuedPromptAfterRedirect(redirect)
            case "queued":
                // Build window or compaction: Hermes runs it as the next turn.
                // The row stays where it was typed so the transcript keeps time order.
                if status == .idle, redirect.completedTurns < 2, !redirect.wasInterrupted {
                    status = .working
                    isSending = true
                }
                drainQueuedPromptAfterRedirect(redirect)
                break
            default:
                // Refused (turn ended first) or failed: keep the words as the next turn.
                messages.removeAll {
                    $0.id == correction.id
                        || ($0.id == resumedRowID && $0.id != streamingMessageID && $0.text.isEmpty
                            && $0.activity.isEmpty)
                }
                requeueRedirect(
                    text, sessionID: queueSessionID, profileID: queueProfile, mentionProfiles: mentionProfiles)
                // Replies share the event stream, so a turn end would already have
                // landed: still working here means the end was missed. Settle it so
                // the prompt sends now instead of waiting on a turn that is gone.
                if hermesHasNoLiveTurn, status == .working {
                    commitStreamingMessage()
                    endLocalTurn(eventSessionID: sessionID)
                }
                drainQueuedPromptAfterRedirect(redirect)
            }
        }
    }

    private func requeueRedirect(_ text: String, sessionID: String, profileID: String?, mentionProfiles: [String]) {
        let index = queuedPrompts.firstIndex { $0.sessionID == sessionID } ?? queuedPrompts.endIndex
        queuedPrompts.insert(
            QueuedPrompt(
                sessionID: sessionID, text: text, images: [], profileID: profileID, mentionProfiles: mentionProfiles),
            at: index)
    }

    /// A stopped turn keeps its queue, except a Send now held back by this redirect.
    private func drainQueuedPromptAfterRedirect(_ redirect: RedirectingPrompt) {
        guard !redirect.wasInterrupted || sendQueuedPromptAfterInterrupt, interruptState != .requesting else { return }
        sendQueuedPromptAfterInterrupt = false
        drainQueuedPromptIfIdle()
    }

    var isRedirectInFlight: Bool {
        queuedPromptSessionID.map { redirectingPrompts[$0] != nil } == true
    }

    /// Queue prompts a redirect can carry: text only, no slash command (desktop `isSteerableEntry`).
    func canSteerQueuedPrompt(_ prompt: QueuedPrompt) -> Bool {
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionActionsReady && status == .working && sessionID != nil && !isRedirectInFlight
            && !text.isEmpty
            && prompt.images.isEmpty && prompt.pdfURLs.isEmpty && prompt.contexts.isEmpty
            && prompt.replyQuote == nil && ComposerSlashCommand(text) == nil
            && prompt.botRecipient == nil
    }

    /// Delivers a queued prompt into the live turn. A refused redirect re-queues it.
    func steerQueuedPrompt(_ id: UUID) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }),
            canSteerQueuedPrompt(queuedPrompts[index]), let sessionID
        else { return }
        let text = queuedPrompts.remove(at: index).text.trimmingCharacters(in: .whitespacesAndNewlines)
        redirectTurn(with: text, sessionID: sessionID)
    }

    /// Prompts a steer can't carry (attachments, slash commands) jump the queue
    /// and stop the turn; the settled turn sends them (desktop `sendQueuedNow`).
    func canSendQueuedPromptNow(_ prompt: QueuedPrompt) -> Bool {
        sessionActionsReady && status == .working && sessionID != nil && interruptState != .requesting
            && !canSteerQueuedPrompt(prompt)
    }

    func sendQueuedPromptNow(_ id: UUID) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }),
            canSendQueuedPromptNow(queuedPrompts[index])
        else { return }
        queuedPrompts.insert(queuedPrompts.remove(at: index), at: 0)
        sendQueuedPromptAfterInterrupt = stop() != nil
    }

    /// Parks the whole composer payload until the active turn settles.
    func queueDraft() {
        guard sessionActionsReady, let sessionID = queuedPromptSessionID else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty || !pendingPDFURLs.isEmpty || !attachedContexts.isEmpty else {
            return
        }
        let request = ComposerMentionPresentation.botRelayRequest(in: text, profileIDs: composerMentionBots.map(\.id))
        let recipient =
            pendingImages.isEmpty && pendingPDFURLs.isEmpty && attachedContexts.isEmpty
            ? composerMentionBots.first(where: { $0.id == request?.profileID }) : nil
        queuedPrompts.append(
            QueuedPrompt(
                sessionID: sessionID, text: text, images: pendingImages, pdfURLs: pendingPDFURLs,
                contexts: attachedContexts, replyQuote: replyQuote,
                botMentions: ComposerBotMention.rebasing(composer.botMentions, from: draft, to: text),
                botRecipient: recipient, profileID: Self.normalizedProfileID(sessionProfileID ?? profileScopeID),
                mentionProfiles: composerMentionProfiles))
        draft = ""
        pendingImages = []
        pendingPDFURLs = []
        attachedContexts = []
        replyQuote = nil
        clearAttachmentErrors()
        restorePendingSendIfPossible(for: composerDraftKey)
        drainQueuedPromptIfIdle()
    }

    func removeQueuedPrompt(_ id: UUID) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return }
        cleanupImageAttachments(queuedPrompts.remove(at: index).images)
    }

    func drainQueuedPromptIfIdle() {
        guard sessionActionsReady, !isSending, status == .idle, !isRestoringSession, !isUpdatingSessionModel,
            !isUpdatingSessionFast,
            pendingBotMentions.isEmpty,
            !nativeVoiceCapture.isAwaitingPlaybackDrain,
            let sessionID, let owner = queuedPromptSessionID
        else { return }
        drainQueuedPrompt(owner: owner, runtimeID: sessionID)
    }

    func drainBackgroundQueuedPrompt(runtimeID: String) {
        let owner = rowSessionID(runtimeID)
        guard owner != queuedPromptSessionID,
            !sessionStopAttempts.contains(where: { key, attempt in
                key.sessionID == owner && attempt.outcome != .failed
            }),
            !inFlightBotActivities.values.contains(where: { $0.originSessionID == owner })
        else { return }
        drainQueuedPrompt(owner: owner, runtimeID: runtimeID)
    }

    private func drainQueuedPrompt(owner: String, runtimeID: String) {
        guard !hasShutDown, queuedSubmissions[owner] == nil, redirectingPrompts[owner] == nil,
            let index = queuedPrompts.firstIndex(where: { $0.sessionID == owner })
        else { return }
        let prompt = queuedPrompts[index]
        let usesSelectedConversation =
            prompt.botRecipient != nil
            || (prompt.images.isEmpty && prompt.pdfURLs.isEmpty && prompt.contexts.isEmpty
                && ComposerSlashCommand(prompt.text) != nil)
        if usesSelectedConversation, runtimeID != sessionID { return }
        queuedPrompts.remove(at: index)
        send(prompt, queueRuntimeID: usesSelectedConversation ? nil : runtimeID)
    }

    /// Appends outside text (Services menu) to the composer without sending it.
    func stageDraft(_ text: String) {
        draft = [draft.trimmingCharacters(in: .whitespacesAndNewlines), text].filter { !$0.isEmpty }.joined(
            separator: "\n\n")
    }

    func moveIntoComposer(_ prompt: QueuedPrompt) {
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = [current, text].filter { !$0.isEmpty }.joined(separator: "\n")
        let mentions = ComposerBotMention.rebasing(prompt.botMentions, from: prompt.text, to: text)
        composer.botMentions += mentions.map { mention in
            var mention = mention
            mention.range.location += current.isEmpty ? 0 : current.utf16.count + 1
            return mention
        }
        pendingImages.append(contentsOf: prompt.images)
        pendingPDFURLs.append(contentsOf: prompt.pdfURLs.filter { !pendingPDFURLs.contains($0) })
        attachedContexts.append(contentsOf: prompt.contexts)
        if replyQuote == nil { replyQuote = prompt.replyQuote }
    }

    /// Pulls a queued prompt back into the composer, attachments included.
    /// Sending it again re-queues it at the tail.
    func editQueuedPrompt(_ id: UUID) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return }
        moveIntoComposer(queuedPrompts.remove(at: index))
    }

    func moveQueuedPrompt(_ id: UUID, offset: Int) {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }),
            let destination = queuedPromptSessionID, queuedPrompts[index].sessionID == destination
        else { return }
        let peers = queuedPrompts.indices.filter { queuedPrompts[$0].sessionID == destination }
        guard let position = peers.firstIndex(of: index), peers.indices.contains(position + offset) else { return }
        queuedPrompts.swapAt(index, peers[position + offset])
    }

    func reorderQueuedPrompt(_ source: UUID, before target: UUID) {
        guard source != target, let from = queuedPrompts.firstIndex(where: { $0.id == source }),
            let to = queuedPrompts.firstIndex(where: { $0.id == target }),
            queuedPrompts[from].sessionID == queuedPrompts[to].sessionID
        else { return }
        let item = queuedPrompts.remove(at: from)
        queuedPrompts.insert(item, at: from < to ? to - 1 : to)
    }

    func submitComposerInput(mentionProfiles: [String]? = nil) {
        guard sessionActionsReady else { return }
        if let mentionProfiles { composerMentionProfiles = mentionProfiles }
        if status == .needsClarification {
            respondToClarification(draft)
        } else if isSending, sessionID != nil {
            steerDraft()
        } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pendingImages.isEmpty,
            pendingPDFURLs.isEmpty, attachedContexts.isEmpty
        {
            drainQueuedPromptIfIdle()
        } else {
            send()
        }
    }
}
