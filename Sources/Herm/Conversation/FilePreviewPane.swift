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
        if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if Self.textExtensions.contains(ext) {
            self = .text
        } else if ArtifactService.kind(for: url.path) == .image {
            self = .image
        } else {
            return nil
        }
    }
}

/// Inline file preview for a session inspector tab: Markdown rendered, other
/// text monospaced, images scaled. Text files carry the shared `TextAnnotator`
/// and reload live, so sent notes show as addressed once Hermes edits the file.
struct FilePreviewPane: View {
    let url: URL
    @ObservedObject var model: DockModel

    @ObservedObject private var center = FilePreviewCenter.shared
    @State private var content: ArtifactTextPreview.Content?
    @State private var modifiedAt: Date?
    /// Off by default so the tab reads as a plain preview until review starts.
    @State private var isAnnotating = false

    private var kind: FilePreviewKind? { FilePreviewKind(url: url) }
    private var path: String { url.path }
    private var text: String? {
        if case .text(let text, _) = content { return text }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyContent
        }
        .background(Color.dockCanvas)
        .onAppear { isAnnotating = center.hasDrafts(path) }
        .task(id: url) { await watch() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(url.lastPathComponent)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if kind != .image, text != nil { AnnotateToggle(isOn: $isAnnotating) }
            openInMenu
        }
        .dockPadding(.horizontal, 16)
        .frame(height: 48)
        .dockButtonSize(.compact)
        .dockPaneTint(Color.dockSurface2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private var openInMenu: some View {
        DockMenu(outlined: true) {
            FileOpenWithItems(url: url)
        } label: {
            HStack(spacing: 6) {
                DockIcon(.arrowSquareOut, size: 13)
                Text("Open in")
                DockIcon(.caretDown, size: 10)
            }
        }
        .dockFont(.body)
        .dockButtonSize(.compact)
        .accessibilityLabel("Open \(url.lastPathComponent) in another app")
    }

    @ViewBuilder
    private var bodyContent: some View {
        if kind == .image {
            ScrollView { AttachmentThumbnailView(url: url, maximumPixelSize: 2_400).dockPadding(16) }
        } else {
            switch content {
            case .text(let text, let truncated):
                TextAnnotator(
                    source: .file(url), text: text, isMarkdown: kind == .markdown,
                    notice: truncated ? "Preview truncated — open the file to see the rest." : nil,
                    isAnnotating: $isAnnotating, model: model
                )
                .id(path)
            case .missing:
                SessionSurfacePreviewPlaceholder(icon: .warning, title: "File not found", detail: path)
            case .binary:
                SessionSurfacePreviewPlaceholder(
                    icon: .file, title: "No inline preview", detail: "Open it in its default app.")
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// ponytail: 1s mtime poll (Hermes writes atomically, which breaks fd
    /// watches); switch to FSEvents like RepositoryWatchService if needed.
    private func watch() async {
        content = nil
        modifiedAt = nil
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

/// The header toggle every annotatable tab uses.
struct AnnotateToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("Annotate", isOn: $isOn)
            .toggleStyle(.dockSwitch)
            .dockFont(.body)
            .fixedSize(horizontal: true, vertical: false)
            .help("Annotate text")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityHint("Select text to add a note. Saved notes are kept when you finish.")
    }
}

/// Shared annotator for any tab showing text (files, chat messages). With
/// Annotate on, selecting text opens a note popover at the selection; notes
/// stay highlighted in place and are sent to the tab's session chat as one
/// revision request.
struct TextAnnotator: View {
    let source: AnnotationSource
    let text: String
    let isMarkdown: Bool
    var notice: String?
    @Binding var isAnnotating: Bool
    @ObservedObject var model: DockModel

    @ObservedObject private var center = FilePreviewCenter.shared
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

    private var key: String { source.key }
    private var review: FileReview { center.review(key) }
    private var drafts: [FileAnnotation] { review.annotations.filter { $0.sentAt == nil } }
    private var sent: [FileAnnotation] { review.annotations.filter { $0.sentAt != nil } }
    private var reviewDiffInput: ReviewDiffInput? {
        guard showsNotes, let baseline = review.baseline, baseline != text else { return nil }
        return ReviewDiffInput(baseline: baseline, current: text)
    }

    var body: some View {
        VStack(spacing: 0) {
            document
            if let notice {
                Text(notice)
                    .dockFont(.compactStatus, weight: .regular)
                    .foregroundStyle(Color.dockMetadataText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dockPadding(.horizontal, 16)
                    .dockPadding(.vertical, 6)
            }
            if isAnnotating {
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
        .animation(.dockEase(duration: 0.15), value: composing?.quote == nil && composing != nil)
        // Turning Annotate off keeps saved notes; it only drops the unsaved one.
        .onChange(of: isAnnotating) { _, on in
            if !on {
                cancelNote()
                showsNotes = false
            }
        }
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

    // MARK: Document

    private var document: some View {
        AnnotatableDocumentView(
            text: text,
            isMarkdown: isMarkdown,
            highlights: isAnnotating ? highlights : [],
            anchor: $anchor,
            onSelect: { range, quote in if isAnnotating { select(range, quote) } },
            onOpenAnnotation: openAnnotation,
            onDismiss: popoverDismissed,
            onRendered: { rendered = $0 },
            editor: {
                AnnotationEditor(
                    annotation: composingBinding,
                    isSaved: composing.map(isSaved) ?? false,
                    onSave: commitNote,
                    onCancel: { cancelNote() },
                    onDelete: deleteComposing
                )
                .frame(width: 320)
            }
        )
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
            AnnotationHighlight(
                id: item.annotation.id, range: item.range,
                style: item.annotation.id == composing?.id ? .active : .draft, number: index + 1)
        }
        for annotation in sent where !annotation.resolved {
            guard let range = range(of: annotation) else { continue }
            result.append(
                AnnotationHighlight(
                    id: annotation.id, range: range, style: annotation.id == composing?.id ? .active : .sent))
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
        if isSaved(annotation) { center.update(annotation, in: key) } else { center.add(annotation, to: key) }
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
        if let composing { center.remove(composing.id, from: key) }
        cancelNote()
    }

    // MARK: Review bar

    private var reviewBar: some View {
        HStack(spacing: 8) {
            Button {
                showsNotes.toggle()
            } label: {
                HStack(spacing: 6) {
                    DockIcon(
                        .chatCircleText, size: 14,
                        color: review.annotations.isEmpty ? Color.dockMetadataText : Color.dockAccent)
                    Text(barSummary)
                        .dockFont(.metadata, weight: .medium)
                        .foregroundStyle(review.annotations.isEmpty ? Color.dockMetadataText : Color.dockSecondaryText)
                        .lineLimit(1)
                    DockIcon(.caretUp, size: 9, color: Color.dockMetadataText)
                }
            }
            .buttonStyle(.dockSecondary)
            .help("All notes")
            .dockPopover(isPresented: $showsNotes, arrowEdge: .top) { notesList }
            Spacer(minLength: 8)
            if drafts.isEmpty {
                Button(action: addToChat) {
                    Label("Add to chat", systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.dockSecondary)
                .help("Reference this in the chat composer")
            } else {
                Button("Send \(drafts.count) to chat", action: sendDrafts)
                    .buttonStyle(.dockPrimary)
                    .help("Attach these notes to the chat as one revision request")
            }
        }
        .dockButtonSize(.compact)
        .dockPadding(.horizontal, 10)
        .dockPadding(.vertical, 8)
        .frame(minHeight: 44)
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
                        Text(
                            "Select any text in the document to leave a note on it. Notes collect here until you send them to the chat."
                        )
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .fixedSize(horizontal: false, vertical: true)
                        .dockPadding(8)
                    }
                    if !drafts.isEmpty {
                        sectionLabel("NOT SENT")
                        ForEach(drafts.sorted { (number(of: $0) ?? .max) < (number(of: $1) ?? .max) }) { noteRow($0) }
                    }
                    if !sent.isEmpty {
                        HStack {
                            sectionLabel("SENT")
                            Spacer()
                            Button("Clear") { center.clearSent(key) }
                                .buttonStyle(.dockCompact)
                                .dockFont(.compactStatus, weight: .regular)
                                .foregroundStyle(Color.dockSecondaryText)
                                .dockPadding(.trailing, 8)
                        }
                        ForEach(sent) { noteRow($0) }
                    }
                    if !changes.isEmpty { changesSection }
                }
                .dockPadding(6)
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
            .dockPadding(.horizontal, 14)
            .dockPadding(.vertical, 10)
        }
        .frame(width: 340)
    }

    private func sectionLabel(_ title: String) -> some View {
        DockSectionLabel(title: title)
            .dockPadding(.horizontal, 8)
            .dockPadding(.top, 8)
            .dockPadding(.bottom, 2)
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
                    DockIcon(
                        annotation.resolved ? .checkCircle : .clock, size: 13,
                        color: annotation.resolved ? Color.dockAccent : Color.dockMetadataText
                    )
                    .help(
                        annotation.resolved
                            ? "Addressed: the quoted text changed" : "Sent; the quoted text is unchanged")
                } else {
                    DockIcon(.notePencil, size: 13, color: Color.dockMetadataText)
                }
            }
            .frame(width: 18)
            .dockPadding(.top, 1)
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
                Button {
                    center.remove(annotation.id, from: key)
                } label: {
                    DockIcon(.trash, size: 11, color: Color.dockMetadataText)
                }
                .buttonStyle(.dockHover)
                .help("Delete note")
                .accessibilityLabel("Delete note")
            }
        }
        .dockPadding(8)
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
            .dockPadding(.horizontal, 8)
            .dockPadding(.top, 8)
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
                .dockPadding(.horizontal, 8)
            }
        }
    }

    // MARK: Sending

    private func sendDrafts() {
        keepComposingDraft()
        cancelNote()
        guard !drafts.isEmpty else { return }
        attach(
            ChatContext(
                id: "review:\(key):\(UUID().uuidString)",
                title: "\(drafts.count) note\(drafts.count == 1 ? "" : "s") · \(source.title)",
                body: source.prompt(drafts)
            ))
        center.markSent(key, baseline: text)
    }

    private func addToChat() {
        attach(ChatContext(id: "ref:\(key)", title: source.title, body: source.referenceBody))
    }

    /// Preview tabs belong to the session they were opened in, so notes go to its chat.
    private func attach(_ context: ChatContext) {
        if !model.attachedContexts.contains(where: { $0.id == context.id }) {
            model.attachedContexts.append(context)
        }
        model.requestComposerFocus()
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
        .dockPadding(14)
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
                    .dockPadding(.top, 1)
                Text(quote)
                    .dockFont(.metadata)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .dockPadding(10)
            .background(
                Color.dockAccent.opacity(0.07),
                in: RoundedRectangle(cornerRadius: DockLayout.controlRadius, style: .continuous))
        } else {
            Text("GENERAL NOTE").dockFont(.sectionLabel).foregroundStyle(Color.dockMetadataText)
        }
    }

    private var sentBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(annotation.resolved ? "Addressed" : "Sent")
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
            .dockButtonSize(.compact)
        }
    }

    private var noteField: some View {
        TextField(placeholder, text: $annotation.note, axis: .vertical)
            .textFieldStyle(.plain)
            .dockFont(.body)
            .foregroundStyle(Color.dockPrimaryText)
            .lineLimit(3...8)
            .focused($isFocused)
            .dockPadding(10)
            .dockWell(stroke: isFocused ? Color.dockAccent.opacity(0.45) : nil)
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
        .dockButtonSize(.compact)
    }

    private var placeholder: String {
        annotation.quote == nil
            ? "What should change overall?"
            : "e.g. remove this, add a step here, change it to…"
    }
}
