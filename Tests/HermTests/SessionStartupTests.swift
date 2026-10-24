import Foundation
import Testing

@testable import Herm

@MainActor
private final class SessionStartupRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rows: [[String: Any]] = [
        ["id": "latest", "title": "Latest", "last_activity_at": 200],
        ["id": "older", "title": "Older", "last_activity_at": 100, "pinned": true],
    ]
    var holdsList = false
    private(set) var listLimits: [Int] = []
    private var listStarted: CheckedContinuation<Void, Never>?
    private var listResponse: CheckedContinuation<Void, Never>?
    private var connectionCount = 0
    private var connectionWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func connect() async throws {
        connectionCount += 1
        if let waiter = connectionWaiter, connectionCount >= waiter.count {
            connectionWaiter = nil
            waiter.continuation.resume()
        }
    }
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "session.list":
            let limit = params["limit"] as? Int ?? 50
            listLimits.append(limit)
            let snapshot = Array(rows.prefix(limit))
            if holdsList, listLimits.count == 1 {
                await withCheckedContinuation { continuation in
                    listResponse = continuation
                    listStarted?.resume()
                    listStarted = nil
                }
            }
            return ["sessions": snapshot]
        case "session.resume":
            return ["session_id": params["session_id"] as? String ?? "", "messages": []]
        case "session.active_list":
            return ["sessions": []]
        default:
            throw HermesGateway.GatewayError.malformedResponse
        }
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        guard path.hasPrefix("/api/sessions?") else { throw HermesGateway.GatewayError.malformedResponse }
        return ["sessions": rows]
    }

    func waitForList() async {
        if listResponse != nil { return }
        await withCheckedContinuation { listStarted = $0 }
    }

    func releaseList() {
        holdsList = false
        listResponse?.resume()
        listResponse = nil
    }

    func waitForConnections(_ count: Int) async {
        if connectionCount >= count { return }
        await withCheckedContinuation { connectionWaiter = (count, $0) }
    }
}

@MainActor
struct SessionStartupTests {
    private func withModel(
        _ body: (DockModel, SessionStartupRPCClient) async throws -> Void
    ) async throws {
        let suite = "SessionStartupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = SessionStartupRPCClient()
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer { model.delegationMonitoringTask?.cancel() }
        try await body(model, client)
    }

    @Test func restoringAfterTheListLoadsKeepsEveryConversation() async throws {
        try await withModel { model, _ in
            await model.loadSessions()?.value
            let loadedIDs = model.sessions.map(\.id)

            await model.restoreLatestSessionIfNeeded()?.value

            #expect(model.sessions.map(\.id) == loadedIDs)
            #expect(model.sessionProjectionState == .ready(model.sessions))
            #expect(model.sessionID == "latest")
            #expect(model.pinnedSessions.map(\.id) == ["older"])
        }
    }

    @Test func restorationWithoutAMountedSidebarLoadsTheCompleteList() async throws {
        try await withModel { model, client in
            await model.restoreLatestSessionIfNeeded()?.value

            #expect(model.sessions.map(\.id) == ["latest", "older"])
            #expect(model.sessionProjectionState == .ready(model.sessions))
            #expect(model.sessionID == "latest")
            #expect(client.listLimits == [50])
        }
    }

    @Test func overlappingForegroundReadsShareTheirCompletion() async throws {
        try await withModel { model, client in
            client.holdsList = true
            let initial = model.loadSessions()
            await client.waitForList()
            let overlapping = model.loadSessions()
            #expect(overlapping != nil)
            #expect(model.isLoadingSessions)
            client.releaseList()
            await initial?.value
            await overlapping?.value

            #expect(client.listLimits == [50])
            #expect(model.sessions.map(\.id) == ["latest", "older"])
            #expect(!model.isLoadingSessions)
            #expect(!model.isPollingSessions)
        }
    }

    @Test(arguments: [false, true])
    func restorationWaitsForTheInFlightList(quietFirst: Bool) async throws {
        try await withModel { model, client in
            client.holdsList = true
            let initial = model.loadSessions(quiet: quietFirst)
            await client.waitForList()
            let restoration = model.restoreLatestSessionIfNeeded()
            await client.waitForConnections(2)
            #expect(client.listLimits == [50])
            client.releaseList()
            await initial?.value
            await restoration?.value

            #expect(client.listLimits == [50])
            #expect(model.sessions.map(\.id) == ["latest", "older"])
            #expect(model.sessionID == "latest")
            #expect(model.sessionProjectionState == .ready(model.sessions))
        }
    }

    @Test func explicitRefreshSupersedesAnOlderBackgroundSnapshot() async throws {
        try await withModel { model, client in
            client.holdsList = true
            let poll = model.loadSessions(quiet: true)
            await client.waitForList()
            client.rows = [["id": "after-mutation", "title": "Updated"]]
            await model.loadSessions()?.value

            #expect(client.listLimits == [50, 50])
            #expect(model.sessions.map(\.id) == ["after-mutation"])
            client.releaseList()
            await poll?.value

            #expect(model.sessions.map(\.id) == ["after-mutation"])
            #expect(!model.isLoadingSessions)
            #expect(!model.isPollingSessions)
        }
    }
}
