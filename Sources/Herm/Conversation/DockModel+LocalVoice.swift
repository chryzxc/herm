import Foundation

@MainActor
final class VoiceAssistantSession {
    static let recognitionUnavailable =
        "On-device speech recognition is unavailable. Check Speech Recognition permission, then resume."
    nonisolated static let mainChatUnavailable = "The main chat is unavailable. Open it in Herm, then ask again."
    nonisolated static let busyMessage = "Herm is busy. Ask again after this reply."
    nonisolated static let pendingPromptMessage = "Answer the current prompt, then ask again."
    weak var control: ControlCenterModel?
    var hasRecognition: () -> Bool = { MicLevelMeter.canDetectWakePhrase }
    var preferenceDefaults: UserDefaults?
    lazy var acknowledgmentPlayback: HermesVoicePlaybackProtocol? =
        Bundle.main.bundleURL.pathExtension == "app" ? VoicePlayback() : nil
    var generateAcknowledgment: (String) async -> String? = OnDeviceAssist.voiceAcknowledgment
    private(set) var acknowledgmentTask: Task<Void, Never>?
    /// A cue without an expiry is still playing. Start the echo grace period when it stops.
    private var recentAcknowledgment: (line: String, until: ContinuousClock.Instant?)?
    private var isPlayingAcknowledgment: Bool { recentAcknowledgment.map { $0.until == nil } ?? false }
    var acknowledgmentNow: () -> ContinuousClock.Instant = { .now }
    private var lastAcknowledgment: String?

    func acknowledge(
        _ kind: VoiceAcknowledgment.Kind, request: String? = nil,
        conversation: (profileID: String?, client: HermesRPCClientProtocol)? = nil
    ) {
        guard let playback = acknowledgmentPlayback else { return }
        stopAcknowledgment(keepEcho: true)
        acknowledgmentTask = Task { [weak self, generateAcknowledgment] in
            let previous = self?.lastAcknowledgment
            let generated: String?
            if let request { generated = await generateAcknowledgment(request) } else { generated = nil }
            guard let self, !Task.isCancelled else { return }
            let line = VoiceAcknowledgment.line(generated, kind: kind, previous: previous)
            let started: @MainActor (String?) -> Void = { [weak self] cue in
                guard let cue, !Task.isCancelled else { return }
                self?.lastAcknowledgment = line
                self?.recentAcknowledgment = (cue, nil)
            }
            if let conversation {
                try? await playback.speak(
                    line, profileID: conversation.profileID, client: conversation.client, onCaption: started)
            } else {
                try? await playback.speakLocally(line, onCaption: started)
            }
            if !Task.isCancelled { endAcknowledgmentEcho() }
        }
    }

    func finishAcknowledgmentBeforeReply() async {
        if isPlayingAcknowledgment {
            await acknowledgmentTask?.value
        } else {
            // A ready answer is more useful than a receipt we haven't started saying.
            stopAcknowledgment(keepEcho: true)
        }
    }

    func excludingAcknowledgmentEcho(_ text: String) -> String {
        guard let recentAcknowledgment else { return text }
        if let until = recentAcknowledgment.until, until <= acknowledgmentNow() { return text }
        return VoiceAcknowledgment.removingEcho(from: text, of: recentAcknowledgment.line)
    }

    func stopAcknowledgment(keepEcho: Bool = false) {
        if let acknowledgmentTask {
            acknowledgmentTask.cancel()
            self.acknowledgmentTask = nil
            acknowledgmentPlayback?.stop()
        }
        if keepEcho { endAcknowledgmentEcho() } else { recentAcknowledgment = nil }
    }

    private func endAcknowledgmentEcho() {
        if isPlayingAcknowledgment {
            recentAcknowledgment?.until = acknowledgmentNow() + .seconds(4)
        }
    }

    let timers = AssistantTimers()
    var findMap: @MainActor (String) async -> AssistantReply = RichMap.lookUp
    var launchBrowser: @MainActor (AssistantBrowserApp) async -> AssistantReply = AssistantMac.openBrowserApp
    lazy var playback = LocalVoicePlayback()
    var task: Task<Void, Never>?
    var isLocal = false
    var isResolvingSession = false

    private var pending: (response: AssistantReply.FollowUp, expires: ContinuousClock.Instant)?
    var hasPending: Bool { pending.map { $0.expires > .now } ?? false }

    nonisolated static func isConfirmationAnswer(_ spoken: String) -> Bool {
        let term = AssistantIntent.normalized(spoken).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return ["send it", "confirm", "prepare to send", "cancel", "discard"].contains(term)
    }

    func setPending(_ response: AssistantReply.FollowUp?, now: ContinuousClock.Instant = .now) {
        pending = response.map { ($0, now.advanced(by: .seconds(45))) }
    }

    func takePending() -> AssistantReply.FollowUp? {
        defer { pending = nil }
        return hasPending ? pending?.response : nil
    }

    func cancelTask(clearPending: Bool = false) {
        if let task {
            task.cancel()
            self.task = nil
            playback.stop()
        }
        if clearPending { pending = nil }
    }

    func reset() {
        cancelTask(clearPending: true)
        stopAcknowledgment()
        isLocal = false
        isResolvingSession = false
    }

    func perform(_ intent: AssistantIntent) async throws -> AssistantReply {
        if let mac = AssistantMac.perform(intent) { return mac }
        switch intent {
        case .timerCreate, .timers, .timerRemaining, .timerExtend, .timerCancel:
            guard let control else { return AssistantReply("Timers need a connected Hermes runtime.") }
            return try await timers.perform(intent, on: control)
        case .calendarNext: return try await AssistantOrganizer.agenda(.today, next: true)
        case .calendarAgenda(let day): return try await AssistantOrganizer.agenda(day)
        case .calendarFree(let day, let part): return try await AssistantOrganizer.free(day, part: part)
        case .calendarBlock(let day, let part, let seconds, let title):
            return try await AssistantOrganizer.free(day, part: part, duration: seconds, title: title)
        case .reminder(let title, let list, let due):
            return try await AssistantOrganizer.reminder(title: title, list: list, day: due)
        case .shortcut(let name): return AssistantShortcuts.runAlias(name)
        case .approvals, .activity, .task:
            return await control?.voiceWork(intent) ?? AssistantReply("The work overview is unavailable.")
        case .message(let channel, let to, let subject, let body, let draftOnly):
            return await AssistantShortcuts.compose(
                channel: channel, recipient: to, subject: subject, body: body, draftOnly: draftOnly)
        case .help(let text): return AssistantReply(text)
        case .map(let place): return await findMap(place)
        case .launchBrowser(let browser): return await launchBrowser(browser)
        case .open, .time, .calculation: return AssistantReply("That Mac command is unavailable.")
        }
    }
}

extension DockModel {
    func startLocalVoiceAssistant(request: String? = nil) {
        guard !hasShutDown, !voiceState.isNativeConversationActive else { return }
        voiceConversationGeneration &+= 1
        let generation = voiceConversationGeneration
        let previous = voiceCapture.claim(self)
        voiceAssistant.isLocal = true
        voiceSessionID = nil
        voiceProfileID = nil
        nativeCaptureIsLocal = true
        pendingWakeRequest = nil
        stopVoiceAnnouncement()
        nativeVoiceCapture.reset()
        voiceState = .preparing
        voiceAssistant.task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, voiceConversationGeneration == generation else { return }
            await MicLevelMeter.askForSpeechPermission()
            guard !Task.isCancelled, voiceConversationGeneration == generation else { return }
            voiceAssistant.task = nil
            isVoiceMicMuted = false
            voiceRepliesEnabled = true
            guard voiceAssistant.hasRecognition() else {
                voiceState = .paused
                voiceSpokenCaption = VoiceAssistantSession.recognitionUnavailable
                return
            }
            voiceTelemetry.beginListening()
            KokoroVoice.prewarmIfSelected()
            voiceState = .listening
            if let request {
                if request.isEmpty {
                    acknowledgeVoiceWake()
                } else {
                    finishVoiceUtterance(transcript: request)
                }
            }
        }
    }

    /// Returns true for any request kept in the private local lane.
    func receiveAssistantRequest(_ transcript: String) -> Bool {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if handleVoicePreviewNavigation(spoken) {
            acknowledgeVoiceRequest()
            return true
        }
        if voiceStage.localVisual != nil, VoicePrompts.isClosePreview(spoken) {
            acknowledgeVoiceRequest()
            dismissVoicePreview()
            return true
        }
        voiceStage.localVisual = nil
        let intent = AssistantIntent.parse(spoken)
        let followUp = voiceAssistant.takePending()
        let local = voiceAssistant.isLocal
        let standaloneAnswer = VoiceAssistantSession.isConfirmationAnswer(spoken)
        guard followUp != nil || intent != nil || local || standaloneAnswer || !isHermesConnected else { return false }
        // When the local assistant hands off a request, the chat acknowledges the submission.
        if followUp != nil || intent != nil || standaloneAnswer || !isHermesConnected {
            acknowledgeVoiceRequest(followUp == nil && !standaloneAnswer ? spoken : nil)
        }
        let generation = voiceConversationGeneration
        voiceSpokenCaption = nil
        voiceState = .thinking
        voiceAssistant.task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let reply: AssistantReply
            do {
                if let followUp {
                    reply = try await followUp(spoken)
                } else if let intent {
                    reply = try await voiceAssistant.perform(intent)
                } else if standaloneAnswer {
                    reply = AssistantReply("There’s no pending voice action.")
                } else if local, isHermesConnected {
                    if await connectAssistantToHermes(request: spoken, generation: generation) { return }
                    reply = AssistantReply(VoiceAssistantSession.mainChatUnavailable)
                } else {
                    reply = AssistantReply("Hermes is unavailable. Ask again after reconnecting.")
                }
            } catch {
                reply = AssistantReply("I couldn't verify the result. Check the source before trying again.")
            }
            guard !Task.isCancelled, voiceConversationGeneration == generation else { return }
            await completeAssistantReply(reply, generation: generation)
        }
        return true
    }

    func restoreLocalAssistantAfterHandoff() {
        voiceAssistant.isLocal = true
        voiceSessionID = nil
        voiceProfileID = nil
        pendingWakeRequest = nil
        nativeCaptureIsLocal = true
        if voiceAssistant.hasRecognition() {
            voiceState = .listening
            speakLocalAssistantAnnouncement("Hermes couldn't open the conversation. Ask again after reconnecting.")
        } else {
            voiceState = .paused
            voiceSpokenCaption = VoiceAssistantSession.recognitionUnavailable
        }
    }

    var voicePreferenceDefaults: UserDefaults { voiceAssistant.preferenceDefaults ?? defaults }

    func acknowledgeVoiceRequest(_ request: String? = nil, usesConversationVoice: Bool = false) {
        guard voiceRepliesEnabled, VoiceAcknowledgment.enabled(in: voicePreferenceDefaults) else { return }
        voiceAssistant.acknowledge(
            .request, request: isVoicePromptActive ? nil : request,
            conversation: usesConversationVoice ? (voiceProfileID, sessionRPCClient) : nil)
    }

    func acknowledgeVoiceWake() {
        guard isNotchVoiceConversation, voiceState == .listening, voiceRepliesEnabled,
            VoiceAcknowledgment.enabled(in: voicePreferenceDefaults)
        else { return }
        voiceAssistant.acknowledge(.wake)
    }

    func speakLocalAssistantAnnouncement(_ text: String) {
        let generation = voiceConversationGeneration
        voiceAssistant.task = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == voiceConversationGeneration else { return }
            await completeAssistantReply(AssistantReply(text), generation: generation)
        }
    }

    func completeAssistantReply(_ reply: AssistantReply, generation: Int) async {
        if voiceRepliesEnabled { await voiceAssistant.finishAcknowledgmentBeforeReply() }
        guard !Task.isCancelled, voiceConversationGeneration == generation else { return }
        if let visual = reply.visual {
            dismissedVoicePreviewTurn = nil
            voiceRevealedTab = nil
            voiceStage.localVisual = ChatMessage(role: .hermes, text: visual)
        }
        lastVoiceSpeech = reply.text
        voiceSpokenCaption = reply.text
        var completedPlayback = false
        if voiceRepliesEnabled {
            voiceState = .speaking
            do {
                try await voiceAssistant.playback.speak(reply.text, literal: reply.requiresReadback) {
                    [weak self] cue in
                    self?.voiceSpokenCaption = cue
                }
                completedPlayback = true
            } catch {
                completedPlayback = false
            }
        }
        guard !Task.isCancelled, voiceConversationGeneration == generation else { return }
        if reply.requiresReadback && (!completedPlayback || !voiceRepliesEnabled) {
            voiceAssistant.setPending(nil)
            voiceSpokenCaption =
                voiceRepliesEnabled
                ? "Herm couldn’t finish reading the message. Ask to send it again."
                : "Turn on voice replies and ask to send the message again."
        } else {
            voiceSpokenCaption = reply.text
            if let followUp = reply.followUp { voiceAssistant.setPending(followUp) }
        }
        voiceAssistant.task = nil
        voiceState = .listening
    }

    private func connectAssistantToHermes(request: String, generation: Int) async -> Bool {
        if let section = VoicePrompts.revealedTab(request) {
            revealInspector(section)
            voiceAssistant.task = nil
            voiceState = .listening
            return true
        }
        guard await resumeVoiceHomeChat(generation: generation),
            !Task.isCancelled, generation == voiceConversationGeneration, isHermesConnected, sessionActionsReady,
            !isRestoringSession
        else { return false }
        voiceAssistant.task = nil
        voiceAssistant.isLocal = false
        voiceAssistant.isResolvingSession = false
        voiceState = .inactive
        startVoiceConversation(initialRequest: request)
        return true
    }
}
