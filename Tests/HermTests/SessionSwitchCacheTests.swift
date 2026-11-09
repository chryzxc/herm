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
    var onPage: (() -> Void)?
    var pageCount = 0
    var unreadRows: [[String: Any]]?

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append(method)
        if method == "model.options", holdModelOptions {
            await withCheckedContinuation { heldModelOptions = $0 }
            return ["providers": []]
        }
        guard method == "session.resume" else { return [:] }
        let id = params["session_id"] as? String ?? ""
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

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
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

    @Test func activityInvalidatesTheCachedTranscript() async throws {
        let rpc = SessionSwitchRPC()
        let model = makeModel(rpc)
        model.resumeSession(session("a"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "a" }
        let key = WorkspaceIdentity.session(profileID: nil, sessionID: "a")
        #expect(model.sessionTranscriptCache.value(for: key) != nil)
        model.receiveGatewayEvent("message.start", params: ["session_id": "runtime-a"])
        #expect(model.sessionTranscriptCache.value(for: key) == nil)
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
        model.resumeSession(session("a"))
        try await waitUntil { rpc.held != nil }
        model.resumeSession(session("b"))
        try await waitUntil { model.sessionActionsReady && model.sessionStorageID == "b" }
        rpc.release()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.sessionStorageID == "b")
        #expect(model.messages.last?.text == "answer b")
    }

    @Test func concurrentModelCatalogRefreshesShareOneRequest() async throws {
        let rpc = SessionSwitchRPC()
        rpc.holdModelOptions = true
        let model = makeModel(rpc)
        model.resumeSession(session("a"))
        try await waitUntil { rpc.heldModelOptions != nil }
        model.refreshSessionModelOptions()
        model.refreshSessionModelOptions()
        #expect(rpc.requests.filter { $0 == "model.options" }.count == 1)
        rpc.releaseModelOptions()
        try await waitUntil { !model.isLoadingRuntimeModelOptions }
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
