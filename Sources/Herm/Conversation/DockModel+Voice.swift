import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// Starts Hermes' native VAD/TTS voice loop. Hermes owns the microphone,
    /// transcription, streaming speech, and spoken barge-in for this mode.
    /// If the locally installed CLI is missing those optional dependencies, the
    /// Dock keeps its existing Apple speech-recognition flow as a clear fallback.
    func startVoiceConversation() {
        guard !isRestoringSession else { return }
        guard sessionID != nil || (newSessionCreationAuthorized && !isCreatingSession) else { return }
        guard voiceState == .inactive || {
            if case .localFallback = voiceState { return true }
            return false
        }() else { return }
        guard !voiceState.isNativeConversationActive else { return }
        voiceConversationGeneration &+= 1
        let generation = voiceConversationGeneration
        nativeVoiceCapture.reset()
        voiceState = .preparing

        Task {
            do {
                try await sessionRPCClient.connect()
                guard voiceConversationGeneration == generation else { return }
                if sessionID == nil {
                    _ = try await createAuthorizedSession(source: "herm")
                }
                guard sessionID != nil else { throw HermesGateway.GatewayError.malformedResponse }
                guard voiceConversationGeneration == generation else { return }

                let requirements = try await sessionRPCClient.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "status"])
                guard voiceConversationGeneration == generation else { return }
                guard (requirements["available"] as? Bool) != false,
                      (requirements["stt_available"] as? Bool) != false else {
                    let detail = Self.safeUserDiagnostic(
                        (requirements["details"] as? String) ?? "Hermes voice dependencies are unavailable."
                    )
                    voiceState = .localFallback(detail)
                    return
                }

                let enabled = try await sessionRPCClient.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "on"])
                guard voiceConversationGeneration == generation else { return }
                if (enabled["tts"] as? Bool) != true {
                    _ = try await sessionRPCClient.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "tts"])
                }
                // Before the first capture picks its path: without an answer
                // yet, turn one fell to Hermes' recorder and never ended.
                await MicLevelMeter.askForSpeechPermission()
                guard voiceConversationGeneration == generation else { return }
                voiceRepliesEnabled = true
                isVoiceMicMuted = false
                skipNextVoicePlaybackDrain = false
                localVoiceTranscriptionFailed = false
                voiceFollowUpArmed = false
                voiceTelemetry.beginListening()
                voiceState = .listening
                armNativeVoiceCapture()
            } catch {
                guard voiceConversationGeneration == generation else { return }
                DebugLog.write("voice: Hermes native voice unavailable: \(Self.safeUserDiagnostic(error.localizedDescription))")
                voiceState = .localFallback(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    /// Creates a backend session only for a New Chat that the user explicitly
    /// requested. Keeping this transition centralized prevents commands such
    /// as send, control prompts, and voice startup from silently creating chats
    /// after startup restoration or a failed resume.
    func createAuthorizedSession(source: String) async throws -> String {
        if let sessionID { return sessionID }
        guard newSessionCreationAuthorized else {
            throw NSError(
                domain: "Herm",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Start a new chat before sending a message."]
            )
        }
        guard !isCreatingSession else {
            throw NSError(
                domain: "Herm",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "The new chat is still starting."]
            )
        }

        let project = newSessionProjectPath
        if sessionModelOptionID == nil, let project, let preferred = ProjectPreferences.shared.modelID(project),
           !runtimeModelOptions.contains(where: { $0.id == preferred }) {
            throw QuickDraftError.message("The preferred project model is unavailable. Select an available model before sending. Your draft is kept.")
        }
        isCreatingSession = true
        defer { isCreatingSession = false }
        var createParams: [String: Any] = ["source": source]
        if let profileID = profileScopeID, !profileID.isEmpty {
            createParams["profile"] = profileID
        }
        if let newSessionProjectPath, !newSessionProjectPath.isEmpty {
            createParams["cwd"] = newSessionProjectPath
        }
        // Hermes rejects sessionless model switches; a new-chat pick rides on
        // session.create as a per-session override instead.
        if let id = sessionModelOptionID ?? project.flatMap({ ProjectPreferences.shared.modelID($0) }),
           let option = runtimeModelOptions.first(where: { $0.id == id }) {
            createParams["model"] = option.model
            createParams["provider"] = option.provider
        }
        if let defaultReasoningVariant {
            createParams["reasoning_effort"] = defaultReasoningVariant.rawValue
        }
        let result = try await sessionRPCClient.request(HermesFeatureIDs.ID.sessionCreate.rawValue, params: createParams)
        guard let createdSessionID = result["session_id"] as? String,
              !createdSessionID.isEmpty else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        if let newSessionProjectPath, !newSessionProjectPath.isEmpty {
            createdSessionProjectPaths[createdSessionID] = newSessionProjectPath
        }
        sessionID = createdSessionID
        sessionProfileID = profileScopeID
        sessionStorageID = Self.stableSessionID(from: result) ?? createdSessionID
        storageIDsByRuntimeID[createdSessionID] = sessionStorageID
        kanbanAttributionSessionID = createdSessionID
        persistActiveSessionID(sessionID)
        let model = (result["model"] as? String) ?? (result["model_name"] as? String)
        if let model {
            currentModelName = model
            sessionModelValue = model
        }
        newSessionCreationAuthorized = false
        newSessionProjectPath = nil
        refreshSessionModelOptions()
        refreshSessionReasoningVariant()
        refreshDelegationStatus()
        startDelegationMonitoring()
        DebugLog.write("model: session created (id present: true)")
        return createdSessionID
    }

    func stopVoiceConversation() {
        voiceConversationGeneration &+= 1
        let wasNative = voiceState.isNativeConversationActive
        skipNextVoicePlaybackDrain = false
        isVoicePromptActive = false
        speakReplyAfterVoicePrompt = false
        isVoiceMicMuted = false
        nativeVoiceCapture.reset()
        voiceState = .inactive
        guard wasNative else { return }
        Task {
            if let sessionID {
                _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: ["action": "stop", "session_id": sessionID])
            }
            _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "off"])
        }
    }

    /// Hermes consumes a bare stop phrase without starting a model turn.
    /// Its acknowledgment is the terminal boundary for that submission.
    func finishVoiceStopSubmission() {
        stopVoiceConversation()
        guard streamingMessageID == nil else { return }
        isSending = false
        status = .idle
        conversationActivityPhase = .idle
    }

    /// Ends the current utterance now instead of waiting for Hermes' VAD
    /// silence window (`voice.silence_duration`, 3s by default). `transcript`
    /// is Herm's on-device text; nil means that recognizer failed.
    /// `overPlayback`: audio was playing meanwhile, so it may be our own reply.
    func finishVoiceUtterance(transcript: String?, overPlayback: Bool = false) {
        if voiceState == .paused {
            // Asleep: only "hey <name>" wakes it, optionally with the request.
            guard !isVoiceMicMuted, let transcript,
                  let request = VoicePrompts.afterWakePhrase(transcript, name: agentDisplayName) else { return }
            wakeCount += 1
            resumeVoiceListening()
            if !request.isEmpty { finishVoiceUtterance(transcript: request) }
            return
        }
        // Speaking while Hermes works steers the running turn, like typing does.
        guard voiceState == .listening || voiceState == .thinking, let sessionID else { return }
        if voiceState == .thinking {
            guard let spoken = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !spoken.isEmpty,
                  !isVoicePromptActive, !(overPlayback && VoicePrompts.isEcho(spoken, of: lastVoiceSpeech)) else { return }
            if isSending, status == .working, !hasQueuedOrRedirectingPrompt {
                redirectTurn(with: spoken, sessionID: sessionID)
            } else {
                queuedPrompts.append(QueuedPrompt(sessionID: queuedPromptSessionID ?? sessionID, text: spoken, images: [], pdfURL: nil))
                drainQueuedPromptIfIdle()
            }
            return
        }
        if nativeCaptureIsLocal {
            guard let transcript else { return fallBackToHermesTranscription() }
            let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }
            // The speakers were on and the words are Hermes' own: an echo, not the user.
            if overPlayback, VoicePrompts.isEcho(spoken, of: lastVoiceSpeech) {
                DebugLog.write("voice: dropped an utterance that echoed the reply")
                return
            }
            nativeVoiceCapture.receivedTranscript(hasText: true)
            voiceTelemetry.receivedTranscript()
            if isVoicePromptActive {
                if let retry = answerVoicePrompt(spoken) {
                    presentVoicePrompt(retry)
                } else {
                    voiceState = .thinking
                }
            } else {
                submitNativeVoiceTranscript(spoken)
            }
            return
        }
        voiceState = .transcribing
        Task {
            _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: ["action": "stop", "session_id": sessionID])
        }
    }

    /// Cuts Hermes off mid-thought or mid-sentence. `session.interrupt` also
    /// silences Hermes' streaming TTS, so one request covers both phases.
    func interruptVoiceTurn() {
        switch voiceState {
        case .thinking:
            skipNextVoicePlaybackDrain = true
            _ = stop()
        case .speaking:
            _ = stop()
            resumeVoiceListening(force: true)
        default:
            break
        }
    }

    /// Ends a quiet follow-up window so side conversations aren't sent to the
    /// agent. Herm keeps listening on-device for the wake phrase only.
    func sleepVoiceConversation() {
        guard voiceState == .listening, nativeCaptureIsLocal, voiceFollowUpArmed,
              !isVoicePromptActive, !isSending else { return }
        nativeVoiceCapture.reset()
        voiceState = .paused
        NSSound(named: "Pop")?.play()
    }

    /// Speech heard while a reply plays cuts it off, like tapping the orb.
    func bargeInVoiceReply(heard: String) {
        guard voiceState == .speaking, !isVoicePromptActive else { return }
        let reply = (messages.last { $0.role == .hermes }?.text ?? "") + " " + streamingText.text
        guard VoicePrompts.isBargeIn(heard, over: reply) else { return }
        interruptVoiceTurn()
    }

    /// Re-opens the microphone after a no-speech pause (or a cut-off reply).
    func resumeVoiceListening(force: Bool = false) {
        guard voiceState == .paused || force, voiceState.isNativeConversationActive else { return }
        isVoiceMicMuted = false
        nativeVoiceCapture.reset()
        voiceState = .listening
        armNativeVoiceCapture()
    }

    /// Muting mid-utterance discards it: the forced stop's transcript lands
    /// while paused and is dropped. Every re-arm path checks the flag.
    func toggleVoiceMicMuted() {
        guard voiceState.isNativeConversationActive else { return }
        guard !isVoiceMicMuted else {
            // Mid-turn, the playback drain re-arms once the reply ends.
            isVoiceMicMuted = false
            resumeVoiceListening()
            return
        }
        isVoiceMicMuted = true
        guard voiceState == .listening, let sessionID else { return }
        nativeVoiceCapture.reset()
        voiceState = .paused
        Task {
            _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: ["action": "stop", "session_id": sessionID])
        }
    }

    func toggleVoiceReplies() {
        guard voiceState.isNativeConversationActive else { return }
        let generation = voiceConversationGeneration
        voiceRepliesEnabled.toggle()
        Task {
            let result = try? await sessionRPCClient.request(HermesFeatureIDs.ID.voiceToggle.rawValue, params: ["action": "tts"])
            guard voiceConversationGeneration == generation else { return }
            if let tts = result?["tts"] as? Bool { voiceRepliesEnabled = tts }
        }
    }

    /// Whether voice mode asks approvals and questions aloud and takes spoken answers.
    var answersVoicePromptsAloud: Bool {
        !localVoiceTranscriptionFailed && MicLevelMeter.canTranscribe
    }

    /// What voice mode reads aloud for a pending approval or clarify question.
    var voicePromptSpeech: String? {
        if let approvalText {
            return VoicePrompts.approvalSpeech(
                title: approvalTitle ?? "Review requested action",
                detail: approvalText,
                choices: approvalDetails?.choices ?? ApprovalChoice.all
            )
        }
        guard status == .needsClarification, let clarificationQuestion else { return nil }
        return VoicePrompts.clarificationSpeech(
            question: clarificationQuestion,
            choices: clarificationChoices,
            multiSelect: clarificationMultiSelect,
            progress: clarificationProgress
        )
    }

    /// Reads a pending prompt aloud and then listens for the answer; nil ends
    /// prompt mode once the approval or question is resolved.
    func presentVoicePrompt(_ speech: String?) {
        guard voiceState.isNativeConversationActive else { return }
        guard let speech else {
            guard isVoicePromptActive else { return }
            isVoicePromptActive = false
            enqueueVoiceRequest(HermesFeatureIDs.ID.voiceToggle.rawValue, ["action": "on"])
            if voiceRepliesEnabled {
                enqueueVoiceRequest(HermesFeatureIDs.ID.voiceToggle.rawValue, ["action": "tts"])
            }
            if isSending || status == .working {
                // The turn resumes; hold the microphone until its reply ends.
                speakReplyAfterVoicePrompt = voiceRepliesEnabled
                nativeVoiceCapture.receivedTranscript(hasText: true)
                voiceState = .thinking
            } else {
                resumeVoiceListening(force: true)
            }
            return
        }
        guard answersVoicePromptsAloud else { return }
        if !isVoicePromptActive {
            isVoicePromptActive = true
            // Hermes keeps its barge-in listener live while a turn is blocked on
            // a prompt, so a spoken answer would interrupt the turn instead of
            // answering it. Voice mode off parks that listener.
            enqueueVoiceRequest(HermesFeatureIDs.ID.voiceToggle.rawValue, ["action": "off"])
        }
        guard voiceRepliesEnabled else { return resumeVoiceListening(force: true) }
        voiceState = .speaking
        enqueueVoiceRequest(HermesFeatureIDs.ID.voiceTTS.rawValue, ["text": speech])
        awaitNativeVoicePlaybackDrain(generation: nativeVoiceCapture.completedResponse(), responseText: speech)
    }

    /// Routes a spoken answer to the pending approval or question. Returns a
    /// re-prompt when the answer was not understood.
    func answerVoicePrompt(_ spoken: String) -> String? {
        if approvalText != nil {
            guard let choice = VoicePrompts.approvalChoice(
                for: spoken,
                choices: approvalDetails?.choices ?? ApprovalChoice.all
            ) else { return VoicePrompts.approvalRetry }
            respondToApproval(choice)
            return nil
        }
        guard status == .needsClarification, clarificationQuestion != nil else { return nil }
        let reply = VoicePrompts.clarificationAnswer(
            for: spoken,
            choices: clarificationChoices,
            multiSelect: clarificationMultiSelect
        )
        respondToClarification(reply.answer, displayText: reply.display)
        return nil
    }

    func fallBackToHermesTranscription() {
        DebugLog.write("voice: on-device recognition failed; using Hermes transcription")
        localVoiceTranscriptionFailed = true
        nativeVoiceCapture.reset()
        if isVoicePromptActive {
            // Hermes' recorder needs voice mode back on; the prompt card takes over.
            presentVoicePrompt(nil)
            voiceState = .paused
        } else {
            armNativeVoiceCapture()
        }
    }

    func enqueueVoiceRequest(_ method: String, _ params: [String: Any]) {
        let previous = voiceRequestChain
        nonisolated(unsafe) let params = params
        voiceRequestChain = Task {
            await previous?.value
            _ = try? await sessionRPCClient.request(method, params: params)
        }
    }

    func armNativeVoiceCapture(generation expectedGeneration: Int? = nil) {
        if let expectedGeneration, !nativeVoiceCapture.isCurrent(generation: expectedGeneration) {
            return
        }
        if isVoiceMicMuted, voiceState.isNativeConversationActive {
            voiceState = .paused
            return
        }
        // A blocked turn is still "sending"; prompt mode listens for its answer.
        guard voiceState.isNativeConversationActive,
              !isSending || isVoicePromptActive,
              let sessionID,
              nativeVoiceCapture.beginCapture() else { return }
        let captureGeneration = nativeVoiceCapture.generation
        nativeCaptureIsLocal = isVoicePromptActive || answersVoicePromptsAloud
        if nativeCaptureIsLocal {
            // Herm's mic meter transcribes this turn live and ends it.
            nativeVoiceCapture.captureStarted()
            voiceState = .listening
            return
        }

        Task {
            do {
                let recording = try await sessionRPCClient.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: ["action": "start", "session_id": sessionID])
                guard nativeVoiceCapture.isCurrent(generation: captureGeneration),
                      voiceState.isNativeConversationActive else { return }
                if (recording["status"] as? String) == "busy" {
                    let shouldRetry = nativeVoiceCapture.captureStartFailed()
                    if shouldRetry {
                        try? await Task.sleep(for: .milliseconds(300))
                        armNativeVoiceCapture(generation: captureGeneration)
                    } else {
                        // Pausing keeps Hermes' voice; the local fallback would
                        // switch replies to the system voice mid-conversation.
                        DebugLog.write("voice: Hermes microphone stayed busy; pausing")
                        voiceState = .paused
                    }
                    return
                }
                nativeVoiceCapture.captureStarted()
                voiceState = .listening
            } catch {
                guard nativeVoiceCapture.isCurrent(generation: captureGeneration),
                      voiceState.isNativeConversationActive else { return }
                let shouldRetry = nativeVoiceCapture.captureStartFailed()
                if shouldRetry {
                    try? await Task.sleep(for: .milliseconds(300))
                    armNativeVoiceCapture(generation: captureGeneration)
                } else {
                    DebugLog.write("voice: capture failed to start; pausing: \(Self.safeUserDiagnostic(error.localizedDescription))")
                    voiceState = .paused
                }
            }
        }
    }

    func recoverNativeVoiceCaptureIfInterruptedTranscriptIsMissing(generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  self.voiceState.isNativeConversationActive,
                  self.nativeVoiceCapture.interruptionTimedOut(generation: generation) else { return }
            self.voiceState = .listening
            self.armNativeVoiceCapture()
        }
    }

    func awaitNativeVoicePlaybackDrain(generation: Int, responseText: String) {
        lastVoiceSpeech = responseText
        let delay = NativeVoicePlaybackDrain.estimatedDuration(for: responseText)
        let formattedDelay = String(format: "%.1f", delay)
        DebugLog.write("voice: holding microphone up to \(formattedDelay)s while TTS drains")
        Task { [weak self] in
            var gate = NativeVoicePlaybackGate(startedAt: ProcessInfo.processInfo.systemUptime, cap: delay)
            repeat {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.nativeVoiceCapture.isCurrent(generation: generation) else { return }
            } while !gate.isDrained(
                outputRunning: NativeVoicePlaybackGate.isOutputRunning() ?? true,
                at: ProcessInfo.processInfo.systemUptime
            )
            guard let self,
                  self.voiceState.isNativeConversationActive,
                  self.nativeVoiceCapture.playbackDrainCompleted(generation: generation) else { return }
            self.voiceTelemetry.beginListening()
            self.voiceState = .listening
            self.drainQueuedPromptIfIdle()
            self.armNativeVoiceCapture()
        }
    }

    func submitNativeVoiceTranscript(_ text: String) {
        guard let sessionID, !isSending else { return }
        let requestGeneration = sessionResumeGeneration
        messages.append(ChatMessage(role: .user, text: text))
        status = .working
        isSending = true
        voiceFollowUpArmed = true
        voiceState = .thinking
        voiceTelemetry.submittedRequest()
        Task {
            do {
                let acknowledgment = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.promptSubmit.rawValue,
                    params: ["session_id": sessionID, "text": GenerativeUIIntegration.preparePrompt(text)]
                )
                guard self.sessionResumeGeneration == requestGeneration,
                      self.sessionID == sessionID else { return }
                if acknowledgment["voice_stopped"] as? Bool == true { finishVoiceStopSubmission() }
            } catch {
                guard self.sessionResumeGeneration == requestGeneration,
                      self.sessionID == sessionID else { return }
                messages.append(ChatMessage(role: .hermes, text: "I couldn’t submit the voice request: \(Self.safeUserDiagnostic(error.localizedDescription))", modelName: currentModelName))
                status = .offline
                isSending = false
                nativeVoiceCapture.reset()
                voiceState = .listening
                armNativeVoiceCapture()
            }
        }
    }
}
