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
}
