import Foundation
import Testing

@testable import Herm

@MainActor
private final class VoiceQueueRPCClient: HermesRPCClientProtocol {
  var onEvent: ((String, [String: Any]) -> Void)?
  var promptResult: [String: Any] = ["status": "streaming"]
  var submitted: [String] = []
  var queuedSubmissions: [Bool] = []
  func connect() async throws {}
  func close() {}
  func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
    if method == "voice.toggle" { return ["available": true, "stt_available": true, "tts": true] }
    if method == "voice.record" { return ["status": "recording"] }
    if method == "prompt.submit" {
      submitted.append(params["text"] as? String ?? "")
      queuedSubmissions.append(params["queued"] as? Bool ?? false)
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
