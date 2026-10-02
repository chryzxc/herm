import Foundation
import Testing
@testable import Herm

@MainActor
private final class RecordingRPCClient: HermesRPCClientProtocol {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [Call] = []

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append(Call(method: method, params: params))
        return [:]
    }

    func close() {}
}

@MainActor
private final class HTTPEnvelopeRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var responses: [[String: Any]]
    private(set) var requestedPaths: [String] = []

    init(responses: [[String: Any]]) {
        self.responses = responses
    }

    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        requestedPaths.append(path)
        guard !responses.isEmpty else {
            throw NSError(domain: "HermesControlTransportTests", code: 1)
        }
        return responses.removeFirst()
    }
    func close() {}
}

private actor ConnectionAttemptCounter {
    private var value = 0

    func increment() { value += 1 }
    func currentValue() -> Int { value }
}

@MainActor
struct HermesControlTransportTests {
    @Test func concurrentConnectionRequestsShareOneAttempt() async throws {
        let gate = HermesConnectionGate()
        let counter = ConnectionAttemptCounter()

        async let first: Void = gate.perform {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
        }
        async let second: Void = gate.perform {
            await counter.increment()
        }

        _ = try await (first, second)
        let attemptCount = await counter.currentValue()

        #expect(attemptCount == 1)
    }

    @Test func routesEventsToSubscribers() {
        let router = HermesEventRouter()
        var received: [(String, String)] = []
        _ = router.subscribe { type, params in
            received.append((type, params["session_id"] as? String ?? ""))
        }

        router.route(type: "approval.request", params: ["session_id": "session-7"])

        #expect(received.count == 1)
        #expect(received.first?.0 == "approval.request")
        #expect(received.first?.1 == "session-7")
    }

    @Test func unsubscribedHandlersStopReceivingEvents() {
        let router = HermesEventRouter()
        var callCount = 0
        let subscription = router.subscribe { _, _ in callCount += 1 }

        router.unsubscribe(subscription)
        router.route(type: "message.complete", params: [:])

        #expect(callCount == 0)
    }

    @Test func sessionScopedSubscriptionIgnoresOtherSessions() {
        let router = HermesEventRouter()
        var received = 0
        _ = router.subscribe(sessionID: "session-1") { _, _ in received += 1 }

        router.route(type: "message.delta", params: ["session_id": "session-2"])
        router.route(type: "message.delta", params: ["session_id": "session-1"])

        #expect(received == 1)
    }

    @Test func webSocketRequestUsesCompatibleUpgradeCredentials() {
        let request = HermesGateway.webSocketRequest(port: 54321, token: "secret-session-token")

        #expect(request.url?.absoluteString == "ws://127.0.0.1:54321/api/ws?token=secret-session-token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-session-token")
    }

    @Test func normalizesCurrentHermesSessionRESTEnvelopesForActivityProjection() async throws {
        let client = HTTPEnvelopeRPCClient(responses: [
            ["sessions": [["id": "session-1"]], "total": 2, "limit": 1, "offset": 0],
            ["session_id": "session-1", "messages": [["id": "message-1", "role": "assistant"]], "pagination": [:]]
        ])
        let rpc = HermesControlRPC(client: client)

        let page = try await rpc.sessionPages(limit: 1, offset: 0)
        let messages = try await rpc.sessionMessages(sessionID: "session-1")

        #expect((page["data"] as? [[String: Any]])?.count == 1)
        #expect(page["has_more"] as? Bool == true)
        #expect((messages["data"] as? [[String: Any]])?.first?["id"] as? String == "message-1")
        #expect(messages["messages"] == nil)
    }

    @Test func activitySessionPageUsesHermesCompatiblePageSize() async throws {
        let client = HTTPEnvelopeRPCClient(responses: [["data": [], "has_more": false]])

        _ = try await HermesControlRPC(client: client).sessionPages()

        #expect(client.requestedPaths == ["/api/sessions?limit=100&offset=0"])
    }

    @Test func namedProjectRPCsUseHermesMethodNames() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.projectsTree()
        _ = try await rpc.projectSessions(projectID: "project-1")

        #expect(client.calls.map(\.method) == ["projects.tree", "projects.project_sessions"])
        #expect(client.calls.last?.params["project_id"] as? String == "project-1")
    }

    @Test func reloadMCPRequiresExplicitConfirmationParameter() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.reloadMCP(sessionID: "session-1")

        #expect(client.calls.last?.method == "reload.mcp")
        #expect(client.calls.last?.params["confirm"] as? Bool == true)
    }

    @Test func sessionScopedCockpitAndProcessRPCsForwardSessionIDs() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.sessionUsage(sessionID: "session-1")
        _ = try await rpc.sessionContextBreakdown(sessionID: "session-1")
        _ = try await rpc.processes(sessionID: "session-1")

        #expect(client.calls.map(\.method) == ["session.usage", "session.context_breakdown", "process.list"])
        #expect(client.calls.allSatisfy { $0.params["session_id"] as? String == "session-1" })
    }

    @Test func deletingSessionUsesSessionDeleteRPC() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.delete(sessionID: "session-1")

        #expect(client.calls.last?.method == "session.delete")
        #expect(client.calls.last?.params["session_id"] as? String == "session-1")
    }

    @Test func steeringRPCForwardsSessionAndText() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.steer(sessionID: "session-1", text: "focus on the auth module")

        #expect(client.calls.last?.method == "session.steer")
        #expect(client.calls.last?.params["session_id"] as? String == "session-1")
        #expect(client.calls.last?.params["text"] as? String == "focus on the auth module")
    }

    @Test func clarificationRPCUsesRequestIdentityAndAnswerValue() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.respondToClarification(requestID: "clarify-1", answer: "Work")

        #expect(client.calls.last?.method == "request.answer")
        #expect(client.calls.last?.params["id"] as? String == "clarify-1")
        #expect((client.calls.last?.params["result"] as? [String: Any])?["answer"] as? String == "Work")
        #expect(client.calls.last?.params["session_id"] == nil)
    }

    @Test func workflowRPCsUseHermesContracts() async throws {
        let client = RecordingRPCClient()
        let rpc = HermesControlRPC(client: client)
        _ = try await rpc.projectFacts(cwd: "/work/app")
        _ = try await rpc.verificationStatus(sessionID: "s1", cwd: "/work/app")
        _ = try await rpc.startBackgroundPrompt(sessionID: "s1", text: "Run tests")
        _ = try await rpc.undo(sessionID: "s1")
        _ = try await rpc.redirect(sessionID: "s1", text: "Focus")
        _ = try await rpc.pauseDelegation(true)
        _ = try await rpc.interruptSubagent(subagentID: "a1")

        #expect(client.calls.map(\.method) == ["project.facts", "verification.status", "prompt.background", "session.undo", "session.redirect", "delegation.pause", "subagent.interrupt"])
        #expect(client.calls.last?.params["subagent_id"] as? String == "a1")
    }

    @Test func offlineAvailableFixtureUsesTypedSessionRPC() async throws {
        let client = HermesOfflineFixtureRPCClient(scenario: .available)
        let result = try await HermesControlRPC(client: client).activeSessions()

        #expect((result["sessions"] as? [[String: Any]])?.first?["id"] as? String == HermesOfflineContractFixtures.sessionID)
        #expect(client.calls.map(\.method) == ["session.active_list"])
    }

    @Test func offlineUnavailableAndDeniedFixturesFailClosed() async {
        for scenario in [HermesOfflineContractFixtures.Scenario.unavailable, .denied] {
            let client = HermesOfflineFixtureRPCClient(scenario: scenario)
            do {
                _ = try await HermesControlRPC(client: client).activeSessions()
                #expect(Bool(false), "expected fixture failure for \(scenario)")
            } catch let error as HermesOfflineTransportError {
                #expect(error == HermesOfflineContractFixtures.error(for: scenario))
            } catch {
                #expect(Bool(false), "unexpected fixture error")
            }
        }
    }

    @Test func offlineMalformedFixtureRemainsRawShapeForTypedAdapterValidation() async throws {
        let client = HermesOfflineFixtureRPCClient(scenario: .malformed)
        let result = try await HermesControlRPC(client: client).activeSessions()

        #expect(result["sessions"] is String)
        #expect(client.calls.first?.method == "session.active_list")
    }

    @Test func offlineStaleFixturePreservesStaleMarker() async throws {
        let client = HermesOfflineFixtureRPCClient(scenario: .stale)
        let result = try await HermesControlRPC(client: client).activeSessions()

        #expect(result["stale"] as? Bool == true)
        #expect((result["sessions"] as? [[String: Any]])?.first?["state"] as? String == "stale")
    }

    @Test func offlineTransientFixtureDoesNotInventAResponse() async {
        let client = HermesOfflineFixtureRPCClient(scenario: .transient)
        do {
            _ = try await HermesControlRPC(client: client).sessionUsage(sessionID: HermesOfflineContractFixtures.sessionID)
            #expect(Bool(false), "expected transient fixture failure")
        } catch let error as HermesOfflineTransportError {
            #expect(error == .transient)
        } catch {
            #expect(Bool(false), "unexpected fixture error")
        }
    }

    @Test func viewsDoNotInvokeRawShellExec() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Herm")
        let files = FileManager.default.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasSuffix("View.swift") } ?? []

        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("shell.exec"), "raw shell.exec in \(file.lastPathComponent)")
        }
    }

    @Test func offlineSuccessAfterMutationUsesNamedRPCAndReadback() async throws {
        let client = HermesOfflineFixtureRPCClient(scenario: .successAfterMutation)
        let rpc = HermesControlRPC(client: client)

        _ = try await rpc.setSessionTitle(sessionID: HermesOfflineContractFixtures.sessionID, title: "Updated fixture title")
        let result = try await rpc.sessionTitle(sessionID: HermesOfflineContractFixtures.sessionID)

        #expect(result["title"] as? String == "Updated fixture title")
        #expect(client.calls.map(\.method) == ["session.title", "session.title"])
        #expect(client.calls.allSatisfy { $0.params["session_id"] as? String == HermesOfflineContractFixtures.sessionID })
    }
}

@MainActor
struct HermesServerRequestTests {
    @Test func clarifyServerRequestBecomesClarifyEventKeyedByRequestID() throws {
        let event = try #require(HermesGateway.event(forServerRequest: [
            "jsonrpc": "2.0", "id": "srq-abc", "method": "clarify",
            "params": ["session_id": "s1", "question": "Which env?", "choices": ["Staging"]]
        ]))
        let payload = try #require(event.params["payload"] as? [String: Any])
        #expect(event.type == "clarify.request")
        #expect(event.params["session_id"] as? String == "s1")
        #expect(payload["request_id"] as? String == "srq-abc")
        #expect(payload["question"] as? String == "Which env?")
    }

    @Test func batchClarifyKeepsFirstQuestionMultiSelectForSingleQuestionSurfaces() throws {
        let event = try #require(HermesGateway.event(forServerRequest: [
            "id": "srq-b", "method": "clarify",
            "params": ["session_id": "s1", "questions": [
                ["qid": "q1", "question": "Which envs?", "choices": ["Staging", "Prod"], "multi_select": true]
            ]]
        ]))
        let payload = try #require(event.params["payload"] as? [String: Any])
        #expect(payload["multi_select"] as? Bool == true)
    }

    @Test func approvalServerRequestKeepsItsPayloadAndUnknownMethodsAreRejected() throws {
        let event = try #require(HermesGateway.event(forServerRequest: [
            "id": "srq-1", "method": "approval",
            "params": ["session_id": "s1", "request_id": "ap-1", "command": "rm -rf build"]
        ]))
        #expect(event.type == "approval.request")
        #expect((event.params["payload"] as? [String: Any])?["command"] as? String == "rm -rf build")
        #expect(HermesGateway.event(forServerRequest: ["id": "srq-2", "method": "tour", "params": [:]]) == nil)
        #expect(HermesGateway.event(forServerRequest: ["id": 3, "method": "approval"]) == nil)
    }

    @Test func vaultSaveLoginAnswersWithIdentifierAndPasswordJSON() throws {
        let event = try #require(HermesGateway.event(forServerRequest: [
            "id": "srq-v", "method": "vault.save_login", "params": ["session_id": "s1", "origin": "https://x.dev", "site": "x.dev"]
        ]))
        #expect(event.type == "prompt.request")
        let payload = try #require(event.params["payload"] as? [String: Any])
        let prompt = try #require(ValuePrompt.from(payload: payload))
        #expect(prompt.asksForLogin)
        let answer = try #require(JSONSerialization.jsonObject(with: Data(prompt.answer(value: "pw", identifier: "me").utf8)) as? [String: String])
        #expect(answer == ["identifier": "me", "password": "pw"])
    }
}
