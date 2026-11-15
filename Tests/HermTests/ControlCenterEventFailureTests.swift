import Foundation
import Testing

@testable import Herm

@MainActor
private final class FailingProjectsRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var projectReads = 0

    func connect() async throws {}
    func close() {}
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "projects.tree" { return ["projects": [["id": "p", "name": "Project"]]] }
        if method == "projects.project_sessions" {
            projectReads += 1
            throw URLError(.notConnectedToInternet)
        }
        if method == "session.active_list" { return ["sessions": [[String: Any]]()] }
        return [:]
    }
}

@MainActor
struct ControlCenterEventFailureTests {
    @Test func persistentProjectReadFailureDoesNotRetryWithoutNewEvents() async throws {
        let client = FailingProjectsRPCClient()
        let model = ControlCenterModel(rpc: HermesControlRPC(client: client), capabilities: [])
        let dock = DockModel(rpcClient: client)
        model.dockModel = dock
        model.projectProfileScopeUnavailable = false
        model.projectProfileID = "profile"
        model.projects = ControlCenterModel.parseProjects(["projects": [["id": "p", "name": "Project"]]])
        model.ingestEvent("message.complete", params: ["session_id": "a"])
        try await Task.sleep(for: .seconds(2))
        #expect(model.eventRefreshTask == nil)
        #expect(model.pendingEventRefreshes.isEmpty)
        #expect(model.refreshState(for: "projects")?.error != nil)
        #expect(client.projectReads == 1)
        model.eventRefreshTask?.cancel()
        model.refreshTask?.cancel()
    }
}
