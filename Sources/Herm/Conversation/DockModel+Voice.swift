import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

extension DockModel {
    /// Local recognition starts without probing unused backend audio devices.
    /// Hermes synthesizes replies; Herm owns playback for this session only.
    func startVoiceConversation(initialRequest: String? = nil) {
        guard !hasShutDown, sessionActionsReady, !isRestoringSession else { return }
        guard sessionID != nil || (!isNotchVoiceConversation && newSessionCreationAuthorized && !isCreatingSession)
        else { return }
        guard
            voiceState == .inactive
                || {
                    if case .localFallback = voiceState { return true }
                    return false
                }()
        else { return }
        guard !voiceState.isNativeConversationActive else { return }
        voiceConversationGeneration &+= 1
        let generation = voiceConversationGeneration
        voiceSessionID = sessionID
        voiceProfileID = sessionProfileID ?? profileScopeID
        nativeVoiceCapture.reset()
        stopVoiceAnnouncement()
        let previousRecorder = voiceCapture.claim(self)
        voiceState = .preparing
        pendingWakeRequest = initialRequest ?? pendingWakeRequest

        Task {
            do {
                await previousRecorder?.value
                guard voiceConversationGeneration == generation else { return }
                await MicLevelMeter.askForSpeechPermission()
                guard voiceConversationGeneration == generation else { return }
                try await sessionRPCClient.connect()
                guard voiceConversationGeneration == generation else { return }
                if sessionID == nil || pendingWorktreeDirectory != nil {
                    _ = try await createAuthorizedSession(source: HermesFeatureIDs.sessionSource)
                }
                guard sessionID != nil else { throw HermesGateway.GatewayError.malformedResponse }
                guard voiceConversationGeneration == generation else { return }
                voiceSessionID = sessionID

                if isNotchVoiceConversation && !voiceAssistant.hasRecognition() {
                    restoreLocalAssistantAfterHandoff()
                    return
                }
                if !isNotchVoiceConversation && !canTranscribeVoice() {
                    let requirements = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.voiceToggle.rawValue, params: scopedSessionParams(["action": "status"]))
                    guard voiceConversationGeneration == generation else { return }
                    guard (requirements["available"] as? Bool) == true,
                        (requirements["stt_available"] as? Bool) == true
                    else {
                        voiceState = .localFallback(
                            Self.safeUserDiagnostic(
                                (requirements["details"] as? String) ?? "Hermes voice dependencies are unavailable."))
                        return
                    }
                }
                voiceRepliesEnabled = true
                isVoiceMicMuted = false
                skipNextVoicePlaybackDrain = false
                voiceReplySilenced = false
                localVoiceTranscriptionFailed = false
                retriedLocalVoiceTranscription = false
                voiceTelemetry.beginListening()
                KokoroVoice.prewarmIfSelected()
                voiceState = isSending ? .thinking : .listening
                if !isSending { armNativeVoiceCapture() }
            } catch {
                guard voiceConversationGeneration == generation else { return }
                DebugLog.write(
                    "voice: Hermes native voice unavailable: \(Self.safeUserDiagnostic(error.localizedDescription))")
                if isNotchVoiceConversation, initialRequest != nil {
                    restoreLocalAssistantAfterHandoff()
                    return
                }
                voiceState = .localFallback(Self.safeUserDiagnostic(error.localizedDescription))
            }
        }
    }

    func confirmPendingWorktree(sessionID: String) async throws -> String {
        guard let expected = pendingWorktreeDirectory else { return sessionID }
        let generation = sessionResumeGeneration
        let owner = sessionStorageID ?? sessionID
        let result = try await sessionRPCClient.request(
            HermesFeatureIDs.ID.sessionResume.rawValue,
            params: scopedSessionParams(["session_id": sessionID], profileID: sessionProfileID))
        guard generation == sessionResumeGeneration, self.sessionID == sessionID else { throw CancellationError() }
        let runtime = result["session_id"] as? String ?? sessionID
        let info = result["info"] as? [String: Any] ?? [:]
        let directory = (result["cwd"] as? String) ?? (info["cwd"] as? String)
        let stored = Self.stableSessionID(from: result)
        let reportedProfile = (result["profile"] as? String) ?? (info["profile_name"] as? String)
        guard
            runtime == sessionID
                || Self.resumeResponseProvesSessionOwnership(
                    requestedSessionID: owner, resolvedSessionID: runtime, result: result),
            stored == nil || stored == owner,
            reportedProfile == nil || reportedProfile == (sessionProfileID ?? profileScopeID ?? "default"),
            let directory, directory.hasPrefix("/"),
            URL(fileURLWithPath: directory).standardizedFileURL.path
                == URL(fileURLWithPath: expected).standardizedFileURL.path
        else {
            throw QuickDraftError.message("Hermes could not confirm the worktree folder. Retry before sending.")
        }
        self.sessionID = runtime
        kanbanAttributionSessionID = runtime
        persistActiveSessionID(runtime)
        storageIDsByRuntimeID[runtime] = owner
        createdSessionProjectPaths[runtime] = expected
        pendingWorktreeDirectories[WorkspaceIdentity.session(profileID: sessionProfileID, sessionID: owner)] = nil
        pendingWorktreeDirectory = nil
        applySessionWorkspace(result, owner: runtime)
        return runtime
    }

    /// Creates a backend session only for a New Chat that the user explicitly
    /// requested. Keeping this transition centralized prevents commands such
    /// as send, control prompts, and voice startup from silently creating chats
    /// after startup restoration or a failed resume.
    func createAuthorizedSession(source: String) async throws -> String {
        if let sessionID {
            return try await confirmPendingWorktree(sessionID: sessionID)
        }
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

        isCreatingSession = true
        defer { isCreatingSession = false }
        let generation = sessionResumeGeneration
        // A quick send from a fresh draft must use the same catalog as the composer.
        if sessionModelOptionID != nil || draftReasoningVariant != nil {
            await runtimeModelOptionsTask?.value
            try Task.checkCancellation()
            guard sessionResumeGeneration == generation else { throw CancellationError() }
        }
        var createParams: [String: Any] = ["source": source]
        if let profileID = profileScopeID, !profileID.isEmpty {
            createParams["profile"] = profileID
        }
        if let newSessionProjectPath, !newSessionProjectPath.isEmpty {
            createParams["cwd"] = newSessionProjectPath
            if pendingWorktreeDirectory != nil { createParams["cwd_explicit"] = true }
        }
        // Hermes rejects sessionless model switches; a new-chat pick rides on
        // session.create as a per-session override instead.
        let option =
            runtimeModelOptionsError == nil
            ? runtimeModelOptions.first(where: { $0.id == sessionModelOptionID }) : nil
        if let option {
            createParams["model"] = option.model
            createParams["provider"] = option.provider
        }
        if let draftReasoningVariant,
            effortCatalog?.choices(for: option?.id ?? defaultModelOptionID)?.contains(draftReasoningVariant)
                == true
        {
            createParams["reasoning_effort"] = draftReasoningVariant.rawValue
        }
        let result = try await sessionRPCClient.request(
            HermesFeatureIDs.ID.sessionCreate.rawValue, params: createParams)
        guard sessionResumeGeneration == generation else { throw CancellationError() }
        guard let createdSessionID = result["session_id"] as? String,
            !createdSessionID.isEmpty
        else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        if let newSessionProjectPath, !newSessionProjectPath.isEmpty {
            createdSessionProjectPaths[createdSessionID] = newSessionProjectPath
        }
        sessionID = createdSessionID
        sessionProfileID = profileScopeID
        sessionStorageID = Self.stableSessionID(from: result) ?? createdSessionID
        storageIDsByRuntimeID[createdSessionID] = sessionStorageID
        if let pendingWorktreeDirectory {
            let key = WorkspaceIdentity.session(profileID: sessionProfileID, sessionID: sessionStorageID)
            pendingWorktreeDirectories[key] = pendingWorktreeDirectory
        }
        applySessionWorkspace(result, owner: createdSessionID)
        kanbanAttributionSessionID = createdSessionID
        persistActiveSessionID(sessionID)
        let model = (result["model"] as? String) ?? (result["model_name"] as? String)
        if let model { currentModelName = model }
        sessionModelOptionID = option?.id
        sessionModelValue = model ?? option?.displayName
        newSessionCreationAuthorized = false
        if newSessionProjectWasPicked, let path = newSessionProjectPath, let stableID = sessionStorageID {
            onPickedProjectSessionCreated?(stableID, path)
        }
        newSessionProjectWasPicked = false
        newSessionProjectPath = nil
        refreshSessionModelOptions()
        refreshSessionReasoningVariant()
        refreshSessionFast()
        refreshDelegationStatus()
        startDelegationMonitoring()
        DebugLog.write("model: session created (id present: true)")
        return try await confirmPendingWorktree(sessionID: createdSessionID)
    }

    func stopVoiceConversation() {
        defer { voiceCapture.release(self) }
        voiceStage.localVisual = nil
        voiceAssistant.reset()
        voiceStage.clearLiveVisual()
        voiceStage.previewNavigation = .init()
        if isNotchVoiceConversation { lastVoiceSpeech = "" }
        voiceConversationGeneration &+= 1
        discardPreparingVoiceSubmission()
        voiceRevealedTab = nil
        voiceStage.screenContext = nil
        let recorderID = voiceRecorderSessionID
        let profile = voiceProfileID ?? "default"
        voiceSessionID = nil
        voiceProfileID = nil
        voiceRecorderSessionID = nil
        voiceRecorderEnabled = false
        voiceCompletionAnnouncements.removeAll()
        stopVoicePlayback()
        skipNextVoicePlaybackDrain = false
        voiceReplySilenced = false
        isVoicePromptActive = false
        isVoiceMicMuted = false
        nativeVoiceCapture.reset()
        voiceState = .inactive
        guard let recorderID else { return }
        let previous = voiceRequestChain
        voiceRequestChain = Task {
            await previous?.value
            guard !hasShutDown else { return }
            _ = try? await sessionRPCClient.request(
                HermesFeatureIDs.ID.voiceRecord.rawValue,
                params: ["action": "stop", "session_id": recorderID, "profile": profile])
            _ = try? await sessionRPCClient.request(
                HermesFeatureIDs.ID.slashExec.rawValue,
                params: ["command": "voice off", "session_id": recorderID, "profile": profile])
        }
    }

    @discardableResult
    private func discardPreparingVoiceSubmission() -> Bool {
        guard let preparingVoiceMessageID else { return false }
        self.preparingVoiceMessageID = nil
        messages.removeAll { $0.id == preparingVoiceMessageID }
        isSending = false
        status = isHermesConnected ? .idle : .offline
        conversationActivityPhase = .idle
        voiceStage.screenContext = nil
        return true
    }

    func interruptPreparingVoiceSubmission() -> Bool {
        guard discardPreparingVoiceSubmission() else { return false }
        sendQueuedPromptAfterInterrupt = false
        voiceAssistant.stopAcknowledgment(keepEcho: true)
        skipNextVoicePlaybackDrain = false
        voiceReplySilenced = false
        resumeVoiceListening(force: true)
        return true
    }

    /// On-device calls carry over to another Bot; a Hermes recorder is bound to its session.
    var canHandOffVoice: Bool {
        voiceState.isNativeConversationActive && voiceState != .preparing && voiceRecorderSessionID == nil
            && !voiceAssistant.isLocal
            && voiceSessionID != nil
    }

    /// Moves the live call to the next conversation before the session switch would end it.
    /// The previous Bot's turn keeps running in its own chat; only its playback is cut.
    func rebindVoice(sessionID: String, profileID: String?) {
        discardPreparingVoiceSubmission()
        voiceConversationGeneration &+= 1
        voiceAssistant.stopAcknowledgment()
        voiceRevealedTab = nil
        voiceStage.screenContext = nil
        voiceCompletionAnnouncements.removeAll()
        skipNextVoicePlaybackDrain = false
        voiceReplySilenced = false
        isVoicePromptActive = false
        stopVoicePlayback()
        nativeVoiceCapture.reset()
        // Hermes' `/voice on` is per session; the next Bot's chat has not had it.
        voiceRecorderEnabled = false
        voiceSessionID = sessionID
        voiceProfileID = profileID
    }

    /// Acknowledges the switch, then the mic reopens for the next request.
    func greetVoiceHandoff() {
        guard voiceState.isNativeConversationActive else { return }
        voiceState = .listening
        if voiceRepliesEnabled {
            speakNativeVoiceReply("Switched bots. Go ahead.")
        } else {
            resumeVoiceListening(force: true)
        }
    }

    var voiceBot: BotSummary? {
        // The notch already shares the workspace roster. Microphone startup can run before any roster is loaded.
        guard isNotchVoiceConversation || isBotModeLoaded else { return nil }
        let profileID = activeBotProfileID ?? voiceProfileID ?? sessionProfileID
        return botMode.voiceBot(profileID: profileID ?? (isNotchVoiceConversation ? "default" : profileScopeID))
    }

    /// The first name is shown to the user. The rest keep the default phrase working.
    var voiceWakeNames: [String] { VoiceWakeShortcut.wakeNames(botName: voiceBot?.name) }
    var voiceWakeName: String { voiceWakeNames[0] }

    /// Asleep, the mic hears only "hey <name>", and only on-device.
    var voiceWakesByVoice: Bool {
        answersVoicePromptsAloud && MicLevelMeter.canDetectWakePhrase
    }

    /// Opt-in: with no call open, the mic still hears "hey <name>" on-device.
    var listensForIdleWake: Bool {
        voiceState == .inactive && appliedIdleWake && voiceCapture.owner == nil && MicLevelMeter.canDetectWakePhrase
    }

    /// Re-primes wake listening when its name or enabled preference changes.
    func refreshIdleWake(suspended: Bool = false) {
        let wanted = !suspended && !hasShutDown && VoiceWakeShortcut.wakeWordEnabled
        let wakeWordChanged = wanted != appliedIdleWake
        appliedIdleWake = wanted
        let listeningForWake = (voiceState == .inactive && wanted) || (voiceState == .paused && !isVoiceMicMuted)
        let wakePhraseChanged = listeningForWake && voiceMic.vocabulary.first != "Hey \(voiceWakeName)"
        if wakePhraseChanged || (voiceState == .inactive && wakeWordChanged) { syncVoiceCapture() }
    }

    /// Points the shared mic at the current voice state. Runs on every state
    /// or mute change, so no view has to be mounted for voice to work.
    func syncVoiceCapture(preservingUtterance: Bool = false) {
        let state = voiceState
        let idleWake = listensForIdleWake
        let listensForWake = (state == .paused && !isVoiceMicMuted && voiceWakesByVoice) || idleWake
        // Permission and runtime setup finish before capture starts.
        let ownsCall = voiceCapture.owner == nil || voiceCapture.owner === self
        if !hasShutDown,
            (ownsCall && state.isNativeConversationActive && state != .preparing && !isVoiceMicMuted
                && (state != .paused || listensForWake)) || idleWake
        {
            voiceMic.start()
        } else {
            voiceMic.stop()
        }
        if !state.isNativeConversationActive { pendingWakeRequest = nil }
        let sessionID = sessionID
        let generation = voiceConversationGeneration
        // An idle wake belongs to whichever chat is open when it is heard.
        let isCurrent = { [weak self] in
            idleWake || (self?.sessionID == sessionID && self?.voiceConversationGeneration == generation)
        }
        voiceMic.onUtteranceEnd = { [weak self] transcript in
            guard let self, isCurrent() else { return }
            if transcript == nil, idleWake || voiceState == .paused {
                // A short burst of noise can end with no words even on a healthy recognizer.
                if voiceMic.utteranceTranscript == nil {
                    voiceMic.stopAfterRecognitionFailure(
                        idleWake
                            ? "Speech recognition stopped. Turn the wake word off and back on to retry."
                            : "Speech recognition stopped. Try again to resume voice.")
                }
                return
            }
            finishVoiceUtterance(transcript: transcript, overPlayback: voiceMic.heardPlayback)
        }
        voiceMic.onUnfinishedUtterance = { [weak self] in
            guard let self, isCurrent(), !listensForWake, voiceState == .listening else { return }
            voiceSpokenCaption = "I couldn't finish transcribing that. Please say it again."
        }
        voiceMic.onQuiet = { [weak self] in
            guard isCurrent() else { return }
            self?.speakPendingVoiceAnnouncements()
        }
        voiceMic.onIdle = { [weak self] in
            guard isCurrent() else { return }
            self?.sleepVoiceConversation()
        }
        voiceMic.onBargeSpeech = { [weak self] heard in
            guard isCurrent() else { return false }
            return self?.bargeInVoiceReply(heard: heard) ?? false
        }
        let awaitsApproval = isVoicePromptActive && approvalText != nil
        // Bias recognition only for the decision the call is currently waiting for.
        let awaitsClarification = isVoicePromptActive && voiceClarificationKey != nil
        var promptVocabulary = awaitsApproval ? VoicePrompts.approvalVocabulary : []
        if awaitsClarification {
            promptVocabulary =
                ["Option one", "Option two", "Option three"]
                + clarificationChoices.prefix(12).map { String($0.prefix(96)) }
        }
        if listensForWake { promptVocabulary = [] }
        let wakeNames = voiceWakeNames
        voiceMic.wakeNames = wakeNames
        voiceMic.vocabulary =
            (listensForWake ? wakeNames.map { "Hey \($0)" } : []) + promptVocabulary + wakeNames
            + [agentRecognitionName, "Herm"] + activeSubagents.compactMap(\.name)
        voiceMic.listen(
            // While Hermes thinks, speech steers the running turn instead of being lost.
            endpointing: !isVoiceMicMuted && (state == .listening || listensForWake || state == .thinking),
            watchingForBarge: state == .speaking && !isVoiceMicMuted && answersVoicePromptsAloud,
            requiresOnDevice: isNotchVoiceConversation || listensForWake,
            wakeOnly: listensForWake, preservingUtterance: preservingUtterance,
            preservingPlaybackOnBargeIn: awaitsApproval || awaitsClarification
        )
    }

    func startVoiceInHomeBot(initialRequest: String? = nil) {
        Task {
            guard !voiceAssistant.isResolvingSession else { return }
            let generation = voiceConversationGeneration
            let resumed = await resumeVoiceHomeChat(generation: generation)
            guard !hasShutDown, voiceConversationGeneration == generation else { return }
            if resumed {
                startVoiceConversation(initialRequest: initialRequest)
            } else {
                voiceState = .localFallback(VoiceAssistantSession.mainChatUnavailable)
            }
        }
    }

    static let voiceBotFaceKey = "voice.widget.lastBotID"

    func resumeVoiceHomeChat(generation: Int) async -> Bool {
        voiceAssistant.isResolvingSession = true
        defer {
            if voiceConversationGeneration == generation { voiceAssistant.isResolvingSession = false }
        }
        let bots = await botMode.readyRoster()
        guard !Task.isCancelled, !hasShutDown, voiceConversationGeneration == generation else { return false }
        let bot = bots.first(where: \.isDefault) ?? bots.first { $0.id == "default" }
        let profileID = bot?.chat?.profileID ?? bot?.id ?? "default"
        if let bot { defaults.set(bot.id, forKey: Self.voiceBotFaceKey) }

        let target: HermesSession?
        if let bot, bot.chat != nil {
            target = botChatSession(bot).session
        } else {
            do {
                target = try await HermesControlRPC(client: sessionRPCClient).existingBotChat(profileID: profileID)
            } catch {
                DebugLog.write("voice: main chat lookup failed: " + Self.safeUserDiagnostic(error.localizedDescription))
                return false
            }
        }
        guard let target, !Task.isCancelled, !hasShutDown, voiceConversationGeneration == generation else {
            return false
        }
        if sessionActionsReady, !isRestoringSession, sessionProfileID == profileID,
            target.id == sessionID || target.id == sessionStorageID
        {
            return true
        }
        return await resumeSession(target, reportFailure: false, profileID: profileID, reviewUnread: false)
    }

    /// Starts hands-free voice, wakes a sleeping call, or hangs up a live one.
    func toggleVoiceFromShortcut() {
        switch voiceState {
        case .inactive, .localFallback:
            if isNotchVoiceConversation {
                startLocalVoiceAssistant(request: pendingWakeRequest)
            } else {
                startVoiceInHomeBot(initialRequest: pendingWakeRequest)
            }
        case .paused: resumeVoiceListening(force: true)
        default: stopVoiceConversation()
        }
    }

    /// The orb's tap during a native conversation: send, interrupt, or wake.
    /// Returns false when native voice is not running, so the caller can
    /// handle its own local-fallback capture.
    @discardableResult
    func voiceOrbTapped() -> Bool {
        switch voiceState {
        case .listening: finishVoiceUtterance(transcript: voiceMic.utteranceTranscript)
        case .thinking, .speaking: interruptVoiceTurn()
        case .paused: resumeVoiceListening()
        case .preparing, .transcribing, .interrupted: break
        case .inactive, .localFallback: return false
        }
        return true
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

    func voiceRequest(from transcript: String) -> String {
        let speech = voiceAssistant.excludingAcknowledgmentEcho(transcript)
        return VoicePrompts.removingVoiceAddress(speech, names: voiceWakeNames + [agentRecognitionName])
    }

    /// Ends the current utterance now instead of waiting for Hermes' VAD
    /// silence window (`voice.silence_duration`, 3s by default). `transcript`
    /// is Herm's on-device text; nil means that recognizer failed.
    /// `overPlayback`: audio was playing meanwhile, so it may be our own reply.
    func finishVoiceUtterance(transcript rawTranscript: String?, overPlayback: Bool = false) {
        guard !isVoiceMicMuted else { return }
        var transcript = rawTranscript
        if voiceState.isNativeConversationActive, voiceState != .paused, let rawTranscript {
            let request = voiceRequest(from: rawTranscript)
            if request.isEmpty {
                let heard = voiceAssistant.excludingAcknowledgmentEcho(rawTranscript)
                if isNotchVoiceConversation, voiceState == .listening, !isVoicePromptActive, !isSending,
                    voiceAssistant.task == nil, !overPlayback,
                    VoicePrompts.afterWakePhrase(heard, names: voiceWakeNames) == ""
                {
                    wakeCount += 1
                    acknowledgeVoiceWake()
                }
                return
            }
            transcript = request
        }
        if voiceState == .inactive {
            // Idle wake word: only "hey <name>" opens a call, optionally with the request.
            guard listensForIdleWake, let transcript,
                let request = VoicePrompts.afterWakePhrase(transcript, names: voiceWakeNames)
            else { return }
            wakeCount += 1
            pendingWakeRequest = request
            toggleVoiceFromShortcut()
            return
        }
        if voiceState.isNativeConversationActive, !isVoicePromptActive, let transcript,
            VoicePrompts.endsVoice(transcript, acceptsPlainStop: isNotchVoiceConversation),
            !overPlayback || !VoicePrompts.isEcho(transcript, of: lastVoiceSpeech)
        {
            stopVoiceConversation()
            return
        }
        if voiceState == .paused {
            // Asleep: only "hey <name>" wakes it, optionally with the request.
            guard !isVoiceMicMuted, let transcript,
                let request = VoicePrompts.afterWakePhrase(transcript, names: voiceWakeNames)
            else { return }
            wakeCount += 1
            resumeVoiceListening()
            if request.isEmpty { acknowledgeVoiceWake() } else { finishVoiceUtterance(transcript: request) }
            return
        }
        if voiceState.isNativeConversationActive, !isVoicePromptActive, let transcript,
            !overPlayback || !VoicePrompts.isEcho(transcript, of: lastVoiceSpeech)
        {
            if VoicePrompts.cancelsVoiceTask(transcript) {
                if isSending || voiceAssistant.task != nil { interruptVoiceTurn() }
                return
            }
            if VoicePrompts.silencesVoiceReply(transcript) {
                if voiceState == .speaking { silenceVoiceReply() }
                if isSending { voiceReplySilenced = true }
                return
            }
        }
        // The final result can arrive before the recognizer sends its barge-in callback.
        if voiceState == .speaking, isVoicePromptActive, approvalText != nil, let transcript {
            guard let decision = classifyApprovalUtterance(transcript),
                VoicePrompts.approvalChoice(for: decision, choices: voiceApprovalChoices) != nil
                    || VoicePrompts.isSeparateRequestDuringApproval(decision),
                bargeInVoiceReply(heard: transcript), voiceState == .listening
            else { return }
            finishVoiceUtterance(transcript: transcript)
            return
        }
        if isVoicePromptActive, approvalText == nil, voiceClarificationKey != nil,
            let transcript, voiceState == .listening || voiceState == .speaking
        {
            submitSpokenClarification(transcript, overPlayback: overPlayback || voiceState == .speaking)
            return
        }
        if isNotchVoiceConversation, !isVoicePromptActive, voiceAssistant.task != nil { return }
        if isNotchVoiceConversation,
            (!isVoicePromptActive && voiceState == .thinking) || (isVoicePromptActive && approvalText == nil),
            let transcript, !(overPlayback && VoicePrompts.isEcho(transcript, of: lastVoiceSpeech))
        {
            if AssistantIntent.parse(transcript) != nil
                || (!isVoicePromptActive && VoiceAssistantSession.isConfirmationAnswer(transcript))
            {
                voiceSpokenCaption =
                    isVoicePromptActive ? VoiceAssistantSession.pendingPromptMessage : VoiceAssistantSession.busyMessage
                return
            }
        }
        if !isVoicePromptActive, voiceState == .listening, let transcript,
            !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !(overPlayback && VoicePrompts.isEcho(transcript, of: lastVoiceSpeech)),
            isNotchVoiceConversation || AssistantBrowserApp.parse(transcript) != nil,
            receiveAssistantRequest(transcript)
        {
            return
        }
        if isNotchVoiceConversation, !isVoicePromptActive, voiceAssistant.isLocal {
            if voiceState == .listening, transcript == nil {
                voiceState = .paused
                voiceSpokenCaption = VoiceAssistantSession.recognitionUnavailable
            }
            return
        }
        if !sessionActionsReady {
            guard voiceState.isNativeConversationActive, let voiceSessionID,
                (storageIDsByRuntimeID[voiceSessionID] ?? voiceSessionID) == sessionStorageID,
                Self.normalizedProfileID(voiceProfileID) == Self.normalizedProfileID(sessionProfileID ?? profileScopeID)
            else { return }
            if let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !(overPlayback && VoicePrompts.isEcho(transcript, of: lastVoiceSpeech))
            {
                stageDraft(transcript)
            }
            return
        }
        // Speaking while Hermes works steers the running turn, like typing does.
        guard voiceState == .listening || voiceState == .thinking, let sessionID else { return }
        if voiceState == .thinking {
            guard let spoken = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !spoken.isEmpty,
                !isVoicePromptActive, !(overPlayback && VoicePrompts.isEcho(spoken, of: lastVoiceSpeech)),
                !consumesVoicePreviewCommand(spoken)
            else { return }
            acknowledgeVoiceRequest(spoken, usesConversationVoice: true)
            if isSending, status == .working, !hasQueuedOrRedirectingPrompt {
                redirectTurn(with: spoken, sessionID: sessionID)
            } else {
                queuedPrompts.append(
                    QueuedPrompt(
                        sessionID: queuedPromptSessionID ?? sessionID, text: spoken, images: [],
                        profileID: Self.normalizedProfileID(sessionProfileID ?? profileScopeID),
                        mentionProfiles: composerMentionProfiles))
                drainQueuedPromptIfIdle()
            }
            return
        }
        if nativeCaptureIsLocal {
            guard let transcript else {
                if isNotchVoiceConversation {
                    voiceState = .paused
                    voiceSpokenCaption = "On-device speech recognition stopped. Resume voice to try again."
                    return
                }
                return fallBackToHermesTranscription()
            }
            var spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else { return }
            if isVoicePromptActive, approvalText != nil {
                guard let answer = classifyApprovalUtterance(spoken) else { return }
                spoken = answer
            } else if overPlayback, VoicePrompts.isEcho(spoken, of: lastVoiceSpeech) {
                DebugLog.write("voice: dropped an utterance that echoed the reply")
                return
            }
            nativeVoiceCapture.receivedTranscript(hasText: true)
            voiceTelemetry.receivedTranscript()
            if !isVoicePromptActive, consumesVoicePreviewCommand(spoken) {
                // A command that answers aloud ("Cypher here.") listens again after it speaks.
                if voiceState != .speaking { resumeVoiceListening(force: true) }
            } else if isVoicePromptActive {
                if voiceSpokenCaption == VoiceAssistantSession.pendingPromptMessage { voiceSpokenCaption = nil }
                // A pending decision stays in listening mode until Hermes confirms it.
                _ = answerVoicePrompt(spoken)
            } else {
                submitVoiceTranscriptOrCommand(spoken)
            }
            return
        }
        voiceState = .transcribing
        let params = scopedSessionParams(["action": "stop", "session_id": sessionID])
        Task {
            _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: params)
        }
    }

    /// Cuts Hermes off mid-thought or mid-sentence. `session.interrupt` also
    /// silences Hermes' streaming TTS, so one request covers both phases.
    func interruptVoiceTurn() {
        if interruptPreparingVoiceSubmission() { return }
        if voiceAssistant.task != nil {
            if voiceAssistant.isResolvingSession {
                stopVoiceConversation()
            } else {
                voiceAssistant.cancelTask()
                resumeVoiceListening(force: true)
            }
            return
        }
        switch voiceState {
        case .thinking:
            skipNextVoicePlaybackDrain = true
            _ = stop()
        case .speaking:
            stopVoicePlayback()
            if isSending && !isVoicePromptActive {
                skipNextVoicePlaybackDrain = true
                _ = stop()
            }
            resumeVoiceListening(force: true)
        default:
            break
        }
    }

    /// Ends a quiet follow-up window so side conversations aren't sent to the
    /// agent. Herm keeps listening on-device for the wake phrase only.
    func sleepVoiceConversation() {
        guard voiceState == .listening, nativeCaptureIsLocal,
            !isVoicePromptActive, !isSending
        else { return }
        if voiceAssistant.hasPending { return }
        voiceAssistant.setPending(nil)
        if isNotchVoiceConversation { voiceSpokenCaption = nil }
        if !voiceAssistant.isLocal, voiceRepliesEnabled, !voiceCompletionAnnouncements.isEmpty {
            let announcements = voiceCompletionAnnouncements.joined(separator: " ")
            voiceCompletionAnnouncements.removeAll()
            speakNativeVoiceReply(announcements)
            return
        }
        nativeVoiceCapture.reset()
        voiceState = .paused
        VoiceEarcon.sleep.play()
    }

    /// Partial speech can stop narration. Only an explicit, finalized command cancels work.
    @discardableResult
    func bargeInVoiceReply(heard: String) -> Bool {
        guard voiceState == .speaking, !isVoiceMicMuted else { return false }
        let spoken = voiceRequest(from: heard)
        guard !spoken.isEmpty else { return false }
        let reply = voiceSpokenCaption ?? lastVoiceSpeech
        if isVoicePromptActive, approvalText != nil {
            guard let answer = classifyApprovalUtterance(spoken),
                VoicePrompts.approvalChoice(for: answer, choices: voiceApprovalChoices) != nil
                    || VoicePrompts.isBargeIn(answer, over: reply)
            else { return false }
        } else if isVoicePromptActive, let key = voiceClarificationKey {
            guard spokenClarification(spoken, key: key, overPlayback: true) != nil else { return false }
        } else {
            guard VoicePrompts.isBargeIn(spoken, over: reply) else { return false }
        }
        silenceVoiceReply()
        return true
    }

    private func silenceVoiceReply() {
        guard isSending, !isVoicePromptActive else {
            interruptVoiceTurn()
            return
        }
        voiceReplySilenced = true
        stopVoicePlayback()
        nativeVoiceCapture.receivedTranscript(hasText: true)
        voiceState = .thinking
    }

    /// Re-opens the microphone after a no-speech pause (or a cut-off reply).
    func resumeVoiceListening(force: Bool = false) {
        guard voiceState == .paused || force, voiceState.isNativeConversationActive else { return }
        if voiceState == .paused {
            // A deliberate resume retries on-device recognition and Hermes' `/voice on`.
            localVoiceTranscriptionFailed = false
            retriedLocalVoiceTranscription = false
            voiceRecorderEnabled = false
            voiceMic.resetRecognitionFailures()
            voiceSpokenCaption = nil
        }
        stopVoicePlayback()
        nativeVoiceCapture.reset()
        if force && isVoiceMicMuted {
            voiceState = .paused
            return
        }
        isVoiceMicMuted = false
        if isNotchVoiceConversation && !voiceAssistant.hasRecognition() {
            voiceState = .paused
            voiceSpokenCaption = VoiceAssistantSession.recognitionUnavailable
            return
        }
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
        if voiceAssistant.isLocal {
            if voiceAssistant.isResolvingSession {
                stopVoiceConversation()
                return
            }
            voiceAssistant.cancelTask(clearPending: true)
            voiceSpokenCaption = nil
            voiceState = .paused
            return
        }
        guard voiceState == .listening, let sessionID else { return }
        nativeVoiceCapture.reset()
        voiceState = .paused
        guard voiceRecorderSessionID == sessionID else { return }
        let params = scopedSessionParams(["action": "stop", "session_id": sessionID])
        Task {
            _ = try? await sessionRPCClient.request(HermesFeatureIDs.ID.voiceRecord.rawValue, params: params)
        }
    }

    func toggleVoiceReplies() {
        guard voiceState.isNativeConversationActive else { return }
        voiceRepliesEnabled.toggle()
        guard !voiceRepliesEnabled else { return }
        voiceAssistant.stopAcknowledgment(keepEcho: true)
        guard voiceState == .speaking else { return }
        if voiceAssistant.task != nil {
            voiceAssistant.playback.stop()
            return
        }
        stopVoicePlayback()
        if isSending && !isVoicePromptActive {
            nativeVoiceCapture.receivedTranscript(hasText: true)
            voiceState = .thinking
        } else {
            resumeVoiceListening(force: true)
        }
    }

    /// Whether voice mode asks approvals and questions aloud and takes spoken answers.
    var answersVoicePromptsAloud: Bool {
        !localVoiceTranscriptionFailed
            && (isNotchVoiceConversation ? voiceAssistant.hasRecognition() : canTranscribeVoice())
    }

    private var voiceApprovalChoices: [String] { approvalDetails?.choices ?? ApprovalChoice.all }

    var voiceClarificationKey: VoiceStageState.ClarificationKey? {
        guard status == .needsClarification || isRespondingToClarification,
            let id = clarificationRequestID, !id.isEmpty, clarificationQuestion != nil
        else { return nil }
        return .init(requestID: id, questionID: activeClarification?.current?.id)
    }

    /// What voice mode reads aloud for a pending approval or clarify question.
    var voicePromptSpeech: String? {
        if let approvalText {
            return VoicePrompts.approvalSpeech(
                approvalDetails
                    ?? ApprovalPresentation(
                        title: approvalTitle ?? "Review requested action",
                        detail: approvalText, detailIsCommand: approvalTitle == "Run command"))
        }
        guard status == .needsClarification || isRespondingToClarification,
            let clarificationQuestion
        else { return nil }
        return VoicePrompts.clarificationSpeech(
            question: clarificationQuestion,
            choices: clarificationChoices,
            multiSelect: clarificationMultiSelect,
            progress: clarificationProgress
        )
    }

    /// Reads a pending prompt aloud and then listens for the answer; nil ends
    /// prompt mode once the approval or question is resolved.
    func presentVoicePrompt(_ speech: String?, awaitingReadout: Bool = false) {
        guard voiceState.isNativeConversationActive, !voiceAssistant.isLocal else { return }
        if speech != nil { voiceAssistant.cancelTask(clearPending: true) }
        guard let speech else {
            guard isVoicePromptActive else { return }
            isVoicePromptActive = false
            stopVoicePlayback()
            if isSending || status == .working {
                // The turn resumes; hold the microphone until its reply ends.
                nativeVoiceCapture.receivedTranscript(hasText: true)
                voiceState = .thinking
            } else {
                resumeVoiceListening(force: true)
            }
            return
        }
        guard answersVoicePromptsAloud else { return }
        isVoicePromptActive = true
        voiceAssistant.stopAcknowledgment(keepEcho: true)
        let previousState = voiceState
        if voiceRepliesEnabled, !awaitingReadout {
            speakPresentedVoicePrompt(speech)
        } else {
            resumeVoiceListening(force: true)
        }
        // A replacement prompt cannot receive a partial heard over the old one.
        if voiceState == previousState { syncVoiceCapture() }
    }

    func speakPresentedVoicePrompt(_ speech: String) {
        voiceStage.recordPromptReadout(speech)
        speakNativeVoiceReply(speech)
    }

    private func classifyApprovalUtterance(_ transcript: String) -> String? {
        VoicePrompts.approvalAnswer(
            transcript, readout: voiceStage.approvalReadout(for: currentConversationApproval?.id))
    }

    /// Routes clear decisions to the pending prompt without treating separate requests as consent.
    func answerVoicePrompt(_ spoken: String) -> Bool {
        if approvalText != nil {
            if isVoicePromptActive, voiceStage.spokenApprovalID != currentConversationApproval?.id { return false }
            if let choice = VoicePrompts.approvalChoice(for: spoken, choices: voiceApprovalChoices) {
                guard !isRespondingToApproval, voiceApproval?.answer?.blocksSubmission != true else { return false }
                voiceSpokenCaption = nil
                if isVoicePromptActive { acknowledgeVoiceRequest(usesConversationVoice: true) }
                respondToApproval(choice)
                return true
            }
            if isVoicePromptActive, handleRequestDuringVoiceApproval(spoken) { return true }
            voiceSpokenCaption = VoicePrompts.approvalAnswerHint(choices: voiceApprovalChoices, heard: spoken)
            return false
        }
        return false
    }

    private func spokenClarification(
        _ transcript: String, key: VoiceStageState.ClarificationKey, overPlayback: Bool
    ) -> VoicePrompts.ClarificationAnswer? {
        guard voiceStage.matchesClarification(key, call: voiceConversationGeneration),
            !isRespondingToClarification,
            let heard = VoicePrompts.clarificationUtterance(
                transcript,
                readout: voiceStage.clarificationReadout(for: key, call: voiceConversationGeneration),
                overPlayback: overPlayback)
        else { return nil }
        return VoicePrompts.clarificationAnswer(
            for: heard, choices: clarificationChoices, multiSelect: clarificationMultiSelect)
    }

    private func submitSpokenClarification(_ transcript: String, overPlayback: Bool) {
        guard sessionActionsReady, nativeCaptureIsLocal, approvalText == nil, let key = voiceClarificationKey,
            voiceStage.matchesClarification(key, call: voiceConversationGeneration), !isRespondingToClarification
        else { return }
        guard let reply = spokenClarification(transcript, key: key, overPlayback: overPlayback) else {
            if !overPlayback, !transcript.isEmpty,
                VoicePrompts.clarificationUtterance(
                    transcript,
                    readout: voiceStage.clarificationReadout(for: key, call: voiceConversationGeneration),
                    overPlayback: false) != nil
            {
                voiceSpokenCaption = VoicePrompts.clarificationHint(
                    choices: clarificationChoices, multiSelect: clarificationMultiSelect, heard: transcript)
            }
            return
        }
        if isNotchVoiceConversation, !reply.pickedOption, AssistantIntent.parse(transcript) != nil {
            voiceSpokenCaption = VoiceAssistantSession.pendingPromptMessage
            return
        }
        if voiceState == .speaking { silenceVoiceReply() }
        if respondToClarification(reply.answer, displayText: reply.display, fromVoice: true) {
            voiceSpokenCaption = "Sending answer…"
        }
    }

    private func handleRequestDuringVoiceApproval(_ spoken: String) -> Bool {
        if let intent = AssistantIntent.parse(spoken) {
            switch intent {
            case .time, .calculation:
                guard let reply = AssistantMac.perform(intent) else { return false }
                acknowledgeVoiceRequest()
                voiceSpokenCaption = reply.text
                if voiceRepliesEnabled { speakNativeVoiceReply(reply.text) }
            default:
                // Private commands must not get forwarded to Hermes as queued text.
                voiceSpokenCaption = VoiceAssistantSession.pendingPromptMessage
            }
            return true
        }
        guard VoicePrompts.isSeparateRequestDuringApproval(spoken),
            sessionActionsReady, let owner = queuedPromptSessionID
        else { return false }
        queuedPrompts.append(
            QueuedPrompt(
                sessionID: owner, text: spoken, images: [],
                profileID: Self.normalizedProfileID(sessionProfileID ?? profileScopeID),
                mentionProfiles: composerMentionProfiles))
        acknowledgeVoiceRequest(usesConversationVoice: true)
        voiceSpokenCaption = "Queued until the current approval and task are finished."
        return true
    }

    func fallBackToHermesTranscription() {
        if isNotchVoiceConversation {
            nativeVoiceCapture.reset()
            voiceState = .paused
            voiceSpokenCaption = VoiceAssistantSession.recognitionUnavailable
            return
        }
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

    func armNativeVoiceCapture(generation expectedGeneration: Int? = nil) {
        if voiceAssistant.isLocal {
            nativeCaptureIsLocal = true
            return
        }
        guard sessionActionsReady else { return }
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
            nativeVoiceCapture.beginCapture()
        else { return }
        let captureGeneration = nativeVoiceCapture.generation
        let conversationGeneration = voiceConversationGeneration
        nativeCaptureIsLocal = isNotchVoiceConversation || isVoicePromptActive || answersVoicePromptsAloud
        if nativeCaptureIsLocal {
            // Herm's mic meter transcribes this turn live and ends it.
            nativeVoiceCapture.captureStarted()
            voiceState = .listening
            if let request = pendingWakeRequest {
                pendingWakeRequest = nil
                finishVoiceUtterance(transcript: request)
            }
            return
        }

        let profile = voiceProfileID ?? "default"
        let needsEnable = !voiceRecorderEnabled
        voiceRecorderSessionID = sessionID
        voiceState = .preparing
        let previous = voiceRequestChain
        voiceRequestChain = Task {
            await previous?.value
            guard voiceConversationGeneration == conversationGeneration,
                self.sessionID == sessionID
            else { return }
            do {
                if needsEnable {
                    _ = try await sessionRPCClient.request(
                        HermesFeatureIDs.ID.slashExec.rawValue,
                        params: ["command": "voice on", "session_id": sessionID, "profile": profile])

                    guard voiceConversationGeneration == conversationGeneration else { return }
                    voiceRecorderEnabled = true
                }
                guard voiceConversationGeneration == conversationGeneration,
                    nativeVoiceCapture.isCurrent(generation: captureGeneration)
                else { return }
                let recording = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.voiceRecord.rawValue,
                    params: ["action": "start", "session_id": sessionID, "profile": profile])
                guard nativeVoiceCapture.isCurrent(generation: captureGeneration),
                    voiceState.isNativeConversationActive
                else { return }
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
                        messages.append(
                            ChatMessage(
                                role: .hermes,
                                text: "The voice microphone is busy. Release it and tap to resume.", isError: true))
                    }
                    return
                }
                nativeVoiceCapture.captureStarted()
                voiceState = .listening
            } catch {
                guard nativeVoiceCapture.isCurrent(generation: captureGeneration),
                    voiceState.isNativeConversationActive
                else { return }
                // Hermes forgot `/voice on` (a new session, or its own reset): send it again.
                if VoicePrompts.isVoiceModeOff(error.localizedDescription) { voiceRecorderEnabled = false }
                // Hermes' recorder was only the fallback; give on-device recognition another turn first.
                if localVoiceTranscriptionFailed, !retriedLocalVoiceTranscription, canTranscribeVoice() {
                    retriedLocalVoiceTranscription = true
                    DebugLog.write("voice: Hermes recorder unavailable; retrying on-device recognition")
                    localVoiceTranscriptionFailed = false
                    voiceMic.resetRecognitionFailures()
                    nativeVoiceCapture.reset()
                    armNativeVoiceCapture()
                    return
                }
                let shouldRetry = nativeVoiceCapture.captureStartFailed()
                if shouldRetry {
                    try? await Task.sleep(for: .milliseconds(300))
                    armNativeVoiceCapture(generation: captureGeneration)
                } else {
                    DebugLog.write(
                        "voice: capture failed to start; pausing: \(Self.safeUserDiagnostic(error.localizedDescription))"
                    )
                    voiceState = .paused
                    messages.append(
                        ChatMessage(
                            role: .hermes,
                            text:
                                "I couldn’t start the voice microphone: \(Self.safeUserDiagnostic(error.localizedDescription)). Check voice setup and microphone permissions, then tap to resume.",
                            isError: true))
                }
            }
        }
    }

    func recoverNativeVoiceCaptureIfInterruptedTranscriptIsMissing(generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                self.voiceState.isNativeConversationActive,
                self.nativeVoiceCapture.interruptionTimedOut(generation: generation)
            else { return }
            self.voiceState = .listening
            self.armNativeVoiceCapture()
        }
    }

    func stopVoicePlayback() {
        voicePlaybackGeneration &+= 1
        voiceReplyStream = nil
        voiceSpeechQueue.removeAll()
        voicePlaybackTask?.cancel()
        voicePlaybackTask = nil
        voicePlayback.stop()
        voiceSpokenCaption = nil
    }

    func speakNativeVoiceReply(_ responseText: String) {
        guard voiceState.isNativeConversationActive, voiceState != .preparing,
            voiceSessionID == sessionID, sessionID != nil
        else { return }
        stopVoicePlayback()
        enqueueVoiceSpeech(responseText)
    }

    func enqueueVoiceSpeech(_ text: String) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voiceSpeechQueue.append(text)
        }
        let readsApproval = isVoicePromptActive && approvalText != nil
        if voicePlaybackTask != nil, !readsApproval {
            voicePlayback.prefetch(text, profileID: voiceProfileID, client: sessionRPCClient)
        }
        guard voicePlaybackTask == nil, voiceState.isNativeConversationActive,
            voiceSessionID == sessionID, let sessionID
        else { return }
        voiceState = .speaking
        let generation = voiceConversationGeneration
        let playbackGeneration = voicePlaybackGeneration
        let captureGeneration = nativeVoiceCapture.completedResponse()
        let profile = voiceProfileID
        voicePlaybackTask = Task {
            await voiceAssistant.finishAcknowledgmentBeforeReply()
            do {
                try Task.checkCancellation()
                while !voiceSpeechQueue.isEmpty {
                    try Task.checkCancellation()
                    let speech = voiceSpeechQueue.removeFirst()
                    lastVoiceSpeech = speech
                    let onCaption: @MainActor (String?) -> Void = { [weak self] cue in
                        guard let self, self.voiceConversationGeneration == generation,
                            self.voicePlaybackGeneration == playbackGeneration,
                            self.sessionID == sessionID,
                            self.nativeVoiceCapture.isCurrent(generation: captureGeneration)
                        else { return }
                        if cue != nil { self.voiceTelemetry.startedSpeaking() }
                        self.voiceSpokenCaption = cue
                    }
                    if readsApproval {
                        try await voicePlayback.speakLocally(speech, onCaption: onCaption)
                    } else {
                        try await voicePlayback.speak(
                            speech, profileID: profile, client: sessionRPCClient, onCaption: onCaption)
                    }
                    try Task.checkCancellation()
                    guard voicePlaybackGeneration == playbackGeneration else { return }
                }
                guard !Task.isCancelled, voiceConversationGeneration == generation,
                    self.sessionID == sessionID,
                    nativeVoiceCapture.playbackDrainCompleted(generation: captureGeneration)
                else { return }
                voicePlaybackTask = nil
                voiceSpokenCaption = nil
                if !isSending, let timings = voiceTelemetry.timings { DebugLog.write(timings) }
                if isSending && !isVoicePromptActive {
                    nativeVoiceCapture.receivedTranscript(hasText: true)
                    voiceState = .thinking
                    return
                }
                if !isVoicePromptActive, voiceRepliesEnabled, !voiceCompletionAnnouncements.isEmpty {
                    let announcements = voiceCompletionAnnouncements.joined(separator: " ")
                    voiceCompletionAnnouncements.removeAll()
                    enqueueVoiceSpeech(announcements)
                    return
                }
                voiceTelemetry.beginListening()
                voiceState = .listening
                drainQueuedPromptIfIdle()
                armNativeVoiceCapture()
            } catch {
                guard !Task.isCancelled, voiceConversationGeneration == generation,
                    voicePlaybackGeneration == playbackGeneration, self.sessionID == sessionID
                else { return }
                stopVoicePlayback()
                nativeVoiceCapture.reset()
                voiceState = .paused
                messages.append(
                    ChatMessage(
                        role: .hermes,
                        text: "I couldn’t play the voice reply: \(Self.safeUserDiagnostic(error.localizedDescription))",
                        modelName: currentModelName, isError: true))
            }
        }
    }

    func streamVoiceReply(_ delta: String) {
        guard voiceRepliesEnabled, !isVoicePromptActive, !skipNextVoicePlaybackDrain, !voiceReplySilenced,
            voiceState.isNativeConversationActive, voiceState != .paused,
            voiceSessionID == sessionID
        else { return }
        if voiceReplyStream == nil { voiceReplyStream = VoiceReplyStream() }
        if let sentence = voiceReplyStream?.append(delta) { enqueueVoiceSpeech(sentence) }
    }

    func flushVoiceNarration() {
        guard voiceRepliesEnabled, !isVoicePromptActive, !skipNextVoicePlaybackDrain, !voiceReplySilenced,
            voiceState.isNativeConversationActive, voiceState != .paused,
            voiceSessionID == sessionID
        else { return }
        if let sentence = voiceReplyStream?.flushSentence() { enqueueVoiceSpeech(sentence) }
    }

    func finishStreamedVoiceReply(_ text: String) {
        let remainder = voiceReplyStream?.finish(text) ?? text
        voiceReplyStream = nil
        enqueueVoiceSpeech(remainder)
    }

    func speakPendingVoiceAnnouncements() {
        guard voiceState == .listening, !isSending, !isVoicePromptActive,
            voiceAssistant.task == nil, !voiceAssistant.hasPending,
            !isVoiceMicMuted, voiceRepliesEnabled, !voiceCompletionAnnouncements.isEmpty
        else { return }
        let announcements = voiceCompletionAnnouncements.joined(separator: " ")
        voiceCompletionAnnouncements.removeAll()
        if voiceAssistant.isLocal {
            speakLocalAssistantAnnouncement(announcements)
        } else {
            speakNativeVoiceReply(announcements)
        }
    }

    func announceVoiceBackgroundCompletion(_ task: HermesBackgroundTask) {
        guard voiceState.isNativeConversationActive, voiceRepliesEnabled,
            voiceSessionID == task.parentSessionID, voiceSessionID == sessionID
        else { return }
        let label = String(task.prompt.prefix(100))
        voiceCompletionAnnouncements.append(
            "Background task finished: \(label). The result is available in background tasks.")
        // Never replace a reply, an approval, or a user's current utterance.
        // Deliver at the next playback boundary or quiet microphone gap.
    }

    func submitNativeVoiceTranscript(_ text: String) {
        guard let sessionID, !isSending else { return }
        voiceReplySilenced = false
        voiceStage.localVisual = nil
        let requestGeneration = sessionResumeGeneration
        let callGeneration = voiceConversationGeneration
        let message = ChatMessage(role: .user, text: text)
        messages.append(message)
        preparingVoiceMessageID = message.id
        status = .working
        isSending = true
        voiceState = .thinking
        voiceTelemetry.submittedRequest()
        voiceStage.screenContext = nil
        acknowledgeVoiceRequest(text, usesConversationVoice: true)
        Task {
            let ownsCall = {
                self.voiceConversationGeneration == callGeneration
                    && self.sessionResumeGeneration == requestGeneration && self.sessionID == sessionID
            }
            let isPreparing = { ownsCall() && self.preparingVoiceMessageID == message.id }
            let scope = scopedSessionParams(["session_id": sessionID])
            do {
                let (extras, screen, jpeg) = await voiceTurnExtras(for: text, isCurrent: isPreparing)
                guard isPreparing() else { return }
                let screenshot: String?
                if let jpeg {
                    screenshot = await stageVoiceScreenshot(jpeg, scope: scope, isCurrent: isPreparing)
                } else {
                    screenshot = nil
                }
                guard isPreparing() else { return }
                var context = screen
                context?.hasScreenshot = screenshot != nil
                voiceStage.screenContext = context
                var lines = extras + (context?.promptLines ?? [])
                if VoicePrompts.requestsScreenshot(text), screenshot == nil {
                    lines.append("A screenshot of the current window was unavailable.")
                }
                preparingVoiceMessageID = nil
                var params = scope
                params["text"] = VoicePrompts.conversationPrompt(text, extras: lines, screenshotReference: screenshot)
                params["voice_turn"] = true
                let acknowledgment = try await sessionRPCClient.request(
                    HermesFeatureIDs.ID.promptSubmit.rawValue, params: params)
                if acknowledgment["voice_stopped"] as? Bool == true {
                    if ownsCall() { finishVoiceStopSubmission() }
                    return
                }
                guard
                    ["streaming", "queued", "redirected", "steered"].contains(acknowledgment["status"] as? String ?? "")
                else {
                    throw QuickDraftError.message(
                        "Hermes did not confirm submission. Check the conversation before retrying.")
                }
            } catch {
                guard ownsCall() else { return }
                messages.append(
                    ChatMessage(
                        role: .hermes,
                        text:
                            "I couldn’t submit the voice request: \(Self.safeUserDiagnostic(error.localizedDescription))",
                        modelName: currentModelName, isError: true))
                status = .offline
                isSending = false
                nativeVoiceCapture.reset()
                if voiceState.isNativeConversationActive { voiceState = .paused }
            }
        }
    }
}

extension DockModel {
    /// The current request; steering mid-turn stays part of it.
    private var voiceTurnRequest: ChatMessage? { messages.last { $0.role == .user && !$0.isSteering } }
    private var voiceTurnID: UUID? { voiceTurnRequest?.id }

    /// This turn's tool calls. The last turn's calls stay in `activeToolCalls` until
    /// Hermes starts the next message, so a new request must not flash them.
    var voiceTurnToolCalls: [ActiveToolCall] {
        guard let start = voiceTurnRequest?.timestamp else { return activeToolCalls }
        return activeToolCalls.filter { $0.startedAt >= start }
    }

    /// The current turn's reply when it has a read-only visual. The preview
    /// omits actions and live widgets without dropping their visual siblings.
    var voiceGenerativeReply: ChatMessage? {
        guard GenerativeUIIntegration.isEnabled, !isVoicePreviewDismissed else { return nil }
        if let visual = voiceStage.localVisual ?? liveVoiceVisual { return visual }
        let start = messages.lastIndex { $0.role == .user }.map { $0 + 1 } ?? messages.startIndex
        return messages[start...].last {
            $0.role == .hermes && !$0.isError && $0.systemEvent == nil && $0.kanbanNotice == nil
                && (VoicePassiveVisual.contains($0.text) || !VoiceReplyMedia.items(in: $0).isEmpty)
        }
    }

    var liveVoiceVisual: ChatMessage? {
        guard streamingResponseStartedAt != nil, let visual = voiceStage.liveVisual,
            visual.id == streamingMessageID, streamingMessageSessionID == sessionID
        else { return nil }
        return visual
    }

    /// Fences become eligible on a batched stream flush, never on each token or UI redraw.
    func prepareLiveVoiceVisual(_ source: String) {
        guard let id = streamingMessageID, !isVoicePreviewDismissed, !skipNextVoicePlaybackDrain,
            GenerativeUIIntegration.isEnabled, source.utf8.count <= 2 * RichDocument.maximumBytes,
            RichDocument.mentionsSurface(source)
        else { return }
        let generation = streamingMessageGeneration
        let call = voiceConversationGeneration
        voiceStage.liveVisualTask?.cancel()
        voiceStage.liveVisualTask = Task { [weak self] in
            let document = await RichDocumentCache.shared.document(source, streaming: true)
            guard !Task.isCancelled, let self else { return }
            voiceStage.liveVisualTask = nil
            guard document.hasVoiceVisuals, voiceState.isNativeConversationActive,
                streamingMessageID == id, streamingMessageGeneration == generation,
                voiceConversationGeneration == call, streamingResponseStartedAt != nil,
                !isVoicePreviewDismissed, !skipNextVoicePlaybackDrain, GenerativeUIIntegration.isEnabled
            else { return }
            if voiceStage.liveVisual?.text != source {
                voiceStage.liveVisual = ChatMessage(id: id, role: .hermes, text: source)
            }
        }
    }

    /// The one preview `surface` shows this turn; see `VoiceStagePresentation.preview`.
    func voicePreview(on surface: VoiceSurface) -> VoicePreview? {
        VoiceStagePresentation.preview(
            on: surface, tab: voiceShownTab, hasVisual: voiceGenerativeReply != nil,
            dismissed: isVoicePreviewDismissed, working: status == .working, calls: voiceTurnToolCalls)
    }

    /// Whether this turn's Talk preview (agent screen or generative reply) was closed.
    var isVoicePreviewDismissed: Bool { dismissedVoicePreviewTurn == .some(voiceTurnID) }

    func dismissVoicePreview() {
        voiceStage.clearLiveVisual()
        voiceStage.previewNavigation = .init()
        voiceStage.localVisual = nil
        dismissedVoicePreviewTurn = .some(voiceTurnID)
        voiceRevealedTab = nil
    }

    /// The tab Talk shows this turn; the next request returns the screen to the agent's work.
    var voiceShownTab: SessionInspector.Section? {
        voiceRevealedTab.flatMap { $0.turn == voiceTurnID ? $0.section : nil }
    }

    /// Opens an inspector tab: the panel in normal layouts, and the screen beside the orb in Talk,
    /// where full voice mode covers the inspector.
    func revealInspector(_ section: SessionInspector.Section) {
        if voiceState != .inactive {
            voiceRevealedTab = VoiceTabReveal(turn: voiceTurnID, section: section)
            if isVoicePreviewDismissed { dismissedVoicePreviewTurn = nil }
        }
        if !isNotchVoiceConversation {
            NotificationCenter.default.post(name: .hermRevealInspector, object: section)
        }
    }

    func handleVoicePreviewNavigation(_ spoken: String) -> Bool {
        guard !isVoicePromptActive, !voiceAssistant.hasPending,
            let command = RichVoicePreview.Command(spoken),
            let message = voiceGenerativeReply, let preview = VoicePassiveVisual.preview(message.text)
        else { return false }
        var position = voicePreviewPosition(for: message.id)
        let line = preview.apply(command, to: &position)
        let navigation = RichVoicePreview.Navigation(messageID: message.id, position: position)
        if navigation != voiceStage.previewNavigation { voiceStage.previewNavigation = navigation }
        // A model-authored result can use the conversation voice. Keep private
        // local results out of Hermes TTS, even if the user also started a chat task.
        if voiceState == .thinking, isSending, voiceRepliesEnabled, voiceStage.localVisual?.id != message.id {
            voiceReplySilenced = true
            enqueueVoiceSpeech(line)
        } else if voiceState == .listening, voiceRepliesEnabled {
            speakLocalAssistantAnnouncement(line)
        } else {
            voiceSpokenCaption = line
        }
        return true
    }

    func voicePreviewPosition(for messageID: UUID) -> RichVoicePreview.Position {
        let navigation = voiceStage.previewNavigation
        return navigation.messageID == messageID ? navigation.position : .init()
    }

    /// "Close" while a preview shows, or "open the browser", is handled here instead of reaching Hermes.
    func consumesVoicePreviewCommand(_ spoken: String) -> Bool {
        if handleVoicePreviewNavigation(spoken) || switchesVoiceBot(spoken) {
            acknowledgeVoiceRequest()
            return true
        }
        if let section = VoicePrompts.revealedTab(spoken) {
            acknowledgeVoiceRequest()
            revealInspector(section)
            return true
        }
        guard VoicePrompts.isClosePreview(spoken), closeVoicePreviewIfShown() else { return false }
        acknowledgeVoiceRequest()
        return true
    }

    /// "Switch to Cypher" opens that Bot's chat; the call hands over instead of ending.
    /// It never reaches the agent, which can't switch Herm's chats.
    private func switchesVoiceBot(_ spoken: String) -> Bool {
        guard let request = VoicePrompts.botSwitchRequest(spoken) else { return false }
        if isNotchVoiceConversation {
            guard request.explicit else { return false }
            speakNativeVoiceReply("Notch voice uses the main chat.")
            return true
        }
        if botMode.inventory.availability == .ready {
            let bots = botMode.inventory.bots.filter { !$0.isHidden }
            if let index = VoicePrompts.botSwitchTarget(spoken, among: bots.map(\.name)) {
                switchVoice(to: bots[index])
                return true
            }
            guard request.explicit else { return false }
            speakNativeVoiceReply(VoicePrompts.botNotFound(request.name))
            return true
        }
        // "Get the weather" is a request, not a switch; only clear phrasings wait for the roster.
        guard request.explicit else { return false }
        Task { [weak self] in
            guard let self else { return }
            let bots = await botMode.readyRoster()
            if let index = VoicePrompts.botSwitchTarget(spoken, among: bots.map(\.name)) {
                switchVoice(to: bots[index])
            } else {
                speakNativeVoiceReply(VoicePrompts.botNotFound(request.name))
            }
        }
        return true
    }

    private func switchVoice(to bot: BotSummary) {
        if bot.id == activeBotProfileID {
            greetVoiceHandoff()
        } else {
            resumeBotChat(bot)
        }
    }

    private func closeVoicePreviewIfShown() -> Bool {
        guard !isVoicePreviewDismissed || voiceShownTab != nil,
            voiceShownTab != nil || VoiceAgentScreen.hasSteps(voiceTurnToolCalls)
                || voiceGenerativeReply != nil
        else { return false }
        dismissVoicePreview()
        return true
    }

    /// A short utterance the keyword matcher missed may still be a local command
    /// ("get rid of that", "pull up the browser"). Apple's on-device model decides;
    /// anything it does not confidently map, or a slow answer, goes to Hermes as said.
    func submitVoiceTranscriptOrCommand(_ spoken: String) {
        guard VoiceStageSettings.understandsCommands, VoicePrompts.mayBeLocalCommand(spoken),
            OnDeviceAssist.isAvailable
        else { return submitNativeVoiceTranscript(spoken) }
        voiceState = .thinking
        let generation = voiceConversationGeneration
        let sessionID = sessionID
        Task { @MainActor [weak self] in
            let command = await OnDeviceAssist.voiceCommand(spoken)
            guard let self, voiceConversationGeneration == generation, self.sessionID == sessionID,
                voiceState == .thinking, !isSending
            else { return }
            if let command, runLocalVoiceCommand(command) {
                acknowledgeVoiceRequest()
                DebugLog.write("voice: ran a local command understood on device")
                resumeVoiceListening(force: true)
            } else {
                submitNativeVoiceTranscript(spoken)
            }
        }
    }

    private func runLocalVoiceCommand(_ command: String) -> Bool {
        if command == "close" { return closeVoicePreviewIfShown() }
        guard let section = SessionInspector.Section(agentTab: command) else { return false }
        revealInspector(section)
        return true
    }

    static func toolNarrationKey(_ call: ActiveToolCall) -> String { call.id + (call.isComplete ? "#done" : "#run") }

    /// The step in plain words: Apple Intelligence's line when it has one, else Herm's own wording.
    func toolStepTitle(_ call: ActiveToolCall) -> String {
        toolNarrations[call.id + "#done"].flatMap { call.isComplete ? $0 : nil }
            ?? toolNarrations[call.id + "#run"] ?? ToolStep.describe(call).title
    }

    /// Whether `toolStepTitle` came from Apple Intelligence, so it can be labeled.
    func isToolStepNarrated(_ call: ActiveToolCall) -> Bool {
        toolNarrations[call.id + "#run"] != nil || (call.isComplete && toolNarrations[call.id + "#done"] != nil)
    }

    /// Rewrites the newest steps in plain words once when each starts and once when it ends.
    // ponytail: newest three steps only, so a burst of parallel calls doesn't queue up the on-device model;
    // older steps keep Herm's wording.
    func narrateLatestToolSteps() {
        if activeToolCalls.isEmpty, !toolNarrations.isEmpty { toolNarrations = [:] }
        guard voiceState.isNativeConversationActive, VoiceStageSettings.narratesSteps, OnDeviceAssist.isAvailable
        else { return }
        for call in activeToolCalls.filter({ !$0.name.hasPrefix("__") }).suffix(3) { narrate(call) }
    }

    private func narrate(_ call: ActiveToolCall) {
        let key = Self.toolNarrationKey(call)
        guard toolNarrations[key] == nil, pendingToolNarrations.insert(key).inserted else { return }
        Task { [weak self] in
            let line = await OnDeviceAssist.narrateToolStep(
                name: call.name, args: call.args ?? [:], result: call.result, isComplete: call.isComplete)
            guard let self else { return }
            self.pendingToolNarrations.remove(key)
            guard let line, self.activeToolCalls.contains(where: { $0.id == call.id }) else { return }
            self.toolNarrations[key] = line
        }
    }
}

/// An inspector tab shown in Talk, for the request it was asked for in.
struct VoiceTabReveal: Equatable {
    var turn: UUID?
    var section: SessionInspector.Section
}
