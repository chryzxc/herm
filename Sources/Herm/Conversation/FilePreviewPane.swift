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
    @State private var fileRevision: PlanFileRevision?
    @State private var watchedURL: URL?
    /// Off by default so the tab reads as a plain preview until review starts.
    @State private var isAnnotating = false
    /// Derived from the loaded text on every reload; nil for non-Markdown.
    @State private var specMap: SpecMap?
    @State private var showsMap = false
    /// Linked to this session's rail as a plan; a local preference.
    @State private var isLinked = false
    @State private var focus: SpecMapFocus?
    @State private var showsFullScreen = false
    @State private var mapSelection: String?
    /// Titles Hermes changed since they were last seen; cleared per node on selection.
    @State private var updatedTitles: Set<String> = []
    @State private var sync = SpecMapDocumentSync()
    /// Recomputed only when its inputs change, never on the token stream that re-runs body.
    @State private var mapOverlay = SpecMapOverlay()
    @Environment(\.sessionPreviewWorkspace) private var previewWorkspace
    @Environment(\.dockHostVisible) private var hostVisible

    private var kind: FilePreviewKind? { FilePreviewKind(url: url) }
    private var path: String { url.path }
    private var text: String? {
        if case .text(let text, _) = content { return text }
        return nil
    }
    private var usefulMap: SpecMap? { specMap?.isUseful == true ? specMap : nil }
    private var isShowingMap: Bool { showsMap && usefulMap != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyContent
        }
        .background(Color.dockCanvas)
        .onAppear { isAnnotating = center.hasDrafts(path) }
        .onChange(of: path, initial: true) { _, path in isLinked = model.isPlanLinked(path) }
        .onChange(of: center.planRequest, initial: true) { _, request in
            guard request == path else { return }
            center.planRequest = nil
            showsMap = true
        }
        .task(id: hostVisible ? url : nil) {
            if hostVisible { await watch() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(url.lastPathComponent)
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            let progress = headerProgress
            if let progress {
                progressSummary(progress)
            }
            Spacer(minLength: 8)
            if let map = usefulMap {
                let isHermesPlan = path.contains("/.hermes/plans/")
                if progress == nil, isHermesPlan || isLinked {
                    Button("Track progress") {
                        model.attachChatContext(SessionPlans.trackProgressContext(path: path, title: map.title))
                    }
                    .buttonStyle(.dockSecondary)
                    .help(
                        "Add a request to the chat composer asking Hermes to name its task list after this plan’s steps, so Herm can show progress here and in the session rail. Herm never edits the plan."
                    )
                }
                if !isHermesPlan, model.navigationSessionID != nil {
                    Button(isLinked ? "Remove from rail" : "Add to rail") {
                        isLinked = model.setPlan(path, linked: !isLinked)
                    }
                    .buttonStyle(.dockSecondary)
                    .help(
                        isLinked
                            ? "Stop showing this plan in this session’s rail. The file is not changed."
                            : "Show this plan in this session’s rail with its progress, so you can follow it without keeping this tab open."
                    )
                }
            }
            openInMenu
        }
        .dockPadding(.horizontal, 16)
        .frame(height: 48)
        .dockButtonSize(.compact)
        .dockPaneTint(Color.dockSurface2)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    /// The file's own checkboxes, else the session's task list where it names plan steps.
    private var headerProgress: (done: Int, total: Int, blocked: Int, fromTaskList: Bool)? {
        guard let map = usefulMap else { return nil }
        if let progress = map.progress { return (progress.done, progress.total, progress.blocked, false) }
        return map.taskListProgress(model.planTasks.map { ($0.content, $0.status) }).map {
            ($0.done, $0.total, 0, true)
        }
    }

    /// The plan's state in both views.
    private func progressSummary(_ progress: (done: Int, total: Int, blocked: Int, fromTaskList: Bool)) -> some View {
        HStack(spacing: 6) {
            Text("\(progress.done)/\(progress.total) done").foregroundStyle(Color.dockMetadataText)
            if progress.blocked > 0 {
                Text("\(progress.blocked) blocked").foregroundStyle(DockStatusTone.attention.color)
            }
            if progress.fromTaskList {
                Text("from task list").foregroundStyle(Color.dockMetadataText)
            }
        }
        .help(
            progress.fromTaskList
                ? "The plan has no checkboxes, so this counts the session’s Hermes task list where tasks name the plan’s steps."
                : "Counted from the plan’s own checkboxes."
        )
        .dockFont(.metadata)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var canAnnotate: Bool { kind != .image && text != nil }

    /// Document | Plan float over the content's bottom edge, beside the thing they change.
    @ViewBuilder
    private var viewControls: some View {
        if usefulMap != nil {
            HStack(spacing: 2) {
                modeTab("Document", icon: .fileText, showsMap: false)
                modeTab("Plan", icon: .treeStructure, showsMap: true)
                    .help(
                        "Show this Markdown as a plan: phases, steps, dependencies and progress, read from the file each time it changes."
                    )
            }
            .fixedSize()
            .dockCard(padding: 3)
            .dockPadding(.bottom, 12)
        }
    }

    /// The document's own tools, top right like the map's: Annotate, then full screen.
    private func documentControls(expanded: Bool) -> some View {
        HStack(spacing: 4) {
            if canAnnotate {
                DockIconAction(
                    icon: .highlighter, label: isAnnotating ? "Stop annotating" : "Annotate: select text to add notes",
                    help: isAnnotating
                        ? "Stop annotating and return to the rich view. Your unsent notes are kept."
                        : "Annotate: select text to add notes on it. Notes collect as a review you can send to Hermes in one message.",
                    isProminent: isAnnotating
                ) {
                    withAnimation(.dockEase(duration: 0.15)) { isAnnotating.toggle() }
                }
                .accessibilityValue(isAnnotating ? "On" : "Off")
            }
            if !expanded {
                DockIconAction(
                    icon: .arrowsOut, label: "Open document full screen",
                    help:
                        "Open this document in a full-window view for easier reading and annotating. Close it to return here."
                ) {
                    showsFullScreen = true
                }
            }
        }
        .dockButtonSize(.compact)
        .dockPadding(10)
    }

    private func modeTab(_ title: String, icon: Ph, showsMap value: Bool) -> some View {
        DockTabButton(title: title, icon: icon, isSelected: showsMap == value, height: 28) {
            switchMode(toMap: value)
        }
    }

    /// The map and the document follow each other: the document scrolls to the
    /// selected node, and the map selects the section the document was reading.
    private func switchMode(toMap: Bool) {
        guard toMap != showsMap else { return }
        if toMap, let map = usefulMap, case let offset = sync.readTopOffset(), offset > 0,
            let node = map.node(atRenderedOffset: offset, in: sync.rendered)
        {
            mapSelection = node.id
        } else if !toMap, let node = mapSelection.flatMap({ usefulMap?.node($0) }) {
            focus = .reveal(node.title)
        }
        withAnimation(.dockEase(duration: 0.2)) { showsMap = toMap }
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
                if isShowingMap, let usefulMap {
                    SpecMapView(
                        map: usefulMap, selectedID: $mapSelection, storageKey: path,
                        overlay: mapOverlay, actions: mapActions
                    )
                    .equatable()
                    .overlay(alignment: .bottom) { viewControls }
                    .onChange(of: overlayInputs(usefulMap), initial: true) { _, inputs in
                        mapOverlay = overlay(inputs)
                    }
                } else {
                    TextAnnotator(
                        source: .file(url), text: text, isMarkdown: kind == .markdown,
                        notice: truncated ? "Preview truncated — open the file to see the rest." : nil,
                        isAnnotating: $isAnnotating, model: model, focus: $focus, sync: sync,
                        accessory: usefulMap == nil ? nil : AnyView(viewControls),
                        controls: AnyView(documentControls(expanded: false))
                    )
                    .id(path)
                    .dockSheet(isPresented: $showsFullScreen) {
                        DockExpandedPage(
                            title: url.lastPathComponent, subtitle: "Document", close: { showsFullScreen = false }
                        ) {
                            TextAnnotator(
                                source: .file(url), text: text, isMarkdown: kind == .markdown,
                                isAnnotating: $isAnnotating, model: model,
                                controls: AnyView(documentControls(expanded: true)))
                        }
                        .frame(minWidth: 900, minHeight: 640)
                        .modifier(ReviewSheetContext())
                    }
                }
            case .missing:
                SessionSurfacePreviewPlaceholder(icon: .warning, title: "File not found", detail: path)
            case .binary:
                SessionSurfacePreviewPlaceholder(
                    icon: .file, title: "No inline preview", detail: "Open it in its default app.")
            case nil:
                DockLoadingIndicator().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func open(_ request: SpecMapFocus) {
        focus = request
        showsMap = false
    }

    private var mapActions: SpecMapActions {
        SpecMapActions(
            reveal: { open(.reveal($0.title)) },
            comment: { open(.comment($0.title)) },
            send: send,
            openNote: { open(.note($0)) },
            seen: { updatedTitles.remove($0.title) },
            openFile: { url in
                if let previewWorkspace {
                    SessionMessageTabs.shared.open(.file(url), in: previewWorkspace)
                } else {
                    ArtifactOpener.open(url.path)
                }
            },
            resolveFile: resolve)
    }

    /// Compared on every body pass. Cheap without a version counter: the map and the
    /// annotations are unchanged values between reloads, and `Array ==` returns early on
    /// shared storage, so the walk over every node runs only when something changed.
    private struct OverlayInputs: Equatable {
        let map: SpecMap
        let notes: [FileAnnotation]
        let plan: TodoPlan?
        let updated: Set<String>
    }

    private func overlayInputs(_ map: SpecMap) -> OverlayInputs {
        OverlayInputs(
            map: map, notes: center.review(AnnotationSource.file(url).key).annotations,
            plan: model.currentTodoPlan, updated: updatedTitles)
    }

    private func overlay(_ inputs: OverlayInputs) -> SpecMapOverlay {
        var notes: [String: [UUID]] = [:]
        for note in inputs.notes where note.sentAt == nil {
            guard let quote = note.quote, let node = inputs.map.node(quoting: quote) else { continue }
            notes[node.id, default: []].append(note.id)
        }
        let live = inputs.plan.map { plan in
            inputs.map.liveStatuses(plan.items.map { ($0.content, $0.status) })
        }
        return SpecMapOverlay(updated: inputs.updated, notes: notes, live: live ?? [:])
    }

    /// A path written in the plan, found relative to the plan or any folder above it.
    /// ponytail: existence checks on the main thread, only for the expanded node's few paths.
    private func resolve(_ relative: String) -> URL? {
        var folder = url.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = folder.appending(path: relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            guard folder.path != "/" else { return nil }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    private func send(_ nodes: [SpecMapNode]) {
        guard let first = nodes.first else { return }
        let title = nodes.count == 1 ? "Spec node · \(first.title)" : "Spec nodes · \(nodes.count) steps"
        let body = ([path] + nodes.map { "## \($0.title)\n\n\($0.detail)" }).joined(separator: "\n\n")
        model.attachChatContext(
            ChatContext(
                id: "spec:\(path):\(nodes.map { String($0.line) }.joined(separator: ","))", title: title, body: body))
    }

    /// ponytail: 1s revision poll (Hermes writes atomically, which breaks fd
    /// watches); switch to FSEvents like RepositoryWatchService if needed.
    private func watch() async {
        if watchedURL != url {
            watchedURL = url
            content = nil
            fileRevision = nil
            specMap = nil
            mapSelection = nil
            updatedTitles = []
        }
        guard kind != .image else { return }
        let url = url
        let isMarkdown = kind == .markdown
        while !Task.isCancelled {
            let previous = fileRevision
            let worker = Task.detached(priority: .utility) {
                PlanFileCache.shared.preview(at: url, markdown: isMarkdown, after: previous)
            }
            let update = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            if let update {
                if fileRevision != update.revision { fileRevision = update.revision }
                if content != update.content {
                    content = update.content
                    if let text { center.reconcile(path, contents: text) }
                }
                if specMap != update.map {
                    if let old = specMap, let map = update.map {
                        updatedTitles.formUnion(map.changedTitles(since: old))
                    }
                    specMap = update.map
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// The document's reading position, shared with the map without re-rendering either.
/// The band under tools floating at a scrolling surface's top edge: solid behind the
/// tool row, then a short fade, so the icons never sit on content. Surfaces start their
/// content `reserved` points down so nothing begins hidden under the tools.
struct ToolsTopFade: View {
    static let reserved: CGFloat = 44

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.dockCanvas, location: 0),
                .init(color: Color.dockCanvas, location: 0.62),
                .init(color: Color.dockCanvas.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom
        )
        .frame(height: 76)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

@MainActor
final class SpecMapDocumentSync {
    var readTopOffset: @MainActor () -> Int = { 0 }
    var rendered = ""
}

/// The Annotate toggle every annotatable tab uses: a highlighter tab that stays lit while on.
struct AnnotateToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        DockTabButton(title: "Annotate", icon: .highlighter, isSelected: isOn, height: 28, font: .control) {
            withAnimation(.dockEase(duration: 0.15)) { isOn.toggle() }
        }
        .fixedSize()
        .help(
            isOn
                ? "Stop annotating and return to the rich view. Your unsent notes are kept."
                : "Select text to add notes on it. Notes collect as a review you can send to Hermes in one message."
        )
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
    /// A Spec Map action to carry out once the document has rendered.
    var focus: Binding<SpecMapFocus?> = .constant(nil)
    /// Where the document is reading, for the map to pick up; never drives a render.
    var sync: SpecMapDocumentSync?
    /// Controls floated over the document's bottom edge; the text scrolls clear of them.
    var accessory: AnyView?
    /// Tools floated at the document's top-right corner.
    var controls: AnyView?

    @ObservedObject private var center = FilePreviewCenter.shared
    /// Rendered document text; highlights are located in this, not the source.
    @State private var rendered = ""
    @State private var scrollTarget: NSRange?
    /// The note being written or viewed: from a selection, a highlight click,
    /// the notes list, or "General note" (no quote, edited in the bottom bar).
    @State private var composing: FileAnnotation?
    @State private var anchor: AnnotationAnchor?
    @State private var showsNotes = false
    @State private var hoveredNote: FileAnnotation.ID?
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
                .overlay(alignment: .bottom) { accessory }
                .overlay(alignment: .top) {
                    // Text scrolling under the top tools fades out instead of colliding with them.
                    if controls != nil { ToolsTopFade() }
                }
                .overlay(alignment: .topTrailing) { controls }
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
        .onChange(of: rendered) { applyFocus() }
        .onChange(of: focus.wrappedValue) { applyFocus() }
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
            onRendered: { text in
                rendered = text
                sync?.rendered = text
            },
            scrollTarget: scrollTarget,
            bottomInset: accessory == nil ? 0 : 56,
            topInset: controls == nil ? 0 : ToolsTopFade.reserved,
            exposeVisibleOffset: sync.map { sync in { sync.readTopOffset = $0 } },
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

    /// Finds the node's title in the rendered text: it differs from the source,
    /// so source lines can't be used. ponytail: first match wins for repeated titles.
    private func applyFocus() {
        guard let request = focus.wrappedValue, !rendered.isEmpty else { return }
        focus.wrappedValue = nil
        let string = rendered as NSString
        switch request {
        case .note(let id):
            guard let annotation = review.annotations.first(where: { $0.id == id }) else { return }
            isAnnotating = true
            // Let the highlights lay out before the popover anchors on one.
            DispatchQueue.main.async { revealNow(annotation) }
        case .reveal(let title), .comment(let title):
            let range = string.range(of: title, options: .caseInsensitive)
            guard range.location != NSNotFound else { return }
            if case .comment = request {
                isAnnotating = true
                select(range, String(string.substring(with: range).prefix(500)))
            } else {
                scrollTarget = range
            }
        }
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
                        sectionLabel("Not sent", count: drafts.count)
                        ForEach(drafts.sorted { (number(of: $0) ?? .max) < (number(of: $1) ?? .max) }) { noteRow($0) }
                    }
                    if !sent.isEmpty {
                        HStack {
                            sectionLabel("Sent", count: sent.count)
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
            HStack {
                Button(action: startGeneralNote) {
                    DockIconLabel("Add general note", icon: .plus)
                }
                .buttonStyle(.dockSecondary)
                Spacer()
            }
            .dockButtonSize(.compact)
            .dockPadding(10)
        }
        .frame(width: 340)
    }

    private func sectionLabel(_ title: String, count: Int? = nil) -> some View {
        DockSectionLabel(title: title, count: count)
            .dockPadding(.horizontal, 8)
            .dockPadding(.top, 8)
            .dockPadding(.bottom, 2)
    }

    /// The quote leads as a citation (what the note is about), the note follows in body type.
    private func noteRow(_ annotation: FileAnnotation) -> some View {
        let isHovered = hoveredNote == annotation.id
        let isComposing = annotation.id == composing?.id
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            noteMarker(annotation)
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                if let quote = annotation.quote {
                    Text(quote)
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .dockPadding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.dockBorderStrong).frame(width: 1)
                        }
                } else {
                    Text("General note")
                        .dockFont(.metadata)
                        .foregroundStyle(Color.dockMetadataText)
                }
                Text(annotation.note)
                    .dockFont(.body)
                    .foregroundStyle(annotation.resolved ? Color.dockSecondaryText : Color.dockPrimaryText)
                    .strikethrough(annotation.resolved, color: Color.dockMetadataText)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if annotation.sentAt == nil {
                Button {
                    center.remove(annotation.id, from: key)
                } label: {
                    DockIcon(.trash, size: 13, color: Color.dockMetadataText)
                }
                .buttonStyle(.dockHover)
                .opacity(isHovered || isComposing ? 1 : 0)
                .help("Delete note")
                .accessibilityLabel("Delete note")
            }
        }
        .dockPadding(.horizontal, 8)
        .dockPadding(.vertical, 8)
        .background(
            isComposing ? Color.dockAccent.opacity(0.12) : isHovered ? Color.dockSurface2 : Color.clear,
            in: RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hoveredNote = $0 ? annotation.id : (hoveredNote == annotation.id ? nil : hoveredNote) }
        .dockTapAction { reveal(annotation) }
        .help(annotation.quote == nil ? "Edit note" : "Show in document")
    }

    /// Draft numbers match the marks in the document; sent notes show whether they were addressed.
    @ViewBuilder
    private func noteMarker(_ annotation: FileAnnotation) -> some View {
        if let number = number(of: annotation) {
            Text("\(number)")
                .dockFont(.metadata, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(Color.dockAccent)
        } else if annotation.sentAt != nil {
            DockIcon(
                annotation.resolved ? .checkCircle : .clock, size: 13,
                color: annotation.resolved ? Color.dockAccent : Color.dockMetadataText
            )
            .help(
                annotation.resolved
                    ? "Addressed: the text this note quoted has changed since you sent it."
                    : "Sent to Hermes. The quoted text hasn’t changed yet.")
        } else {
            DockIcon(.notePencil, size: 13, color: Color.dockMetadataText)
        }
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
    private func attach(_ context: ChatContext) { model.attachChatContext(context) }
}

extension DockModel {
    /// Adds a context chip to the composer once and focuses it; never sends.
    func attachChatContext(_ context: ChatContext) {
        if !attachedContexts.contains(where: { $0.id == context.id }) { attachedContexts.append(context) }
        requestComposerFocus()
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
