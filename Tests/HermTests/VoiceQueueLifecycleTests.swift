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
    var holdConnection = false
    var connectionContinuation: CheckedContinuation<Void, Never>?
    var holdCreation = false
    var creationContinuation: CheckedContinuation<[String: Any], Never>?
    func connect() async throws {
        if holdConnection { await withCheckedContinuation { connectionContinuation = $0 } }
    }
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if method == "session.create", holdCreation {
            return await withCheckedContinuation { creationContinuation = $0 }
        }
        if method == "voice.toggle" { return ["available": true, "stt_available": true, "tts": true] }
        if method == "slash.exec", let command = params["command"] as? String {
            voiceMode = command == "voice on" && canEnableRecorder ? "voice_only" : "off"
            return [:]
        }
        if method == "config.get", params["key"] as? String == "voice" { return ["value": voiceMode] }
        if method == "voice.record" { return ["status": "recording"] }
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
private final class VoiceQueuePlayback: HermesVoicePlaybackProtocol {
    var speeches: [(text: String, profile: String?)] = []
    var stopped = 0
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    var caption: (@MainActor (String?) -> Void)?
    func speak(
        _ text: String, profileID: String?, client: HermesRPCClientProtocol,
        onCaption: @escaping @MainActor (String?) -> Void
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
        DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "voice-queue-\(UUID().uuidString).json"),
            initialSessionID: "voice-queue", rpcClient: client, voicePlayback: playback)
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
