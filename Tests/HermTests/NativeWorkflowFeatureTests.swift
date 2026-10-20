import AppKit
import Foundation
import Testing

@testable import Herm

@MainActor
private final class WorkflowFeatureRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}

@MainActor
struct NativeWorkflowFeatureTests {
    @Test func editingQueuePreservesDraftPayloadAndPosition() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            initialSessionID: "owner", rpcClient: WorkflowFeatureRPC())
        defer { model.shutdown() }
        model.status = .working
        model.isSending = true
        model.draft = "Original"
        model.queueDraft()
        model.draft = "Second"
        model.queueDraft()
        model.draft = "Unsent active draft"
        let id = model.queuedPrompts[0].id
        model.editQueuedPrompt(id)
        model.editingQueuedPromptText = "Edited"
        #expect(model.queuedPrompts.map(\.text) == ["Original", "Second"])
        #expect(model.draft == "Unsent active draft")
        model.finishQueuedPromptEdit(save: false)
        #expect(model.queuedPrompts[0].text == "Original")
        model.editQueuedPrompt(id)
        model.editingQueuedPromptText = "Edited"
        model.finishQueuedPromptEdit(save: true)
        #expect(model.queuedPrompts.map(\.text) == ["Edited", "Second"])
        #expect(model.queuedPrompts[0].id == id)
        #expect(model.draft == "Unsent active draft")
        model.moveQueuedPrompt(id, offset: 1)
        #expect(model.queuedPrompts.map(\.text) == ["Second", "Edited"])
    }

    @Test func editingHeadHoldsQueueAtCompletion() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            initialSessionID: "owner", rpcClient: WorkflowFeatureRPC())
        defer { model.shutdown() }
        model.status = .working
        model.isSending = true
        model.draft = "First"
        model.queueDraft()
        model.draft = "Second"
        model.queueDraft()
        model.editQueuedPrompt(model.queuedPrompts[0].id)
        model.status = .idle
        model.isSending = false
        model.drainQueuedPromptIfIdle()
        #expect(model.queuedPrompts.map(\.text) == ["First", "Second"])
        #expect(!model.isSending)
    }

    @Test func diffIdentityAndSourcePreserveWhitespaceAndUnicode() {
        let a = DiffDocument(path: "file.swift", patch: "@@ -1 +1 @@\n-\tlet value = \"old\"\n+\tlet value = \"日本語\"")
        #expect(a.lines[1].oldLine == 1)
        #expect(a.lines[2].newLine == 1)
        #expect(DiffDocument.source(a.lines[2]) == "\tlet value = \"日本語\"")
        #expect(a.identity != DiffDocument(path: "other.swift", patch: a.patch).identity)
        let selection = DiffSelection(lines: [a.lines[2]])
        let note = RevisionNote(documentID: a.identity, path: a.path, selection: selection, text: "Check input")
        #expect(note.context(currentIdentity: "changed").body.contains("Source comparison changed"))
        #expect(note.context(currentIdentity: a.identity).body.contains("日本語"))
    }

    @Test func projectActionsRejectEscapingAndMissingDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            try ProjectAction(name: "Test", command: "swift test").workingDirectory(project: root.path)
                == root.resolvingSymlinksInPath().path)
        #expect(throws: (any Error).self) {
            try ProjectAction(name: "Test", command: "test", directory: "../").workingDirectory(project: root.path)
        }
        #expect(throws: (any Error).self) {
            try ProjectAction(name: "Test", command: "test", directory: "/tmp").workingDirectory(project: root.path)
        }
        #expect(throws: (any Error).self) {
            try ProjectAction(name: "Test", command: "test", directory: "missing").workingDirectory(project: root.path)
        }
    }

    @Test func preferencesStayProjectScoped() throws {
        let suite = "HermWorkflow.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectPreferences(defaults: defaults)
        try store.save([ProjectAction(name: "Build", command: "swift build")], path: "/tmp/project-a")
        store.setModel("provider/model", path: "/tmp/project-a")
        #expect(store.actions("/tmp/project-a").count == 1)
        #expect(store.actions("/tmp/project-b").isEmpty)
        #expect(store.modelID("/tmp/project-b") == nil)
    }
}
