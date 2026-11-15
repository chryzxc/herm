import Combine
import Foundation
import Testing

@testable import Herm

@MainActor
private final class SessionActivityStatusRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.resume" {
            let stored = params["session_id"] as? String ?? ""
            return ["session_id": "runtime-\(stored)", "session_key": stored, "messages": []]
        }
        throw HermesGateway.GatewayError.malformedResponse
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        throw HermesGateway.GatewayError.malformedResponse
    }
}

@MainActor
struct SessionActivityStatusTests {
    @Test(arguments: ["tool.call", "reasoning.delta"])
    func runningSessionKeepsSidebarAndNotchStatusAfterSwitch(event: String) async throws {
        let suite = "SessionActivityStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults, rpcClient: SessionActivityStatusRPCClient())
        defer { model.delegationMonitoringTask?.cancel() }
        let first = session("a")
        let second = session("b")
        model.sessions = [first, second]
        #expect(await model.resumeSession(first, reportFailure: true))
        #expect(model.sessionID == "runtime-a")
        #expect(model.rowSessionID("runtime-a") == "a")

        // Reattachment can begin mid-turn, without replaying message.start.
        model.receiveGatewayEvent(
            event,
            params: [
                "session_id": "runtime-a",
                "payload": ["name": "terminal", "args": ["command": "pwd"], "delta": "Thinking"],
            ])
        #expect(model.status == .working)
        #expect(status(for: try #require(model.sessions.first), model: model) == .working)

        #expect(await model.resumeSession(second, reportFailure: true))
        #expect(model.navigationSessionID == "b")
        #expect(model.status == .idle)
        let background = try #require(model.sessions.first { $0.id == "a" })
        #expect(background.isWorking)
        #expect(status(for: background, model: model) == .working)
        let tasks = EdgeNotchTask.build(
            current: nil, sessions: model.sessions, currentSessionIDs: model.currentSessionIDs, isOnline: true)
        #expect(tasks.first { $0.id == "a" }?.phase == .working)
        #expect(!tasks.contains { $0.id == "b" })

        model.receiveGatewayEvent("message.complete", params: ["session_id": "runtime-a", "payload": [:]])
        let completed = try #require(model.sessions.first { $0.id == "a" })
        #expect(!completed.isWorking)
        #expect(completed.hasUnreadUpdate)
        #expect(model.navigationSessionID == "b")
        #expect(model.status == .idle)
        model.receiveGatewayEvent(event, params: ["session_id": "runtime-a", "payload": [:]])
        #expect(model.sessions.first { $0.id == "a" }?.isWorking == true)
        #expect(model.status == .idle)
        model.receiveGatewayEvent("error", params: ["session_id": "runtime-a", "payload": [:]])
        #expect(model.sessions.first { $0.id == "a" }?.isWorking == false)
        let ended = EdgeNotchTask.build(
            current: nil, sessions: model.sessions, currentSessionIDs: model.currentSessionIDs, isOnline: true)
        #expect(ended.first { $0.id == "a" }?.phase != .working)
        await model.sessionLoadTask?.value
    }

    @Test func pinnedOnlyActivity() throws {
        let suite = "SessionActivityStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults, rpcClient: SessionActivityStatusRPCClient())
        model.pinnedSessions = [session("a")]
        model.receiveGatewayEvent("message.start", params: ["session_id": "a", "payload": [:]])
        #expect(model.pinnedSessions.first?.isWorking == true)
        model.receiveGatewayEvent("message.complete", params: ["session_id": "a", "payload": [:]])
        #expect(model.pinnedSessions.first?.isWorking == false)
        #expect(model.pinnedSessions.first?.hasUnreadUpdate == true)
    }

    @Test func stoppedTailAndRepeatedEventsDoNotRepublishActivity() throws {
        let suite = "SessionActivityStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults, initialSessionID: "a", rpcClient: SessionActivityStatusRPCClient())
        model.sessions = [session("a"), session("b")]
        model.isDiscardingStoppedTurn = true
        model.receiveGatewayEvent("tool.call", params: ["session_id": "a", "payload": [:]])
        #expect(model.sessions.first?.isWorking == false)
        model.receiveGatewayEvent("tool.call", params: ["session_id": "b", "payload": [:]])
        #expect(model.sessions.last?.isWorking == true)
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        model.receiveGatewayEvent("tool.call", params: ["session_id": "b", "payload": [:]])
        #expect(publications == 0)
        withExtendedLifetime(subscription) {}
    }

    @Test func gatewayLifecycleUpdatesPinnedCopiesWithoutWaitingForAPoll() async throws {
        let suite = "SessionActivityStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults, rpcClient: SessionActivityStatusRPCClient())
        model.sessions = [session("a"), session("b")]
        model.pinnedSessions = [session("a")]
        model.storageIDsByRuntimeID["runtime-a"] = "a"
        model.receiveGatewayEvent("message.start", params: ["session_id": "runtime-a", "payload": [:]])
        #expect(model.sessions.first?.isWorking == true)
        #expect(model.pinnedSessions.first?.isWorking == true)
        model.receiveGatewayEvent("message.complete", params: ["session_id": "runtime-a", "payload": [:]])
        #expect(model.sessions.first?.isWorking == false)
        #expect(model.pinnedSessions.first?.isWorking == false)
        #expect(model.pinnedSessions.first?.hasUnreadUpdate == true)
        await model.sessionLoadTask?.value
    }

    @Test(arguments: ["/repos/Alpha", "tmp"])
    func projectSummaryKeepsAuthoritativeActivity(name: String) throws {
        let suite = "SessionActivityStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = SessionActivityStatusRPCClient()
        let model = DockModel(defaults: defaults, rpcClient: client)
        model.sessions = [
            HermesSession(
                id: "a", title: "A", preview: "", startedAt: nil, messageCount: 1,
                source: "test", isWorking: true, hasUnreadUpdate: true),
            HermesSession(
                id: "b", title: "B", preview: "", startedAt: nil, messageCount: 1,
                source: "test", hasUnreadUpdate: true),
        ]
        let control = ControlCenterModel(rpc: HermesControlRPC(client: client))
        var inputs = SessionNavSidebarSnapshot.inputs(model: model, control: control)
        inputs.projects = [
            ProjectSummary(
                id: "p1", name: name, repoCount: 1, sessionCount: 3, sessionIDs: ["a", "b", "c"],
                preview: nil, isActive: false)
        ]
        inputs.projectSessionsByProjectID = [
            "p1": [
                SessionSummary(id: "a", title: "A", state: "completed", preview: nil),
                SessionSummary(id: "b", title: "B", state: "working", preview: nil),
                SessionSummary(id: "c", title: "C", state: "working", preview: nil),
            ]
        ]
        let snapshot = SessionNavSidebarSnapshot(inputs: inputs)
        let row = try #require(snapshot.conversations.first { $0.id == "a" })
        #expect(row.isWorking)
        #expect(row.hasUnreadUpdate)
        #expect(status(for: row, model: model) == .working)
        let completed = try #require(snapshot.conversations.first { $0.id == "b" })
        #expect(!completed.isWorking && completed.hasUnreadUpdate)
        let summaryOnly = try #require(snapshot.conversations.first { $0.id == "c" })
        #expect(!summaryOnly.isWorking && !summaryOnly.hasUnreadUpdate)
    }

    private func session(_ id: String) -> HermesSession {
        HermesSession(id: id, title: id, preview: "", startedAt: nil, messageCount: 0, source: "test")
    }

    private func status(for session: HermesSession, model: DockModel) -> SidebarSessionStatus {
        SidebarSessionStatusResolver.resolve(
            session: session, summary: nil, activeSessionID: model.navigationSessionID,
            activeStatus: model.status, attention: nil, seenAt: nil, isProfileBaselined: false)
    }
}
