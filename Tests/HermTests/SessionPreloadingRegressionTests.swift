import Foundation
import Testing

@testable import Herm

@MainActor
private final class PreloadingRegressionRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var fetchedPaths: [String] = []
    var failScan = false
    var holdTranscript = false
    var pendingTranscript: CheckedContinuation<Void, Never>?

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "session.resume" else { return [:] }
        let id = params["session_id"] as? String ?? ""
        return [
            "session_id": "runtime-\(id)", "session_key": id,
            "messages": [["role": "assistant", "text": "stored \(id)", "row_id": 1]],
        ]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        fetchedPaths.append(path)
        if path.hasPrefix("/api/profiles/sessions/sidebar") {
            if failScan { throw HermesGateway.GatewayError.malformedResponse }
            return [
                "recents": [
                    "sessions": [
                        ["id": "shared", "profile": "two", "title": "Other", "pinned": true],
                        ["id": "unknown", "title": "Unknown", "pinned": true],
                    ]
                ]
            ]
        }
        if path.hasPrefix("/api/sessions/") {
            if holdTranscript {
                holdTranscript = false
                await withCheckedContinuation { pendingTranscript = $0 }
            }
            return ["messages": [["id": 1, "role": "assistant", "content": "stored tail"]]]
        }
        throw HermesGateway.GatewayError.malformedResponse
    }
}

@MainActor
struct SessionPreloadingRegressionTests {
    @Test func sidebarSwitchCachesTheTailBeforeMarkingItLoading() async throws {
        let suite = "SessionPreloadingRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"), defaults: defaults,
            botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: PreloadingRegressionRPC())
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        func session(_ id: String) -> HermesSession {
            HermesSession(
                id: id, profileID: "one", title: id, preview: "", startedAt: nil,
                messageCount: 1, source: "test")
        }
        #expect(await model.resumeSession(session("a"), reportFailure: true))
        model.messages.append(ChatMessage(role: .hermes, text: "completed while viewing"))
        model.resumeSession(session("b"))
        _ = await model.sessionResumeTask?.value
        let key = WorkspaceIdentity.session(profileID: "one", sessionID: "a")
        #expect(model.sessionTranscriptCache.value(for: key)?.messages.last?.text == "completed while viewing")
    }

    @Test func loadedPinsRemainVisibleDuringAnIndexRefresh() {
        let pin = HermesSession(
            id: "pin", profileID: "one", title: "Pinned", preview: "", startedAt: nil,
            messageCount: 1, source: "test", isPinned: true)
        let presentation = PinnedSessionPresentation(pinned: [pin], live: [], projection: .loading)
        #expect(presentation.sessions.map(\.scopedID) == [pin.scopedID])
    }

    @Test func backgroundScanPreloadsPinsAcrossProfiles() async throws {
        let suite = "SessionPreloadingRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let client = PreloadingRegressionRPC()
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        model.profileScopeID = "one"
        model.pinnedSessions = [
            HermesSession(
                id: "shared", profileID: "one", title: "Pin", preview: "", startedAt: nil,
                messageCount: 1, source: "test", isPinned: true)
        ]
        model.loadAllBotSessions(force: true)
        await model.allBotSessionsTask?.value
        await model.sessionTranscriptPreloadTask?.value
        for profile in ["one", "two"] {
            let key = WorkspaceIdentity.session(profileID: profile, sessionID: "shared")
            #expect(model.sessionTranscriptCache.value(for: key)?.messages.last?.text == "stored tail")
            #expect(client.fetchedPaths.contains { $0.contains("profile=\(profile)") })
        }
        #expect(!client.fetchedPaths.contains { $0.contains("/unknown/") })
    }

    @Test func scanFailureStillPreloadsCurrentPins() async throws {
        let suite = "SessionPreloadingRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let client = PreloadingRegressionRPC()
        client.failScan = true
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        model.profileScopeID = "one"
        model.pinnedSessions = [
            HermesSession(
                id: "pin", profileID: nil, title: "Pin", preview: "", startedAt: nil,
                messageCount: 1, source: "test", isPinned: true)
        ]
        model.loadAllBotSessions(force: true)
        await model.allBotSessionsTask?.value
        await model.sessionTranscriptPreloadTask?.value
        let key = WorkspaceIdentity.session(profileID: "one", sessionID: "pin")
        #expect(model.sessionTranscriptCache.value(for: key)?.messages.last?.text == "stored tail")
    }

    @Test func forcedScanDoesNotWaitForTranscriptRead() async throws {
        let suite = "SessionPreloadingRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let client = PreloadingRegressionRPC()
        client.holdTranscript = true
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        model.loadAllBotSessions(force: true)
        await model.allBotSessionsTask?.value
        for _ in 0..<100 where client.pendingTranscript == nil { await Task.yield() }
        #expect(client.pendingTranscript != nil)
        model.loadAllBotSessions(force: true)
        await model.allBotSessionsTask?.value
        #expect(client.fetchedPaths.filter { $0.hasPrefix("/api/profiles/sessions/sidebar") }.count == 2)
        client.holdTranscript = false
        client.pendingTranscript?.resume()
        client.pendingTranscript = nil
        await model.sessionTranscriptPreloadTask?.value
    }

    @Test func switchingCachesBufferedStreamingText() async throws {
        let suite = "SessionPreloadingRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = DockModel(defaults: defaults, rpcClient: PreloadingRegressionRPC())
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        func session(_ id: String) -> HermesSession {
            HermesSession(
                id: id, profileID: "one", title: id, preview: "", startedAt: nil,
                messageCount: 1, source: "test")
        }
        #expect(await model.resumeSession(session("a"), reportFailure: true))
        let message = ChatMessage(role: .hermes, text: "")
        model.messages.append(message)
        model.streamingMessageID = message.id
        model.streamingMessageSessionID = model.sessionID
        model.streamingMessageBuffer = "buffered response"
        model.resumeSession(session("b"))
        #expect(!model.sessionActionsReady)
        let key = WorkspaceIdentity.session(profileID: "one", sessionID: "a")
        #expect(model.sessionTranscriptCache.value(for: key)?.messages.last?.text == "buffered response")
        _ = await model.sessionResumeTask?.value
        #expect(model.sessionTranscriptCache.value(for: key)?.messages.last?.text == "buffered response")
    }

    @Test func routineRefreshDoesNotCancelRemotePreload() async throws {
        let suite = "SessionPreloadingRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let client = PreloadingRegressionRPC()
        client.holdTranscript = true
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        model.loadAllBotSessions(force: true)
        await model.allBotSessionsTask?.value
        for _ in 0..<100 where client.pendingTranscript == nil { await Task.yield() }
        #expect(client.pendingTranscript != nil)
        let task = model.sessionTranscriptPreloadTask
        model.loadAllBotSessions()
        client.pendingTranscript?.resume()
        client.pendingTranscript = nil
        await task?.value
        let key = WorkspaceIdentity.session(profileID: "two", sessionID: "shared")
        #expect(model.sessionTranscriptCache.value(for: key)?.messages.last?.text == "stored tail")
    }
}
