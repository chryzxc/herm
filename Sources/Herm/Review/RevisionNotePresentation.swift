import SwiftUI

/// Shared source identity for the editor and the private review tray.
struct RevisionNoteLocation: View {
    let note: RevisionNote
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DockSpacing.control) {
            DockIcon(.file).foregroundStyle(Color.dockMetadataText)
            Text((note.path as NSString).lastPathComponent)
                .dockFont(size: 12, weight: .semibold).lineLimit(1).truncationMode(.middle)
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

struct RevisionNoteExcerpt: View {
    let note: RevisionNote
    private var lines: [DiffLine] { note.selection.lines.filter { $0.kind != .hunk } }
    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: DockSpacing.group) {
                    Text(lines.map { String($0.newLine ?? $0.oldLine ?? 0) }.joined(separator: "\n"))
                        .foregroundStyle(Color.dockMetadataText).textSelection(.disabled)
                        .frame(minWidth: 20, alignment: .trailing)
                    Text(note.selection.excerpt).foregroundStyle(Color.dockPrimaryText).textSelection(.enabled)
                }
                .dockFont(size: 12, design: .monospaced).fontDesign(.monospaced).lineSpacing(3)
                .padding(DockSpacing.group).frame(minWidth: geometry.size.width, alignment: .leading)
            }
        }
        .frame(height: min(132, max(44, CGFloat(lines.count) * 18 + 24)))
        .dockPaneTint(Color.dockSurface)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
        .accessibilityLabel("Captured source")
    }
}

struct RevisionNotesTray: View {
    @ObservedObject var state: DiffReviewState
    let canSend: Bool
    let send: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    title
                    Spacer(minLength: DockSpacing.group)
                    sendButton
                }
                VStack(alignment: .leading, spacing: DockSpacing.control) {
                    title
                    sendButton
                }
            }.padding(DockSpacing.group)
            if let error = state.revisionNotes.error {
                Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
                    .padding(.horizontal, DockSpacing.group).padding(.bottom, DockSpacing.control)
            }
            ForEach(state.notes) { note in
                VStack(alignment: .leading, spacing: DockSpacing.control) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            RevisionNoteLocation(note: note)
                            Spacer()
                            actions(note)
                        }
                        VStack(alignment: .leading, spacing: DockSpacing.control) {
                            RevisionNoteLocation(note: note)
                            actions(note)
                        }
                    }
                    Text(note.text).dockFont(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 760, alignment: .leading)
                    if state.revisionNotes.isStale(note) { RevisionNoteStaleLabel() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DockSpacing.group)
                .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
            }
            Text(
                canSend
                    ? "Adds notes to your conversation draft." : "Open this review from a conversation to send notes."
            )
            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
            .padding(.horizontal, DockSpacing.group).padding(.bottom, DockSpacing.group)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }
    private var title: some View {
        HStack(spacing: DockSpacing.control) {
            Text("Private revision notes").dockFont(size: 12, weight: .semibold)
            Text("\(state.notes.count)").dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
        }
    }
    private var sendButton: some View {
        Button("Send revision", action: send).buttonStyle(.dockPrimary).disabled(!canSend || state.notes.isEmpty)
    }
    private func actions(_ note: RevisionNote) -> some View {
        HStack(spacing: DockSpacing.tight) {
            Button("Edit") { state.editNote(note) }.buttonStyle(.dockCompact)
            Button("Remove") { state.notes.removeAll { $0.id == note.id } }.buttonStyle(.dockCompact)
        }.fixedSize()
    }
}
