import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// Sends the composer draft, or a queued prompt without touching the draft.
    /// The optional callback reports RPC submission, not completion of the turn.
    func send(_ queued: QueuedPrompt? = nil, onSubmission: ((String?) -> Void)? = nil) {
        let originalText = queued?.text ?? draft
        let prompt = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedImages = queued?.images ?? pendingImages
        let attachedPDF = queued == nil ? pendingPDFURL : queued?.pdfURL
        let contexts = queued == nil ? attachedContexts : queued?.contexts ?? []
        let botMentions = ComposerBotMention.rebasing(
            queued?.botMentions ?? composer.botMentions, from: originalText, to: prompt)
        guard !prompt.isEmpty || !attachedImages.isEmpty || attachedPDF != nil || !contexts.isEmpty,
            !isSending,
            sessionActionsReady,
            !isUpdatingSessionModel, !isUpdatingSessionFast,
            !isRestoringSession,
            sessionID != nil || (newSessionCreationAuthorized && !isCreatingSession)
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

        if attachedImages.isEmpty, attachedPDF == nil, contexts.isEmpty, let command = ComposerSlashCommand(prompt) {
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
        } else if attachedPDF != nil {
            text = attachedImages.isEmpty ? "[document]" : "[attachments]"
        } else {
            text = "[image]"
        }
        let isVoiceTurn = voiceState.isNativeConversationActive && voiceSessionID == sessionID
        let richContext = generationContext()
        let submittedText = GenerativeUIIntegration.preparePrompt(
            ComposerMentionPresentation.annotatedPrompt(text, profileIDs: composerMentionProfiles), context: richContext
        )
        let sessionBeforeSend = sessionID
        let sendOwner = composerDraftKey

        let botActivityID = sessionBeforeSend.flatMap { eventSessionID in
            inFlightBotActivities.values.first { $0.botChatSessionID == eventSessionID }?.activityID
        }
        let sendGeneration = sessionResumeGeneration
        guard pendingSessionSends.count < 256 else {
            if let queued { queuedPrompts.insert(queued, at: 0) }
            messages.append(
                ChatMessage(
                    role: .hermes,
                    text: "Too many messages await confirmation. Check your conversations before sending."
                ))
            onSubmission?("Too many messages await confirmation. Check your conversations before sending.")
            return
        }
        sessionStopAttempts[sendOwner] = nil
        let snapshot = SessionComposerDraft(
            text: originalText, images: attachedImages, pdfURL: attachedPDF, contexts: contexts,
            replyQuote: queued == nil ? replyQuote : queued?.replyQuote,
            attachmentError: pendingAttachmentError, pdfError: pendingPDFError, botMentions: botMentions)
        if queued == nil {
            draft = ""
            pendingImages = []
            pendingPDFURL = nil
            attachedContexts = []
            replyQuote = nil
            clearAttachmentErrors()
            restorePendingSendIfPossible(for: sendOwner)
        }
        let visibleText = isAttachmentOnly ? "" : text
        let transcriptText =
            attachedPDF.map { "[PDF: \($0.lastPathComponent)]" + (visibleText.isEmpty ? "" : "\n\(visibleText)") }
            ?? visibleText
        let sentMessage = ChatMessage(
            role: .user, text: transcriptText, images: attachedImages.map(\.image),
            botMentions: ComposerBotMention.rebasing(botMentions, from: prompt, to: transcriptText))
        messages.append(sentMessage)
        let sendID = UUID()
        pendingSessionSends.append(
            SessionPendingSend(
                id: sendID, owner: sendOwner, snapshot: snapshot, message: sentMessage,
                baselineRowID: transcriptMessageIDsByRowID.keys.max() ?? 0))
        submittedMessageIDForPin = messages.last?.id
        status = .working
        isSending = true
        if let sessionID { turnStartedAtBySession[sessionID] = Date() }
        if voiceState.isNativeConversationActive, !isVoicePromptActive {
            nativeVoiceCapture.receivedTranscript(hasText: true)
            voiceState = .thinking
        }
        DebugLog.write("model: send started (\(prompt.count) characters, images: \(attachedImages.count))")

        Task {
            var submissionReported = false
            defer {
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
                guard self.sessionResumeGeneration == sendGeneration,
                    self.sessionID == sessionBeforeSend
                else { return }
                if sessionID == nil || pendingWorktreeDirectory != nil {
                    _ = try await createAuthorizedSession(source: HermesFeatureIDs.sessionSource)
                }
                guard let sessionID else { throw HermesGateway.GatewayError.malformedResponse }
                // Keep this operation bound to the session selected above. A
                // late resume must not redirect a prompt into another chat.
                let promptSessionID = sessionID
                guard self.sessionResumeGeneration == sendGeneration,
                    self.sessionID == promptSessionID
                else { return }
                if sessionBeforeSend == nil, let index = pendingSessionSends.firstIndex(where: { $0.id == sendID }) {
                    pendingSessionSends[index].owner = composerDraftKey
                }
                touchSession(sessionID: promptSessionID, at: Date(), preview: text)

                var fileReferences: [String] = []
                if contexts.contains(where: { $0.attachmentURL != nil }) {
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
                    guard self.sessionResumeGeneration == sendGeneration, self.sessionID == promptSessionID else {
                        return
                    }
                    let attached = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.fileAttach.rawValue,
                        params: scopedSessionParams([
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
                let outgoingText =
                    fileReferences.isEmpty
                    ? submittedText
                    : GenerativeUIIntegration.preparePrompt(
                        ComposerMentionPresentation.annotatedPrompt(
                            text + "\n\n" + fileReferences.joined(separator: "\n"), profileIDs: composerMentionProfiles),
                        context: richContext
                    )
                for attachedImage in attachedImages {
                    let base64 = try await AttachmentPayload.encoded(at: attachedImage.fileURL)
                    guard self.sessionResumeGeneration == sendGeneration,
                        self.sessionID == promptSessionID
                    else { return }
                    let attachResult = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.imageAttachBytes.rawValue,
                        params: scopedSessionParams([
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

                if let attachedPDF {
                    let base64 = try await AttachmentPayload.encoded(at: attachedPDF, maximumBytes: 25 * 1024 * 1024)
                    guard self.sessionResumeGeneration == sendGeneration,
                        self.sessionID == promptSessionID
                    else { return }
                    let result = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.pdfAttach.rawValue,
                        params: scopedSessionParams([
                            "session_id": promptSessionID,
                            "content_base64": base64,
                            "filename": attachedPDF.lastPathComponent,
                        ])
                    )
                    guard result["attached"] as? Bool == true else {
                        throw HermesGateway.GatewayError.imageAttachFailed(
                            (result["message"] as? String) ?? "Hermes could not attach the PDF."
                        )
                    }
                }

                guard self.sessionResumeGeneration == sendGeneration,
                    self.sessionID == promptSessionID
                else { return }
                let baselineAttempt = UUID()
                let baselineOrigin = QuickDestination(
                    profileID: sessionProfileID, sessionID: navigationSessionID ?? promptSessionID,
                    title: currentSessionTitle ?? "Session")
                var baselineDirectory = sessionWorkspace?.cwd ?? createdSessionProjectPaths[promptSessionID]
                if baselineDirectory == nil {
                    let origin = HermesSession(
                        id: navigationSessionID ?? promptSessionID, profileID: sessionProfileID,
                        title: currentSessionTitle ?? "Session", preview: "", startedAt: nil, messageCount: 0,
                        source: HermesFeatureIDs.sessionSource)
                    baselineDirectory = try? await HermesWorkflowRPC(
                        client: controlRPCClient, profileID: sessionProfileID
                    ).sessionDirectory(origin)
                    guard self.sessionResumeGeneration == sendGeneration, self.sessionID == promptSessionID else {
                        return
                    }
                }
                if let directory = baselineDirectory {
                    await DeveloperWorkflowModel.shared.captureTurnBaseline(
                        origin: baselineOrigin, path: directory, attemptID: baselineAttempt)
                    guard self.sessionResumeGeneration == sendGeneration, self.sessionID == promptSessionID else {
                        return
                    }
                }
                if let index = pendingSessionSends.firstIndex(where: { $0.id == sendID }) {
                    pendingSessionSends[index].phase = .submitting
                    pendingSessionSends[index].submittedText =
                        isVoiceTurn ? VoicePrompts.conversationPrompt(outgoingText) : outgoingText
                }
                let acknowledgment = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.promptSubmit.rawValue,
                    params: scopedSessionParams([
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
                }
                if accepted { cleanupImageAttachments(attachedImages) }
                submissionReported = true
                onSubmission?(
                    accepted ? nil : "Herm could not confirm submission. Check the conversation before retrying.")
                guard self.sessionResumeGeneration == sendGeneration,
                    self.sessionID == promptSessionID
                else { return }
                if !accepted {
                    messages.append(
                        ChatMessage(
                            role: .hermes,
                            text: "Herm could not confirm submission. Check the conversation before retrying."))
                }
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
                else { return }
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
                messages.append(ChatMessage(role: .hermes, text: message, modelName: currentModelName))
                if let botActivityID {
                    markBotActivityFailed(id: botActivityID, result: message)
                }
                status = transportFailure ? .offline : .idle
                isSending = false
                submissionReported = true
                onSubmission?(message)
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
            pendingImages.isEmpty, pendingPDFURL == nil, attachedContexts.isEmpty, replyQuote == nil,
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
            guard self.sessionResumeGeneration == steeringGeneration,
                self.sessionID == sessionID
            else { return }
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
                let index = queuedPrompts.firstIndex { $0.sessionID == queueSessionID } ?? queuedPrompts.endIndex
                queuedPrompts.insert(
                    QueuedPrompt(sessionID: queueSessionID, text: text, images: [], pdfURL: nil), at: index)
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
            && prompt.images.isEmpty && prompt.pdfURL == nil && prompt.contexts.isEmpty
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
        guard !text.isEmpty || !pendingImages.isEmpty || pendingPDFURL != nil || !attachedContexts.isEmpty else {
            return
        }
        let request = ComposerMentionPresentation.botRelayRequest(in: text, profileIDs: composerMentionBots.map(\.id))
        let recipient =
            pendingImages.isEmpty && pendingPDFURL == nil && attachedContexts.isEmpty
            ? composerMentionBots.first(where: { $0.id == request?.profileID }) : nil
        queuedPrompts.append(
            QueuedPrompt(
                sessionID: sessionID, text: text, images: pendingImages, pdfURL: pendingPDFURL,
                contexts: attachedContexts, replyQuote: replyQuote,
                botMentions: ComposerBotMention.rebasing(composer.botMentions, from: draft, to: text),
                botRecipient: recipient))
        draft = ""
        pendingImages = []
        pendingPDFURL = nil
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

    /// Sends the oldest queued prompt of the open session, one per settled turn.
    func drainQueuedPromptIfIdle() {
        guard sessionActionsReady, !isSending, status == .idle, !isRestoringSession, !isUpdatingSessionModel,
            !isUpdatingSessionFast,
            pendingBotMentions.isEmpty,
            !nativeVoiceCapture.isAwaitingPlaybackDrain,
            sessionID != nil, let sessionID = queuedPromptSessionID,
            redirectingPrompts[sessionID] == nil,
            let index = queuedPrompts.firstIndex(where: { $0.sessionID == sessionID })
        else { return }
        send(queuedPrompts.remove(at: index))
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
        if pendingPDFURL == nil { pendingPDFURL = prompt.pdfURL }
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
            pendingPDFURL == nil, attachedContexts.isEmpty
        {
            drainQueuedPromptIfIdle()
        } else {
            send()
        }
    }
}
