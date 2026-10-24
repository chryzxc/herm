import Foundation
import Testing

@testable import Herm

@MainActor
final class PullRequestChatRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [(String, [String: Any])] = []
    var history: [String: Any] = ["messages": []]
    var active: [[String: Any]] = []
    var submitStatus = "streaming"
    var missingHistory = false
    var delayedHistory: CheckedContinuation<[String: Any], Error>?
    var delayHistory = false
    var rejectResume = false
    var delayResume = false
    var delayedResume: CheckedContinuation<[String: Any], Error>?
    var rejectSubmit = false
    var delaySubmit = false
    var delayedSubmit: CheckedContinuation<[String: Any], Error>?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        switch method {
        case "session.create": return ["session_id": "runtime", "stored_session_id": "pr-chat"]
        case "session.resume":
            if rejectResume { throw HermesGateway.GatewayError.disconnected }
            if delayResume { return try await withCheckedThrowingContinuation { delayedResume = $0 } }
            return ["session_id": "runtime", "stored_session_id": "pr-chat", "profile": "default", "running": false]
        case "prompt.submit":
            if rejectSubmit {
                throw NSError(domain: "Hermes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request rejected"])
            }
            if delaySubmit { return try await withCheckedThrowingContinuation { delayedSubmit = $0 } }
            return ["status": submitStatus]
        case "session.active_list": return ["sessions": active]
        default: return [:]
        }
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if missingHistory { throw HermesGateway.GatewayError.httpError(404) }
        if delayHistory { return try await withCheckedThrowingContinuation { delayedHistory = $0 } }
        return history
    }
}

@MainActor
struct PullRequestChatTests {
    func record(_ number: Int = 93, repository: String = "owner/repo") throws -> PullRequestRecord {
        try #require(
            PullRequestCenterAPI().parse(
                [
                    "number": number, "title": "Bound synthetic measurement tooling", "state": "open",
                    "body": "Add bounded measurements.", "user": ["login": "author"],
                    "head": ["ref": "measurements", "sha": "abc"], "base": ["ref": "main", "sha": "def"],
                ], repository: GitHubReferenceParser.repository(repository)!, localPath: ""))
    }

    func runtime(_ rpc: PullRequestChatRPC, defaults: UserDefaults) -> DockModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
            initialSessionID: "selected-workspace", botActivityFileURL: directory.appendingPathComponent("bots.json"),
            rpcClient: rpc)
    }

    @Test func attachPRToCurrentChatPreservesSessionAndDraft() throws {
        let suite = "PullRequestChatTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = PullRequestChatRPC()
        let runtime = runtime(rpc, defaults: defaults)
        defer { runtime.shutdown() }
        let router = ChatContextRouter()
        router.model = runtime
        runtime.draft = "My existing draft"
        let existing = ChatContext(id: "existing", title: "Existing attachment", body: "Keep this")
        runtime.attachedContexts = [existing]
        var pr = try record()
        router.attachToCurrentChat(ChatContext(pullRequest: pr))
        pr.body = "Updated description"
        let updated = ChatContext(pullRequest: pr)
        router.attachToCurrentChat(updated)
        #expect(runtime.attachedContexts == [existing, updated])
        #expect(runtime.sessionID == "selected-workspace")
        #expect(runtime.draft == "My existing draft")
        #expect(!rpc.calls.contains { ["session.create", "session.resume", "prompt.submit"].contains($0.0) })
    }

    @Test func newPRSessionIsLinkedAndReopenedWithoutChangingWorkspace() async throws {
        let suite = "PullRequestChatTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = PullRequestChatRPC()
        let runtime = runtime(rpc, defaults: defaults)
        defer { runtime.shutdown() }
        runtime.draft = "Workspace draft"
        let chat = PullRequestChatModel(links: defaults)
        defer { chat.shutdown() }
        let pr = try record()
        await chat.prepareConversation(for: pr, runtime: runtime)
        let model = try #require(chat.conversation)
        #expect(model !== runtime)
        #expect(model.sessionID == nil)
        #expect(!rpc.calls.contains { $0.0 == "session.create" })
        model.draft = "What changed?"
        model.send()
        for _ in 0..<200 where !rpc.calls.contains(where: { $0.0 == "prompt.submit" }) { await Task.yield() }
        let prompt = try #require(rpc.calls.first { $0.0 == "prompt.submit" }?.1)
        #expect(prompt["profile"] as? String == "default")
        #expect((prompt["text"] as? String)?.contains("Pull request #93") == true)
        #expect(chat.linkedDestination(for: pr)?.sessionID == "pr-chat")
        #expect(runtime.sessionID == "selected-workspace")
        #expect(runtime.draft == "Workspace draft")
        #expect(runtime.attachedContexts.isEmpty)
        let reopened = PullRequestChatModel(links: defaults)
        defer { reopened.shutdown() }
        await reopened.prepareConversation(for: pr, runtime: runtime)
        #expect(rpc.calls.filter { $0.0 == "session.create" }.count == 1)
        let resume = try #require(rpc.calls.last { $0.0 == "session.resume" }?.1)
        #expect(resume["session_id"] as? String == "pr-chat")
        #expect(resume["profile"] as? String == "default")
        #expect(reopened.conversation?.sessionStorageID == "pr-chat")
    }

    @Test func prDraftsAndLinksAreScopedByRepositoryAndNumber() async throws {
        let suite = "PullRequestChatTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = PullRequestChatRPC()
        let runtime = runtime(rpc, defaults: defaults)
        defer { runtime.shutdown() }
        let first = PullRequestChatModel(links: defaults)
        let second = PullRequestChatModel(links: defaults)
        defer {
            first.shutdown()
            second.shutdown()
        }
        await first.prepareConversation(for: try record(1), runtime: runtime)
        await second.prepareConversation(for: try record(2), runtime: runtime)
        first.conversation?.draft = "First PR question"
        #expect(second.conversation?.draft.isEmpty == true)
        _ = try await first.conversation?.createAuthorizedSession(source: "herm")
        #expect(first.linkedDestination(for: try record(1))?.sessionID == "pr-chat")
        #expect(second.linkedDestination(for: try record(2)) == nil)
        #expect(first.linkedDestination(for: try record(1, repository: "other/repo")) == nil)
        await first.prepareConversation(for: try record(1), runtime: runtime)
        #expect(first.conversation?.draft == "First PR question")
    }

    @Test func linkedConversationBlocksSendingUntilResumeSettles() async throws {
        let suite = "PullRequestChatTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = PullRequestChatRPC()
        let runtime = runtime(rpc, defaults: defaults)
        defer { runtime.shutdown() }
        let pr = try record()
        let first = PullRequestChatModel(links: defaults)
        defer { first.shutdown() }
        await first.prepareConversation(for: pr, runtime: runtime)
        _ = try await first.conversation?.createAuthorizedSession(source: "herm")
        rpc.delayResume = true
        let reopened = PullRequestChatModel(links: defaults)
        defer { reopened.shutdown() }
        let loading = Task { await reopened.prepareConversation(for: pr, runtime: runtime) }
        while rpc.delayedResume == nil { await Task.yield() }
        let model = try #require(reopened.conversation)
        #expect(model.isRestoringSession)
        model.draft = "Wait for the previous conversation"
        model.send()
        #expect(!rpc.calls.contains { $0.0 == "prompt.submit" })
        rpc.delayedResume?.resume(returning: [
            "session_id": "runtime", "stored_session_id": "pr-chat", "profile": "default", "running": false,
        ])
        await loading.value
        #expect(!model.isRestoringSession)
        #expect(reopened.linkedDestination(for: pr)?.sessionID == "pr-chat")
    }

    @Test func unavailableLinkedSessionIsNotReplaced() async throws {
        let suite = "PullRequestChatTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = PullRequestChatRPC()
        let runtime = runtime(rpc, defaults: defaults)
        defer { runtime.shutdown() }
        let pr = try record()
        let first = PullRequestChatModel(links: defaults)
        defer { first.shutdown() }
        await first.prepareConversation(for: pr, runtime: runtime)
        _ = try await first.conversation?.createAuthorizedSession(source: "herm")
        rpc.rejectResume = true
        let reopened = PullRequestChatModel(links: defaults)
        defer { reopened.shutdown() }
        await reopened.prepareConversation(for: pr, runtime: runtime)
        #expect(reopened.conversation?.status == .offline)
        #expect(reopened.linkedDestination(for: pr)?.sessionID == "pr-chat")
        #expect(rpc.calls.filter { $0.0 == "session.create" }.count == 1)
    }

    @Test func sessionEventsReachPRConversationAndKeepWorkspaceIsolated() async throws {
        let suite = "PullRequestChatTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = PullRequestChatRPC()
        let runtime = runtime(rpc, defaults: defaults)
        defer { runtime.shutdown() }
        let chat = PullRequestChatModel(links: defaults)
        defer { chat.shutdown() }
        await chat.prepareConversation(for: try record(), runtime: runtime)
        let model = try #require(chat.conversation)
        _ = try await model.createAuthorizedSession(source: "herm")
        runtime.receiveGatewayEvent("message.start", params: ["session_id": "runtime"])
        #expect(model.streamingMessageID != nil)
        #expect(runtime.streamingMessageID == nil)
        runtime.receiveGatewayEvent(
            "message.delta", params: ["session_id": "runtime", "payload": ["text": "Shared session reply"]])
        runtime.receiveGatewayEvent("message.complete", params: ["session_id": "runtime"])
        #expect(model.messages.contains { $0.role == .hermes && $0.text == "Shared session reply" })
        #expect(runtime.messages.isEmpty)
    }

    @Test func historyRejectsAnotherOwnerAndHidesToolPayloadsAndContext() throws {
        let session = HermesSession(
            id: "pr-chat", profileID: "default", title: "PR", preview: "", startedAt: nil, messageCount: 0,
            source: "herm")
        for mismatch in [["session_id": "other"], ["profile": "other"]] {
            var result: [String: Any] = mismatch
            result["messages"] = [["role": "assistant", "content": "Wrong conversation"]]
            #expect(throws: (any Error).self) {
                try HermesPullRequestChatService.parse(result, session: session, isRunning: false)
            }
        }
        let snapshot = try HermesPullRequestChatService.parse(
            [
                "messages": [
                    [
                        "role": "user",
                        "content": "<pull_request_context>\nPR metadata\n</pull_request_context>\n\nWhat changed?",
                    ],
                    ["role": "assistant", "content": "Tool arguments", "tool_calls": [["id": "tool"]]],
                    ["role": "tool", "content": "Raw output"],
                    ["role": "assistant", "content": [["type": "text", "text": "A bounded change."]]],
                ]
            ], session: session, isRunning: false)
        #expect(snapshot.messages.map(\.text) == ["What changed?", "A bounded change."])
        #expect(snapshot.messages.map(\.isUser) == [true, false])
    }

    @Test func missingHistoryWaitsOnlyForTheCapturedActiveSession() async throws {
        let rpc = PullRequestChatRPC()
        rpc.missingHistory = true
        rpc.active = [["session_key": "runtime", "status": "waiting"]]
        let destination = QuickDestination(profileID: "default", sessionID: "pr-chat", runtimeID: "runtime")
        let snapshot = try await HermesPullRequestChatService(client: rpc).load(destination)
        #expect(snapshot.isRunning && snapshot.needsAttention)
        rpc.active = [["session_key": "another-chat", "status": "working"]]
        await #expect(throws: (any Error).self) {
            try await HermesPullRequestChatService(client: rpc).load(destination)
        }
    }

}
