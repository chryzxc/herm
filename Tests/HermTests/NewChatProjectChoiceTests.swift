import Foundation
import Testing

@testable import Herm

@Suite struct NewChatProjectChoiceTests {
    private func project(_ id: String, _ name: String) -> ProjectSummary {
        ProjectSummary(
            id: id, name: name, repoCount: 1, sessionCount: 0, sessionIDs: [], preview: nil, isActive: false)
    }

    @Test func listsOnlyRenderableProjectsByFolderName() {
        let options = NewChatProjectChoice.options(
            from: [project("a", "/work/herm"), project("b", "__no_project__"), project("c", "tmp")], query: "")
        #expect(options.map(\.title) == ["herm"])
        #expect(options.first?.path == "/work/herm")
    }

    @Test func searchMatchesNameOrPath() {
        let projects = [project("a", "/work/herm"), project("b", "/code/audition")]
        #expect(NewChatProjectChoice.options(from: projects, query: " aud ").map(\.id) == ["b"])
        #expect(NewChatProjectChoice.options(from: projects, query: "/work").map(\.id) == ["a"])
        #expect(NewChatProjectChoice.options(from: projects, query: "zzz").isEmpty)
    }

    @Test func labelPromptsUntilAProjectIsChosen() {
        #expect(NewChatProjectChoice.label(forPath: nil) == "Choose project")
        #expect(NewChatProjectChoice.label(forPath: "") == "Choose project")
        #expect(NewChatProjectChoice.label(forPath: "/work/herm") == "herm")
    }

    @Test func selectionIgnoresTrailingSlash() {
        let option = NewChatProjectChoice.Option(id: "a", path: "/work/herm", title: "herm")
        #expect(NewChatProjectChoice.isSelected(option, path: "/work/herm/"))
        #expect(!NewChatProjectChoice.isSelected(option, path: nil))
    }
}

extension NewChatProjectChoiceTests {
    @Test func skipsProjectsWithoutAnAbsoluteFolder() {
        let options = NewChatProjectChoice.options(
            from: [project("a", "notes"), project("b", "/work/herm")], query: "")
        #expect(options.map(\.id) == ["b"])
    }
}

@MainActor
struct NewChatProjectSessionTests {
    private func model(_ rpc: PullRequestChatRPC, _ defaults: UserDefaults) -> DockModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DockModel(
            sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
            initialSessionID: "selected", botActivityFileURL: directory.appendingPathComponent("bots.json"),
            rpcClient: rpc)
    }

    @Test func pickedProjectSetsFolderAndGroupsTheCreatedSessionOnce() async throws {
        let suite = "NewChatProjectSessionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = PullRequestChatRPC()
        let model = model(rpc, defaults)
        defer { model.shutdown() }
        var grouped: [(String, String)] = []
        model.onPickedProjectSessionCreated = { grouped.append(($0, $1)) }
        model.newChat()
        model.chooseNewChatProject("/work/herm")
        _ = try await model.createAuthorizedSession(source: "herm")
        let create = try #require(rpc.calls.first { $0.0 == "session.create" }?.1)
        #expect(create["cwd"] as? String == "/work/herm")
        #expect(grouped.count == 1)
        #expect(grouped.first?.0 == "pr-chat")
        #expect(grouped.first?.1 == "/work/herm")
        #expect(!model.newSessionProjectWasPicked)
    }

    @Test func unpickedChatsAreNotGroupedAndPickingNeedsAFreshChat() async throws {
        let suite = "NewChatProjectSessionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = PullRequestChatRPC()
        let model = model(rpc, defaults)
        defer { model.shutdown() }
        var grouped = 0
        model.onPickedProjectSessionCreated = { _, _ in grouped += 1 }
        model.chooseNewChatProject("/work/herm")
        #expect(model.newSessionProjectPath == nil)
        model.newChat(projectPath: "/work/other")
        _ = try await model.createAuthorizedSession(source: "herm")
        #expect(grouped == 0)
    }

    @Test func pickingProjectReplacesAPendingWorktreeFolder() {
        let suite = "NewChatProjectSessionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = model(PullRequestChatRPC(), defaults)
        defer { model.shutdown() }
        model.newChat()
        model.pendingWorktreeDirectory = "/work/herm-wt"
        model.chooseNewChatProject("/work/other")
        #expect(model.pendingWorktreeDirectory == nil)
        #expect(model.newSessionProjectPath == "/work/other")
    }
}
