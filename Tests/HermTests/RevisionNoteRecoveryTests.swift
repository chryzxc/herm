import Foundation
import Testing

@testable import Herm

@MainActor
struct RevisionNoteRecoveryTests {
    @Test func restoresUserNotesButRequiresSourceRevalidation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.json")
        let store = RevisionNoteStore(file: file)
        let document = DiffDocument(path: "main.swift", patch: "@@ -1 +1 @@\n-old\n+new")
        let note = RevisionNote(
            documentID: document.identity, path: document.path,
            selection: DiffSelection(lines: Array(document.lines.suffix(1))), text: "Handle the empty case")
        store.register(path: document.path, identity: document.identity)
        store.notes = [note]
        store.flush()
        #expect(store.error == nil)
        let restored = RevisionNoteStore(file: file)
        #expect(restored.notes.first?.id == note.id)
        #expect(restored.notes.first?.text == note.text)
        #expect(restored.isStale(note))
        restored.register(path: document.path, identity: document.identity)
        #expect(!restored.isStale(note))
        restored.register(path: document.path, identity: "changed")
        #expect(restored.isStale(note))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func unknownRecoveryIsPreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.json")
        let original = Data(#"{"version":99,"notes":[]}"#.utf8)
        try original.write(to: file)
        let store = RevisionNoteStore(file: file)
        #expect(store.error != nil)
        store.notes = []
        store.flush()
        #expect(try Data(contentsOf: file) == original)
    }
}
