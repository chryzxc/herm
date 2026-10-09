import Foundation
import Testing
@testable import Herm

@MainActor
private final class DirectBotRoutingRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onRelay: (() -> Void)?
    var relayResult: [String: Any] = ["reply": "The audit is complete."]
    private(set) var requests: [(method: String, params: [String: Any])] = []

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        switch method {
        case "bot_relay.deliver":
            onRelay?()
            return relayResult
        default:
            return [:]
        }
    }

    func close() {}
}

@MainActor
struct DirectBotRoutingTests {
    @Test func composerMentionUsesCurrentChatAndLeavesDeliveryToHermesAgent() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = DockModel(initialSessionID: "ordinary-session", rpcClient: rpc)
        model.draft = "@cypher audit the codebase"
        model.submitComposerInput(mentionProfiles: ["cypher"])
        for _ in 0..<50 where !rpc.requests.contains(where: { $0.method == "prompt.submit" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let submit = try #require(rpc.requests.first(where: { $0.method == "prompt.submit" }))
        #expect(submit.params["session_id"] as? String == "ordinary-session")
        #expect((submit.params["text"] as? String)?.contains("message_agent target: \"cypher\"") == true)
        #expect(!rpc.requests.contains(where: { $0.method == "bot_relay.deliver" }))
        #expect(model.messages.first?.text == "@cypher audit the codebase")
        model.shutdown()
    }

    @Test func relayWaitsForAgentWorkWithoutSlowingControlRequests() {
        #expect(HermesGateway.requestTimeout(for: "bot_relay.deliver") == 1500)
        #expect(HermesGateway.requestTimeout(for: "session.list") == 15)
    }

    @Test func explicitBotRequestRelaysIntoTheCurrentConversationWithoutResuming() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("direct-bot-routing-\(UUID().uuidString).json"),
            initialSessionID: "ordinary-session",
            botActivityFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("direct-bot-activity-\(UUID().uuidString).json"),
            rpcClient: rpc
        )

        model.sendDirectBotRequest(profileID: "sentry", displayName: "Sentry", text: "audit the codebase")
        for _ in 0..<50 where !rpc.requests.contains(where: { $0.method == "bot_relay.deliver" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let relay = try #require(rpc.requests.first(where: { $0.method == "bot_relay.deliver" }))
        #expect(relay.params["profile"] as? String == "sentry")
        #expect(relay.params["message"] as? String == "audit the codebase")
        #expect(!rpc.requests.contains(where: { $0.method == "session.resume" }))
        #expect(model.sessionID == "ordinary-session")
        #expect(model.messages.map(\.text) == ["@Sentry audit the codebase", "The audit is complete."])
        #expect(model.messages.first?.botProfileID == "sentry")
        #expect(model.messages.first?.botDisplayName == "Sentry")
        #expect(model.messages.last?.botProfileID == "sentry")
    }

    @Test func unrelatedGatewayEventDoesNotBindUnresolvedBotActivity() async throws {
        let rpc = DirectBotRoutingRPCClient()
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("direct-bot-unbound-\(UUID().uuidString).json"),
            initialSessionID: "ordinary-session",
            botActivityFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("direct-bot-unbound-activity-\(UUID().uuidString).json"),
            rpcClient: rpc
        )
        rpc.onRelay = {
            model.receiveGatewayEvent("message.start", params: ["session_id": "unrelated-session"])
        }

        model.sendDirectBotRequest(profileID: "sentry", displayName: "Sentry", text: "audit the codebase")
        for _ in 0..<50 where !rpc.requests.contains(where: { $0.method == "bot_relay.deliver" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let activity = try #require(model.botActivityBySessionID["ordinary-session"]?.first)
        #expect(activity.botChatSessionID == nil)
    }

    @Test func everyBotReceivesTheCurrentSessionContext() {
        let context = [
            ChatMessage(role: .user, text: "We are reviewing the origin repository."),
            ChatMessage(role: .hermes, text: "The repository is loaded.")
        ]
        let message = DockModel.botRelayMessage(request: "check security", transcript: context)

        #expect(message.contains("User: We are reviewing the origin repository."))
        #expect(message.contains("Assistant: The repository is loaded."))
        #expect(message.contains("Respond to this request: check security"))
    }

    @Test func emptyRelayAcknowledgmentDoesNotResubmitThroughBotChat() async throws {
        let rpc = DirectBotRoutingRPCClient()
        rpc.relayResult = ["accepted": true]
        let model = DockModel(
            initialSessionID: "ordinary-session",
            botActivityFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("direct-bot-empty-\(UUID().uuidString).json"),
            rpcClient: rpc
        )

        model.sendDirectBotRequest(profileID: "sentry", displayName: "Sentry", text: "audit the codebase")
        for _ in 0..<50 where !rpc.requests.contains(where: { $0.method == "bot_relay.deliver" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(rpc.requests.map(\.method) == ["bot_relay.deliver"])
        #expect(model.botActivityBySessionID["ordinary-session"]?.first?.state == .queued)
    }

    @Test func synchronousReplyWithEmptySessionIDCompletesWithoutFallback() async throws {
        let rpc = DirectBotRoutingRPCClient()
        rpc.relayResult = ["reply": "The audit is complete.", "session_id": ""]
        let model = DockModel(
            initialSessionID: "ordinary-session",
            botActivityFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("direct-bot-empty-session-\(UUID().uuidString).json"),
            rpcClient: rpc
        )

        model.sendDirectBotRequest(profileID: "sentry", displayName: "Sentry", text: "audit the codebase")
        for _ in 0..<50 where !rpc.requests.contains(where: { $0.method == "bot_relay.deliver" }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(rpc.requests.map(\.method) == ["bot_relay.deliver"])
        #expect(model.messages.last?.text == "The audit is complete.")
        #expect(model.botActivityBySessionID["ordinary-session"]?.first?.state == .completed)
    }
}
