import Foundation
import Testing
@testable import Herm

/// Serves a deferred `session.resume` and pages a stored transcript over the
/// `/api/sessions/{id}/messages?order=latest` contract Hermes implements.
@MainActor
private final class PagedTranscriptRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requests: [(method: String, params: [String: Any])] = []
    private(set) var fetchedPaths: [String] = []
    var storedRows: [[String: Any]] = []
    var failHTTP = false
    var timelinePageSize = 500

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        guard method == "session.resume" else { return [:] }
        let sessionID = params["session_id"] as? String ?? ""
        if params["defer_history"] as? Bool == true {
            return ["session_id": sessionID, "messages": [], "hydrating": true, "message_count": storedRows.count]
        }
        return ["session_id": sessionID, "messages": storedRows.map { ["role": $0["role"]!, "text": $0["content"]!] }]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        fetchedPaths.append(path)
        if failHTTP { throw URLError(.cannotConnectToHost) }
        let query = URLComponents(string: path)?.queryItems ?? []
        if path.contains("/timeline") {
            // Two prompts per page exercises the cursor loop.
            let after = Int(query.first { $0.name == "after_row_id" }?.value ?? "") ?? 0
            let prompts = storedRows.filter { $0["role"] as? String == "user" && ($0["id"] as! Int) > after }
            let page = Array(prompts.prefix(timelinePageSize))
            let hasMore = prompts.count > page.count
            return [
                "entries": page.map { ["row_id": $0["id"]!, "preview": $0["content"]!, "timestamp": 1.0] },
                "pagination": ["has_more": hasMore, "next_cursor": hasMore ? page.last!["id"]! : NSNull()],
            ]
        }
        let limit = Int(query.first { $0.name == "limit" }?.value ?? "") ?? 500
        let offset = Int(query.first { $0.name == "offset" }?.value ?? "") ?? 0
        let upper = max(0, storedRows.count - offset)
        let lower = max(0, upper - limit)
        let page = Array(storedRows[lower..<upper])
        return ["messages": page, "pagination": ["limit": limit, "offset": offset, "order": "latest", "returned": page.count]]
    }

    func close() {}
}

private func storedTranscript(turns: Int) -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for turn in 0..<turns {
        rows.append(["id": rows.count + 1, "role": "user", "content": "question \(turn)"])
        rows.append(["id": rows.count + 1, "role": "tool", "content": "tool output \(turn)"])
        rows.append(["id": rows.count + 1, "role": "assistant", "content": "answer \(turn)"])
    }
    return rows
}

private struct WaitTimeout: Error {}

/// Generous and loud: the suite shares the main actor with slow rendering
/// tests, and a silent timeout used to let later indexing trap the runner.
@MainActor
private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 30) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
struct TranscriptHistoryPagingTests {
    @Test func pagePathRequestsLatestDisplayPageForProfile() throws {
        let path = try #require(TranscriptHistoryPaging.pagePath(sessionID: "a/b c", profileID: "forge", limit: 120, offset: 240))
        #expect(path == "/api/sessions/a%2Fb%20c/messages?limit=120&offset=240&order=latest&include_compacted=true&profile=forge")
        let unscoped = try #require(TranscriptHistoryPaging.pagePath(sessionID: "s1", profileID: nil, limit: 120, offset: 0))
        #expect(!unscoped.contains("profile="))
    }

    @Test func onlyAnOmittedTranscriptIsPaged() {
        #expect(TranscriptHistoryPaging.resumeResponseDefersTranscript(["messages": [], "hydrating": true]))
        #expect(TranscriptHistoryPaging.resumeResponseDefersTranscript(["messages": [], "messages_omitted": true]))
        // Older Hermes builds ignore the flags and inline the transcript.
        #expect(!TranscriptHistoryPaging.resumeResponseDefersTranscript(["messages": [["role": "user", "text": "hi"]], "hydrating": true]))
        #expect(!TranscriptHistoryPaging.resumeResponseDefersTranscript(["messages": []]))
    }

    @Test func advanceDropsOverlappingRowsAndStopsOnShortPage() {
        var cursor = TranscriptHistoryCursor(storageSessionID: "s", profileID: nil, seenRowIDs: [5])
        let full = TranscriptHistoryPaging.Page(rows: [["id": 4], ["id": 5]], returned: 2, isPaginated: true)
        #expect(TranscriptHistoryPaging.advance(&cursor, with: full, limit: 2).count == 1)
        #expect(cursor.nextOffset == 2 && cursor.hasMore)
        let short = TranscriptHistoryPaging.Page(rows: [["id": 1]], returned: 1, isPaginated: true)
        _ = TranscriptHistoryPaging.advance(&cursor, with: short, limit: 2)
        #expect(!cursor.hasMore)
        var legacy = TranscriptHistoryCursor(storageSessionID: "s", profileID: nil)
        _ = TranscriptHistoryPaging.advance(&legacy, with: .init(rows: [["id": 1]], returned: 1, isPaginated: false), limit: 1)
        #expect(!legacy.hasMore)
    }

    @Test func storedRowsUseGatewayDisplayRules() {
        let skill = "[IMPORTANT: The user has invoked the \"work\" skill. The full skill content is loaded below.]\n\nBODY\n\n"
            + "The user has provided the following instruction alongside the skill invocation: fix  the leak\n\n[Runtime note: x]"
        let rows = TranscriptHistoryPaging.displayRows(fromStoredRows: [
            ["role": "user", "content": "[System: switched model]"],
            ["role": "assistant", "content": "scaffold", "display_kind": "hidden"],
            ["role": "tool", "content": "raw output"],
            ["role": "assistant", "content": "SUMMARY", "display_content": "Earlier turns were compacted."],
            ["role": "user", "content": skill, "timestamp": 12.0],
            ["role": "assistant", "content": [["type": "text", "text": "parts"]]],
            ["role": "assistant", "content": "  "],
        ])
        let visible = rows.filter { $0["role"] as? String != "tool" }
        #expect(visible.map { $0["text"] as? String } == ["[System: switched model]", "Earlier turns were compacted.", "/work fix the leak", "parts"])
        #expect(visible[2]["timestamp"] as? Double == 12.0)
    }

    @Test func hermesWrittenRowsRestoreAsSystemCards() {
        let rows = TranscriptHistoryPaging.displayRows(fromStoredRows: [
            ["role": "system", "content": "Session forked"],
            ["role": "user", "content": "[System: The active model for this chat is x]"],
            ["role": "user", "content": "[ASYNC DELEGATION BATCH COMPLETE — 2 tasks]\nresults"],
            ["role": "user", "content": "[REMOTE DIGEST: nightly]"],
            ["role": "user", "content": "done", "display_kind": "process_complete"],
            ["role": "user", "content": "go faster", "display_kind": "steer"],
            ["role": "user", "content": "[Triggering message id: `1` — use as `message_id` for reply/react/pin via the discord tools.]\nhi"],
        ])
        let messages = DockModel.parseMessages(rows).messages
        #expect(messages.map { $0.systemEvent?.label } == [
            "System", "Model switch", "Delegation complete", "Remote digest", "Process complete", nil, nil,
        ])
        #expect(messages[5].role == .user)
        #expect(messages[6].text == "hi")
    }

    @Test func storedToolRowsBecomeTheReplyActivity() {
        let calls = #"[{"id": "c1", "type": "function", "function": {"name": "terminal", "arguments": "{\"command\": \"gh pr view\"}"}}]"#
        let rows = TranscriptHistoryPaging.displayRows(fromStoredRows: [
            ["id": 1, "role": "user", "content": "update the PR", "timestamp": 100.0],
            ["id": 2, "role": "assistant", "content": "", "tool_calls": calls, "reasoning": "Checking the PR", "timestamp": 110.0],
            ["id": 3, "role": "tool", "content": "{\"output\": \"ok\"}", "tool_call_id": "c1", "tool_name": "terminal", "timestamp": 120.0],
            ["id": 4, "role": "tool", "content": "{}", "tool_call_id": "c2", "tool_name": "search_files", "timestamp": 125.0],
            ["id": 5, "role": "assistant", "content": "Updated PR", "timestamp": 160.0],
        ])
        let messages = DockModel.parseMessages(rows).messages
        #expect(messages.map(\.text) == ["update the PR", "Updated PR"])
        let activity = messages[1].activity
        #expect(activity.map(\.name) == [ActiveToolCall.thinkingName, "terminal", "search_files"])
        #expect(activity[0].result == "Checking the PR")
        #expect(activity[1].context == "gh pr view")
        #expect(messages[1].responseDuration == 60)
    }

    @Test func resumeLoadsOnlyTheTailAndPagesEarlierHistoryOnDemand() async throws {
        let rpc = PagedTranscriptRPCClient()
        rpc.storedRows = storedTranscript(turns: 200)
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: "long", title: "Long", preview: "", startedAt: nil, messageCount: 600, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        let resume = try #require(rpc.requests.first { $0.method == "session.resume" })
        #expect(resume.params["defer_history"] as? Bool == true)
        #expect(resume.params["omit_messages"] as? Bool == true)
        // 120 stored rows = 40 turns = 80 visible messages, newest last.
        #expect(model.messages.count == 80)
        #expect(model.messages.last?.text == "answer 199")
        #expect(model.canLoadEarlierTranscript)

        let newestIDs = model.messages.map(\.id)
        model.loadEarlierTranscriptIfAvailable()
        try await waitUntil { model.messages.count == 160 }
        #expect(model.messages.first?.text == "question 120")
        #expect(Array(model.messages.suffix(80).map(\.id)) == newestIDs)
        #expect(model.lastTranscriptPrepend?.count == 80)
        #expect(model.lastTranscriptPrepend?.resultingCount == 160)

        for _ in 0..<10 where model.messages.count < 400 {
            try await waitUntil { model.canLoadEarlierTranscript }
            model.loadEarlierTranscriptIfAvailable()
            let before = model.messages.count
            try await waitUntil { model.messages.count > before }
        }
        // A full final page cannot know it was the last; one empty read settles it.
        try await waitUntil { model.canLoadEarlierTranscript }
        model.loadEarlierTranscriptIfAvailable()
        try await waitUntil { rpc.fetchedPaths.last?.contains("offset=600") == true && !model.canLoadEarlierTranscript }
        #expect(model.messages.count == 400)
        #expect(model.messages.first?.text == "question 0")
        #expect(!model.canLoadEarlierTranscript)
    }

    @Test func timelinePageReadsEntriesAndCursor() throws {
        let path = try #require(TranscriptHistoryPaging.timelinePath(sessionID: "s1", profileID: nil, afterRowID: 42))
        #expect(path == "/api/sessions/s1/timeline?limit=500&after_row_id=42")
        let page = try #require(TranscriptHistoryPaging.timelinePage(from: [
            "entries": [["row_id": 7, "preview": "hi", "timestamp": 3.0]],
            "pagination": ["has_more": true, "next_cursor": 9],
        ]))
        #expect(page.entries == [TranscriptTimelineEntry(rowID: 7, preview: "hi", timestamp: 3.0)])
        #expect(page.nextCursor == 9)
        let last = try #require(TranscriptHistoryPaging.timelinePage(from: [
            "entries": [], "pagination": ["has_more": false, "next_cursor": NSNull()],
        ]))
        #expect(last.nextCursor == nil)
    }

    @Test func navigatorListsUnloadedPromptsBeforeLoadedMessages() async throws {
        let rpc = PagedTranscriptRPCClient()
        rpc.storedRows = storedTranscript(turns: 200)
        rpc.timelinePageSize = 64
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: "long", title: "Long", preview: "", startedAt: nil, messageCount: 600, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.unloadedTranscriptPrompts.count == 160 }

        #expect(rpc.fetchedPaths.filter { $0.contains("/timeline") }.count == 4)
        let items = model.messageNavigatorItems
        // 160 unloaded prompts, then the 80 loaded messages.
        try #require(items.count == 240)
        #expect(items.first?.preview == "question 0")
        #expect(items.first?.storedRowID == 1)
        #expect(items[160].storedRowID == nil)
        #expect(items[160].messageID == model.messages.first?.id)
        #expect(items.map(\.ordinal) == Array(1...240))
        // Loaded messages are matched on their full text, not the preview.
        #expect(MessageNavigator.search(items: items, query: "question 17").map(\.preview) == ["question 17", "question 170", "question 171", "question 172", "question 173", "question 174", "question 175", "question 176", "question 177", "question 178", "question 179"])
    }

    @Test func jumpingToAnUnloadedPromptLoadsHistoryThroughIt() async throws {
        let rpc = PagedTranscriptRPCClient()
        rpc.storedRows = storedTranscript(turns: 400)
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: "long", title: "Long", preview: "", startedAt: nil, messageCount: 1200, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.unloadedTranscriptPrompts.isEmpty }

        let target = try #require(model.messageNavigatorItems.first { $0.preview == "question 150" })
        let rowID = try #require(target.storedRowID)
        let messageID = try #require(await model.loadTranscriptHistory(through: rowID))
        let index = try #require(model.messages.firstIndex { $0.id == messageID })
        #expect(model.messages[index].text == "question 150")
        // One prepend, and only as deep as the prompt required.
        #expect(model.lastTranscriptPrepend?.count == model.messages.count - 80)
        #expect(model.messages.first?.text != "question 0")
        #expect(model.canLoadEarlierTranscript)
        #expect(model.unloadedTranscriptPrompts.allSatisfy { $0.rowID < rowID })
        #expect(!model.isLoadingTranscriptHistory)

        let jump = ConversationMessageWindow.jumpPlan(
            for: try #require(model.messageNavigatorItems.first { $0.messageID == messageID }),
            sessionID: model.sessionID ?? "",
            messages: model.messages
        )
        #expect(jump?.windowRange.contains(index) == true)
    }

    @Test func searchLoadsTheRemainingHistory() async throws {
        let rpc = PagedTranscriptRPCClient()
        rpc.storedRows = storedTranscript(turns: 400)
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: "long", title: "Long", preview: "", startedAt: nil, messageCount: 1200, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(await model.loadTranscriptHistory(through: nil) == nil)
        #expect(model.messages.count == 800)
        #expect(!model.hasUnloadedTranscript)
        #expect(model.unloadedTranscriptPrompts.isEmpty)
        #expect(MessageNavigator.search(items: model.messageNavigatorItems, query: "answer 3").count == 111)
    }

    @Test func unavailableTranscriptPagesFallBackToInlineResume() async throws {
        let rpc = PagedTranscriptRPCClient()
        rpc.storedRows = storedTranscript(turns: 3)
        rpc.failHTTP = true
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: "s", title: "S", preview: "", startedAt: nil, messageCount: 9, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.messages.count == 6 }

        let resumes = rpc.requests.filter { $0.method == "session.resume" }
        #expect(resumes.count == 2)
        #expect(resumes.last?.params["defer_history"] == nil)
        #expect(model.messages.count == 6)
        #expect(!model.canLoadEarlierTranscript)
    }
}

@MainActor @Test func runningDurationUsesWholeUnits() {
    #expect(TurnActivityView.roughDuration(1.9) == "1 second")
    #expect(TurnActivityView.roughDuration(45) == "45 seconds")
    #expect(TurnActivityView.roughDuration(119) == "1 minute")
    #expect(TurnActivityView.roughDuration(7_300) == "2 hours")
}
