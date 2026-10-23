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
    func record(_ number: Int = 93) throws -> PullRequestRecord {
        try #require(
            PullRequestCenterAPI().parse(
                [
                    "number": number, "title": "Bound synthetic measurement tooling", "state": "open",
                    "body": "Add bounded measurements.", "user": ["login": "author"],
                    "head": ["ref": "measurements", "sha": "abc"], "base": ["ref": "main", "sha": "def"],
                ], repository: GitHubReferenceParser.repository("owner/repo")!, localPath: ""))
    }

    @Test func defaultBotReceivesPRContextAndFollowUpsReuseTheSession() async throws {
        let rpc = PullRequestChatRPC()
        let chat = PullRequestChatModel()
        let drafts = QuickDraftStore(directory: nil)
        let pr = try record()
        chat.text = "What changed?"
        await chat.submit(pr, client: rpc, drafts: drafts)
        #expect(chat.text.isEmpty)
        #expect(chat.destination?.profileID == "default")
        #expect(chat.destination?.sessionID == "pr-chat")
        #expect(chat.running)
        #expect(drafts.records.isEmpty)
        let prompt = try #require(rpc.calls.first { $0.0 == "prompt.submit" }?.1)
        #expect(prompt["profile"] as? String == "default")
        #expect(prompt["session_id"] as? String == "runtime")
        #expect((prompt["text"] as? String)?.contains("Pull request #93") == true)
        #expect((prompt["text"] as? String)?.hasSuffix("What changed?") == true)
        rpc.history = ["messages": [["role": "assistant", "content": "It adds measurements."]]]
        await chat.refresh(client: rpc)
        #expect(!chat.running)
        #expect(chat.messages.last?.text == "It adds measurements.")
        chat.text = "Which tests cover it?"
        await chat.submit(pr, client: rpc, drafts: drafts)
        #expect(rpc.calls.filter { $0.0 == "session.create" }.count == 1)
        #expect(rpc.calls.filter { $0.0 == "prompt.submit" }.count == 2)
    }

    @Test func ambiguousSubmissionKeepsDraftAndBlocksDuplicateSend() async throws {
        let rpc = PullRequestChatRPC()
        rpc.submitStatus = "queued"
        let chat = PullRequestChatModel()
        let drafts = QuickDraftStore(directory: nil)
        chat.text = "Explain the risk"
        await chat.submit(try record(), client: rpc, drafts: drafts)
        #expect(chat.needsReview)
        #expect(!chat.canSend)
        #expect(chat.text == "Explain the risk")
        #expect(drafts.records.first?.delivery == .needsReview)
        #expect(chat.destination?.sessionID == "pr-chat")
        await chat.submit(try record(), client: rpc, drafts: drafts)
        #expect(rpc.calls.filter { $0.0 == "prompt.submit" }.count == 1)
        chat.allowDeliberateRetry()
        #expect(chat.canSend)
    }

    @Test func rejectedSendKeepsItsErrorAcrossRefreshAndRetriesTheCapturedSession() async throws {
        let rpc = PullRequestChatRPC()
        rpc.rejectSubmit = true
        let chat = PullRequestChatModel()
        let drafts = QuickDraftStore(directory: nil)
        chat.text = "Explain this PR"
        let pr = try record()
        await chat.submit(pr, client: rpc, drafts: drafts)
        #expect(!chat.needsReview)
        #expect(chat.canSend)
        #expect(chat.text == "Explain this PR")
        #expect(chat.error?.contains("Request rejected") == true)
        await chat.refresh(client: rpc)
        #expect(chat.error?.contains("Request rejected") == true)
        rpc.rejectSubmit = false
        await chat.submit(pr, client: rpc, drafts: drafts)
        #expect(chat.error == nil)
        #expect(chat.text.isEmpty)
        #expect(drafts.records.isEmpty)
        #expect(rpc.calls.filter { $0.0 == "session.create" }.count == 1)
    }

    @Test func pendingSendPreventsDuplicateSubmission() async throws {
        let rpc = PullRequestChatRPC()
        rpc.delaySubmit = true
        let chat = PullRequestChatModel()
        let drafts = QuickDraftStore(directory: nil)
        let pr = try record()
        chat.text = "Explain this PR"
        let first = Task { await chat.submit(pr, client: rpc, drafts: drafts) }
        while rpc.delayedSubmit == nil { await Task.yield() }
        #expect(chat.sending)
        #expect(!chat.canSend)
        await chat.submit(pr, client: rpc, drafts: drafts)
        #expect(rpc.calls.filter { $0.0 == "prompt.submit" }.count == 1)
        rpc.delayedSubmit?.resume(returning: ["status": "streaming"])
        await first.value
        #expect(!chat.sending)
        #expect(chat.running)
    }

    @Test func historyLimitsAndFailedReadsPreserveTheLastReply() async throws {
        let rpc = PullRequestChatRPC()
        let chat = PullRequestChatModel()
        let drafts = QuickDraftStore(directory: nil)
        chat.text = "Explain this PR"
        await chat.submit(try record(), client: rpc, drafts: drafts)
        rpc.history = ["messages": [["role": "assistant", "content": "Saved answer"]]]
        await chat.refresh(client: rpc)
        rpc.history = ["messages": [["role": "assistant", "content": String(repeating: "x", count: 256_001)]]]
        await chat.refresh(client: rpc)
        #expect(chat.messages.last?.text == "Saved answer")
        #expect(chat.error?.contains("preview limit") == true)
        rpc.history = [:]
        await chat.refresh(client: rpc)
        #expect(chat.messages.last?.text == "Saved answer")
        #expect(chat.error != nil)
    }

    @Test func PRSwitchesKeepSeparateDraftsAndConversations() throws {
        let details = PullRequestDetailStore()
        let firstCenter = PullRequestCenterModel(details: details)
        let inspectorCenter = PullRequestCenterModel(details: details)
        let store = firstCenter.details.chats
        let first = store.chat(for: try record(1))
        first.text = "First PR question"
        let second = store.chat(for: try record(2))
        #expect(first !== second)
        #expect(second.text.isEmpty)
        #expect(store.chat(for: try record(1)) === first)
        #expect(first.text == "First PR question")
        #expect(inspectorCenter.details.chats.chat(for: try record(1)) === first)
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

    @Test func refreshFromBeforeSubmissionCannotClearTheNewRunningState() async throws {
        let rpc = PullRequestChatRPC()
        let chat = PullRequestChatModel()
        let drafts = QuickDraftStore(directory: nil)
        chat.text = "First question"
        await chat.submit(try record(), client: rpc, drafts: drafts)
        await chat.refresh(client: rpc)
        rpc.delayHistory = true
        let refresh = Task { await chat.refresh(client: rpc) }
        while rpc.delayedHistory == nil { await Task.yield() }
        chat.text = "Follow up"
        await chat.submit(try record(), client: rpc, drafts: drafts)
        rpc.delayedHistory?.resume(returning: ["messages": []])
        await refresh.value
        #expect(chat.running)
    }
}
