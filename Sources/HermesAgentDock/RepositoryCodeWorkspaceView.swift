import AppKit
import SwiftUI

/// Single-file editor used by Project Files and Changed Files. Git blame is
/// loaded for the saved working-tree contents and rendered in the editor's
/// synchronized vertical ruler.
struct RepositoryCodeWorkspaceView: View {
    let repositoryPath: String
    let document: RepositoryFileDocument
    let onClose: () -> Void
    let onSave: (String) async -> Bool

    @State private var draft: String
    @State private var savedDraft: String
    @State private var blameState: BlameState = .loading
    @State private var hoveredBlameLine: RepositoryBlameLine?
    @State private var blameGeneration = UUID()
    @State private var isSaving = false
    @State private var saveError: String?

    private enum BlameState {
        case loading
        case loaded(RepositoryBlameDocument)
        case unavailable(String)
    }

    init(repositoryPath: String, document: RepositoryFileDocument, onClose: @escaping () -> Void, onSave: @escaping (String) async -> Bool) {
        self.repositoryPath = repositoryPath
        self.document = document
        self.onClose = onClose
        self.onSave = onSave
        _draft = State(initialValue: document.contents)
        _savedDraft = State(initialValue: document.contents)
    }

    private var hasUnsavedChanges: Bool { draft != savedDraft }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.scifiBorderLight)
            editor
            if let saveError {
                Text(saveError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.scifiWarning.opacity(0.08))
            }
        }
        .background(Color.scifiCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.scifiBorderStrong, lineWidth: 0.5))
        // Keep a finite viewport so the embedded AppKit scroll view owns
        // scrolling for long files instead of expanding with the inspector's
        // outer ScrollView.
        .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 620)
        .task(id: document.id) { await loadBlame() }
        .onChange(of: document.contents) { _, contents in
            draft = contents
            savedDraft = contents
        }
        .onDisappear { blameGeneration = UUID() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.scifiPress)
            .foregroundStyle(Color.scifiMuted)
            .frame(width: 32, height: 32)
            .help("Back to files")

            Image(systemName: "doc.text")
                .foregroundStyle(Color.scifiAccent)
            VStack(alignment: .leading, spacing: 0) {
                Text(document.path)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hasUnsavedChanges {
                Circle()
                    .fill(Color.scifiWarning)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
            Button(action: save) {
                Image(systemName: isSaving ? "ellipsis" : "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.scifiPress)
            .foregroundStyle(hasUnsavedChanges ? Color.scifiAccent : Color.scifiTertiary)
            .disabled(!hasUnsavedChanges || isSaving)
            .help(isSaving ? "Saving…" : "Save")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            InlineBlameEditor(
                text: $draft,
                filePath: document.path,
                blame: blameDocument,
                unavailableReason: blameUnavailableReason,
                onSelectBlame: { _ in },
                onHoverBlame: { hoveredBlameLine = $0 }
            )
            .frame(minHeight: 360, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if let hoveredBlameLine {
                    blameDetail(hoveredBlameLine)
                        .padding(12)
                        .transition(.opacity)
                        .zIndex(10)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var blameDocument: RepositoryBlameDocument? {
        if case .loaded(let document) = blameState { return document }
        return nil
    }

    private var blameUnavailableReason: String? {
        if case .unavailable(let reason) = blameState { return reason }
        return nil
    }

    private var isBlameLoading: Bool {
        if case .loading = blameState { return true }
        return false
    }

    private func loadBlame() async {
        let generation = UUID()
        blameGeneration = generation
        blameState = .loading
        let result = await RepositoryService.blame(path: repositoryPath, filePath: document.path)
        guard generation == blameGeneration else { return }
        switch result {
        case .available(let document): blameState = .loaded(document)
        case .unavailable(let reason): blameState = .unavailable(reason)
        }
    }

    private func save() {
        isSaving = true
        saveError = nil
        Task {
            let succeeded = await onSave(draft)
            await MainActor.run {
                isSaving = false
                if succeeded {
                    savedDraft = draft
                } else {
                    saveError = "Could not save this file. It may no longer be a regular UTF-8 file."
                }
            }
            if succeeded { await loadBlame() }
        }
    }

    private func blameDetail(_ line: RepositoryBlameLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("LINE \(line.lineNumber)", systemImage: "number")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
            Text(line.commit.author)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.scifiFg)
            if let authoredAt = line.commit.authoredAt {
                Text(authoredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
            }
            Text(line.commit.isUncommitted ? "NOT COMMITTED YET" : line.commit.hash)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(line.commit.isUncommitted ? Color.scifiWarning : Color.scifiTertiary)
                .textSelection(.enabled)
            Text(line.commit.summary)
                .font(.system(size: 12))
                .foregroundStyle(Color.scifiFg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.scifiCanvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.scifiBorderStrong, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 5)
        .environment(\.colorScheme, .dark)
    }

}
