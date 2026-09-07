import Foundation
import Testing
@testable import HermesAgentDock

/// Records every RPC request and returns scripted responses. `onEvent` fires
/// while `request` is still in flight so tests can interleave gateway events
/// with an open session switch, exactly like a second session streaming while
/// the user opens another conversation.
@MainActor
private final class SessionIsolationRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requests: [(method: String, params: [String: Any])] = []
    var resumeResponses: [[String: Any]] = []
    /// Closure invoked during the `session.resume` await, before its response resolves.
    var duringResume: (() -> Void)?

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        switch method {
        case "session.resume":
            duringResume?()
            let index = requests.filter { $0.method == "session.resume" }.count - 1
            return index < resumeResponses.count ? resumeResponses[index] : ["session_id": params["session_id"] as? String ?? "", "messages": []]
        default:
            return [:]
        }
    }

    func close() {}
}

@MainActor
private struct Fixtures {
    static let sessionA = "session-a"
    static let sessionB = "session-b"

    static var sessionAResponse: [String: Any] {
        [
            "session_id": sessionA,
            "messages": [
                ["role": "user", "content": "question in session A"],
                ["role": "assistant", "content": "answer in session A"]
            ]
        ]
    }

    static func messageEvent(_ type: String, sessionID: String?, delta: String? = nil, text: String? = nil) -> (String, [String: Any]) {
        var params: [String: Any] = [:]
        if let sessionID { params["session_id"] = sessionID }
        var payload: [String: Any] = [:]
        if let delta { payload["delta"] = delta }
        if let text { payload["text"] = text }
        params["payload"] = payload
        return (type, params)
    }
}

@MainActor
struct SessionConversationIsolationTests {
    @Test func taggedStreamFromRespondingSessionDoesNotEnterOpenSession() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.sessionID == Fixtures.sessionA }

        model.receiveGatewayEvent("message.start", params: ["session_id": Fixtures.sessionB, "payload": [:]])
        model.receiveGatewayEvent("message.delta", params: ["session_id": Fixtures.sessionB, "payload": ["delta": "secret from session B"]])
        model.receiveGatewayEvent("message.complete", params: ["session_id": Fixtures.sessionB, "payload": [:]])

        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
        #expect(model.streamingText.text.isEmpty)
    }

    @Test func untaggedStreamFromRespondingSessionDoesNotEnterOpenSession() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.sessionID == Fixtures.sessionA }

        model.receiveGatewayEvent("message.start", params: ["payload": [:]])
        model.receiveGatewayEvent("message.delta", params: ["payload": ["delta": "secret from session B"]])
        model.receiveGatewayEvent("message.complete", params: ["payload": [:]])

        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
        #expect(model.streamingText.text.isEmpty)
    }

    @Test func respondingSessionEventsDuringResumeWindowDoNotEnterOpeningSession() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        rpc.duringResume = {
            model.receiveGatewayEvent("message.start", params: ["session_id": Fixtures.sessionB, "payload": [:]])
            model.receiveGatewayEvent("message.delta", params: ["session_id": Fixtures.sessionB, "payload": ["delta": "secret from session B"]])
        }
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(model.sessionID == Fixtures.sessionA)
        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
        #expect(model.streamingText.text.isEmpty)
    }

    @Test func resumeResponseForAnotherSessionDoesNotAdoptThatConversation() async throws {
        let rpc = SessionIsolationRPCClient()
        // Hermes returns the currently active (responding) session's identity
        // and messages instead of the requested session's.
        rpc.resumeResponses = [
            [
                "session_id": Fixtures.sessionB,
                "messages": [
                    ["role": "user", "content": "question in session B"],
                    ["role": "assistant", "content": "answer in session B"]
                ]
            ]
        ]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(model.sessionID == Fixtures.sessionA)
        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
    }

    @Test func resumeResponseForkingTheRequestedSessionIsAdopted() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            [
                "session_id": "runtime-fork",
                "session_key": Fixtures.sessionA,
                "messages": [
                    ["role": "user", "content": "question in session A"],
                    ["role": "assistant", "content": "answer in session A"]
                ]
            ]
        ]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(model.sessionID == "runtime-fork")
        #expect(model.messages.contains { $0.text == "question in session A" })
    }

    @Test func resumeOfCanonicalBotChatMayResolveToAFreshSessionID() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            [
                "session_id": "sentry-session",
                "session_key": BotService.canonicalBotChatTitle,
                "messages": []
            ]
        ]
        let model = DockModel(rpcClient: rpc)
        let sentry = BotSummary(
            id: "sentry",
            name: "Sentry",
            title: nil,
            description: nil,
            model: nil,
            isActive: false,
            chat: nil,
            avatarURL: nil,
            preview: nil,
            lastActive: nil,
            isHidden: false,
            hasAvatar: false,
            isDefault: false
        )
        model.resumeBotChat(sentry)
        try await waitUntil { model.sessionID == "sentry-session" }

        #expect(model.messages.isEmpty)
    }

    @Test func canonicalBotChatDoesNotAdoptAnUnrelatedResumeResponse() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            [
                "session_id": Fixtures.sessionB,
                "messages": [
                    ["role": "assistant", "content": "answer in session B"]
                ]
            ]
        ]
        let model = DockModel(rpcClient: rpc)
        let sentry = BotSummary(
            id: "sentry", name: "Sentry", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: false
        )

        model.resumeBotChat(sentry)
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(model.sessionID == BotService.canonicalBotChatTitle)
        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
    }
}

@MainActor
private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}
