import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
private final class MessageActionRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requests: [(method: String, params: [String: Any])] = []
    var branchResponse: [String: Any] = [:]
    var resumeResponse: [String: Any] = [:]
    var resumeDelay: Duration = .zero

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        switch method {
        case "session.branch": return branchResponse
        case "session.resume":
            if resumeDelay != .zero { try await Task.sleep(for: resumeDelay) }
            return resumeResponse.isEmpty
            ? ["session_id": params["session_id"] as? String ?? "", "messages": []]
            : resumeResponse
        default: return [:]
        }
    }

    func close() {}
}

@MainActor
struct ConversationMessageActionsTests {
    @Test func readableTextRemovesMarkdownAffordancesButKeepsContent() {
        let text = ConversationMessageActionState.readableText("# Answer\n\n**Use** [this](https://example.com) and `code`.")

        #expect(text == "Answer\n\nUse this and code.")
    }

    @Test func readableTextPreservesLiteralUnderscores() {
        let text = ConversationMessageActionState.readableText("Use foo_bar and `snake_case`.")

        #expect(text == "Use foo_bar and snake_case.")
    }

    @Test func pendingActionsAreScopedAndDuplicateRunsAreIgnored() async throws {
        let state = ConversationMessageActionState()
        let firstID = UUID()
        let secondID = UUID()
        var firstRuns = 0
        var secondRuns = 0

        state.run(firstID) {
            firstRuns += 1
            try? await Task.sleep(for: .milliseconds(20))
        }
        state.run(firstID) { firstRuns += 1 }
        state.run(secondID) { secondRuns += 1 }

        #expect(state.isPending(firstID))
        #expect(state.isPending(secondID))
        try await waitUntil { !state.isPending(firstID) && !state.isPending(secondID) }
        #expect(firstRuns == 1)
        #expect(secondRuns == 1)
        #expect(!state.isPending(firstID))
        #expect(!state.isPending(secondID))
    }

    @Test func branchSendsSourceMessageAndSelectsReturnedBranch() async throws {
        let rpc = MessageActionRPCClient()
        rpc.branchResponse = ["session_id": "branch-session"]
        rpc.resumeResponse = [
            "session_id": "branch-session",
            "messages": [["role": "assistant", "content": "branched answer"]]
        ]
        let model = DockModel(initialSessionID: "source-session", rpcClient: rpc)
        let message = ChatMessage(id: UUID(), role: .hermes, text: "source answer")

        await model.branchConversation(from: message)
        try await waitUntil { model.sessionID == "branch-session" && model.status == .idle }

        let branch = rpc.requests.first { $0.method == "session.branch" }
        #expect(branch?.params["session_id"] as? String == "source-session")
        #expect(branch?.params["message_id"] as? String == message.id.uuidString)
        #expect(model.sessionID == "branch-session")
        #expect(model.messages.last?.text == "branched answer")
    }

    @Test func refreshProjectsAuthoritativeMessagesAndCompletesOnMalformedResponse() async throws {
        let rpc = MessageActionRPCClient()
        rpc.resumeResponse = [
            "session_id": "source-session",
            "messages": [["role": "assistant", "content": "authoritative answer"]]
        ]
        let model = DockModel(initialSessionID: "source-session", rpcClient: rpc)

        await model.refreshCurrentSession()
        try await waitUntil { model.status == .idle && model.messages.count == 1 }
        #expect(model.messages[0].text == "authoritative answer")
        #expect(rpc.requests.contains { $0.method == "session.resume" })

        rpc.resumeResponse = ["session_id": "source-session", "messages": "malformed"]
        await model.refreshCurrentSession()
        try await waitUntil { model.status == .offline }
        #expect(model.sessionID == "source-session")
        #expect(model.messages.count == 1)
        #expect(model.messages[0].text == "authoritative answer")
    }

    @Test func branchPendingStateCoversResumeAndSuppressesDuplicateBranch() async throws {
        let rpc = MessageActionRPCClient()
        rpc.branchResponse = ["session_id": "branch-session"]
        rpc.resumeDelay = .milliseconds(50)
        rpc.resumeResponse = [
            "session_id": "branch-session",
            "messages": [["role": "assistant", "content": "branched answer"]]
        ]
        let model = DockModel(initialSessionID: "source-session", rpcClient: rpc)
        let state = ConversationMessageActionState()
        let message = ChatMessage(id: UUID(), role: .hermes, text: "source answer")

        state.run(message.id) { await model.branchConversation(from: message) }
        try await waitUntil { state.isPending(message.id) }
        state.run(message.id) { await model.branchConversation(from: message) }
        try await waitUntil { !state.isPending(message.id) && model.status == .idle }

        #expect(rpc.requests.filter { $0.method == "session.branch" }.count == 1)
        #expect(model.sessionID == "branch-session")
        #expect(model.messages.last?.text == "branched answer")
    }

    @Test func readAloudCanBeStoppedAndDuplicateToggleDoesNotLeaveActiveState() {
        let voice = VoiceOutput()
        let messageID = UUID()

        voice.speak(messageID: messageID, text: "A response")
        voice.speak(messageID: messageID, text: "A response")
        voice.stop()

        #expect(!voice.isSpeaking)
        #expect(voice.speakingMessageID == nil)
    }
}

@MainActor
private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}
