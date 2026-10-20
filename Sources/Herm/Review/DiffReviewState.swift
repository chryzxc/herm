import Combine
import Foundation

/// Transient interaction state shared by compact and expanded presentations of one review.
@MainActor
final class DiffReviewState: ObservableObject {
    let viewport = DiffViewportState()
    @Published var contextPatch: String?
    @Published var contextError: String?
    @Published var loadingContext = false
    @Published var contextLines = 3
    @Published var splitOverride: Bool?
    @Published var wrapsOverride: Bool?
    @Published var findRequest = 0
    @Published var owner: HermesSession?
    @Published private(set) var pendingNote: RevisionNote?
    @Published var note = "" { didSet { noteError = nil } }
    @Published private(set) var noteError: String?
    let revisionNotes: RevisionNoteStore
    var activeSourceIdentity = ""
    private var notesSubscription: AnyCancellable?
    private var documents: [(input: String, value: DiffDocument)] = []

    func document(path: String, patch: String) -> DiffDocument {
        if let index = documents.firstIndex(where: { $0.value.path == path && $0.input == patch }) {
            let cached = documents.remove(at: index)
            documents.append(cached)
            return cached.value
        }
        let value = DiffDocument(path: path, patch: patch)
        if documents.count == 2 { documents.removeFirst() }
        documents.append((patch, value))
        return value
    }

    var notes: [RevisionNote] {
        get { revisionNotes.notes }
        set { revisionNotes.notes = newValue }
    }
    init(revisionNotes: RevisionNoteStore? = nil) {
        self.revisionNotes = revisionNotes ?? RevisionNoteStore()
        notesSubscription = self.revisionNotes.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    @Published private(set) var editingNoteID: UUID?

    func beginNote(selection: DiffSelection, documentID: String, path: String, comparison: DiffComparisonIdentity?) {
        guard selection.first != nil else {
            contextError = "Select a source line before adding a revision note."
            return
        }
        pendingNote = RevisionNote(
            documentID: documentID, path: path, selection: selection, text: "", comparison: comparison)
        note = ""
        editingNoteID = nil
    }
    func editNote(_ value: RevisionNote) {
        pendingNote = value
        editingNoteID = value.id
        note = value.text
    }
    func cancelNote() {
        pendingNote = nil
        editingNoteID = nil
        note = ""
    }
    @discardableResult func saveNote() -> Bool {
        guard var value = pendingNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard note.utf8.count <= 16 * 1024 else {
            noteError = "Keep each revision note within 16 KiB. Shorten the text before saving."
            return false
        }
        value.text = note
        if let editingNoteID {
            guard let index = notes.firstIndex(where: { $0.id == editingNoteID }) else {
                noteError = "This note was removed elsewhere. Your edited text is kept; copy it before closing."
                return false
            }
            notes[index].text = value.text
        } else {
            guard notes.count < 100 else {
                noteError = "The review tray is full. Send or remove notes before adding another."
                return false
            }
            notes.append(value)
        }
        cancelNote()
        return true
    }
}
