import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
private final class DirectBotRoutingRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requests: [(method: String, params: [String: Any])] = []

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        switch method {
        case "session.resume":
            return [
                "session_id": "sentry-session",
                "session_key": BotService.canonicalBotChatTitle,
                "messages": []
            ]
        case "prompt.submit":
            return [:]
        default:
            return [:]
        }
    }

    func close() {}
}

@MainActor
struct DirectBotRoutingTests {
    @Test func explicitBotRequestResumesTheProfileScopedBotChatBeforeSubmitting() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("direct-bot-routing-\(UUID().uuidString).json"),
            initialSessionID: "ordinary-session",
            rpcClient: rpc
        )

        model.sendDirectBotRequest(profileID: "sentry", displayName: "Sentry", text: "audit the codebase")
        for _ in 0..<50 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let resume = try #require(rpc.requests.first(where: { $0.method == "session.resume" }))
        #expect(resume.params["profile"] as? String == "sentry")
        #expect(resume.params["session_id"] as? String == BotService.canonicalBotChatTitle)
        let submit = try #require(rpc.requests.first(where: { $0.method == "prompt.submit" }))
        #expect(submit.params["session_id"] as? String == "sentry-session")
        #expect(submit.params["text"] as? String == "audit the codebase")
        #expect(model.activeBotProfileID == "sentry")
    }
}
