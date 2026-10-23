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
