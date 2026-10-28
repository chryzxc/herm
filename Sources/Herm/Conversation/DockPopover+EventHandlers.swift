import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension DockPopover {
    func openRequestedAutomation() async {
        guard let id = controlCenter.requestedAutomationJobID else { return }
        let owner = controlCenter.requestedAutomationOwner
        let profile = owner?.profileID ?? "default"
        if owner != nil, (model.profileScopeID ?? "default") != profile {
            await botMode.refreshNow(force: true)
            guard controlCenter.requestedAutomationJobID == id, controlCenter.requestedAutomationOwner == owner else {
                return
            }
            guard botMode.bots.contains(where: { $0.id == profile && !$0.isHidden }) else {
                controlCenter.automationNavigationError =
                    "The routine belongs to \(profile). Refresh the profile inventory or reopen its notch detail; Herm did not select another profile's routine."
                controlCenter.requestedAutomationJobID = nil
                controlCenter.requestedAutomationOwner = nil
                return
            }
            botMode.selectProfile(profile)
            handleProfileScopeChange(profile)
        }
        controlCenter.refresh()
        sessionNavNavigation.selectGlobal(.automations)
        fullscreenGlobalTab = .automations
        fullscreenSurface = .global
        controlCenter.requestedAutomationDidNavigate = true
    }

    func openRequestedRepositoryReview() {
        guard let request = controlCenter.requestedRepositoryReview, let id = request.sessionID,
            let path = request.projectPath, !model.isRestoringSession,
            model.currentSessionIDs.contains(id), model.workflowSession?.profileID == request.profileID
        else { return }
        controlCenter.requestedRepositoryReview = nil
        sessionNavNavigation.openSession(id)
        fullscreenSurface = .conversation
        inspectorScope = .session
        cachedSessionRepositoryPath = path
        selectSessionMode(.sourceControl)
        Task {
            await developerWorkflow.setActiveRepository(
                path: path, preferences: repositoryPreferences, control: controlCenter)
        }
    }

    func loadInitialModelConfiguration() {
        model.refreshRuntimeConfiguration()
        model.refreshRuntimeModelOptions()
        model.refreshDefaultReasoningVariant()
    }

    func handleVoiceStateChange(_ state: HermesVoiceState) {
        // Permission and runtime setup finish before capture starts.
        if state.isNativeConversationActive, state != .preparing, !model.isVoiceMicMuted {
            micLevelMeter.start()
        } else {
            micLevelMeter.stop()
        }
        let sessionID = model.sessionID
        let generation = model.voiceConversationGeneration
        micLevelMeter.onUtteranceEnd = { [model, micLevelMeter] transcript in
            guard model.sessionID == sessionID, model.voiceConversationGeneration == generation else { return }
            model.finishVoiceUtterance(transcript: transcript, overPlayback: micLevelMeter.heardPlayback)
        }
        micLevelMeter.onQuiet = { [model] in
            guard model.sessionID == sessionID, model.voiceConversationGeneration == generation else { return }
            model.speakPendingVoiceAnnouncements()
        }
        micLevelMeter.onIdle = { [model] in
            guard model.sessionID == sessionID, model.voiceConversationGeneration == generation else { return }
            model.sleepVoiceConversation()
        }
        micLevelMeter.onBargeSpeech = { [model] heard in
            guard model.sessionID == sessionID, model.voiceConversationGeneration == generation else { return false }
            return model.bargeInVoiceReply(heard: heard)
        }
        // Asleep, the meter only listens for the wake phrase, and only on-device.
        let listensForWake = state == .paused && !model.isVoiceMicMuted && wakesByVoice
        micLevelMeter.listen(
            // While Hermes thinks, speech steers the running turn instead of being lost.
            endpointing: !model.isVoiceMicMuted && (state == .listening || listensForWake || state == .thinking),
            watchingForBarge: state == .speaking && !model.isVoiceMicMuted && model.answersVoicePromptsAloud
        )
        if state == .interrupted {
            // The native gateway has accepted a spoken interruption. Stop
            // any fallback playback immediately before it resumes capture.
            voiceOutput.stop()
        }
        if case .localFallback = state {
            resumeVoiceConversationIfReady()
        }
    }

    /// Approvals and questions are spoken in voice mode and answered aloud.
    func handleVoicePromptChange(_ speech: String?) {
        guard sessionWorkspaceMode == .voice else { return }
        if model.voiceState.isNativeConversationActive { return model.presentVoicePrompt(speech) }
        if let speech { speakLocalVoicePrompt(speech) }
    }

    func speakLocalVoicePrompt(_ speech: String) {
        speechInput.stopForAssistantSpeech()
        voiceOutput.speak(messageID: UUID(), text: speech)
    }

    func handleVoicePlaybackChange(_ isSpeaking: Bool) {
        guard !isSpeaking, !model.voiceState.isNativeConversationActive else { return }
        resumeVoiceConversationIfReady()
    }

    func handleSessionModeChange(previousMode: SessionWorkspaceMode, mode: SessionWorkspaceMode) {
        guard previousMode == .voice, mode != .voice else { return }
        isVoiceImmersive = false
        // Leaving voice mode must always release both fallback and native
        // voice capture, including a microphone that is still starting.
        releaseVoiceCapture()
    }

    func releaseVoiceCapture() {
        micLevelMeter.stop()
        speechInput.stopForAssistantSpeech()
        voiceOutput.stop()
        model.stopVoiceConversation()
    }

    func handleRecordingChange(_ isRecording: Bool) {
        guard !isRecording, speechInput.errorMessage != nil else { return }
        sessionWorkspaceMode = .chat
    }

    func handleCompletedTranscript(_ transcript: String?) {
        guard sessionWorkspaceMode == .voice, model.voiceSessionID == model.sessionID else {
            speechInput.consumeCompletedTranscript()
            return
        }
        if sessionWorkspaceMode == .voice, model.voicePromptSpeech != nil, let transcript, !transcript.isEmpty {
            speechInput.consumeCompletedTranscript()
            if let retry = model.answerVoicePrompt(transcript) { speakLocalVoicePrompt(retry) }
            return
        }
        guard let transcript, !transcript.isEmpty, !model.isSending else { return }
        guard !voiceOutput.isSpeaking else {
            speechInput.consumeCompletedTranscript()
            return
        }
        model.draft = transcript
        speechInput.consumeCompletedTranscript()
        model.send()
    }

    func handleWorkspaceVisibilityChange(_ visible: Bool) {
        if isNarrowLayout { isNarrowControlVisible = visible }
        synchronizePanelLayout()
    }

    func handleCapabilitiesChange(_ capabilities: [CapabilityState]) {
        let available =
            capabilities.first { capability in
                capability.id == HermesFeatureIDs.ID.bots.rawValue
            }?.isAvailable == true
        botMode.setCapabilityAvailable(available)
        if available { botMode.refresh() }
    }

    func handleModelStatusChange(_ status: HermesStatus) {
        synchronizeWorkspace(status: status)
        // Picks up worktrees/branches the agent created during the turn.
        if status == .idle, activeSessionRepositoryPath != nil {
            Task { await refreshSessionWorkflow() }
        }
        guard case .localFallback = model.voiceState, model.voiceSessionID == model.sessionID,
            sessionWorkspaceMode == .voice,
            status == .idle,
            !model.voiceState.isNativeConversationActive
        else { return }
        if suppressNextVoiceResponse {
            suppressNextVoiceResponse = false
            resumeVoiceConversationIfReady()
            return
        }
        let response = model.messages.last { message in
            message.role == .hermes
        }
        let responseText = response?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !responseText.isEmpty, let response else {
            resumeVoiceConversationIfReady()
            return
        }
        speechInput.stopForAssistantSpeech()
        voiceOutput.speak(messageID: response.id, text: response.text)
    }

    func handleSessionIDChange(oldValue: String?, newValue: String?) {
        DebugLog.writeDiagnostic(
            "session.switch old=\(oldValue ?? "nil") new=\(newValue ?? "nil") title=\(model.currentSessionTitle ?? "nil") cachedProject=\(cachedProjectName ?? "nil") cachedRepo=\(cachedSessionRepositoryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "nil")"
        )
        synchronizeWorkspace()
        controlCenter.focus(sessionID: newValue)
        sessionNavNavigation.synchronizeActiveSession(model.navigationSessionID)
        synchronizePanelLayout()

        guard oldValue != newValue else { return }
        if oldValue != nil {
            speechInput.reset()
            releaseVoiceCapture()
            if sessionWorkspaceMode == .voice { sessionWorkspaceMode = .chat }
        }
        let title = model.currentSessionTitle
        let previousTitle = lastSessionTitleAtIdentityChange
        let titleChanged = previousTitle != nil && title != previousTitle
        lastSessionTitleAtIdentityChange = title
        guard newValue == nil || titleChanged else { return }
        cachedProjectName = nil
        cachedSessionRepositoryPath = nil
        refreshCachedProjectName()
        cacheSessionRepositoryPath()
    }

    func handleProjectMembershipChange() {
        DebugLog.writeDiagnostic(
            "session.membership_changed session=\(model.sessionID ?? "nil") project=\(contextProjectName ?? "nil") cachedProject=\(cachedProjectName ?? "nil")"
        )
        refreshCachedProjectName()
        cacheSessionRepositoryPath()
        synchronizeSessionMetadataFromControlCenter()
    }

    func handleMessageCountChange(oldCount: Int, newCount: Int) {
        guard newCount > oldCount else { return }
        synchronizeWorkspace()
    }

    func handleSessionMetadataChange() {
        model.refreshSessionModelOptions()
        synchronizeSessionMetadataFromControlCenter()
    }

    func clearSessionSurfaceSelections() {
        sourceControlRequestID = UUID()
        explorerSelection = nil
        selectedChange = nil
        selectedChangeDiff = nil
        isLoadingChangeDiff = false
    }

    func handleWorkspaceChange() {
        synchronizeWorkspace()
    }

    func configureWorkspaceOnAppear() {
        synchronizePanelLayout()
        synchronizeWorkspace()
        sessionNavNavigation.synchronizeActiveSession(model.navigationSessionID)
        controlCenter.bind(to: model)
        // The session Activity child can mount before this root lifecycle hook.
        // Reissue its durable, read-only projection after binding so an early
        // unbound attempt cannot leave the visible session permanently empty.
        controlCenter.refreshSessionKanban(for: model.kanbanSessionID)
        botMode.bind(
            to: model.controlRPCClient,
            capabilityAvailable: controlCenter.capabilityAvailable(HermesFeatureIDs.ID.bots.rawValue))
        agentUpdateService.checkForUpdates()
        Task { @MainActor in
            await botMode.refreshNow(force: true)
            handleProfileScopeChange(botMode.selectedProfileID)
            model.restoreLatestSessionIfNeeded()
            controlCenter.refresh()
            controlCenter.startInitialProjectNavigationLoad()
        }
        // Seed the project name cache immediately after bind so the label is
        // visible from the first render if membership data is already loaded.
        refreshCachedProjectName()
    }
}
