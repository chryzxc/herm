import AppKit
import SwiftUI

/// File types Herm previews in-app. Anything not mapped here opens in its
/// default app; add a case (and its pane branch) to support a new type.
enum FilePreviewKind {
    case markdown, text, image

    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let textExtensions: Set<String> = [
        "txt", "log", "json", "yaml", "yml", "toml", "csv", "xml", "html", "css", "js", "ts", "tsx", "jsx",
        "swift", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "sh", "zsh", "sql", "ini", "env",
    ]

    init?(url: URL) {
        guard url.isFileURL else { return nil }
        let ext = url.pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) { self = .markdown }
        else if Self.textExtensions.contains(ext) { self = .text }
        else if ArtifactService.kind(for: url.path) == .image { self = .image }
        else { return nil }
    }
}

/// Inline file preview for the inspector panel: Markdown rendered, other text
/// monospaced, images scaled. Selecting text opens a note popover right at
/// the selection; notes stay highlighted in place and are sent back to the
/// Hermes session that produced the file as one revision request.
struct FilePreviewPane: View {
    let url: URL
    @ObservedObject var model: DockModel
    let onClose: () -> Void

    @ObservedObject private var center = FilePreviewCenter.shared
    @State private var content: ArtifactTextPreview.Content?
    @State private var modifiedAt: Date?
    /// Rendered document text; highlights are located in this, not the source.
    @State private var rendered = ""
    /// The note being written or viewed: from a selection, a highlight click,
    /// the notes list, or "General note" (no quote, edited in the bottom bar).
    @State private var composing: FileAnnotation?
    @State private var anchor: AnnotationAnchor?
    @State private var showsNotes = false
    @State private var showsChanges = false
    @State private var changes: [FileAnnotationText.DiffLine] = []

    private struct ReviewDiffInput: Equatable, Sendable {
        let baseline: String
        let current: String
    }

    private var kind: FilePreviewKind? { FilePreviewKind(url: url) }
    private var path: String { url.path }
    private var review: FileReview { center.review(path) }
    private var drafts: [FileAnnotation] { review.annotations.filter { $0.sentAt == nil } }
    private var sent: [FileAnnotation] { review.annotations.filter { $0.sentAt != nil } }
    private var text: String? {
        if case .text(let text, _) = content { return text }
        return nil
    }
    private var canAnnotate: Bool { kind != .image && text != nil }
    private var reviewDiffInput: ReviewDiffInput? {
        guard showsNotes, let baseline = review.baseline, let text, baseline != text else { return nil }
        return ReviewDiffInput(baseline: baseline, current: text)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyContent
            if canAnnotate {
                Group {
                    if let composing, composing.quote == nil {
                        AnnotationEditor(
                            annotation: composingBinding,
                            isSaved: isSaved(composing),
                            onSave: commitNote,
                            onCancel: { cancelNote() },
                            onDelete: deleteComposing
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        reviewBar
                    }
                }
                .dockPaneTint(Color.dockSurface2)
                .overlay(alignment: .top) { Color.dockBorderLight.frame(height: 0.5) }
            }
        }
        .background(Color.dockCanvas)
        .animation(.dockEase(duration: 0.15), value: composing?.quote == nil && composing != nil)
        .task(id: url) { await watch() }
        .task(id: reviewDiffInput) {
            changes = []
            guard let input = reviewDiffInput else { return }
            let result = await Task.detached(priority: .utility) {
                FileAnnotationText.lineDiff(old: input.baseline, new: input.current)
            }.value
            guard !Task.isCancelled else { return }
            changes = result
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(url.lastPathComponent)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            DockIconButton(icon: .arrowSquareOut, label: "Open in default app",
                           style: DockThemePalette(theme: DockThemeRuntime.current)) { ArtifactOpener.open(path) }
            DockIconButton(icon: .x, label: "Close preview",
                           style: DockThemePalette(theme: DockThemeRuntime.current), action: onClose)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .dockPaneTint(Color.dockSurface2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    // MARK: Document

    @ViewBuilder
    private var bodyContent: some View {
        if kind == .image {
            ScrollView { AttachmentThumbnailView(url: url, maximumPixelSize: 2_400).padding(16) }
        } else {
            switch content {
            case .text(let text, let truncated):
                VStack(spacing: 0) {
                    AnnotatableDocumentView(
                        text: text,
                        isMarkdown: kind == .markdown,
                        highlights: highlights,
                        anchor: $anchor,
                        onSelect: select,
                        onOpenAnnotation: openAnnotation,
                        onDismiss: popoverDismissed,
                        onRendered: { rendered = $0 }
                    ) {
                        AnnotationEditor(
                            annotation: composingBinding,
                            isSaved: composing.map(isSaved) ?? false,
                            onSave: commitNote,
                            onCancel: { cancelNote() },
                            onDelete: deleteComposing
                        )
                        .frame(width: 320)
                    }
                    if truncated {
                        Text("Preview truncated — open the file to see the rest.")
                            .dockFont(.compactStatus, weight: .regular)
                            .foregroundStyle(Color.dockMetadataText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }
                }
            case .missing:
                SessionSurfacePreviewPlaceholder(icon: .warning, title: "File not found", detail: path)
            case .binary:
                SessionSurfacePreviewPlaceholder(icon: .file, title: "No inline preview", detail: "Open it in its default app.")
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Drafts are numbered in document order; the same numbers label the
    /// margin markers and the notes list.
    private var numbered: [(annotation: FileAnnotation, range: NSRange)] {
        drafts.compactMap { annotation in range(of: annotation).map { (annotation, $0) } }
            .sorted { $0.range.location < $1.range.location }
    }

    private func number(of annotation: FileAnnotation) -> Int? {
        numbered.firstIndex { $0.annotation.id == annotation.id }.map { $0 + 1 }
    }

    private var highlights: [AnnotationHighlight] {
        var result = numbered.enumerated().map { index, item in
            AnnotationHighlight(id: item.annotation.id, range: item.range,
                                style: item.annotation.id == composing?.id ? .active : .draft, number: index + 1)
        }
        for annotation in sent where !annotation.resolved {
            guard let range = range(of: annotation) else { continue }
            result.append(AnnotationHighlight(id: annotation.id, range: range, style: annotation.id == composing?.id ? .active : .sent))
        }
        // A fresh selection being written has no saved range yet.
        if let composing, !isSaved(composing), let anchor {
            result.append(AnnotationHighlight(id: composing.id, range: anchor.range, style: .active))
        }
        return result
    }

    private func range(of annotation: FileAnnotation) -> NSRange? {
        guard let quote = annotation.quote, !rendered.isEmpty else { return nil }
        return FileAnnotationText.range(of: quote, in: rendered, near: annotation.location)
    }

    // MARK: Interaction

    private var composingBinding: Binding<FileAnnotation> {
        Binding(
            get: { composing ?? FileAnnotation(note: "") },
            // A closing popover's editor can still write back after Cancel;
            // only accept edits to the note actually being composed.
            set: { if composing?.id == $0.id { composing = $0 } }
        )
    }

    private func isSaved(_ annotation: FileAnnotation) -> Bool {
        review.annotations.contains { $0.id == annotation.id }
    }

    private func select(_ range: NSRange, _ quote: String) {
        keepComposingDraft()
        composing = FileAnnotation(quote: quote, location: range.location, note: "")
        anchor = AnnotationAnchor(range: range, annotationID: nil)
    }

    private func openAnnotation(_ id: UUID, _ range: NSRange) {
        guard let annotation = review.annotations.first(where: { $0.id == id }) else { return }
        keepComposingDraft()
        composing = annotation
        anchor = AnnotationAnchor(range: range, annotationID: id)
    }

    /// List rows scroll to their highlight and open the popover there.
    private func reveal(_ annotation: FileAnnotation) {
        showsNotes = false
        // Let the list popover finish closing before the note's opens.
        DispatchQueue.main.async { revealNow(annotation) }
    }

    private func revealNow(_ annotation: FileAnnotation) {
        guard annotation.quote != nil else {
            keepComposingDraft()
            composing = annotation
            anchor = nil
            return
        }
        guard let range = range(of: annotation) else { return }
        openAnnotation(annotation.id, range)
    }

    private func startGeneralNote() {
        showsNotes = false
        keepComposingDraft()
        anchor = nil
        composing = FileAnnotation(note: "")
    }

    /// Click-away keeps what was typed: a non-empty note is saved as a draft.
    private func popoverDismissed() {
        keepComposingDraft()
        composing = nil
        anchor = nil
    }

    /// Empty notes are never kept.
    private func keepComposingDraft() {
        guard var annotation = composing, annotation.sentAt == nil else { return }
        annotation.note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !annotation.note.isEmpty else { return }
        if isSaved(annotation) { center.update(annotation, in: path) } else { center.add(annotation, to: path) }
    }

    private func commitNote() {
        keepComposingDraft()
        cancelNote()
    }

    private func cancelNote() {
        composing = nil
        anchor = nil
    }

    private func deleteComposing() {
        if let composing { center.remove(composing.id, from: path) }
        cancelNote()
    }

    // MARK: Review bar

    private var reviewBar: some View {
        HStack(spacing: 8) {
            Button { showsNotes.toggle() } label: {
                HStack(spacing: 6) {
                    DockIcon(.chatCircleText, size: 14, color: review.annotations.isEmpty ? Color.dockMetadataText : Color.dockAccent)
                    Text(barSummary)
                        .dockFont(.metadata, weight: .medium)
                        .foregroundStyle(review.annotations.isEmpty ? Color.dockMetadataText : Color.dockSecondaryText)
                        .lineLimit(1)
                    DockIcon(.caretUp, size: 9, color: Color.dockMetadataText)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dockHover)
            .help("All notes on this file")
            .popover(isPresented: $showsNotes, arrowEdge: .top) { notesList }
            Spacer(minLength: 8)
            if drafts.isEmpty {
                Button(action: addToChat) {
                    Label("Add to chat", systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.dockSecondary)
                .help("Reference this file in the chat composer")
            } else {
                Button("Send \(drafts.count) to chat", action: sendDrafts)
                    .buttonStyle(.dockPrimary)
                    .help("Attach these notes to the chat as one revision request")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var barSummary: String {
        if review.annotations.isEmpty { return "Select text to add a note" }
        var parts: [String] = []
        if !drafts.isEmpty { parts.append("\(drafts.count) note\(drafts.count == 1 ? "" : "s")") }
        if !sent.isEmpty { parts.append("\(sent.filter(\.resolved).count)/\(sent.count) addressed") }
        return parts.joined(separator: " · ")
    }

    // MARK: Notes list

    private var notesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if review.annotations.isEmpty {
                        Text("Select any text in the document to leave a note on it. Notes collect here until you send them to the chat.")
                            .dockFont(.metadata)
                            .foregroundStyle(Color.dockMetadataText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                    }
                    if !drafts.isEmpty {
                        sectionLabel("NOT SENT")
                        ForEach(drafts.sorted { (number(of: $0) ?? .max) < (number(of: $1) ?? .max) }) { noteRow($0) }
                    }
                    if !sent.isEmpty {
                        HStack {
                            sectionLabel("SENT")
                            Spacer()
                            Button("Clear") { center.clearSent(path) }
                                .buttonStyle(.dockCompact)
                                .dockFont(.compactStatus, weight: .regular)
                                .foregroundStyle(Color.dockSecondaryText)
                                .padding(.trailing, 8)
                        }
                        ForEach(sent) { noteRow($0) }
                    }
                    if !changes.isEmpty { changesSection }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            Button(action: startGeneralNote) {
                Label("Add general note", systemImage: "plus")
                    .dockFont(.control)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dockCompact)
            .foregroundStyle(Color.dockSecondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .dockFont(.sectionLabel)
            .foregroundStyle(Color.dockMetadataText)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func noteRow(_ annotation: FileAnnotation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let number = number(of: annotation) {
                    Text("\(number)")
                        .dockFont(.compactStatus, weight: .semibold)
                        .foregroundStyle(Color.dockAccent)
                        .frame(width: 18, height: 16)
                        .background(Color.dockAccent.opacity(0.22), in: Capsule())
                } else if annotation.sentAt != nil {
                    DockIcon(annotation.resolved ? .checkCircle : .clock, size: 13,
                             color: annotation.resolved ? Color.dockAccent : Color.dockMetadataText)
                        .help(annotation.resolved ? "Addressed: the quoted text changed" : "Sent, still in the file")
                } else {
                    DockIcon(.notePencil, size: 13, color: Color.dockMetadataText)
                }
            }
            .frame(width: 18)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(annotation.note)
                    .dockFont(.body)
                    .foregroundStyle(annotation.resolved ? Color.dockSecondaryText : Color.dockPrimaryText)
                    .lineLimit(3)
                Text(annotation.quote.map { "“\($0)”" } ?? "General note")
                    .dockFont(.compactStatus, weight: .regular)
                    .foregroundStyle(Color.dockMetadataText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if annotation.sentAt == nil {
                Button { center.remove(annotation.id, from: path) } label: {
                    DockIcon(.trash, size: 11, color: Color.dockMetadataText)
                }
                .buttonStyle(.dockHover)
                .help("Delete note")
                .accessibilityLabel("Delete note")
            }
        }
        .padding(8)
        .background(
            annotation.id == composing?.id ? Color.dockAccent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { reveal(annotation) }
        .help(annotation.quote == nil ? "Edit note" : "Show in document")
    }

    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showsChanges.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("CHANGES SINCE REVIEW · \(changes.count) LINES").dockFont(.sectionLabel)
                    DockIcon(showsChanges ? .caretDown : .caretRight, size: 9, color: Color.dockMetadataText)
                }
                .foregroundStyle(Color.dockMetadataText)
            }
            .buttonStyle(.dockHover)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            if showsChanges {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, line in
                        Text("\(String(line.sign)) \(line.text)")
                            .dockFont(.compactStatus, weight: .regular, design: .monospaced)
                            .foregroundStyle(line.sign == "+" ? Color.dockSuccess : Color.dockDestructive)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: Sending

    private func sendDrafts() {
        keepComposingDraft()
        cancelNote()
        guard let text, !drafts.isEmpty else { return }
        attach(ChatContext(
            id: "review:\(path):\(UUID().uuidString)",
            title: "\(drafts.count) note\(drafts.count == 1 ? "" : "s") · \(url.lastPathComponent)",
            body: FileAnnotationText.prompt(path: path, annotations: drafts)
        ))
        center.markSent(path, baseline: text)
    }

    private func addToChat() {
        attach(ChatContext(
            id: "file:\(path)",
            title: url.lastPathComponent,
            body: "Regarding `\(path)`:"
        ))
    }

    /// Back to the session the preview came from; the current chat otherwise.
    private func attach(_ context: ChatContext) {
        if let origin = center.sessionID, origin != model.sessionID,
           let session = model.sessions.first(where: { $0.id == origin }) {
            Task { await model.attachContext(context, to: session) }
            return
        }
        if !model.attachedContexts.contains(where: { $0.id == context.id }) {
            model.attachedContexts.append(context)
        }
        model.requestComposerFocus()
    }

    // MARK: Live reload

    /// ponytail: 1s mtime poll (Hermes writes atomically, which breaks fd
    /// watches); switch to FSEvents like RepositoryWatchService if needed.
    private func watch() async {
        content = nil
        modifiedAt = nil
        rendered = ""
        cancelNote()
        guard kind != .image else { return }
        let url = url
        while !Task.isCancelled {
            let date = await Task.detached(priority: .utility) {
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            }.value
            guard !Task.isCancelled else { return }
            if content == nil || date != modifiedAt {
                modifiedAt = date
                let loaded = await Task.detached { ArtifactTextPreview.Content.load(url) }.value
                guard !Task.isCancelled else { return }
                content = loaded
                if let text { center.reconcile(path, contents: text) }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// The note editor shown in the selection popover (and the bottom bar for
/// general notes). Sent notes are read-only: they're already with Hermes.
private struct AnnotationEditor: View {
    @Binding var annotation: FileAnnotation
    let isSaved: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    @FocusState private var isFocused: Bool

    private var isSent: Bool { annotation.sentAt != nil }
    private var canSave: Bool { !annotation.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            quoteHeader
            if isSent {
                sentBody
            } else {
                noteField
                footer
            }
        }
        .padding(14)
        .onAppear {
            // Popover content attaches to its window a beat after appearing.
            DispatchQueue.main.async { isFocused = !isSent }
        }
    }

    @ViewBuilder
    private var quoteHeader: some View {
        if let quote = annotation.quote {
            HStack(alignment: .top, spacing: 8) {
                DockIcon(.quotes, size: 12, color: .dockAccent)
                    .padding(.top, 1)
                Text(quote)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.dockAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        } else {
            Text("GENERAL NOTE").dockFont(.sectionLabel).foregroundStyle(Color.dockMetadataText)
        }
    }

    private var sentBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(annotation.resolved ? "Addressed" : "Sent · still in the file")
                .dockFont(.compactStatus, weight: .regular)
                .foregroundStyle(Color.dockMetadataText)
            if !annotation.note.isEmpty {
                Text(annotation.note)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockPrimaryText)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done", action: onCancel).buttonStyle(.dockSecondary)
            }
            .controlSize(.small)
        }
    }

    private var noteField: some View {
        TextField(placeholder, text: $annotation.note, axis: .vertical)
            .textFieldStyle(.plain)
            .dockFont(.body)
            .foregroundStyle(Color.dockPrimaryText)
            .lineLimit(3...8)
            .focused($isFocused)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous)
                    .dockSurfaceFill(Color.dockSurface2, stroke: isFocused ? Color.dockAccent.opacity(0.45) : Color.dockBorderLight, lineWidth: 1)
            )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if isSaved {
                Button(action: onDelete) {
                    DockIcon(.trash, size: 13, color: .dockDestructive)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dockHover)
                .help("Delete note")
                .accessibilityLabel("Delete note")
            } else {
                Text("⌘↩ to save")
                    .dockFont(.compactStatus, weight: .regular)
                    .foregroundStyle(Color.dockMetadataText)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.dockSecondary)
                .keyboardShortcut(.cancelAction)
            Button(isSaved ? "Save" : "Add note", action: onSave)
                .buttonStyle(.dockPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
        }
        .controlSize(.small)
    }

    private var placeholder: String {
        annotation.quote == nil
            ? "What should change overall?"
            : "e.g. remove this, add a step here, change it to…"
    }
}
