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
        guard method == "session.cwd.set" || method == "session.workspace.move" else { return [:] }
        if let cwdSetError { throw cwdSetError }
        return ["cwd": params["cwd"] as? String ?? "", "branch": "feature/move"]
    }

    var moveRequests: [[String: Any]] { requests.filter { $0.method == "session.workspace.move" }.map(\.params) }
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

    @Test func storedConversationMovesToTheProjectFolderByKey() async throws {
        let rpc = WorkspaceMoveRPCClient()
        let model = model(rpc, sessionID: nil)
        defer { model.shutdown() }
        let path = try worktree()
        let session = HermesSession(
            id: "stored-1", profileID: "work", title: "Old chat", preview: "", startedAt: nil, updatedAt: nil,
            messageCount: 3, source: "tui", isHidden: false, isWorking: false, hasUnreadUpdate: false)

        #expect(await model.moveSessionToProject(session, path: path))

        let params = try #require(rpc.moveRequests.first)
        #expect(params["session_key"] as? String == "stored-1")
        #expect(params["cwd"] as? String == path)
        #expect(params["profile"] as? String == "work")
        #expect(rpc.cwdSetRequests.isEmpty)
    }

    @Test func workingConversationIsNotMoved() async throws {
        let rpc = WorkspaceMoveRPCClient()
        let model = model(rpc, sessionID: nil)
        defer { model.shutdown() }
        let session = HermesSession(
            id: "busy", profileID: nil, title: "Busy", preview: "", startedAt: nil, updatedAt: nil,
            messageCount: 1, source: "tui", isHidden: false, isWorking: true, hasUnreadUpdate: false)

        #expect(await !model.moveSessionToProject(session, path: try worktree()))
        #expect(rpc.moveRequests.isEmpty)
        #expect(model.pendingAttachmentError == DockModel.sessionWorkspaceBusyMessage)
    }

    @Test func openChatWaitingOnApprovalIsNotMoved() async throws {
        let rpc = WorkspaceMoveRPCClient()
        let model = model(rpc)
        defer { model.shutdown() }
        model.status = .needsApproval
        let session = HermesSession(
            id: "live-session", profileID: nil, title: "S", preview: "", startedAt: nil, updatedAt: nil,
            messageCount: 1, source: "tui", isHidden: false, isWorking: false, hasUnreadUpdate: false)

        #expect(!model.canMoveSessionWorkspace)
        #expect(await !model.moveSessionToProject(session, path: try worktree()))
        #expect(rpc.moveRequests.isEmpty)
        #expect(model.pendingAttachmentError == DockModel.sessionWorkspaceBusyMessage)
    }

    @Test func performLinksLocallyAndMovesTheProjectListsIncludingTheRuntimeAlias() async throws {
        let rpc = WorkspaceMoveRPCClient()
        let model = model(rpc, sessionID: "runtime-1")
        defer { model.shutdown() }
        model.sessionStorageID = "stored-1"
        let path = try worktree()
        let control = ControlCenterModel(rpc: nil)
        func summary(_ id: String, _ name: String, _ ids: Set<String>) -> ProjectSummary {
            ProjectSummary(
                id: id, name: name, repoCount: 1, sessionCount: ids.count, sessionIDs: ids, preview: nil,
                isActive: false)
        }
        control.projects = [summary("A", "/repos/A", ["stored-1", "runtime-1"]), summary("B", path, [])]
        let store = WorkspaceStore(fileURL: URL(fileURLWithPath: "/tmp/\(UUID()).json"))
        let session = HermesSession(
            id: "stored-1", profileID: nil, title: "Chat", preview: "", startedAt: nil, updatedAt: nil,
            messageCount: 2, source: "tui", isHidden: false, isWorking: false, hasUnreadUpdate: false)

        let moved = await SessionProjectMove.perform(
            session, to: SidebarProjectTarget(title: "B", path: path), model: model, control: control, store: store)

        #expect(moved)
        #expect(store.projectPathsBySessionID["stored-1"] == path)
        #expect(control.project(forSessionID: "stored-1")?.id == "B")
        #expect(control.project(forSessionID: "runtime-1")?.id == "B")
        #expect(control.projects.first { $0.id == "A" }?.sessionIDs.isEmpty == true)
        #expect(SessionProjectMove.currentProjectID("stored-1", control: control, store: store) == "B")
    }

    @Test func concurrentMoveIsRejected() async throws {
        let rpc = WorkspaceMoveRPCClient()
        let model = model(rpc, sessionID: nil)
        defer { model.shutdown() }
        model.movingSessionToProjectID = "other"
        let session = HermesSession(
            id: "s", profileID: nil, title: "S", preview: "", startedAt: nil, updatedAt: nil,
            messageCount: 1, source: "tui", isHidden: false, isWorking: false, hasUnreadUpdate: false)

        #expect(await !model.moveSessionToProject(session, path: try worktree()))
        #expect(rpc.moveRequests.isEmpty)
    }

    @Test func failedProjectMoveReportsAndReturnsFalse() async throws {
        let rpc = WorkspaceMoveRPCClient()
        rpc.cwdSetError = NSError(domain: "Hermes", code: 1, userInfo: [NSLocalizedDescriptionKey: "move failed"])
        let model = model(rpc, sessionID: nil)
        defer { model.shutdown() }
        let session = HermesSession(
            id: "stored-2", profileID: nil, title: "Chat", preview: "", startedAt: nil, updatedAt: nil,
            messageCount: 0, source: "tui", isHidden: false, isWorking: false, hasUnreadUpdate: false)

        #expect(await !model.moveSessionToProject(session, path: try worktree()))
        #expect(model.pendingAttachmentError != nil)
    }
}
