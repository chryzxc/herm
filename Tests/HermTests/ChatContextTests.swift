import Foundation
import Testing

@testable import Herm

@Test func attachedContextsPrecedeTheTypedPrompt() {
    let task = KanbanTaskSummary(
        id: "t1", title: "Fix login", status: "ready", detail: "Users get 500", priority: nil, assignee: nil)
    let context = ChatContext(kanbanTask: task)
    let prompt = ChatContext.prompt("Work on this task", contexts: [context])
    #expect(prompt.hasPrefix("Kanban task t1: \"Fix login\""))
    #expect(prompt.contains("Users get 500"))
    #expect(prompt.hasSuffix("\n\nWork on this task"))
    #expect(ChatContext.prompt("", contexts: [context]) == context.body)
}

@MainActor
@Test func kanbanContextOpensANewChatBeforeNavigation() async throws {
    let suite = "ChatContextTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let rpc = PullRequestChatRPC()
    let model = DockModel(
        sessionAgentStateFileURL: directory.appendingPathComponent("agents.json"), defaults: defaults,
        initialSessionID: "existing-chat", botActivityFileURL: directory.appendingPathComponent("bots.json"),
        rpcClient: rpc)
    defer { model.shutdown() }
    model.draft = "Existing draft"
    model.attachedContexts = [ChatContext(id: "previous", title: "Previous", body: "Previous context")]
    let task = KanbanTaskSummary(
        id: "t1", title: "Fix login", status: "ready", detail: "Users get 500", priority: "0", assignee: "default")
    let context = ChatContext(kanbanTask: task)
    let router = ChatContextRouter()
    router.model = model
    var opened = false
    router.onOpened = { sessionID in
        #expect(sessionID == nil)
        #expect(model.sessionStorageID == nil)
        #expect(model.attachedContexts == [context])
        #expect(model.composerFocusRequest > 0)
        opened = true
    }

    router.attach(context, to: nil)
    for _ in 0..<200 where !opened { await Task.yield() }

    #expect(opened)
    #expect(model.newSessionCreationAuthorized)
    #expect(model.draft.isEmpty)
    #expect(context.body.contains("Users get 500"))
    #expect(!rpc.calls.contains { ["session.resume", "prompt.submit"].contains($0.0) })
}
