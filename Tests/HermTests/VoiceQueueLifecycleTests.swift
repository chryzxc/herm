import Foundation
import Testing

@testable import Herm

@MainActor
private final class VoiceQueueRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var promptResult: [String: Any] = ["status": "streaming"]
    var promptError: Error?
    var requests: [(method: String, params: [String: Any])] = []
    var submitted: [String] = []
    var queuedSubmissions: [Bool] = []
    var voiceMode = "off"
    var canEnableRecorder = true
    var mainChatID: String?
    var holdConnection = false
    var connectionContinuation: CheckedContinuation<Void, Never>?
    var holdCreation = false
    var holdFile = false
    var fileContinuation: CheckedContinuation<[String: Any], Error>?
    var creationContinuation: CheckedContinuation<[String: Any], Never>?
    var clarificationResult: [String: Any] = ["status": "ok"]
    var clarificationError: Error?
    func connect() async throws {
        if holdConnection { await withCheckedContinuation { connectionContinuation = $0 } }
    }
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if let mainChatID {
            if method == "profiles.list" {
                return [
                    "profiles": [["id": "default", "is_default": true, "chat": ["session_id": mainChatID]]]
                ]
            }
            if method == "session.resume", params["session_id"] as? String == mainChatID {
                return ["session_id": mainChatID, "messages": [[String: Any]]()]
            }
        }
        if method == "session.create", holdCreation {
            return await withCheckedContinuation { creationContinuation = $0 }
        }
        if method == "file.attach", holdFile {
            return try await withCheckedThrowingContinuation { fileContinuation = $0 }
        }
        if method == "voice.toggle" { return ["available": true, "stt_available": true, "tts": true] }
        if method == "slash.exec", let command = params["command"] as? String {
            if command == "voice on", !canEnableRecorder {
                throw NSError(
                    domain: "HermVoice", code: 501,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "This Hermes runtime does not support session-scoped voice recording."
                    ])
            }
            voiceMode = command == "voice on" && canEnableRecorder ? "voice_only" : "off"
            return [:]
        }
        if method == "config.get", params["key"] as? String == "voice" { return ["value": voiceMode] }
        if method == "voice.record" { return ["status": "recording"] }
        if method == "session.interrupt" { return ["status": "interrupted"] }
        if method == HermesFeatureIDs.ID.approvalRespond.rawValue { return ["resolved": 1] }
        if [HermesFeatureIDs.ID.clarifyLock.rawValue, HermesFeatureIDs.ID.clarifyRespond.rawValue].contains(method) {
            if let clarificationError { throw clarificationError }
            return clarificationResult
        }
        if method == "prompt.submit" {
            submitted.append(params["text"] as? String ?? "")
            queuedSubmissions.append(params["queued"] as? Bool ?? false)
            if let promptError { throw promptError }
            return promptResult
        }
        return [:]
    }
}

@MainActor
final class VoiceQueuePlayback: HermesVoicePlaybackProtocol {
    var speeches: [(text: String, profile: String?)] = []
    var localSpeeches: [String] = []
    var stopped = 0
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    var caption: (@MainActor (String?) -> Void)?
    func speak(
        _ text: String, profileID: String?, client: HermesRPCClientProtocol,
        onCaption: @escaping @MainActor (String?) -> Void
    ) async throws {
        try await play(text, profileID: profileID, onCaption: onCaption)
    }
    func speakLocally(_ text: String, onCaption: @escaping @MainActor (String?) -> Void) async throws {
        localSpeeches.append(text)
        try await play(text, profileID: nil, onCaption: onCaption)
    }
    private func play(
        _ text: String, profileID: String?, onCaption: @escaping @MainActor (String?) -> Void
    ) async throws {
        speeches.append((text, profileID))
        caption = onCaption
        if hold {
            await withCheckedContinuation { continuation = $0 }
        } else {
            onCaption(text)
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func stop() { stopped += 1 }
}

@MainActor
struct VoiceQueueLifecycleTests {
    private func model(_ client: VoiceQueueRPCClient, playback: VoiceQueuePlayback = VoiceQueuePlayback()) -> DockModel
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-queue-\(UUID().uuidString)")
        return DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            initialSessionID: "voice-queue", botActivityFileURL: root.appendingPathComponent("bots.json"),
            rpcClient: client, voicePlayback: playback)
    }
    private func event(_ model: DockModel, _ type: String, _ payload: [String: Any] = [:]) {
        model.receiveGatewayEvent(type, params: ["session_id": "voice-queue", "payload": payload])
    }
    private func startVoice(_ model: DockModel) async throws {
        model.startVoiceConversation()
        for _ in 0..<100 where model.voiceState == .preparing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.voiceState == .listening)
        await model.voiceRequestChain?.value
    }

    @Test func skillStartDoesNotSpeakAProgressAnnouncement() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        let model = model(client, playback: playback)
        defer { model.shutdown() }
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.isSending = true
        model.voiceState = .thinking
        event(model, "tool.start", ["id": "skill-1", "name": "skill_view", "args": ["name": "fixture"]])
        await Task.yield()
        #expect(playback.speeches.isEmpty)
    }

    @Test func closingThePreviewLastsUntilTheNextRequest() {
        let model = model(VoiceQueueRPCClient())
        // The Talk stage redraws only on these sources; the close must be one of them.
        #expect(model.workspacePresentationSources().contains { $0.name == "dismissedVoicePreviewTurn" })
        model.messages.append(ChatMessage(role: .user, text: "find my notes"))
        model.activeToolCalls = [
            ActiveToolCall(
                id: "1", name: "search_files", input: "", context: "", startedAt: .now, result: "{}",
                isComplete: true, completedAt: .now, args: [:])
        ]
        #expect(!model.consumesVoicePreviewCommand("open the second one"))
        #expect(model.consumesVoicePreviewCommand("close it"))
        #expect(model.isVoicePreviewDismissed)
        #expect(!model.consumesVoicePreviewCommand("close it"))
        model.messages.append(ChatMessage(role: .user, text: "now the slides"))
        #expect(!model.isVoicePreviewDismissed)
        // The last turn's steps wait for the next `message.start` to clear; the new request must not flash them.
        #expect(model.voiceTurnToolCalls.isEmpty)
        #expect(!model.consumesVoicePreviewCommand("close it"))
    }

    @Test func aRevealedTabShowsInTalkUntilClosedOrTheNextRequest() {
        let model = model(VoiceQueueRPCClient())
        model.messages.append(ChatMessage(role: .user, text: "find my notes"))
        model.revealInspector(.browser)
        #expect(model.voiceShownTab == nil)  // Outside Talk the inspector panel shows it.
        model.voiceState = .listening
        #expect(model.consumesVoicePreviewCommand("open the browser"))
        #expect(model.voiceShownTab == .browser)
        #expect(model.consumesVoicePreviewCommand("close it"))
        #expect(model.voiceShownTab == nil)
        model.revealInspector(.terminal)  // Hermes' herm_inspector or focus_pane, after a close.
        #expect(model.voiceShownTab == .terminal && !model.isVoicePreviewDismissed)
        model.messages.append(ChatMessage(role: .user, text: "now the slides"))
        #expect(model.voiceShownTab == nil)
    }

    @Test func repeatedStartDoesNotCancelSpeechAndBargeInDropsTheRemainingQueue() async throws {
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(VoiceQueueRPCClient(), playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        event(model, "message.start")
        event(model, "message.delta", ["delta": "The first answer is ready. Next"])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let stopped = playback.stopped
        event(model, "message.start")
        #expect(playback.stopped == stopped)
        event(model, "message.delta", ["delta": " comes another sentence. Last"])
        #expect(!model.voiceSpeechQueue.isEmpty)
        model.interruptVoiceTurn()
        #expect(model.voiceSpeechQueue.isEmpty)
        playback.continuation?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(playback.speeches.count == 1)
        model.stopVoiceConversation()
    }

    @Test func cuttingInReadsAnOptionWithoutCancelingOrRedirectingTheTurn() async throws {
        let before = UserDefaults.standard.object(forKey: GenerativeUIIntegration.preferenceKey)
        UserDefaults.standard.set(true, forKey: GenerativeUIIntegration.preferenceKey)
        defer { UserDefaults.standard.set(before, forKey: GenerativeUIIntegration.preferenceKey) }
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(client, playback: playback)
        defer { model.shutdown() }
        model.canTranscribeVoice = { true }
        model.voiceAssistant.hasRecognition = { true }
        try await startVoice(model)
        model.isNotchVoiceConversation = true
        model.isHermesConnected = true
        event(model, "message.start")
        event(model, "message.delta", ["delta": "I found a couple of journeys. The first"])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let narration = try #require(playback.continuation)
        playback.continuation = nil

        let comparison = """
            ```herm-ui
            {"version":2,"id":"options","title":"Journeys","fallback":"Journeys","kind":"native","blocks":[
            {"type":"comparison","id":"opts","payload":{"criteria":["Cost"],"options":[
            {"id":"a","title":"Ferry","values":["$30"]},{"id":"b","title":"Bus","values":["$12"]}]}}]}
            ```
            """
        let prose = "I found a couple of journeys. The first is faster. The second is cheaper."
        let fullReply = prose + "\n\n" + comparison
        event(model, "message.delta", ["delta": " is faster. The second is cheaper.\n\n" + comparison])
        model.flushStreamingMessage()
        await model.voiceStage.liveVisualTask?.value
        let visual = try #require(model.liveVoiceVisual)

        #expect(model.bargeInVoiceReply(heard: "Read the second option"))
        narration.resume()
        #expect(model.voiceState == .thinking)
        #expect(model.isSending)
        #expect(model.interruptState == .idle)
        model.finishVoiceUtterance(transcript: "Read the second option")
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let readout = try #require(playback.continuation)
        playback.continuation = nil
        #expect(model.voicePreviewPosition(for: visual.id).option == 1)
        #expect(playback.speeches.last?.text == "Bus. Cost: $12.")

        event(model, "message.delta", ["delta": "\nA little more detail."])
        event(model, "message.complete", ["text": fullReply])
        #expect(model.voiceState == .speaking)
        #expect(model.voiceGenerativeReply?.id == visual.id)
        #expect(model.voiceSpeechQueue.isEmpty)
        #expect(!model.isSending)
        let agentActions = ["session.interrupt", "prompt.redirect", "prompt.submit"]
        #expect(!client.requests.contains { agentActions.contains($0.method) })

        playback.hold = false
        readout.resume()
        for _ in 0..<100 where model.voiceState != .listening { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.speeches.count == 2)
        #expect(model.voiceState == .listening)
        model.finishVoiceUtterance(transcript: "Actually, my budget is eighty dollars.")
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.submitted.first?.contains("my budget is eighty dollars") == true)
        model.finishVoiceUtterance(transcript: "End the call")
        #expect(model.voiceState == .inactive)
    }

    @Test func onlyTheFinalizedCancelCommandStopsWork() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        defer { model.shutdown() }
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        event(model, "message.start")
        model.voiceState = .speaking
        #expect(model.bargeInVoiceReply(heard: "Cancel"))
        #expect(model.interruptState == .idle)
        #expect(model.isSending)
        model.finishVoiceUtterance(transcript: "Stop talking")
        #expect(model.interruptState == .idle)
        #expect(model.isSending)

        model.finishVoiceUtterance(transcript: "Cancel the task")
        for _ in 0..<100 where model.isSending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.requests.filter { $0.method == "session.interrupt" }.count == 1)
        #expect(!model.isSending)
    }

    @Test func subagentCompletionNoticeIsScopedAndDeduplicated() async throws {
        let model = model(VoiceQueueRPCClient())
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.receiveGatewayEvent(
            "subagent.complete",
            params: [
                "session_id": "unrelated", "payload": ["subagent_id": "other", "name": "Other agent"],
            ])
        #expect(model.voiceCompletionAnnouncements.isEmpty)
        event(model, "subagent.start", ["subagent_id": "worker", "name": "Researcher"])
        event(model, "subagent.complete", ["subagent_id": "worker", "name": "Researcher"])
        event(model, "subagent.complete", ["subagent_id": "worker", "name": "Researcher"])
        #expect(model.voiceCompletionAnnouncements == ["Researcher finished."])
        model.stopVoiceConversation()
    }

    @Test func disablingStreamedRepliesKeepsSpokenSteeringAvailable() async throws {
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(VoiceQueueRPCClient(), playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        event(model, "message.start")
        event(model, "message.delta", ["delta": "I am checking that. Next"])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.toggleVoiceReplies()
        #expect(model.voiceState == .thinking)
        #expect(model.isSending)
        #expect(model.voiceSpeechQueue.isEmpty)
        playback.continuation?.resume()
        model.stopVoiceConversation()
    }

    @Test func queuedVoiceFollowUpRetainsTheFastVoiceRoute() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.draft = "Follow up aloud"
        model.queueDraft()
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let request = client.requests.last(where: { $0.method == "prompt.submit" })
        #expect(request?.params["voice_turn"] as? Bool == true)
        #expect(client.submitted.first == VoicePrompts.conversationPrompt("Follow up aloud"))
        model.stopVoiceConversation()
    }

    @Test func speechStartsBeforeCompletionAndFinalDoesNotRepeatThePrefix() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(client, playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        event(model, "message.start")
        event(model, "message.delta", ["delta": "The first answer is ready. Here is"])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isSending)
        #expect(playback.speeches.count == 1)
        #expect(
            playback.speeches.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == "The first answer is ready.")
        event(model, "message.complete", ["text": "The first answer is ready. Here is the rest."])
        #expect(playback.speeches.count == 1)
        playback.hold = false
        playback.continuation?.resume()
        for _ in 0..<100 where model.voiceState != .listening { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.speeches.map(\.text).joined() == "The first answer is ready. Here is the rest.")
        #expect(model.voiceState == .listening)
        #expect(model.nativeVoiceCapture.captureArmed)
    }

    @Test func aGapInStreamedSpeechKeepsTheAgentTurnWorking() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        event(model, "message.start")
        event(model, "message.delta", ["delta": "I will check that. Next"])
        for _ in 0..<100 where model.voiceState != .thinking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.isSending)
        #expect(!model.nativeVoiceCapture.captureArmed)
        #expect(model.voiceState == .thinking)
        model.stopVoiceConversation()
    }

    @Test func backgroundCompletionWaitsForQuietAndIsNotAnnouncedTwice() async throws {
        let playback = VoiceQueuePlayback()
        let model = model(VoiceQueueRPCClient(), playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.registerBackgroundTask(id: "work", prompt: "Check the build", parentSessionID: "voice-queue")
        event(model, "background.complete", ["task_id": "work", "text": "Build passed"])
        event(model, "background.complete", ["task_id": "work", "text": "Build passed"])
        #expect(model.voiceCompletionAnnouncements.count == 1)
        #expect(playback.speeches.isEmpty)
        model.isVoicePromptActive = true
        model.speakPendingVoiceAnnouncements()
        #expect(model.voiceCompletionAnnouncements.count == 1)
        model.isVoicePromptActive = false
        model.speakPendingVoiceAnnouncements()
        for _ in 0..<100 where playback.speeches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.speeches.count == 1)
        #expect(playback.speeches.first?.text.contains("Check the build") == true)
        model.stopVoiceConversation()
        #expect(model.voiceCompletionAnnouncements.isEmpty)
    }

    @Test func streamedSpeechIsCancelledOnSessionChange() async throws {
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(VoiceQueueRPCClient(), playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        event(model, "message.start")
        event(model, "message.delta", ["delta": "The first sentence is ready. Another follows."])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.sessionID = "elsewhere"
        playback.continuation?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.voiceState == .inactive)
        #expect(model.voiceSpeechQueue.isEmpty)
        #expect(model.voiceReplyStream == nil)
        #expect(model.voiceSpokenCaption == nil)
    }

    @Test func localBargeInStopsAudioWithoutInterruptingAnAlreadyCompletedTurn() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(client, playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.speakNativeVoiceReply("The forecast is sunny today.")
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        playback.caption?("The forecast is sunny today.")
        model.bargeInVoiceReply(heard: "forecast is sunny today")
        #expect(model.voiceState == .speaking)
        let stops = playback.stopped
        model.bargeInVoiceReply(heard: "Actually tell me about tomorrow")
        #expect(model.voiceState == .listening)
        #expect(playback.stopped > stops)
        #expect(model.interruptState == .idle)
        playback.caption?("A stale caption")
        #expect(model.voiceSpokenCaption == nil)
        playback.continuation?.resume()
        model.finishVoiceUtterance(transcript: "Actually tell me about tomorrow")
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.submitted == [VoicePrompts.conversationPrompt("Actually tell me about tomorrow")])
        model.stopVoiceConversation()
    }

    @Test func mutedMicrophoneRejectsLateSpeechAndInterruptions() {
        let model = model(VoiceQueueRPCClient())
        model.voiceState = .thinking
        model.isVoiceMicMuted = true
        model.finishVoiceUtterance(transcript: "Do not send this")
        #expect(model.queuedPrompts.isEmpty)
        #expect(model.messages.isEmpty)
        model.voiceState = .speaking
        model.bargeInVoiceReply(heard: "Wait stop")
        #expect(model.voiceState == .speaking)
    }

    @Test func idleSpeechOpensNoCallWithoutTheWakeWordSetting() {
        let model = model(VoiceQueueRPCClient())
        #expect(!model.listensForIdleWake)
        model.finishVoiceUtterance(transcript: "Hey Herm what's on my calendar")
        #expect(model.voiceState == .inactive)
        #expect(model.pendingWakeRequest == nil)
        #expect(model.wakeCount == 0)
    }

    @Test func voiceShortcutStartsWakesAndHangsUp() async throws {
        let client = VoiceQueueRPCClient()
        client.mainChatID = "voice-queue"
        let model = model(client)
        model.toggleVoiceFromShortcut()
        // The shortcut checks the bot roster first.
        for _ in 0..<100 where model.voiceState == .preparing || model.voiceState == .inactive {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.voiceState == .listening)
        #expect(model.voiceSessionID == client.mainChatID)
        #expect(model.voiceProfileID == "default")
        #expect(!client.requests.contains { $0.method == "session.create" })
        model.voiceState = .paused
        model.toggleVoiceFromShortcut()
        // Resuming re-arms capture; it may pass through preparing first.
        #expect(model.voiceState != .paused && model.voiceState.isNativeConversationActive)
        model.toggleVoiceFromShortcut()
        #expect(model.voiceState == .inactive)
    }

    @Test func automaticResumeNeverUnmutesTheMicrophone() {
        let model = model(VoiceQueueRPCClient())
        model.voiceState = .speaking
        model.isVoiceMicMuted = true
        model.resumeVoiceListening(force: true)
        #expect(model.isVoiceMicMuted)
        #expect(model.voiceState == .paused)
        #expect(!model.nativeVoiceCapture.captureArmed)
    }

    @Test func interruptingASpokenApprovalKeepsTheApprovalActive() {
        let model = model(VoiceQueueRPCClient())
        model.voiceState = .speaking
        model.isVoicePromptActive = true
        model.isSending = true
        model.lastVoiceSpeech = "May I run this command?"
        model.bargeInVoiceReply(heard: "Wait please")
        #expect(model.isVoicePromptActive)
        #expect(model.interruptState == .idle)
        #expect(model.voiceState == .listening)
    }

    @Test func localRecognitionDoesNotWaitForBackendAudioChecksOrEnableGlobalSpeech() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        #expect(model.nativeCaptureIsLocal)
        #expect(client.requests.allSatisfy { !$0.method.hasPrefix("voice.") && $0.method != "slash.exec" })
        model.toggleVoiceReplies()
        #expect(!model.voiceRepliesEnabled)
        #expect(client.requests.isEmpty)
    }

    @Test func completedLocalTranscriptSubmitsAndSpeaksTheOwningSessionsReply() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        let model = model(client, playback: playback)
        model.canTranscribeVoice = { true }
        model.sessionProfileID = "voice-bot"
        try await startVoice(model)
        model.finishVoiceUtterance(transcript: "Hello")
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.requests.last?.params["voice_turn"] as? Bool == true)
        event(model, "message.complete", ["text": "Hello back."])
        for _ in 0..<100 where playback.speeches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.speeches.count == 1)
        #expect(playback.speeches.first?.text == "Hello back.")
        #expect(playback.speeches.first?.profile == "voice-bot")
        for _ in 0..<100 where model.voiceState == .speaking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.voiceState == .listening)
        #expect(model.nativeVoiceCapture.captureArmed)
    }

    @Test func changingSessionsCancelsStartupBeforeItCanEnableCapture() async throws {
        let client = VoiceQueueRPCClient()
        client.holdConnection = true
        let model = model(client)
        model.startVoiceConversation()
        for _ in 0..<100 where client.connectionContinuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.sessionID = "another-session"
        client.connectionContinuation?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.voiceState == .inactive)
        #expect(client.requests.isEmpty)
    }

    @Test func backgroundRepliesAndLatePlaybackCannotMoveVoiceIntoAnotherSession() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(client, playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": "background-session", "payload": ["text": "Do not speak"]])
        #expect(playback.speeches.isEmpty)
        model.finishVoiceUtterance(transcript: "Hello")
        event(model, "message.complete", ["text": "Owned reply"])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let stops = playback.stopped
        model.sessionID = "another-session"
        playback.continuation?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(playback.stopped > stops)
        playback.caption?("Late caption from previous session")
        #expect(model.voiceSpokenCaption == nil)
        #expect(playback.speeches.map(\.text) == ["Owned reply"])
        #expect(model.voiceState == .inactive)
        #expect(!model.nativeVoiceCapture.captureArmed)
    }

    @Test func recorderCleanupUsesTheOriginalSessionAndProfile() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.sessionProfileID = "voice-bot"
        try await startVoice(model)
        model.sessionID = "another-session"
        model.sessionProfileID = "another-bot"
        await model.voiceRequestChain?.value
        let cleanup = client.requests.filter {
            $0.params["command"] as? String == "voice off" || $0.params["action"] as? String == "stop"
        }
        #expect(cleanup.count == 2)
        #expect(
            cleanup.allSatisfy {
                $0.params["session_id"] as? String == "voice-queue" && $0.params["profile"] as? String == "voice-bot"
            })
        #expect(
            client.requests.filter { $0.method == "voice.toggle" }.allSatisfy {
                $0.params["action"] as? String == "status"
            })
    }

    @Test func lateVoiceSessionCreationCannotReplaceANewerChat() async throws {
        let client = VoiceQueueRPCClient()
        client.holdCreation = true
        let model = model(client)
        model.newChat()
        model.startVoiceConversation()
        for _ in 0..<100 where client.creationContinuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        model.newChat()
        client.creationContinuation?.resume(returning: ["session_id": "late-created-session"])
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.sessionID == nil)
        #expect(model.newSessionCreationAuthorized)
        #expect(model.voiceState == .inactive)
    }

    @Test func profileChangesEndVoiceEvenWhenTheRuntimeSessionIDStaysTheSame() async throws {
        let model = model(VoiceQueueRPCClient())
        model.canTranscribeVoice = { true }
        model.sessionProfileID = "voice-bot"
        try await startVoice(model)
        model.sessionProfileID = "another-bot"
        #expect(model.voiceState == .inactive)
        #expect(model.voiceSessionID == nil)
    }

    @Test func unavailableSessionRecorderFailsClosedWithoutEnablingGlobalVoice() async throws {
        let client = VoiceQueueRPCClient()
        client.canEnableRecorder = false
        let model = model(client)
        model.startVoiceConversation()
        for _ in 0..<300 where model.voiceState == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.voiceState == .paused)
        #expect(model.messages.last?.isError == true)
        #expect(model.messages.last?.text.contains("session-scoped voice recording") == true)
        #expect(!client.requests.contains { $0.method == "voice.record" })
        #expect(
            client.requests.filter { $0.method == "voice.toggle" }.allSatisfy {
                $0.params["action"] as? String == "status"
            })
        model.stopVoiceConversation()
        await model.voiceRequestChain?.value
    }

    @Test func aNotchClarificationSpeaksWithoutAWorkspaceView() async throws {
        let playback = VoiceQueuePlayback()
        let model = model(VoiceQueueRPCClient(), playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.stopVoiceConversation() }
        try await startVoice(model)

        event(model, "clarify.request", ["request_id": "voice-clarify", "question": "Which list?"])
        for _ in 0..<100 where !model.isVoicePromptActive || model.voiceState == .speaking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(playback.speeches.map(\.text) == ["Which list?"])
        #expect(model.isVoicePromptActive)
        #expect(model.voiceState == .listening)
    }

    @Test func spokenScreenClickIsHumanizedLocallyWithoutChangingTheChatCard() async throws {
        let playback = VoiceQueuePlayback()
        let model = model(VoiceQueueRPCClient(), playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        model.defaults.set(true, forKey: OnDeviceAssist.explainApprovalsKey)
        model.voiceStage.explainApproval = { _ in
            Issue.record("The known screen-click format should not need Apple Intelligence.")
            return nil
        }
        defer { model.shutdown() }
        try await startVoice(model)

        let command = "computer_use: click at (728, 859)"
        event(model, "approval.request", ["request_id": "click-approval", "command": command])
        for _ in 0..<100 where playback.speeches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.localSpeeches == ["I need to click on the screen. May I continue?"])
        #expect(model.currentConversationApproval?.approval.detail == command)
        #expect(model.currentConversationApproval?.resolved == false)
    }

    @Test(arguments: [true, false])
    func onDeviceApprovalExplanationIsLocalAndFallsBackWhenUnavailable(returnsExplanation: Bool) async throws {
        let playback = VoiceQueuePlayback()
        let model = model(VoiceQueueRPCClient(), playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        model.defaults.set(true, forKey: OnDeviceAssist.explainApprovalsKey)
        model.voiceStage.explainApproval = { approval in
            #expect(approval.detail == "git status")
            return returnsExplanation ? "I need to check for uncommitted changes" : nil
        }
        defer { model.shutdown() }
        try await startVoice(model)

        event(model, "approval.request", ["request_id": "status-approval", "command": "git status"])
        for _ in 0..<100 where playback.speeches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let firstLine =
            returnsExplanation
            ? "I need to check for uncommitted changes" : "A command needs approval. Check the details in chat"
        #expect(playback.localSpeeches == ["\(firstLine). May I continue?"])
        #expect(model.currentConversationApproval?.approval.detail == "git status")
    }

    @Test func anApprovalCanBeAnsweredBeforeItsExplanationArrives() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        let model = model(client, playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        model.defaults.set(true, forKey: OnDeviceAssist.explainApprovalsKey)
        var explanation: CheckedContinuation<String?, Never>?
        model.voiceStage.explainApproval = { _ in
            await withCheckedContinuation { explanation = $0 }
        }
        defer {
            explanation?.resume(returning: nil)
            model.shutdown()
        }
        try await startVoice(model)

        event(model, "approval.request", ["request_id": "slow-approval", "command": "git status"])
        for _ in 0..<100 where explanation == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(explanation != nil && model.isVoicePromptActive && model.voiceState == .listening)
        model.finishVoiceUtterance(transcript: "Yes")
        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        let narration = explanation
        explanation = nil
        narration?.resume(returning: "I need to check for uncommitted changes.")
        await Task.yield()
        let responses = client.requests.filter { $0.method == HermesFeatureIDs.ID.approvalRespond.rawValue }
        #expect(responses.map { $0.params["request_id"] as? String } == ["slow-approval"])
        #expect(responses.map { $0.params["choice"] as? String } == [ApprovalChoice.once])
        #expect(model.currentConversationApproval?.resolved == true)
        #expect(playback.speeches.isEmpty)
    }

    @Test func finalizedYesCanAllowOnceWhileApprovalIsStillSpeaking() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(client, playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)

        event(
            model, "approval.request",
            ["request_id": "still-speaking", "command": "computer_use: click at (728, 859)"])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let narration = try #require(playback.continuation)
        defer { narration.resume() }
        try #require(model.voiceState == .speaking && model.isVoicePromptActive)
        model.finishVoiceUtterance(transcript: "I need to click on the screen. May I continue?", overPlayback: true)
        #expect(model.currentConversationApproval?.resolved == false)

        model.finishVoiceUtterance(transcript: "May I continue? Yes, I allow it.", overPlayback: true)
        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        let responses = client.requests.filter { $0.method == HermesFeatureIDs.ID.approvalRespond.rawValue }
        #expect(responses.map { $0.params["request_id"] as? String } == ["still-speaking"])
        #expect(responses.map { $0.params["choice"] as? String } == [ApprovalChoice.once])
        #expect(!client.requests.contains { $0.method == "session.interrupt" })
        #expect(client.submitted.isEmpty)
    }

    @Test(arguments: ["Yes", "I allow it", "Yes, I allow it", "May I continue? Yes"])
    func spokenApprovalAllowsOnceWithoutWaitingForTheReadoutOrClicking(answer: String) async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(client, playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)

        let method = HermesFeatureIDs.ID.approvalRespond.rawValue
        event(model, "approval.request", ["request_id": "voice-approval", "command": "git status"])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let narration = try #require(playback.continuation)
        defer { narration.resume() }
        try #require(model.isVoicePromptActive && model.voiceState == .speaking)
        #expect(!model.bargeInVoiceReply(heard: "May I continue"))
        #expect(model.bargeInVoiceReply(heard: answer))
        #expect(model.voiceState == .listening)
        #expect(!client.requests.contains { $0.method == method })
        #expect(!client.requests.contains { $0.method == "session.interrupt" })

        model.finishVoiceUtterance(transcript: answer, overPlayback: true)
        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        let responses = client.requests.filter { $0.method == method }
        #expect(responses.count == 1)
        #expect(responses.first?.params["choice"] as? String == ApprovalChoice.once)
        #expect(responses.first?.params["request_id"] as? String == "voice-approval")
        #expect(model.approvalText == nil)
        #expect(model.currentConversationApproval?.resolved == true)
        #expect(client.submitted.isEmpty)
    }

    @Test func explicitRetryAfterDenialAsksForFreshApprovalInsteadOfReplayingTheOldOne() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)
        model.isHermesConnected = true
        model.voiceRepliesEnabled = false
        model.finishVoiceUtterance(transcript: "Play a song in Spotify")
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try #require(client.submitted.count == 1)

        event(model, "approval.request", ["request_id": "first", "command": "Spotify playback"])
        for _ in 0..<100 where !model.isVoicePromptActive { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.isVoicePromptActive)
        let method = HermesFeatureIDs.ID.approvalRespond.rawValue
        model.finishVoiceUtterance(transcript: "I don't want to click it myself")
        #expect(model.approvalText != nil)
        #expect(!client.requests.contains { $0.method == method })
        model.finishVoiceUtterance(transcript: "No, don't run that")
        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.currentConversationApproval?.resolved == true)
        event(model, "message.complete", ["text": "This attempt did not run."])
        for _ in 0..<100 where model.voiceState != .listening { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.voiceState == .listening)

        let retry = "Try playing that song in Spotify again"
        model.finishVoiceUtterance(transcript: retry)
        for _ in 0..<100 where client.submitted.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let freshPrompt = try #require(client.submitted.last)
        #expect(client.submitted.count == 2)
        #expect(GenerativeUIIntegration.displayUserText(freshPrompt) == retry)
        #expect(freshPrompt.contains(VoicePrompts.closedApprovalGuidance))
        let oldAnswers = client.requests.filter { $0.method == method }
        #expect(oldAnswers.count == 1)
        #expect(oldAnswers.first?.params["choice"] as? String == ApprovalChoice.deny)

        event(model, "approval.request", ["request_id": "second", "command": "Spotify playback"])
        for _ in 0..<100 where model.voiceStage.spokenApprovalID != model.currentConversationApproval?.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.finishVoiceUtterance(transcript: "Yes")
        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        let answers = client.requests.filter { $0.method == method }
        #expect(answers.count == 2)
        #expect(answers.last?.params["request_id"] as? String == "second")
        #expect(answers.last?.params["choice"] as? String == ApprovalChoice.once)
    }

    @Test func compactionStatusClearsAndNeverDisplaysForAnotherSession() async throws {
        let model = model(VoiceQueueRPCClient())
        defer { model.shutdown() }
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.voiceState = .thinking
        model.compactingSessionID = "another-session"
        #expect(!VoiceStagePresentation(model: model).isCompacting)
        event(model, "status.update", ["kind": "compressing"])
        #expect(VoiceStagePresentation(model: model).widgetStatus == "Compacting conversation")
        event(model, "status.update", ["kind": "compacted"])
        #expect(VoiceStagePresentation(model: model).widgetStatus == "Thinking")

        event(model, "status.update", ["kind": "compressing"])
        event(model, "error", ["message": "Compaction failed"])
        #expect(model.compactingSessionID == nil)
    }

    @Test func acknowledgmentFollowsTheVoiceAndProfileOfItsReply() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        let model = model(client)
        model.voiceAssistant.acknowledgmentPlayback = playback
        let fullReceipt = "I’ll check tomorrow’s forecast and see whether you’ll need an umbrella on your way to work."
        model.voiceAssistant.generateAcknowledgment = { request in
            if request == "Find tomorrow’s weather" { return fullReceipt }
            #expect(request == "What time is it?")
            return "Let me check the time."
        }
        defer { model.shutdown() }
        try await startVoice(model)
        model.voiceProfileID = "profile-a"

        model.submitNativeVoiceTranscript("Find tomorrow’s weather")
        await model.voiceAssistant.acknowledgmentTask?.value
        #expect(playback.speeches.first?.text == fullReceipt)
        #expect(playback.speeches.first?.profile == "profile-a")
        #expect(playback.localSpeeches.isEmpty)

        model.acknowledgeVoiceRequest("What time is it?")
        await model.voiceAssistant.acknowledgmentTask?.value
        #expect(playback.localSpeeches == ["Let me check the time."])
    }

    @Test(arguments: [false, true])
    func acknowledgmentEchoLastsThroughPlaybackAndAfterItStops(muted: Bool) async throws {
        let model = model(VoiceQueueRPCClient())
        let playback = VoiceQueuePlayback()
        playback.hold = true
        model.voiceAssistant.acknowledgmentPlayback = playback
        let line = "I’ll check tomorrow’s forecast and see whether you’ll need an umbrella on your way to work."
        model.voiceAssistant.generateAcknowledgment = { _ in line }
        var clock = ContinuousClock.now
        model.voiceAssistant.acknowledgmentNow = { clock }
        model.voiceState = .listening
        defer {
            playback.continuation?.resume()
            model.shutdown()
        }

        model.acknowledgeVoiceRequest("Will I need an umbrella tomorrow?")
        let task = try #require(model.voiceAssistant.acknowledgmentTask)
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let stop = try #require(playback.continuation)
        playback.caption?(line)
        clock += .seconds(10)
        #expect(model.voiceAssistant.excludingAcknowledgmentEcho(line).isEmpty)

        if muted {
            model.toggleVoiceReplies()
            #expect(playback.stopped == 1)
            #expect(model.voiceAssistant.acknowledgmentTask == nil)
        }
        playback.continuation = nil
        stop.resume()
        await task.value

        clock += .seconds(3)
        #expect(model.voiceAssistant.excludingAcknowledgmentEcho(line + " Bring it up") == "Bring it up")
        clock += .seconds(2)
        #expect(model.voiceAssistant.excludingAcknowledgmentEcho(line) == line)
    }

    @Test func replySkipsAnAcknowledgmentThatHasNotStartedSpeaking() async throws {
        let client = VoiceQueueRPCClient()
        let reply = VoiceQueuePlayback()
        let acknowledgment = VoiceQueuePlayback()
        let model = model(client, playback: reply)
        model.voiceAssistant.acknowledgmentPlayback = acknowledgment
        var pending: CheckedContinuation<String?, Never>?
        model.voiceAssistant.generateAcknowledgment = { _ in
            await withCheckedContinuation { pending = $0 }
        }
        defer {
            pending?.resume(returning: nil)
            model.shutdown()
        }
        try await startVoice(model)

        model.acknowledgeVoiceRequest("Find tomorrow’s weather", usesConversationVoice: true)
        let receipt = model.voiceAssistant.acknowledgmentTask
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(pending != nil)
        model.speakNativeVoiceReply("Tomorrow will be cloudy.")
        for _ in 0..<100 where reply.speeches.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reply.speeches.first?.text == "Tomorrow will be cloudy.")
        #expect(acknowledgment.speeches.isEmpty)

        pending?.resume(returning: "I’ll check the forecast.")
        pending = nil
        await receipt?.value
        #expect(acknowledgment.speeches.isEmpty)
    }

    @Test func anIndependentRequestQueuesBehindApprovalAndRunsOnceTheTaskFinishes() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)
        model.isHermesConnected = true
        model.voiceRepliesEnabled = false
        model.finishVoiceUtterance(transcript: "Prepare a report")
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try #require(client.submitted.count == 1)

        event(model, "approval.request", ["request_id": "held-approval", "command": "git status"])
        for _ in 0..<100 where !model.isVoicePromptActive { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.isVoicePromptActive && model.voiceState == .listening)
        let followUp = "Show the weather tomorrow"
        model.finishVoiceUtterance(transcript: followUp)
        #expect(model.queuedPrompts.map(\.text) == [followUp])
        #expect(model.voiceSpokenCaption == "Queued until the current approval and task are finished.")

        let method = HermesFeatureIDs.ID.approvalRespond.rawValue
        model.finishVoiceUtterance(transcript: "Can you run it?")
        await Task.yield()
        #expect(model.queuedPrompts.map(\.text) == [followUp])
        #expect(model.isVoicePromptActive)
        #expect(client.submitted.count == 1)
        #expect(!client.requests.contains { $0.method == method })

        model.finishVoiceUtterance(transcript: "Yes, I allow it.")
        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.submitted.count == 1)
        let decisions = client.requests.filter { $0.method == method }
        #expect(decisions.count == 1)
        #expect(decisions.first?.params["request_id"] as? String == "held-approval")
        #expect(decisions.first?.params["choice"] as? String == ApprovalChoice.once)

        event(model, "message.complete", ["text": "The report is ready."])
        for _ in 0..<100 where client.submitted.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.submitted.last.map(GenerativeUIIntegration.displayUserText) == followUp)
        #expect(client.submitted.count == 2)
        #expect(model.queuedPrompts.isEmpty)
    }

    @Test func aLocalCalculationAnswersWithoutResolvingOrSendingThePendingApproval() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)
        model.voiceRepliesEnabled = false
        event(model, "approval.request", ["request_id": "current", "command": "git status"])
        for _ in 0..<100 where !model.isVoicePromptActive { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.isVoicePromptActive)

        model.finishVoiceUtterance(transcript: "What is 2 plus 3?")
        #expect(model.voiceSpokenCaption?.contains("5") == true)
        #expect(model.currentConversationApproval?.resolved == false)
        #expect(model.queuedPrompts.isEmpty)
        #expect(client.submitted.isEmpty)
        #expect(!client.requests.contains { $0.method == HermesFeatureIDs.ID.approvalRespond.rawValue })
    }

    @Test func unclearApprovalKeepsListeningWithoutRepeatingTheReadout() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        let model = model(client, playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)

        event(model, "approval.request", ["request_id": "voice-approval", "command": "git status"])
        for _ in 0..<100 where !model.isVoicePromptActive || model.voiceState != .listening {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.isVoicePromptActive && model.voiceState == .listening)
        #expect(model.voiceMic.vocabulary.first == "Yes")
        model.finishVoiceUtterance(transcript: "Yes if it's safe")
        let method = HermesFeatureIDs.ID.approvalRespond.rawValue
        #expect(model.voiceState == .listening)
        #expect(model.isVoicePromptActive)
        #expect(model.voiceSpokenCaption?.contains("Heard “Yes if it's safe”") == true)
        #expect(playback.speeches.count == 1)
        #expect(!client.requests.contains { $0.method == method })

        model.finishVoiceUtterance(transcript: "Uh, yes yes")
        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        let approvals = client.requests.filter { $0.method == method }
        #expect(approvals.count == 1)
        #expect(approvals.first?.params["choice"] as? String == ApprovalChoice.once)
        #expect(playback.speeches.count == 1)
    }

    @Test(arguments: ["May I continue? Yes.", "I continue. I allow it.", "I allow it. I allow it."])
    func aLateTranscriptCanAnswerTheApprovalAfterPlaybackHasEnded(answer: String) async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)

        event(model, "approval.request", ["request_id": "voice-approval", "command": "git status"])
        for _ in 0..<100 where !model.isVoicePromptActive || model.voiceState != .listening {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.isVoicePromptActive && model.voiceState == .listening)
        let method = HermesFeatureIDs.ID.approvalRespond.rawValue
        model.finishVoiceUtterance(transcript: "May I continue?", overPlayback: false)
        #expect(!client.requests.contains { $0.method == method })
        model.finishVoiceUtterance(transcript: answer, overPlayback: false)

        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        let decisions = client.requests.filter { $0.method == method }
        #expect(decisions.count == 1)
        #expect(decisions.first?.params["request_id"] as? String == "voice-approval")
        #expect(decisions.first?.params["choice"] as? String == ApprovalChoice.once)
        #expect(model.approvalText == nil)
    }

    @Test func anUnpresentedReplacementApprovalDoesNotReceiveTheOldAnswer() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)
        model.voiceRepliesEnabled = false
        event(model, "approval.request", ["request_id": "original", "command": "git status"])
        for _ in 0..<100 where model.voiceStage.spokenApprovalID == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = try #require(model.voiceStage.spokenApprovalID)
        event(model, "approval.request", ["request_id": "replacement", "command": "git diff"])
        try #require(model.currentConversationApproval?.id != original)
        model.finishVoiceUtterance(transcript: "Yes")

        for _ in 0..<100 where model.voiceStage.spokenApprovalID == original {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.voiceStage.spokenApprovalID == model.currentConversationApproval?.id)
        let method = HermesFeatureIDs.ID.approvalRespond.rawValue
        #expect(!client.requests.contains { $0.method == method })
        model.finishVoiceUtterance(transcript: "Yes")
        for _ in 0..<100 where model.approvalText != nil { try await Task.sleep(for: .milliseconds(10)) }
        let submitted = client.requests.filter { $0.method == method }
        #expect(submitted.count == 1)
        #expect(submitted.first?.params["request_id"] as? String == "replacement")
    }

    @Test(arguments: [false, true])
    func privateNotchCommandsLeaveSpokenPromptsPending(isApproval: Bool) async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)
        let privateCommand: String
        let method: String
        if isApproval {
            event(model, "approval.request", ["request_id": "voice-approval", "command": "git status"])
            privateCommand = "Cancel the coffee timer."
            method = HermesFeatureIDs.ID.approvalRespond.rawValue
        } else {
            event(model, "clarify.request", ["request_id": "voice-clarify", "question": "Which list?"])
            privateCommand = "Send a text to Robin saying Please call me."
            method = HermesFeatureIDs.ID.clarifyRespond.rawValue
        }
        for _ in 0..<100 where !model.isVoicePromptActive || model.voiceState != .listening {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.isVoicePromptActive && model.voiceState == .listening)

        model.finishVoiceUtterance(transcript: privateCommand)
        await Task.yield()
        #expect(model.voiceState == .listening)
        #expect(model.isVoicePromptActive)
        #expect(model.voiceSpokenCaption == VoiceAssistantSession.pendingPromptMessage)
        #expect(!model.messages.contains { $0.text == privateCommand })
        #expect(!client.requests.contains { $0.method == method })

        model.finishVoiceUtterance(transcript: isApproval ? "Cancel." : "Groceries")
        for _ in 0..<100 where !client.requests.contains(where: { $0.method == method }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let answer = try #require(client.requests.first { $0.method == method })
        if isApproval {
            #expect(answer.params["choice"] as? String == ApprovalChoice.deny)
        } else {
            let result = answer.params["result"] as? [String: Any]
            #expect(result?["answer"] as? String == "Groceries")
        }
    }

    @Test func endingVoiceCancelsAnUnsentBriefingAndClearsItsOptimisticMessage() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.canTranscribeVoice = { true }
        var ready: CheckedContinuation<VoiceBriefing.Facts, Never>?
        model.briefingFacts = { await withCheckedContinuation { ready = $0 } }
        try await startVoice(model)
        model.finishVoiceUtterance(transcript: "Brief me")
        for _ in 0..<100 where ready == nil { try await Task.sleep(for: .milliseconds(10)) }

        model.finishVoiceUtterance(transcript: "Stop listening")
        try #require(ready).resume(returning: VoiceBriefing.Facts())
        for _ in 0..<10 { await Task.yield() }
        #expect(model.voiceState == .inactive)
        #expect(model.messages.isEmpty)
        #expect(client.submitted.isEmpty)
        #expect(!model.isSending)
    }

    @Test(arguments: [true, false])
    func interruptingContextPreparationDoesNotSend(useOrb: Bool) async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        defer { model.shutdown() }
        model.canTranscribeVoice = { true }
        var ready: CheckedContinuation<VoiceBriefing.Facts, Never>?
        model.briefingFacts = { await withCheckedContinuation { ready = $0 } }
        try await startVoice(model)
        model.finishVoiceUtterance(transcript: "Brief me")
        for _ in 0..<100 where ready == nil { try await Task.sleep(for: .milliseconds(10)) }
        let preparation = try #require(ready)

        if useOrb { _ = model.voiceOrbTapped() } else { _ = model.stop() }
        preparation.resume(returning: VoiceBriefing.Facts())
        for _ in 0..<10 { await Task.yield() }
        #expect(model.voiceState == .listening)
        #expect(model.messages.isEmpty)
        #expect(!model.isSending)
        #expect(!client.requests.contains { $0.method == "session.interrupt" || $0.method == "prompt.submit" })
    }

    @Test func cancellingDuringScreenshotUploadDoesNotReturnAReference() async throws {
        let client = VoiceQueueRPCClient()
        client.holdFile = true
        let model = model(client)
        var current = true
        let upload = Task {
            await model.stageVoiceScreenshot(Data([1]), scope: ["session_id": "voice-queue"], isCurrent: { current })
        }
        for _ in 0..<100 where client.fileContinuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        current = false
        try #require(client.fileContinuation).resume(returning: ["attached": true, "ref_text": "@file:screen.jpg"])
        #expect(await upload.value == nil)
        #expect(client.requests.map(\.method) == ["file.attach"])
    }

    @Test(arguments: [true, false])
    func screenshotUploadNeverQueuesAnImageForTheNextTurn(acknowledged: Bool) async throws {
        let client = VoiceQueueRPCClient()
        client.holdFile = true
        let model = model(client)
        let upload = Task {
            await model.stageVoiceScreenshot(
                Data([1]), scope: ["session_id": "voice-queue", "profile": "work"], isCurrent: { true })
        }
        for _ in 0..<100 where client.fileContinuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let continuation = try #require(client.fileContinuation)
        if acknowledged {
            continuation.resume(returning: ["attached": true, "ref_text": "@file:attachments/screen.jpg"])
        } else {
            continuation.resume(throwing: HermesGateway.GatewayError.httpError(500))
        }
        #expect(await upload.value == (acknowledged ? "@file:attachments/screen.jpg" : nil))
        #expect(client.requests.map(\.method) == ["file.attach"])
        let request = try #require(client.requests.first)
        #expect(request.params["session_id"] as? String == "voice-queue")
        #expect(request.params["profile"] as? String == "work")
        #expect(request.params["data_url"] as? String == "data:image/jpeg;base64,AQ==")
        #expect(request.params["name"] as? String == "screen.jpg")
    }

    @Test func aFocusedProjectionTakesTheCaptureLeaseFromNotchVoice() async throws {
        let workspace = model(VoiceQueueRPCClient())
        let notchProjection = EdgeQuickConversationModel()
        let voice = notchProjection.prepareVoice(runtime: workspace)
        let pane = DockModel(
            initialSessionID: "split-voice", rpcClient: workspace.controlRPCClient,
            voiceCapture: workspace.voiceCapture)
        defer {
            pane.stopVoiceConversation()
            notchProjection.shutdown()
        }
        voice.sessionID = "notch-voice"
        voice.voiceAssistant.hasRecognition = { true }
        pane.canTranscribeVoice = { true }

        try await startVoice(voice)
        #expect(workspace.voiceCapture.owner === voice)
        try await startVoice(pane)
        #expect(workspace.voiceCapture.owner === pane)
        #expect(voice.voiceState == .inactive)
    }

    @Test func claimingStandbyCaptureKeepsTheRequestSaidInTheSameBreath() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.voiceCapture.standby = model
        model.canTranscribeVoice = { true }
        defer { model.stopVoiceConversation() }
        model.pendingWakeRequest = "What time is it?"

        model.startVoiceConversation()
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.submitted == [VoicePrompts.conversationPrompt("What time is it?")])
        #expect(model.pendingWakeRequest == nil)
    }

    @Test func theFirstListeningWindowCanExpireWithoutARequest() async throws {
        let model = model(VoiceQueueRPCClient())
        model.canTranscribeVoice = { true }
        defer { model.stopVoiceConversation() }
        try await startVoice(model)
        model.sleepVoiceConversation()
        #expect(model.voiceState == .paused)
    }

    @Test func aSpokenOptionNameResolvesTheCurrentQuestionWithoutRunningItAsACommand() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        var openedApp = false
        model.voiceAssistant.launchBrowser = { _ in
            openedApp = true
            return AssistantReply("Opened.")
        }
        defer { model.shutdown() }
        try await startVoice(model)
        model.draft = "Leave this draft alone."
        event(
            model, "clarify.request",
            ["request_id": "choose-browser", "question": "Which option?", "choices": ["Open Chrome", "Use Safari"]])
        for _ in 0..<100 where !model.isVoicePromptActive || model.voiceState != .listening {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.isVoicePromptActive && model.voiceState == .listening)
        #expect(model.voiceMic.vocabulary.contains("Open Chrome"))
        model.voiceMic.onUtteranceEnd?("Open Chrome")
        for _ in 0..<100 where model.clarificationQuestion != nil { try await Task.sleep(for: .milliseconds(10)) }
        let answers = client.requests.filter { $0.method == HermesFeatureIDs.ID.clarifyRespond.rawValue }
        #expect(answers.count == 1)
        #expect(answers.first?.params["id"] as? String == "choose-browser")
        #expect((answers.first?.params["result"] as? [String: Any])?["answer"] as? String == "Open Chrome")
        #expect(!openedApp)
        #expect(model.draft == "Leave this draft alone.")
        #expect(model.clarificationQuestion == nil)
    }

    @Test func anExplicitOptionCanCutInButTheSpokenListCannotAnswerItself() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(client, playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)
        event(
            model, "clarify.request",
            ["request_id": "choose-list", "question": "Which list?", "choices": ["Work", "Family"]])
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        let narration = try #require(playback.continuation)
        defer { narration.resume() }
        let method = HermesFeatureIDs.ID.clarifyRespond.rawValue
        #expect(!model.bargeInVoiceReply(heard: "Family"))
        model.finishVoiceUtterance(transcript: "Two. Family.", overPlayback: true)
        #expect(!client.requests.contains { $0.method == method })
        model.finishVoiceUtterance(transcript: "Two. Family. Choose option two.", overPlayback: true)
        for _ in 0..<100 where model.clarificationQuestion != nil { try await Task.sleep(for: .milliseconds(10)) }
        let answers = client.requests.filter { $0.method == method }
        #expect(answers.count == 1)
        #expect((answers.first?.params["result"] as? [String: Any])?["answer"] as? String == "Family")
        #expect(!client.requests.contains { $0.method == "session.interrupt" })
        #expect(model.clarificationQuestion == nil)
    }

    @Test func batchClarificationCanRetryThenAdvancesWithoutReusingTheOldQuestion() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        let model = model(client, playback: playback)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)
        model.voiceRepliesEnabled = false
        event(
            model, "clarify.request",
            [
                "request_id": "batch", "question": "Which env?",
                "questions": [
                    ["qid": "env", "question": "Which env?", "choices": ["Staging", "Production"]],
                    [
                        "qid": "days", "question": "Which days?", "choices": ["Monday", "Tuesday", "Friday"],
                        "multi_select": true,
                    ],
                ],
            ])
        for _ in 0..<100 where !model.isVoicePromptActive || model.voiceState != .listening {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.isVoicePromptActive && model.voiceState == .listening)
        let method = HermesFeatureIDs.ID.clarifyLock.rawValue
        model.finishVoiceUtterance(transcript: "Staging or Production")
        #expect(model.voiceSpokenCaption?.contains("Heard") == true)
        #expect(!client.requests.contains { $0.method == method })
        client.clarificationError = CocoaError(.fileReadUnknown)
        model.finishVoiceUtterance(transcript: "Option one")
        for _ in 0..<100 where model.isRespondingToClarification { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.voiceState == .listening)
        #expect(model.clarificationQuestion == "Which env?")
        #expect(model.voiceSpokenCaption?.hasPrefix("Couldn’t send that answer") == true)

        client.clarificationError = nil
        model.finishVoiceUtterance(transcript: "Staging")
        for _ in 0..<100 where !model.voiceMic.vocabulary.contains("Friday") {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.clarificationQuestion == "Which days?")
        model.finishVoiceUtterance(transcript: "One and Friday")
        for _ in 0..<100 where model.clarificationQuestion != nil { try await Task.sleep(for: .milliseconds(10)) }
        let locks = client.requests.filter { $0.method == method }
        #expect(locks.map { $0.params["question_id"] as? String } == ["env", "env", "days"])
        #expect(locks.map { $0.params["answer"] as? String } == ["Staging", "Staging", #"["Monday","Friday"]"#])
        #expect(model.clarificationQuestion == nil)
        #expect(playback.speeches.isEmpty)
        #expect(model.messages.filter { $0.role == .user && $0.text == "Staging" }.count == 1)
    }

    @Test func spokenAnswerToAnExpiredClarificationClearsTheQuestion() async throws {
        let client = VoiceQueueRPCClient()
        client.clarificationResult = ["status": "expired"]
        let model = model(client)
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { true }
        defer { model.shutdown() }
        try await startVoice(model)
        model.voiceRepliesEnabled = false
        event(model, "clarify.request", ["request_id": "expired", "question": "What size?"])
        for _ in 0..<100 where !model.isVoicePromptActive { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.isVoicePromptActive)
        model.finishVoiceUtterance(transcript: "Medium")
        for _ in 0..<100 where model.clarificationQuestion != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.clarificationQuestion == nil)
        #expect(!model.isVoicePromptActive)
        #expect(model.voiceState == .listening)
        #expect(model.voiceSpokenCaption?.contains("expired") == true)
    }

    @Test func spokenQuestionReopensCaptureWhileTheTurnWaitsForItsAnswer() async throws {
        let client = VoiceQueueRPCClient()
        let playback = VoiceQueuePlayback()
        let model = model(client, playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.isSending = true
        model.status = .needsClarification
        model.presentVoicePrompt("Which option should I use?")
        for _ in 0..<100 where model.voiceState == .speaking { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.speeches.map(\.text) == ["Which option should I use?"])
        #expect(model.voiceState == .listening)
        #expect(model.isVoicePromptActive)
        #expect(model.nativeVoiceCapture.captureArmed)
        model.presentVoicePrompt(nil)
        #expect(model.voiceState == .thinking)
        #expect(!model.isVoicePromptActive)
        #expect(client.requests.isEmpty)
    }

    @Test func captionsWaitForAudioAndFollowTheSegmentActuallyPlaying() async throws {
        let playback = VoiceQueuePlayback()
        playback.hold = true
        let model = model(VoiceQueueRPCClient(), playback: playback)
        model.canTranscribeVoice = { true }
        try await startVoice(model)
        model.speakNativeVoiceReply("First sentence. Second sentence.")
        for _ in 0..<100 where playback.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.voiceSpokenCaption == nil, "Waiting for synthesis must not advance the captions")
        playback.caption?("First sentence.")
        #expect(model.voiceSpokenCaption == "First sentence.")
        playback.caption?(nil)
        #expect(model.voiceSpokenCaption == nil)
        playback.caption?("Second sentence.")
        #expect(model.voiceSpokenCaption == "Second sentence.")
        model.stopVoiceConversation()
        playback.continuation?.resume()
        #expect(model.voiceSpokenCaption == nil)
    }

    @Test func idleChatImmediatelySendsAParkedDraft() {
        let model = model(VoiceQueueRPCClient())
        event(model, "message.complete", ["text": "Finished"])
        model.draft = "Follow up"
        model.queueDraft()
        #expect(model.queuedPrompts.isEmpty)
        #expect(model.isSending)
        #expect(model.messages.last?.text == "Follow up")
    }

    @Test func terminalErrorReleasesTheNextChatMessage() {
        let model = model(VoiceQueueRPCClient())
        model.status = .working
        model.isSending = true
        model.draft = "Follow up"
        model.queueDraft()
        event(model, "error", ["message": "The turn failed"])
        #expect(model.queuedPrompts.isEmpty)
        #expect(model.isSending)
        #expect(model.messages.last?.text == "Follow up")
    }

    @Test func stopAcknowledgmentDoesNotWaitForAReplyThatNeverStarts() async throws {
        let client = VoiceQueueRPCClient()
        client.promptResult = ["voice_stopped": true]
        let model = model(client)
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "Stop"])
        for _ in 0..<100 where model.isSending { try await Task.sleep(for: .milliseconds(10)) }
        #expect(client.submitted == [VoicePrompts.conversationPrompt("Stop")])
        #expect(!model.isSending)
        #expect(model.status == .idle)
        #expect(model.voiceState == .inactive)
    }

    @Test func recorderIdleCannotReopenCaptureDuringAnActiveReply() async throws {
        let model = model(VoiceQueueRPCClient())
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "First request"])
        event(model, "voice.status", ["state": "idle"])
        #expect(model.isSending)
        #expect(model.voiceState == .thinking)
    }

    @Test func spokenRequestKeepsTheSessionProfileThroughItsReply() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.sessionProfileID = "voice-bot"
        model.profileScopeID = "another-bot"
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "Hello"])
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        let voiceRequests = client.requests.filter { $0.method.hasPrefix("voice.") || $0.method == "prompt.submit" }
        #expect(voiceRequests.allSatisfy { $0.params["profile"] as? String == "voice-bot" })
        #expect(client.submitted == [VoicePrompts.conversationPrompt("Hello")])
        #expect(model.voiceState == .thinking)
        event(model, "message.start")
        event(model, "message.delta", ["delta": "Hello back."])
        event(model, "message.complete", ["text": "Hello back."])
        #expect(model.messages.last?.text == "Hello back.")
        #expect(model.voiceState == .speaking)
        #expect(model.nativeVoiceCapture.isAwaitingPlaybackDrain)
    }

    @Test func lateRecorderTranscriptsCannotResetAPendingReplyOrPlayback() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "Hello"])
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        for payload: [String: Any] in [[:], ["no_speech_limit": true], ["text": "duplicate"]] {
            event(model, "voice.transcript", payload)
            #expect(model.isSending)
            #expect(model.voiceState == .thinking)
            #expect(model.nativeVoiceCapture.hasPendingTranscript)
        }
        event(model, "message.complete", ["text": "Hello back."])
        event(model, "voice.transcript")
        #expect(model.voiceState == .speaking)
        #expect(model.nativeVoiceCapture.isAwaitingPlaybackDrain)
        #expect(client.submitted.count == 1)
    }

    @Test func onDeviceTranscriptUsesTheSessionProfileAndKeepsTheComposerDraft() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        model.sessionProfileID = "voice-bot"
        model.voiceState = .listening
        model.nativeCaptureIsLocal = true
        model.draft = "Keep this draft"
        model.finishVoiceUtterance(transcript: "Hello")
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        #expect(client.requests.last?.params["profile"] as? String == "voice-bot")
        #expect(client.submitted == [VoicePrompts.conversationPrompt("Hello")])
        #expect(model.draft == "Keep this draft")
        #expect(model.isSending)
        #expect(model.voiceState == .thinking)
    }

    @Test func nativeBargeInTransfersPlaybackToTheNextSpokenRequest() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "Hello"])
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        event(model, "message.complete", ["text": "Hello back."])
        event(model, "voice.interrupted")
        event(model, "voice.transcript", ["text": "Another question"])
        for _ in 0..<100 where client.submitted.count < 2 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(client.submitted == ["Hello", "Another question"].map { VoicePrompts.conversationPrompt($0) })
        #expect(model.voiceState == .thinking)
        #expect(model.nativeVoiceCapture.hasPendingTranscript)
        #expect(!model.nativeVoiceCapture.isAwaitingPlaybackDrain)
    }

    @Test func failedVoiceSubmissionPausesWithAnErrorInsteadOfRestartingCapture() async throws {
        let client = VoiceQueueRPCClient()
        client.promptError = NSError(
            domain: "Hermes", code: 4001,
            userInfo: [NSLocalizedDescriptionKey: "session not found"])
        let model = model(client)
        try await startVoice(model)
        let captures = client.requests.filter { $0.method == "voice.record" }.count
        event(model, "voice.transcript", ["text": "Hello"])
        for _ in 0..<100 where model.isSending { try await Task.sleep(for: .milliseconds(10)) }

        #expect(!model.isSending)
        #expect(model.voiceState == .paused)
        #expect(model.messages.last?.isError == true)
        #expect(model.messages.last?.text.contains("couldn’t submit the voice request") == true)
        #expect(client.requests.filter { $0.method == "voice.record" }.count == captures)
        event(model, "voice.status", ["state": "idle"])
        event(model, "voice.transcript")
        event(model, "voice.interrupted")
        #expect(model.voiceState == .paused)
    }

    @Test func spokenStopStillEndsVoiceWhileAReplyIsPending() {
        let model = model(VoiceQueueRPCClient())
        model.voiceState = .thinking
        model.isSending = true
        event(model, "voice.transcript", ["stop_phrase": true, "text": "Stop"])
        #expect(model.voiceState == .inactive)
    }

    @Test(arguments: ["error", "message.complete"])
    func backendFailurePausesVoiceWithTheReportedError(_ type: String) async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "Hello"])
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        event(model, "message.start")
        event(model, type, ["message": "Provider unavailable", "error": "Provider unavailable"])

        #expect(!model.isSending)
        #expect(model.messages.last?.isError == true)
        #expect(model.voiceState == .paused)
        #expect(!model.nativeVoiceCapture.isAwaitingPlaybackDrain)
        event(model, "voice.status", ["state": "idle"])
        event(model, "voice.interrupted")
        #expect(model.voiceState == .paused)
    }

    @Test func speechAfterAnIdleTransitionDoesNotRemainInTheQueue() async throws {
        let model = model(VoiceQueueRPCClient())
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "First request"])
        event(model, "clarify.expire")
        model.finishVoiceUtterance(transcript: "Follow up")
        #expect(model.queuedPrompts.isEmpty)
        #expect(model.isSending)
        #expect(model.messages.last?.text == "Follow up")
    }

    @Test func queuedVoiceTurnWaitsForPlaybackAndNewBackendTurnOwnsThinking() async throws {
        let model = model(VoiceQueueRPCClient())
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "First request"])
        model.draft = "Follow up"
        model.queueDraft()
        event(model, "message.complete", ["text": "The first answer"])
        #expect(model.queuedPrompts.count == 1)
        #expect(!model.isSending)
        #expect(model.voiceState == .speaking)
        event(model, "message.start")
        #expect(model.isSending)
        #expect(model.voiceState == .thinking)
    }

    @Test func playbackCompletionSendsTheNextVoiceMessageExactlyOnce() async throws {
        let client = VoiceQueueRPCClient()
        let model = model(client)
        try await startVoice(model)
        event(model, "voice.transcript", ["text": "First request"])
        for _ in 0..<100 where client.submitted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        model.draft = "Follow up"
        model.queueDraft()
        event(model, "message.complete", ["text": "Done"])
        let deadline = Date().addingTimeInterval(6)
        while client.submitted.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.submitted == ["First request", "Follow up"].map { VoicePrompts.conversationPrompt($0) })
        #expect(client.queuedSubmissions == [false, true])
        #expect(model.queuedPrompts.isEmpty)
        #expect(model.isSending)
        #expect(model.voiceState == .thinking)
    }

    @Test func deliberatelyStoppedChatKeepsItsQueueUntilTheUserResumes() async {
        let model = model(VoiceQueueRPCClient())
        model.status = .working
        model.isSending = true
        model.draft = "Follow up"
        model.queueDraft()
        await model.stop()?.value
        event(model, "message.complete", ["text": "Interrupted"])
        #expect(model.queuedPrompts.count == 1)
        #expect(!model.isSending)
        model.submitComposerInput()
        #expect(model.queuedPrompts.isEmpty)
        #expect(model.isSending)
        #expect(model.messages.last?.text == "Follow up")
    }
}
