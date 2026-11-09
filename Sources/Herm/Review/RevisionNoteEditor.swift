import SwiftUI

/// Opens on highlight (or a click on an annotated line), anchored to the code, like the
/// markdown/text annotator's note popover. The code itself stays visible beside it.
struct RevisionNotePopover: View {
    @ObservedObject var state: DiffReviewState
    let close: () -> Void
    @FocusState private var isFocused: Bool
    private var isEditing: Bool { state.editingNoteID != nil }
    private var canSave: Bool { !state.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pending = state.pendingNote {
                RevisionNoteLocation(note: pending)
                if state.revisionNotes.isStale(pending) { RevisionNoteStaleLabel(explainsAnchor: true) }
            }
            TextField("What should change here?", text: $state.note, axis: .vertical)
                .textFieldStyle(.plain).dockFont(.body).foregroundStyle(Color.dockPrimaryText)
                .lineLimit(3...8).focused($isFocused).dockPadding(10)
                .dockWell(stroke: isFocused ? Color.dockAccent.opacity(0.45) : nil)
                .accessibilityLabel("Revision note")
            if let error = state.noteError {
                Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if isEditing {
                    Button {
                        state.deleteEditingNote()
                        close()
                    } label: {
                        DockIcon(.trash, size: 13, color: .dockDestructive)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.dockHover).help("Delete note").accessibilityLabel("Delete note")
                } else {
                    Text("⌘↩ to save").dockFont(.compactStatus, weight: .regular)
                        .foregroundStyle(Color.dockMetadataText)
                }
                Spacer()
                Button("Cancel", action: close).buttonStyle(.dockSecondary).keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add note") { if state.saveNote() { close() } }
                    .buttonStyle(.dockPrimary).keyboardShortcut(.return, modifiers: .command).disabled(!canSave)
            }
        }
        .dockPadding(14).frame(width: 340).dockMenuSurface()
        .onAppear { DispatchQueue.main.async { isFocused = true } }
    }
}
