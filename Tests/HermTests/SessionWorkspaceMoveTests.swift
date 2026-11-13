import Foundation
import Testing

@testable import Herm

@MainActor
private final class WorkspaceMoveRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requests: [(method: String, params: [String: Any])] = []
    var cwdSetError: Error?

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        guard method == "session.cwd.set" else { return [:] }
        if let cwdSetError { throw cwdSetError }
        return ["cwd": params["cwd"] as? String ?? "", "branch": "feature/move"]
    }

    var cwdSetRequests: [[String: Any]] { requests.filter { $0.method == "session.cwd.set" }.map(\.params) }
}

@MainActor
struct SessionWorkspaceMoveTests {
    private func model(_ rpc: WorkspaceMoveRPCClient, sessionID: String? = "live-session") -> DockModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-move-\(UUID())")
        return DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: "workspace-move-\(UUID())")!,
            initialSessionID: sessionID,
            botActivityFileURL: directory.appendingPathComponent("bots.json"), rpcClient: rpc
        )
    }

    private func worktree() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("move-worktree-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.path
    }

    @Test func movesTheLiveSessionAndAdoptsTheConfirmedWorkspace() async throws {
        let rpc = WorkspaceMoveRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        let path = try worktree()

        #expect(await model.moveSessionWorkspace(to: path))

        let params = try #require(rpc.cwdSetRequests.first)
        #expect(params["session_id"] as? String == "live-session")
        #expect(params["cwd"] as? String == path)
        #expect(model.sessionID == "live-session")
        #expect(model.sessionWorkspace?.cwd == path)
        #expect(model.sessionWorkspace?.branch == "feature/move")
        #expect(model.sessionWorkspace?.repositoryPath == path)
        #expect(model.pendingAttachmentError == nil)
    }

    @Test func runningTurnBlocksTheMoveWithoutCallingHermes() async throws {
        let rpc = WorkspaceMoveRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.isSending = true

        #expect(!model.canMoveSessionWorkspace)
        #expect(await !model.moveSessionWorkspace(to: try worktree()))
        #expect(rpc.cwdSetRequests.isEmpty)
        #expect(model.pendingAttachmentError == DockModel.sessionWorkspaceBusyMessage)
    }

    @Test func hermesBusyRefusalKeepsTheWorkspaceAndExplainsWhy() async throws {
        let rpc = WorkspaceMoveRPCClient()
        rpc.cwdSetError = NSError(
            domain: "Hermes", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "session busy", "HermesRPCCode": NSNumber(value: 4009)])
        let model = model(rpc)
        defer { model.shutdown() }

        #expect(await !model.moveSessionWorkspace(to: try worktree()))
        #expect(model.sessionWorkspace == nil)
        #expect(model.pendingAttachmentError == DockModel.sessionWorkspaceBusyMessage)
    }

    @Test func chatWithoutSessionHasNothingToMove() async throws {
        let rpc = WorkspaceMoveRPCClient()
        let model = model(rpc, sessionID: nil)
        defer { model.shutdown() }

        #expect(!model.canMoveSessionWorkspace)
        #expect(await !model.moveSessionWorkspace(to: try worktree()))
        #expect(rpc.cwdSetRequests.isEmpty)
    }
}
