import SwiftUI

struct RevisionNoteEditor: View {
    @ObservedObject var state: DiffReviewState
    @FocusState private var isEditing: Bool
    var body: some View {
        DockModal(title: state.editingNoteID == nil ? "Add revision note" : "Edit revision note", width: 460) {
            if let pending = state.pendingNote {
                VStack(alignment: .leading, spacing: DockSpacing.control) {
                    RevisionNoteLocation(note: pending)
                    RevisionNoteExcerpt(note: pending)
                    if state.revisionNotes.isStale(pending) { RevisionNoteStaleLabel(explainsAnchor: true) }
                }
            }
            VStack(alignment: .leading, spacing: DockSpacing.control) {
                Text("Your note").dockFont(size: 12, weight: .semibold)
                TextField("Describe the change you want…", text: $state.note, axis: .vertical)
                    .textFieldStyle(.dockGlass).lineLimit(4...8).focused($isEditing)
                    .accessibilityLabel("Revision note")
            }
            if let error = state.noteError {
                Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
            }
        } footer: {
            Spacer()
            Button("Cancel") { state.cancelNote() }.buttonStyle(.dockSecondary)
            Button(state.editingNoteID == nil ? "Add note" : "Save note") {
                state.saveNote()
            }.buttonStyle(.dockPrimary).disabled(
                state.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .dockFont(.body).foregroundStyle(Color.dockPrimaryText)
        .onAppear { isEditing = true }
    }
}
