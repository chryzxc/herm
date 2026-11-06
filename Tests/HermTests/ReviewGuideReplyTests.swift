import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
private final class ReviewGuideRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var response: [String: Any] = ["messages": []]
    var paths: [String] = []
    var suspended: CheckedContinuation<[String: Any], Error>?
    var delay = false
    var missingHistory = false
    var status = "working"

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        ["sessions": [["session_key": "review", "status": status]]]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        paths.append(path)
        if missingHistory { throw HermesGateway.GatewayError.httpError(404) }
        if delay { return try await withCheckedThrowingContinuation { suspended = $0 } }
        return response
    }
}

@MainActor
struct ReviewGuideReplyTests {
    private func session(_ profile: String? = nil) -> HermesSession {
        HermesSession(
            id: "review", profileID: profile, title: "Review guide", preview: "",
            startedAt: nil, messageCount: 0, source: "herm")
    }

    @Test func unpersistedHistoryWaitsOnlyWhileSessionIsActive() async {
        let client = ReviewGuideRPC()
        client.missingHistory = true
        let model = ReviewGuideReplyModel()
        for status in ["starting", "working", "waiting"] {
            client.status = status
            await model.refresh(session: session(), client: client)
            #expect(model.error == nil)
            #expect(model.reply == nil)
        }
        client.status = "idle"
        await model.refresh(session: session(), client: client)
        #expect(model.error != nil)
    }

    @Test func waitingGuideLoadsOnALaterRefresh() async {
        let client = ReviewGuideRPC()
        let model = ReviewGuideReplyModel()
        await model.refresh(session: session("reviewer"), client: client)
        #expect(model.reply == nil)
        #expect(model.error == nil)
        client.response = ["messages": [["role": "assistant", "content": "## Review\nCheck recovery."]]]
        await model.refresh(session: session("reviewer"), client: client)
        #expect(model.reply == "## Review\nCheck recovery.")
        #expect(client.paths.last?.contains("order=latest") == true)
        #expect(client.paths.last?.contains("profile=reviewer") == true)
    }

    @Test func unchangedGuideDoesNotPublishReplyAgain() async {
        let client = ReviewGuideRPC()
        client.response = ["messages": [["role": "assistant", "content": "Saved guide"]]]
        let model = ReviewGuideReplyModel()
        var publications: [String?] = []
        let subscription = model.$reply.sink { publications.append($0) }
        await model.refresh(session: session(), client: client)
        let count = publications.count
        await model.refresh(session: session(), client: client)
        #expect(publications.count == count)
        withExtendedLifetime(subscription) {}
    }

    @Test func blankRepliesKeepTheWaitingState() async {
        let client = ReviewGuideRPC()
        let model = ReviewGuideReplyModel()
        client.response = ["messages": [["role": "assistant", "content": " \n\t"]]]
        await model.refresh(session: session(), client: client)
        #expect(model.reply == nil)
        #expect(model.error == nil)
    }

    @Test func emptyAndFailedRefreshesKeepTheDisplayedGuide() async {
        let client = ReviewGuideRPC()
        let model = ReviewGuideReplyModel()
        client.response = ["messages": [["role": "assistant", "content": "Saved guide"]]]
        await model.refresh(session: session(), client: client)
        client.response = ["messages": []]
        await model.refresh(session: session(), client: client)
        #expect(model.reply == "Saved guide")
        client.response = [:]
        await model.refresh(session: session(), client: client)
        #expect(model.reply == "Saved guide")
        #expect(model.error != nil)
        #expect(!model.loading)
    }

    @Test func profileChangesResetContentAndRejectLateReplies() async {
        let client = ReviewGuideRPC()
        let model = ReviewGuideReplyModel()
        client.delay = true
        let old = Task { await model.refresh(session: session("first"), client: client) }
        while client.suspended == nil { await Task.yield() }
        model.reset(session: session("second"))
        client.delay = false
        client.response = ["messages": [["role": "assistant", "content": "New guide"]]]
        await model.refresh(session: session("second"), client: client)
        client.suspended?.resume(returning: ["messages": [["role": "assistant", "content": "Old guide"]]])
        await old.value
        #expect(model.reply == "New guide")
        #expect(model.error == nil)
        #expect(!model.loading)
    }

    @Test func changingRuntimeClearsThePreviousGuide() async {
        let first = ReviewGuideRPC()
        let model = ReviewGuideReplyModel()
        first.response = ["messages": [["role": "assistant", "content": "First runtime"]]]
        await model.refresh(session: session(), client: first)
        #expect(model.reply == "First runtime")
        await model.refresh(session: session(), client: ReviewGuideRPC())
        #expect(model.reply == nil)
    }

    @Test func mismatchedOwnersFailClosed() async {
        let client = ReviewGuideRPC()
        let model = ReviewGuideReplyModel()
        for owner in [["session_id": "other"], ["profile": "other"]] as [[String: Any]] {
            client.response = owner.merging(
                ["messages": [["role": "assistant", "content": "Wrong guide"]]] as [String: Any]
            ) { _, new in new }
            await model.refresh(session: session("reviewer"), client: client)
            #expect(model.reply == nil)
            #expect(model.error != nil)
        }
    }
}
