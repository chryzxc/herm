import AppKit
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class DeliveryVoiceRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [(String, [String: Any])] = []

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        if method == "voice.toggle" { return ["available": true, "stt_available": true] }
        if method == "config.get", params["key"] as? String == "voice" {
            throw NSError(
                domain: "HermesRPC", code: 4002,
                userInfo: [NSLocalizedDescriptionKey: "unknown config key: voice"])
        }
        if method == "voice.record" { return ["status": "recording"] }
        return [:]
    }
}

@MainActor
struct DeliveryBugReproductionTests {
    @Test func supportedRecorderStartsWithoutAnOptionalVoiceConfigGetter() async throws {
        let client = DeliveryVoiceRPC()
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("delivery-voice-\(UUID().uuidString).json"),
            initialSessionID: "delivery-voice", rpcClient: client)
        model.canTranscribeVoice = { false }
        model.startVoiceConversation()
        for _ in 0..<300 where model.voiceState == .preparing {
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.voiceRequestChain?.value
        #expect(client.requests.contains { $0.0 == "voice.record" && $0.1["action"] as? String == "start" })
        #expect(model.voiceState == .listening)
        #expect(!client.requests.contains { $0.0 == "config.get" && $0.1["key"] as? String == "voice" })
        model.stopVoiceConversation()
        await model.voiceRequestChain?.value
    }
}
