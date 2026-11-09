import SwiftUI

/// Shared source identity for the note popover and the notes list.
struct RevisionNoteLocation: View {
    let note: RevisionNote
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DockSpacing.control) {
            DockIcon(.file).foregroundStyle(Color.dockMetadataText)
            Text((note.path as NSString).lastPathComponent)
                .dockFont(.body, weight: .semibold).lineLimit(1).truncationMode(.middle)
            Text(
                "\(note.selection.anchor.first)"
                    + (note.selection.anchor.last == note.selection.anchor.first
                        ? "" : "–\(note.selection.anchor.last)") + " · \(note.selection.anchor.side)"
            )
            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
        }
        .help(note.locationLabel).accessibilityElement(children: .ignore).accessibilityLabel(note.locationLabel)
    }
}

struct RevisionNoteStaleLabel: View {
    var explainsAnchor = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DockSpacing.tight) {
            DockIcon(.warning).foregroundStyle(Color.dockWarning)
            Text(explainsAnchor ? "Source changed. This note keeps its captured lines." : "Source changed")
                .foregroundStyle(Color.dockSecondaryText)
        }.dockFont(.metadata).fixedSize(horizontal: false, vertical: true)
    }
}

/// Toolbar entry for private revision notes: an icon with a count badge, shown only once a
/// note exists. The list popover sends every note to chat as one attachment.
struct RevisionNotesButton: View {
    @ObservedObject var store: RevisionNoteStore
    let canSend: Bool
    let send: () -> Void
    @State private var showingList = false
    private var label: String { store.notes.count == 1 ? "1 revision note" : "\(store.notes.count) revision notes" }
    var body: some View {
        if !store.notes.isEmpty || store.error != nil {
            Button {
                showingList.toggle()
            } label: {
                PullRequestReviewToolbarIcon(name: .notePencil, accessibilityLabel: label, isSelected: showingList)
                    .overlay(alignment: .topTrailing) {
                        if !store.notes.isEmpty {
                            Text("\(store.notes.count)")
                                .dockFont(.compactStatus, weight: .semibold).monospacedDigit()
                                .foregroundStyle(Color.dockOnAccentText)
                                .frame(minWidth: 7).dockPill(tint: Color.dockAccent, solid: true, compact: true)
                                .offset(x: 5, y: -4).allowsHitTesting(false)
                        }
                    }
            }
            .buttonStyle(.dockHover).fixedSize()
            .dockPopover(isPresented: $showingList, arrowEdge: .bottom) {
                RevisionNoteList(store: store, canSend: canSend) {
                    send()
                    showingList = false
                }
            }
        }
    }
}

struct RevisionNoteList: View {
    @ObservedObject var store: RevisionNoteStore
    let canSend: Bool
    let send: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DockSpacing.control) {
                Text("Revision notes").dockFont(.body, weight: .semibold)
                Spacer(minLength: DockSpacing.group)
                Button("Send to chat", action: send).buttonStyle(.dockPrimary)
                    .disabled(!canSend || store.notes.isEmpty)
                    .help(
                        canSend ? "Attach these notes to your chat draft" : "Open this review from a chat to send notes"
                    )
            }.dockPadding(DockSpacing.group)
            if let error = store.error {
                Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .dockPadding(.horizontal, DockSpacing.group).dockPadding(.bottom, DockSpacing.control)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.notes) { note in row(note) }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360).fixedSize(horizontal: false, vertical: true)
            Text("Click highlighted lines in the diff to edit a note.")
                .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                .dockPadding(DockSpacing.group)
                .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        }
        .frame(width: 360).foregroundStyle(Color.dockPrimaryText).dockMenuSurface()
    }
    private func row(_ note: RevisionNote) -> some View {
        VStack(alignment: .leading, spacing: DockSpacing.tight) {
            HStack(spacing: DockSpacing.control) {
                RevisionNoteLocation(note: note)
                Spacer(minLength: 0)
                Button {
                    store.notes.removeAll { $0.id == note.id }
                } label: {
                    DockIcon(.trash, size: 13, color: .dockSecondaryText)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.dockHover).help("Remove note").accessibilityLabel("Remove note on \(note.locationLabel)")
            }
            Text(note.text).dockFont(.body).lineLimit(4).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if store.isStale(note) { RevisionNoteStaleLabel() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dockPadding(.horizontal, DockSpacing.group).dockPadding(.vertical, DockSpacing.control)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }
}

/// Scopes a review's note button to a page header that already shows it, so file diffs omit theirs.
private struct RevisionNotesInHeaderKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var revisionNotesInHeader: Bool {
        get { self[RevisionNotesInHeaderKey.self] }
        set { self[RevisionNotesInHeaderKey.self] = newValue }
    }
}
