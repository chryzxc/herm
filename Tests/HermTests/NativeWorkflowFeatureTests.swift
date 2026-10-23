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
    @Test func editingQueuedPromptMovesItIntoComposerAndRequeuesAtTail() {
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            initialSessionID: "owner", rpcClient: WorkflowFeatureRPC())
        defer { model.shutdown() }
        model.status = .working
        model.isSending = true
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "queue-edit-\(UUID().uuidString).png")
        model.pendingImages = [ImageAttachment(image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: imageURL)]
        model.draft = "First"
        model.queueDraft()
        model.draft = "Second"
        model.queueDraft()

        model.editQueuedPrompt(model.queuedPrompts[0].id)
        #expect(model.queuedPrompts.map(\.text) == ["Second"])
        #expect(model.draft == "First")
        #expect(model.pendingImages.first?.fileURL == imageURL)

        model.draft = "First, edited"
        model.submitComposerInput()
        #expect(model.queuedPrompts.map(\.text) == ["Second", "First, edited"])
        #expect(model.queuedPrompts[1].images.first?.fileURL == imageURL)
        #expect(model.draft.isEmpty && model.pendingImages.isEmpty)
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
