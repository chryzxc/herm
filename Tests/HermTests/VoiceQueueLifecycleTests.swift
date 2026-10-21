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
  func connect() async throws {}
  func close() {}
  func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
    requests.append((method, params))
    if method == "voice.toggle" { return ["available": true, "stt_available": true, "tts": true] }
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
struct VoiceQueueLifecycleTests {
  private func model(_ client: VoiceQueueRPCClient) -> DockModel {
    DockModel(
      sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
        "voice-queue-\(UUID().uuidString).json"),
      initialSessionID: "voice-queue", rpcClient: client)
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
    #expect(client.submitted == [GenerativeUIIntegration.preparePrompt("Stop")])
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
    #expect(client.submitted == [GenerativeUIIntegration.preparePrompt("Hello")])
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
    #expect(client.submitted == [GenerativeUIIntegration.preparePrompt("Hello")])
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

    #expect(client.submitted == ["Hello", "Another question"].map { GenerativeUIIntegration.preparePrompt($0) })
    #expect(model.voiceState == .thinking)
    #expect(model.nativeVoiceCapture.hasPendingTranscript)
    #expect(!model.nativeVoiceCapture.isAwaitingPlaybackDrain)
  }

  @Test func failedVoiceSubmissionPausesWithAnErrorInsteadOfRestartingCapture() async throws {
    let client = VoiceQueueRPCClient()
    client.promptError = NSError(domain: "Hermes", code: 4001,
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
    #expect(client.submitted == ["First request", "Follow up"].map { GenerativeUIIntegration.preparePrompt($0) })
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
