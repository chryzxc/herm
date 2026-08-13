import SwiftUI

/// Focused code review and small-edit surface that stays inside the Dock
/// popover. It intentionally provides one file at a time rather than becoming
/// a second IDE.
struct RepositoryCodeWorkspaceView: View {
    let document: RepositoryFileDocument
    let diff: RepositoryDiff?
    let isLoadingDiff: Bool
    let onClose: () -> Void
    let onReloadDiff: () -> Void
    let onSave: (String) async -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: String
    @State private var savedDraft: String
    @State private var mode: Mode = .diff
    @State private var isSaving = false
    @State private var saveError: String?

    private enum Mode: String, CaseIterable, Identifiable {
        case diff = "Diff"
        case edit = "Edit"
        var id: Self { self }
    }

    init(document: RepositoryFileDocument, diff: RepositoryDiff?, isLoadingDiff: Bool, onClose: @escaping () -> Void, onReloadDiff: @escaping () -> Void, onSave: @escaping (String) async -> Bool) {
        self.document = document
        self.diff = diff
        self.isLoadingDiff = isLoadingDiff
        self.onClose = onClose
        self.onReloadDiff = onReloadDiff
        self.onSave = onSave
        _draft = State(initialValue: document.contents)
        _savedDraft = State(initialValue: document.contents)
    }

    private var hasUnsavedChanges: Bool { draft != savedDraft }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.scifiBorderLight)
            modePicker
            Divider().overlay(Color.scifiBorderLight)
            Group {
                switch mode {
                case .diff: diffContent
                case .edit: editorContent
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color.scifiCanvas)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.scifiBorderStrong, lineWidth: 0.5))
        .animation(reduceMotion ? nil : .scifiEase(duration: 0.18), value: mode)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.scifiPress)
            .foregroundStyle(Color.scifiMuted)
            .help("Back to changed files")

            Image(systemName: "doc.text")
                .foregroundStyle(Color.scifiAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.path)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("INLINE WORKSPACE · \(document.byteCount.formatted()) BYTES")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            }
            Spacer(minLength: 0)
            if hasUnsavedChanges {
                Text("UNSAVED")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { candidate in
                Button {
                    withAnimation(reduceMotion ? nil : .scifiEase(duration: 0.16)) { mode = candidate }
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mode == candidate ? Color.scifiFg : Color.scifiMuted)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .overlay(alignment: .bottom) {
                            if mode == candidate { Color.scifiAccent.frame(height: 2) }
                        }
                }
                .buttonStyle(.scifiPress)
            }
            Spacer()
            if mode == .diff {
                Button(isLoadingDiff ? "Loading…" : "Reload") { onReloadDiff() }
                    .buttonStyle(.scifiPress)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.scifiAccent)
                    .disabled(isLoadingDiff)
            } else {
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.scifiPress)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasUnsavedChanges ? Color.scifiAccent : Color.scifiTertiary)
                    .disabled(!hasUnsavedChanges || isSaving)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
    }

    @ViewBuilder
    private var diffContent: some View {
        if isLoadingDiff {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    if diff.isTruncated {
                        Text("DIFF TRUNCATED FOR SAFE POPOVER DISPLAY")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.scifiWarning)
                            .padding(10)
                    }
                    ForEach(Array(diff.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { index, line in
                        diffLine(String(line), number: index + 1)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.scifiTertiary)
                Text("No textual diff is available for this file.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.scifiMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func diffLine(_ line: String, number: Int) -> some View {
        let kind: DiffLineKind = line.hasPrefix("+") && !line.hasPrefix("+++") ? .addition : line.hasPrefix("-") && !line.hasPrefix("---") ? .deletion : line.hasPrefix("@@") ? .hunk : .context
        return HStack(spacing: 8) {
            Text("\(number)")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(Color.scifiTertiary)
            Text(line.isEmpty ? " " : line)
                .foregroundStyle(kind.foreground)
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background(kind.background)
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.scifiFg)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.scifiCanvas)
            if let saveError {
                Text(saveError)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.scifiWarning)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.scifiWarning.opacity(0.08))
            }
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
        }
    }
}

private enum DiffLineKind {
    case addition, deletion, hunk, context
    var foreground: Color { self == .addition ? Color.scifiSuccess : self == .deletion ? Color.scifiDestructive : self == .hunk ? Color.scifiAccent : Color.scifiFg }
    var background: Color { self == .addition ? Color.scifiSuccess.opacity(0.08) : self == .deletion ? Color.scifiDestructive.opacity(0.08) : self == .hunk ? Color.scifiAccent.opacity(0.08) : .clear }
}
