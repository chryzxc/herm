import AppKit
import Foundation
import Testing

@testable import Herm

@MainActor
private final class SessionSwitchRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [String] = []
    var holdNextA = false
    var held: CheckedContinuation<Void, Never>?
    var nextFailure: Error?
    var nextResponse: [String: Any]?
    var holdModelOptions = false
    var heldModelOptions: CheckedContinuation<Void, Never>?
    var holdHistory = false
    var heldHistory: CheckedContinuation<Void, Never>?
    var resumeInfo: [String: Any] = [:]
    var reasoningReads: [String] = []
    var onPage: (() -> Void)?
    var pageCount = 0
    var unreadRows: [[String: Any]]?
    var historyPaths: [String] = []
    var storedHistory: [String: Any]?
    var beforeStoredHistoryReturns: (@MainActor () async -> Void)?
    var storedTimeline: [String: Any]?
    var timeoutNextA = false

    static var resumeTimeout: NSError {
        NSError(domain: "Hermes", code: 408, userInfo: [NSLocalizedDescriptionKey: "Hermes did not respond in time."])
    }

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append(method)
        if method == "model.options", holdModelOptions {
            await withCheckedContinuation { heldModelOptions = $0 }
            return ["providers": []]
        }
        if method == "config.get", params["key"] as? String == "reasoning" {
            reasoningReads.append(params["session_id"] as? String ?? "")
            return ["value": "medium"]
        }
        guard method == "session.resume" else { return [:] }
        let id = params["session_id"] as? String ?? ""
        if id == "a", timeoutNextA {
            timeoutNextA = false
            throw Self.resumeTimeout
        }
        if let unreadRows {
            return [
                "session_id": "runtime-\(id)", "session_key": id,
                "messages": unreadRows.map { row in
                    [
                        "role": row["role"]!, "text": row["content"]!, "row_id": row["id"]!,
                        "timestamp": row["timestamp"]!,
                    ]
                },
            ]
        }
        if id == "a", holdNextA {
            holdNextA = false
            await withCheckedContinuation { held = $0 }
            if let nextFailure { throw nextFailure }
            if let nextResponse { return nextResponse }
        }
        if holdHistory {
            return [
                "session_id": "runtime-\(id)", "session_key": id, "info": resumeInfo,
                "messages": [[String: Any]](), "messages_omitted": true,
            ]
        }
        return [
            "session_id": "runtime-\(id)", "session_key": id,
            "messages": [
                ["role": "user", "text": "question \(id)", "row_id": 1],
                ["role": "assistant", "text": "answer \(id)", "row_id": 2],
            ],
        ]
    }

    func release() {
        held?.resume()
        held = nil
    }

    func releaseModelOptions() {
        holdModelOptions = false
        heldModelOptions?.resume()
        heldModelOptions = nil
    }

    func releaseHistory() {
        holdHistory = false
        heldHistory?.resume()
        heldHistory = nil
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        let endpoint = URLComponents(string: path)?.path
        if endpoint?.hasSuffix("/messages") == true, let storedHistory {
            historyPaths.append(path)
            let beforeReturn = beforeStoredHistoryReturns
            beforeStoredHistoryReturns = nil
            await beforeReturn?()
            return storedHistory
        }
        if endpoint?.hasSuffix("/timeline") == true, let storedTimeline {
            historyPaths.append(path)
            return storedTimeline
        }
        if holdHistory { await withCheckedContinuation { heldHistory = $0 } }
        pageCount += 1
        onPage?()
        if let unreadRows { return ["messages": unreadRows, "pagination": ["returned": unreadRows.count]] }
        let rows: [[String: Any]] = (0..<120).map {
            ["id": $0 + 1, "role": "tool", "content": "tool result"]
        }
        return ["messages": rows, "pagination": ["returned": rows.count]]
    }
}

@MainActor
struct SessionSwitchCacheTests {
    @Test func unreadReplyAfterStaleSessionRecencyStillGetsADivider() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        let profile = UUID().uuidString
        let seen = SidebarSessionSeenStore.shared
        let now = Date()
        let previous = now.addingTimeInterval(-120)
        let staleUpdate = now.addingTimeInterval(-90)
        let reply = now.addingTimeInterval(-30)
        seen.markSeen(profileID: profile, sessionID: "chat", at: previous)
        defer { seen.reconcile(profileID: profile, availableSessionIDs: []) }
        rpc.unreadRows = [
            ["id": 1, "role": "user", "content": "Question", "timestamp": previous.timeIntervalSince1970],
            ["id": 2, "role": "assistant", "content": "Reply", "timestamp": reply.timeIntervalSince1970],
        ]
        let session = HermesSession(
            id: "chat", profileID: profile, title: "Chat", preview: "", startedAt: previous,
            updatedAt: staleUpdate, messageCount: 2, source: "test")
        #expect(await model.resumeSession(session, reportFailure: true))
        #expect(model.unreadDividerMessageID == model.messages.last?.id)
        #expect(seen.seenAt(profileID: profile, sessionID: "chat").map { $0 >= reply } == true)
        #expect(rpc.pageCount == 1)
    }

    @Test(arguments: [2, TranscriptHistoryPaging.conversationBufferRowLimit])
    func openedTailPlacesUnreadDividerWithoutReadingItAgain(rowCount: Int) async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        let profile = UUID().uuidString
        let seen = SidebarSessionSeenStore.shared
        let now = Date()
        let seenAt = now.addingTimeInterval(-120)
        let promptAt = rowCount == 2 ? seenAt : now.addingTimeInterval(-60)
        let replyAt = now.addingTimeInterval(-30)
        seen.markSeen(profileID: profile, sessionID: "a", at: seenAt)
        defer { seen.reconcile(profileID: profile, availableSessionIDs: []) }
        var rows: [[String: Any]] = (0..<(rowCount - 2)).map { index in
            [
                "id": index + 1, "role": "assistant", "content": "Earlier answer",
                "timestamp": seenAt.timeIntervalSince1970,
            ]
        }
        rows.append([
            "id": rowCount - 1, "role": "user", "content": "Question", "timestamp": promptAt.timeIntervalSince1970,
        ])
        rows.append([
            "id": rowCount, "role": "assistant", "content": "Unread reply", "timestamp": replyAt.timeIntervalSince1970,
        ])
        rpc.holdHistory = true
        rpc.storedHistory = storedPage(rows, profile: profile)
        rpc.storedTimeline = ["entries": [[String: Any]]()]

        #expect(await model.resumeSession(session("a", profile: profile), reportFailure: true))

        #expect(model.sessionActionsReady)
        #expect(model.unreadDividerMessageID == model.messages.last?.id)
        #expect(seen.seenAt(profileID: profile, sessionID: "a").map { $0 >= replyAt } == true)
        #expect(rpc.historyPaths.filter { $0.contains("/messages?") }.count == 1)
    }

    @Test func unreadReplyBeforeLoadedTailStillGetsADivider() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        let profile = UUID().uuidString
        let seen = SidebarSessionSeenStore.shared
        let now = Date()
        let seenAt = now.addingTimeInterval(-120)
        seen.markSeen(profileID: profile, sessionID: "a", at: seenAt)
        defer { seen.reconcile(profileID: profile, availableSessionIDs: []) }
        let oldestReply: [String: Any] = [
            "id": 1, "role": "assistant", "content": "Earlier unread reply",
            "timestamp": now.addingTimeInterval(-60).timeIntervalSince1970,
        ]
        let tail: [[String: Any]] = (0..<TranscriptHistoryPaging.conversationBufferRowLimit).map { index in
            [
                "id": index + 2, "role": "assistant", "content": "Later unread reply",
                "timestamp": now.addingTimeInterval(-30).timeIntervalSince1970,
            ]
        }
        let fullHistory = storedPage([oldestReply] + tail, profile: profile)
        let earlierPage = storedPage([oldestReply], profile: profile)
        rpc.holdHistory = true
        rpc.storedTimeline = ["entries": [[String: Any]]()]
        rpc.storedHistory = storedPage(tail, profile: profile)
        rpc.beforeStoredHistoryReturns = { [weak rpc] in
            rpc?.storedHistory = fullHistory
            rpc?.beforeStoredHistoryReturns = { [weak rpc] in rpc?.storedHistory = earlierPage }
        }

        #expect(await model.resumeSession(session("a", profile: profile), reportFailure: true))

        #expect(model.sessionActionsReady)
        #expect(model.messages.first?.text == "Earlier unread reply")
        #expect(model.unreadDividerMessageID == model.messages.first?.id)
        #expect(rpc.historyPaths.filter { $0.contains("/messages?") }.count == 3)
    }

    private func makeModel(_ rpc: SessionSwitchRPC) -> DockModel {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-switch-test-\(id)")
        let defaults = UserDefaults(suiteName: "Herm.SessionSwitchTests.\(id)")!
        return DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: rpc)
    }

    private func session(_ id: String, profile: String? = nil) -> HermesSession {
        HermesSession(
            id: id, profileID: profile, title: id, preview: "", startedAt: nil, messageCount: 2, source: "test")
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for session switch")
    }

    @Test func backgroundBotReplyAlreadyHasItsFinalPositionAndIdentityInOpeningPreview() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        model.resumeSession(session("a"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        model.resumeSession(session("b"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "b" }

        model.insertBotActivity(
            BotActivityRecord(
                originSessionID: "a", botID: "cypher", botName: "Cypher", summary: "Bot response",
                state: .completed, createdAt: .distantFuture, updatedAt: .distantFuture, result: "Report"))
        rpc.holdNextA = true
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        let preview = try #require(model.sessionTranscriptPreview)
        #expect(preview.messages.map(\.text) == ["question a", "answer a", "Report"])
        #expect(model.messages.isEmpty)
        rpc.release()
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        #expect(model.messages.map(\.id) == preview.messages.map(\.id))
    }

    @Test func cachedTranscriptAppearsBeforeResumeAndIsReadOnlyUntilConfirmed() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: ConversationMessageActionState(),
            voice: VoiceOutput(), coordinator: ConversationTranscriptCoordinator())
        model.resumeSession(session("a"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        let originalIDs = model.messages.map(\.id)
        model.resumeSession(session("b"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "b" }

        rpc.holdNextA = true
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        source.refresh()
        #expect(model.messages.isEmpty)
        #expect(source.snapshot.messages.map(\.text) == ["question a", "answer a"])
        #expect(source.snapshot.messages.map(\.id) == originalIDs)
        #expect(!source.snapshot.context.actionsReady)
        #expect(!model.sessionActionsReady)
        model.draft = "do not send yet"
        model.send()
        #expect(model.draft == "do not send yet")
        #expect(!rpc.requests.contains("prompt.submit"))
        model.voiceState = .listening
        model.voiceProfileID = model.sessionProfileID
        model.voiceSessionID = "another-session"
        model.finishVoiceUtterance(transcript: "unrelated voice")
        #expect(!model.draft.contains("unrelated voice"))
        model.voiceSessionID = model.sessionID
        model.finishVoiceUtterance(transcript: "spoken while loading")
        #expect(model.draft.contains("spoken while loading"))

        let latestRequest = model.scrollToLatestMessageRequest
        rpc.release()
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        source.refresh()
        #expect(model.scrollToLatestMessageRequest == latestRequest)
        #expect(source.snapshot.messages.map(\.id) == originalIDs)
        #expect(source.snapshot.context.actionsReady)
        #expect(model.sessionTranscriptPreview == nil)
    }

    enum PreloadedTail: CaseIterable {
        case read, unread, partial, newerSession, unprovenOwner
    }

    @Test(arguments: PreloadedTail.allCases)
    func firstVisitShowsOnlyAPreloadThatCoversTheReadTail(tail: PreloadedTail) async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer {
            rpc.release()
            model.shutdown()
        }
        let profile = UUID().uuidString
        let seen = SidebarSessionSeenStore.shared
        let seenAt = Date().addingTimeInterval(-90)
        let updatedAt = seenAt.addingTimeInterval(-30)
        seen.markSeen(profileID: profile, sessionID: "a", at: seenAt)
        defer { seen.reconcile(profileID: profile, availableSessionIDs: []) }
        func savedSession(updatedAt: Date) -> HermesSession {
            HermesSession(
                id: "a", profileID: profile, title: "Saved", preview: "", startedAt: nil,
                updatedAt: updatedAt, messageCount: 2, source: "test")
        }
        let saved = savedSession(updatedAt: updatedAt)
        var rows: [[String: Any]] = []
        if tail == .partial {
            rows = (1..<(TranscriptHistoryPaging.pageRowLimit)).map {
                ["id": $0, "role": "tool", "content": "Earlier work", "timestamp": updatedAt.timeIntervalSince1970]
            }
        }
        let replyAt = tail == .unread ? seenAt.addingTimeInterval(30) : updatedAt
        rows.append([
            "id": rows.count + 1, "role": "assistant", "content": "Preloaded reply",
            "timestamp": replyAt.timeIntervalSince1970,
        ])
        rpc.storedHistory = storedPage(rows, profile: tail == .unprovenOwner ? "another-profile" : profile)
        model.sessions = [saved]
        model.scheduleTranscriptPreload()
        await model.sessionTranscriptPreloadTask?.value

        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: ConversationMessageActionState(),
            voice: VoiceOutput(), coordinator: ConversationTranscriptCoordinator())
        rpc.holdNextA = true
        model.resumeSession(tail == .newerSession ? savedSession(updatedAt: seenAt.addingTimeInterval(1)) : saved)
        try await waitUntil { rpc.held != nil }
        source.refresh()

        #expect((model.sessionTranscriptPreview?.isPreloaded == true) == (tail != .unprovenOwner))
        #expect(model.positionsAtUnreadOnResume)
        #expect(!source.snapshot.context.actionsReady)
        #expect(source.snapshot.messages.map(\.text) == (tail == .read ? ["Preloaded reply"] : []))
    }

    @Test func switchingBackToAnotherBotShowsItsTranscriptInTheSelectionTurn() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer {
            rpc.release()
            model.shutdown()
        }
        let profile = UUID().uuidString
        let a = session("a", profile: profile)
        let b = session("b", profile: UUID().uuidString)
        let seen = SidebarSessionSeenStore.shared
        defer { seen.reconcile(profileID: profile, availableSessionIDs: []) }

        model.setProfileScope(profile)
        #expect(await model.resumeSession(a, reportFailure: true))
        seen.markSeen(profileID: profile, sessionID: a.id, at: .now)
        model.setProfileScope(b.profileID)
        #expect(await model.resumeSession(b, reportFailure: true))

        model.setProfileScope(profile)
        rpc.holdNextA = true
        model.resumeSession(a)
        #expect(model.sessionProfileID == profile)
        #expect(model.navigationSessionID == a.id)
        #expect(model.sessionTranscriptLoadState == .refreshing)
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: ConversationMessageActionState(),
            voice: VoiceOutput(), coordinator: ConversationTranscriptCoordinator())
        #expect(source.snapshot.messages.map(\.text) == ["question a", "answer a"])
        #expect(!source.snapshot.context.actionsReady)
        try await waitUntil { rpc.held != nil }
        rpc.release()
        _ = await model.sessionResumeTask?.value
        #expect(model.sessionActionsReady)
    }

    @Test func activityWhileAwayStillShowsLastLoadedTranscriptBeforeResume() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        #expect(await model.resumeSession(session("a"), reportFailure: true))
        let originalIDs = model.messages.map(\.id)
        #expect(await model.resumeSession(session("b"), reportFailure: true))
        model.receiveGatewayEvent("message.complete", params: ["session_id": "runtime-a"])
        rpc.holdNextA = true
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        #expect(model.displayedTranscriptMessages.map(\.id) == originalIDs)
        #expect(model.displayedTranscriptMessages.map(\.text) == ["question a", "answer a"])
        #expect(!model.sessionActionsReady)
        rpc.release()
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
    }

    @Test func activityKeepsTheCachedTranscript() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        model.resumeSession(session("a"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        let key = WorkspaceIdentity.session(profileID: nil, sessionID: "a")
        #expect(model.sessionTranscriptCache.value(for: key) != nil)
        model.receiveGatewayEvent("message.start", params: ["session_id": "runtime-a"])
        #expect(model.sessionTranscriptCache.value(for: key) != nil)
    }

    @Test func leavingASessionCachesItsCurrentTail() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        #expect(await model.resumeSession(session("a"), reportFailure: true))
        model.messages.append(ChatMessage(role: .hermes, text: "added while viewing"))
        #expect(await model.resumeSession(session("b"), reportFailure: true))
        rpc.holdNextA = true
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        #expect(model.displayedTranscriptMessages.last?.text == "added while viewing")
        rpc.release()
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
    }

    @Test func startingANewChatCachesTheConversationItLeaves() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        #expect(await model.resumeSession(session("a"), reportFailure: true))
        model.messages.append(ChatMessage(role: .hermes, text: "added before new chat"))
        model.newChat()
        rpc.holdNextA = true
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        #expect(model.displayedTranscriptMessages.last?.text == "added before new chat")
        rpc.release()
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
    }

    @Test func failedRefreshKeepsPreviewAndRetryCanConfirmIt() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        model.resumeSession(session("a"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        model.resumeSession(session("b"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "b" }
        rpc.holdNextA = true
        rpc.nextFailure = URLError(.notConnectedToInternet)
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        rpc.release()
        try await waitUntil {
            if case .failed = model.sessionTranscriptLoadState { return true }
            return false
        }
        #expect(model.sessionTranscriptPreview?.messages.last?.text == "answer a")
        #expect(!model.sessionActionsReady)
        rpc.nextFailure = nil
        model.resumeSession(session("a"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        #expect(model.messages.last?.text == "answer a")
    }

    @Test func coldProfileSessionShowsStoredHistoryAfterResumeTimeout() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        let selected = session("a", profile: "other-profile")
        let listed = session("b", profile: "current-profile")
        model.sessionProjectionState = .ready([listed])
        model.allBotSessionsState = .ready([listed, selected])
        rpc.storedHistory = [
            "session_id": "a", "profile": "other-profile", "pagination": ["returned": 2],
            "messages": [
                ["id": 9, "role": "user", "content": "Stored question"],
                ["id": 10, "role": "assistant", "content": "Stored answer"],
            ],
        ]
        rpc.holdNextA = true
        rpc.nextFailure = SessionSwitchRPC.resumeTimeout

        let opening = model.startSessionResume(selected, reportFailure: true, reviewUnread: false)
        try await waitUntil { rpc.held != nil }
        rpc.release()
        #expect(await !opening.value)

        #expect(model.displayedTranscriptMessages.map(\.text) == ["Stored question", "Stored answer"])
        #expect(!model.sessionActionsReady)
        #expect(model.sessionProjectionState == .ready([listed]))
        #expect(model.allBotSessionsState == .ready([listed, selected]))
        let path = try #require(rpc.historyPaths.first)
        let url = try #require(URLComponents(string: path))
        #expect(url.path == "/api/sessions/a/messages")
        #expect(url.queryItems?.first(where: { $0.name == "profile" })?.value == "other-profile")
    }

    @Test func recoveredSelectionIgnoresLiveCompletionWithoutMarkingItSeen() async {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        let profile = UUID().uuidString
        let seen = SidebarSessionSeenStore.shared
        defer {
            seen.reconcile(profileID: profile, availableSessionIDs: [])
            model.shutdown()
        }
        rpc.storedHistory = storedPage([["id": 1, "role": "user", "content": "stored prompt"]], profile: profile)
        rpc.timeoutNextA = true
        let selected = session("a", profile: profile)
        #expect(await !model.startSessionResume(selected, reportFailure: true, reviewUnread: false).value)
        let previousSeen = Date().addingTimeInterval(-60)
        seen.markSeen(profileID: profile, sessionID: selected.id, at: previousSeen)
        model.isPopoverVisible = true
        model.receiveGatewayEvent(
            "message.complete", params: ["session_id": selected.id, "payload": ["text": "live completion"]])
        #expect(model.displayedTranscriptMessages.map(\.text) == ["stored prompt"])
        #expect(seen.seenAt(profileID: profile, sessionID: selected.id) == previousSeen)
        #expect(!model.autoTitleAttempts.contains(selected.id))
        #expect(!model.sessionActionsReady)
    }

    @Test func timeoutRecoveryDoesNotProjectCompletionWhileStoredHistoryIsPending() async {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        let profile = UUID().uuidString
        let seen = SidebarSessionSeenStore.shared
        let previousSeen = Date().addingTimeInterval(-60)
        seen.markSeen(profileID: profile, sessionID: "a", at: previousSeen)
        defer {
            seen.reconcile(profileID: profile, availableSessionIDs: [])
            model.shutdown()
        }
        model.isPopoverVisible = true
        rpc.timeoutNextA = true
        rpc.storedHistory = storedPage([["id": 1, "role": "user", "content": "stored prompt"]], profile: profile)
        var checkedPendingHistory = false
        rpc.beforeStoredHistoryReturns = {
            checkedPendingHistory = true
            model.receiveGatewayEvent(
                "message.complete", params: ["session_id": "a", "seq": 1, "payload": ["text": "live reply"]])
            #expect(model.displayedTranscriptMessages.isEmpty)
            #expect(seen.seenAt(profileID: profile, sessionID: "a") == previousSeen)
            #expect(!model.sessionActionsReady)
        }

        #expect(await !model.resumeSession(session("a", profile: profile), reportFailure: true, reviewUnread: false))
        #expect(checkedPendingHistory)
        #expect(model.displayedTranscriptMessages.map(\.text) == ["stored prompt"])
        #expect(seen.seenAt(profileID: profile, sessionID: "a") == previousSeen)
    }

    @Test(arguments: [false, true])
    func confirmedRetryPublishesSequencedCompletionOnce(historyIncludesReply: Bool) async {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        let selected = session("a", profile: "owner")
        defer { model.shutdown() }
        let prompt: [String: Any] = ["id": 1, "role": "user", "content": "stored prompt"]
        let reply: [String: Any] = ["id": 2, "role": "assistant", "content": "live reply"]
        let completion: [String: Any] = [
            "session_id": "runtime-a", "seq": 1, "payload": ["text": "live reply"],
            "persisted_turn": ["complete": true, "final_assistant_row_id": 2],
        ]
        rpc.timeoutNextA = true
        rpc.storedHistory = storedPage([prompt])
        #expect(await !model.resumeSession(selected, reportFailure: true, reviewUnread: false))
        rpc.holdHistory = true  // Omit messages from resume so the retry reads the REST tail.
        rpc.storedHistory = storedPage(historyIncludesReply ? [prompt, reply] : [prompt])
        var deliveredDuringHistoryRead = false
        rpc.beforeStoredHistoryReturns = {
            deliveredDuringHistoryRead = true
            #expect(model.sessionID == "runtime-a")
            model.receiveGatewayEvent("message.complete", params: completion)
            model.receiveGatewayEvent("message.complete", params: completion)
            #expect(model.displayedTranscriptMessages.map(\.text) == ["stored prompt"])
            #expect(!model.sessionActionsReady)
        }

        #expect(await model.resumeSession(selected, reportFailure: true, reviewUnread: false))
        #expect(deliveredDuringHistoryRead)
        model.receiveGatewayEvent("message.complete", params: completion)
        #expect(model.sessionActionsReady)
        #expect(model.displayedTranscriptMessages.map(\.text) == ["stored prompt", "live reply"])
    }

    @Test func authenticationChangeClearsOpenRecoveredPaneAndRejectsLateRecovery() async throws {
        let rpc = SessionSwitchRPC()
        let runtime = makeModel(rpc)
        let chat = EdgeQuickConversationModel()
        defer {
            chat.shutdown()
            runtime.shutdown()
        }
        let destination = QuickDestination(profileID: "owner", sessionID: "a")
        rpc.storedHistory = storedPage([["id": 1, "role": "user", "content": "previous identity"]])
        rpc.timeoutNextA = true
        await chat.load(destination, runtime: runtime)
        let model = try #require(chat.conversation)
        #expect(model.hasReadableStoredTranscript)
        #expect(!model.storedMessageReferences.isEmpty)

        rpc.timeoutNextA = true
        rpc.beforeStoredHistoryReturns = { model.invalidateGatewayAuthenticationProjection() }
        let retry = try #require(chat.startLoad(destination, runtime: runtime))
        #expect(await !retry.value)
        #expect(chat.conversation === model)
        #expect(chat.paneLoadFailed)
        #expect(!chat.isLoading)
        #expect(!model.hasReadableStoredTranscript)
        #expect(model.displayedTranscriptMessages.isEmpty)
        #expect(model.storedMessageReferences.isEmpty)
        #expect(model.transcriptMessageIDsByRowID.isEmpty)
        #expect(model.transcriptHistoryCursor == nil)
        #expect(!model.sessionActionsReady)
    }

    @Test func startupKeepsSavedReadOnlySelectionWithoutResumingLatest() async {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        model.profileScopeID = "owner"
        model.defaults.set("a", forKey: model.lastSessionIDKey(for: model.profileScopeID))
        model.sessionProjectionState = .ready([session("b", profile: "owner")])
        model.isPollingSessions = true
        rpc.storedHistory = storedPage([["id": 1, "role": "user", "content": "saved prompt"]])
        rpc.timeoutNextA = true

        await model.restoreLatestSessionIfNeeded()?.value

        #expect(model.navigationSessionID == "a")
        #expect(model.displayedTranscriptMessages.map(\.text) == ["saved prompt"])
        #expect(!model.sessionActionsReady)
        #expect(rpc.requests.filter { $0 == "session.resume" }.count == 1)
    }

    @Test func recoveredCompactionTipPagesReadOnlyAndOnlySuccessfulRetryEnablesActions() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        let selected = session("a", profile: "owner")
        let limit = TranscriptHistoryPaging.conversationBufferRowLimit
        let rows: [[String: Any]] = (2...(limit + 1)).map { ["id": $0, "role": "user", "content": "row \($0)"] }
        rpc.storedHistory = storedPage(rows, sessionID: "tip")
        rpc.storedTimeline = [
            "session_id": "tip", "profile": "owner", "entries": [["row_id": 1, "preview": "older"]],
        ]
        rpc.timeoutNextA = true

        #expect(await !model.startSessionResume(selected, reportFailure: true, reviewUnread: false).value)
        #expect(model.hasReadableStoredTranscript)
        #expect(model.navigationSessionID == "a")
        #expect(model.sessionID == "a")
        #expect(!model.sessionActionsReady)
        let proof = try #require(rpc.historyPaths.dropFirst().first.flatMap { URLComponents(string: $0) })
        #expect(proof.path == "/api/sessions/a/timeline")
        #expect(proof.queryItems?.contains(URLQueryItem(name: "limit", value: "1")) == true)
        #expect(proof.queryItems?.contains(URLQueryItem(name: "profile", value: "owner")) == true)
        await model.transcriptTimelineTask?.value
        #expect(model.unloadedTranscriptPrompts.map(\.rowID) == [1])
        let timeline = try #require(rpc.historyPaths.last.flatMap { URLComponents(string: $0) })
        #expect(timeline.path == "/api/sessions/tip/timeline")
        #expect(timeline.queryItems?.contains(URLQueryItem(name: "profile", value: "owner")) == true)
        rpc.storedTimeline = [
            "session_id": "tip", "profile": "other", "entries": [["row_id": 1, "preview": "foreign"]],
        ]
        model.loadTranscriptTimeline(generation: model.sessionResumeGeneration)
        await model.transcriptTimelineTask?.value
        #expect(model.unloadedTranscriptPrompts.isEmpty)

        rpc.storedHistory = storedPage([["id": 1, "role": "user", "content": "wrong tip"]])
        #expect(await model.loadTranscriptHistory(through: 1) == nil)
        #expect(model.messages.first?.text == "row 2")
        rpc.storedHistory = storedPage([["id": 1, "role": "user", "content": "older"]], sessionID: "tip")
        #expect(await model.loadTranscriptHistory(through: 1) != nil)
        #expect(model.messages.first?.text == "older")
        #expect(model.messages.count == limit + 1)
        #expect(!model.sessionActionsReady)

        let pagedIDs = model.messages.map(\.id)
        let pagedCursor = model.transcriptHistoryCursor
        rpc.storedHistory = storedPage(Array(rows.suffix(2)), sessionID: "tip")
        rpc.storedTimeline = ["session_id": "tip", "profile": "owner", "entries": [[String: Any]]()]
        rpc.holdNextA = true
        rpc.nextFailure = SessionSwitchRPC.resumeTimeout
        let retry = model.startSessionResume(selected, reportFailure: true, reviewUnread: false)
        try await waitUntil { rpc.held != nil }
        #expect(model.sessionTranscriptLoadState == .refreshing)
        #expect(model.hasReadableStoredTranscript)
        #expect(model.displayedTranscriptMessages.map(\.id) == pagedIDs)
        #expect(!model.sessionActionsReady)
        rpc.release()
        #expect(await !retry.value)
        #expect(model.messages.first?.text == "older")
        #expect(model.messages.map(\.id) == pagedIDs)
        #expect(model.transcriptHistoryCursor == pagedCursor)
        #expect(model.hasReadableStoredTranscript)
        #expect(!model.sessionActionsReady)
        #expect(await model.startSessionResume(selected, reportFailure: true, reviewUnread: false).value)
        #expect(model.sessionActionsReady)
        #expect(model.messages.last?.text == "answer a")
        #expect(rpc.requests.filter { $0 == "session.resume" }.count == 3)
    }

    @Test func coldRecoveryRejectsStoredRowsFromAnotherProfile() async {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        rpc.storedHistory = storedPage([["id": 1, "role": "user", "content": "foreign"]], profile: "other")
        rpc.timeoutNextA = true
        let selected = session("a", profile: "owner")

        #expect(await !model.startSessionResume(selected, reportFailure: true, reviewUnread: false).value)
        #expect(rpc.historyPaths.count == 1)
        #expect(!model.displayedTranscriptMessages.contains { $0.text == "foreign" })
        #expect(!model.hasReadableStoredTranscript)
        #expect(!model.sessionActionsReady)
    }

    @Test func lateStoredHistoryCannotReplaceANewerSelection() async {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        defer { model.shutdown() }
        rpc.storedHistory = storedPage([["id": 1, "role": "user", "content": "late a"]])
        rpc.timeoutNextA = true
        let selected = session("a", profile: "owner")
        let newer = session("b", profile: "owner")
        rpc.beforeStoredHistoryReturns = {
            let opening = model.startSessionResume(newer, reportFailure: true, reviewUnread: false)
            #expect(await opening.value)
            #expect(model.navigationSessionID == "b")
        }

        #expect(await !model.startSessionResume(selected, reportFailure: true, reviewUnread: false).value)
        #expect(rpc.historyPaths.count == 1)
        #expect(model.navigationSessionID == "b")
        #expect(model.sessionActionsReady)
        #expect(model.messages.map(\.text) == ["question b", "answer b"])
    }

    private func storedPage(
        _ rows: [[String: Any]], sessionID: String = "a", profile: String = "owner"
    ) -> [String: Any] {
        ["session_id": sessionID, "profile": profile, "pagination": ["returned": rows.count], "messages": rows]
    }

    @Test func cacheEvictsLeastRecentlyUsedAndRejectsOversizedEntries() {
        let cache = SessionTranscriptCache()
        for index in 0..<8 {
            let message = ChatMessage(role: .user, text: "message \(index)")
            cache.store(RestoredTranscript(messages: [message], pendingImages: []), references: [:], for: "\(index)")
        }
        #expect(cache.value(for: "0") != nil)
        let newest = ChatMessage(role: .user, text: "newest")
        cache.store(RestoredTranscript(messages: [newest], pendingImages: []), references: [:], for: "8")
        #expect(cache.value(for: "1") == nil)
        #expect(cache.value(for: "0") != nil)
        let large = ChatMessage(role: .user, text: String(repeating: "x", count: 16 * 1024 * 1024 + 1))
        cache.store(RestoredTranscript(messages: [large], pendingImages: []), references: [:], for: "large")
        #expect(cache.value(for: "large") == nil)
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("cached-image.png")
        let pending = RestoredTranscript.PendingImages(messageID: newest.id, fileURLs: [imageURL])
        cache.store(RestoredTranscript(messages: [newest], pendingImages: [pending]), references: [:], for: "image-ref")
        #expect(cache.value(for: "image-ref")?.pendingImages.first?.fileURLs == [imageURL])
        let decoded = ChatMessage(role: .user, text: "image", image: NSImage(size: NSSize(width: 1, height: 1)))
        cache.store(RestoredTranscript(messages: [decoded], pendingImages: []), references: [:], for: "decoded")
        #expect(cache.value(for: "decoded") == nil)
        cache.store(RestoredTranscript(messages: [newest], pendingImages: []), references: [:], for: "keep")
        cache.refresh(RestoredTranscript(messages: [decoded], pendingImages: []), references: [:], for: "keep")
        #expect(cache.value(for: "keep")?.messages.last?.text == "newest")
        let history = (0..<50).map { ChatMessage(role: .user, text: "message \($0)") }
        cache.store(RestoredTranscript(messages: history, pendingImages: []), references: [:], for: "history")
        #expect(cache.value(for: "history")?.messages.count == 36)
        #expect(cache.value(for: "history")?.messages.first?.text == "message 14")
    }

    @Test func missingSessionDiscardsCachedContent() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        model.resumeSession(session("a"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        model.resumeSession(session("b"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "b" }
        rpc.holdNextA = true
        rpc.nextFailure = NSError(domain: "Hermes", code: 1, userInfo: ["HermesRPCCode": 4007])
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        rpc.release()
        try await waitUntil {
            if case .failed = model.sessionTranscriptLoadState { return true }
            return false
        }
        #expect(model.sessionTranscriptPreview == nil)
        let key = WorkspaceIdentity.session(profileID: model.sessionProfileID, sessionID: "a")
        #expect(model.sessionTranscriptCache.value(for: key) == nil)
    }

    @Test func ownershipMismatchKeepsOnlyTheSelectedSessionsPreview() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        model.resumeSession(session("a"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        model.resumeSession(session("b"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "b" }
        rpc.holdNextA = true
        rpc.nextResponse = [
            "session_id": "unrelated", "session_key": "unrelated",
            "messages": [["role": "assistant", "text": "wrong conversation"]],
        ]
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        rpc.release()
        try await waitUntil {
            if case .failed = model.sessionTranscriptLoadState { return true }
            return false
        }
        #expect(model.sessionTranscriptPreview?.messages.last?.text == "answer a")
        #expect(!model.displayedTranscriptMessages.contains { $0.text == "wrong conversation" })
        #expect(!model.sessionActionsReady)
    }

    @Test func cachedMessagesNeverCrossProfileBoundaries() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        model.resumeSession(session("a", profile: "one"))
        try await waitUntil { model.sessionActionsReady && model.sessionProfileID == "one" }
        rpc.holdNextA = true
        model.resumeSession(session("a", profile: "two"))
        try await waitUntil { rpc.held != nil }
        #expect(model.sessionTranscriptPreview == nil)
        #expect(model.displayedTranscriptMessages.isEmpty)
        rpc.release()
        try await waitUntil { model.sessionActionsReady && model.sessionProfileID == "two" }
    }

    @Test func obsoleteHistoryReadStopsWithoutInlineResumeFallback() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        rpc.onPage = { model.newChat() }
        do {
            _ = try await model.loadTranscriptTail(
                storageSessionID: "old", profileID: nil, minimumRowCount: 0,
                fallbackResumeParams: ["session_id": "old", "defer_history": true])
            Issue.record("A replaced session must cancel its history read")
        } catch is CancellationError {
            #expect(rpc.pageCount == 1)
            #expect(!rpc.requests.contains("session.resume"))
        }
    }

    @Test func lateResumeCannotReplaceANewerSelection() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        rpc.holdNextA = true
        rpc.nextResponse = [
            "session_id": "runtime-a", "session_key": "a", "messages": [[String: Any]](),
            "info": ["reasoning_effort": "high"],
        ]
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        model.resumeSession(session("b"))
        try await waitUntil {
            model.sessionActionsReady && model.sessionStorageID == "b" && model.sessionReasoningVariant == .medium
        }
        rpc.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.sessionStorageID == "b")
        #expect(model.messages.last?.text == "answer b")
        #expect(model.sessionReasoningVariant == .medium)
    }

    @Test func concurrentModelCatalogRefreshesShareOneRequest() async throws {
        let rpc = SessionSwitchRPC()
        rpc.holdModelOptions = true
        let model = makeModel(rpc)
        model.resumeSession(session("a"))
        try await waitUntil { rpc.heldModelOptions != nil && model.sessionActionsReady }
        model.refreshSessionModelOptions()
        model.refreshSessionModelOptions()
        #expect(rpc.requests.filter { $0 == "model.options" }.count == 1)
        rpc.releaseModelOptions()
        try await waitUntil { !model.isLoadingRuntimeModelOptions }
    }

    @Test(arguments: [true, false])
    func thinkingLevelLoadsWhileHistoryAndCatalogArePending(snapshotHasEffort: Bool) async throws {
        let rpc = SessionSwitchRPC()
        rpc.holdHistory = true
        rpc.holdModelOptions = true
        if snapshotHasEffort { rpc.resumeInfo = ["reasoning_effort": "high"] }
        let model = makeModel(rpc)
        defer {
            rpc.releaseHistory()
            rpc.releaseModelOptions()
            model.shutdown()
        }
        model.resumeSession(session("a"))
        try await waitUntil {
            rpc.heldHistory != nil && rpc.heldModelOptions != nil && model.sessionReasoningVariant != nil
        }

        #expect(!model.sessionActionsReady)
        #expect(model.isEffortCatalogPending)
        #expect(rpc.reasoningReads == (snapshotHasEffort ? [] : ["runtime-a"]))
        let presentation = ComposerEffortPresentation(
            selection: model.sessionReasoningVariant, choices: nil, wire: model.sessionReasoningWire,
            pending: false, loading: model.isEffortCatalogPending, stale: model.sessionReasoningStale)
        #expect(presentation.status == (snapshotHasEffort ? "High" : "Medium"))
        #expect(presentation.disabled)

        rpc.releaseHistory()
        rpc.releaseModelOptions()
        try await waitUntil { model.sessionActionsReady && !model.isLoadingRuntimeModelOptions }
    }

    @Test func selectedSessionAttentionCannotActBeforeConfirmation() async {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        model.sessionID = "a"
        model.sessionStorageID = "a"
        model.storageIDsByRuntimeID["runtime-a"] = "a"
        model.sessionTranscriptLoadState = .loading
        let control = ControlCenterModel(rpc: HermesControlRPC(client: rpc))
        control.dockModel = model
        let item = AttentionItem(
            id: "approval", reference: .init(source: .hermesApproval, sourceID: "runtime-a", sessionID: "runtime-a"),
            kind: .approval, title: "Approval", detail: "", createdAt: .now, state: .open, actions: [.approve])
        control.respond(to: item, action: .approve)
        var fallback = item
        fallback.reference.sessionID = nil
        control.respond(to: fallback, action: .stop)
        for _ in 0..<10 { await Task.yield() }
        #expect(!rpc.requests.contains("approval.respond"))
        #expect(!rpc.requests.contains("session.interrupt"))
    }
}
