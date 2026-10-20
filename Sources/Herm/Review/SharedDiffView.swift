import AppKit
import SwiftUI

/// Used by local Git, PRs, and attachment review; never exposes save callbacks.
struct SharedDiffView: View {
    let patch: String
    let path: String
    var preferredSplit = false
    var wraps = false
    var wordDiffs = true
    var onComment: ((DiffLine) -> Void)?
    var contextLoader: ((Int) async throws -> String)?
    var projectPath: String?
    var reveal: DiffSearchMatch?
    @State private var expanded = false
    @State private var availableWidth: CGFloat = 0
    var comparison: DiffComparisonIdentity?
    var owningSession: HermesSession?
    var expandedPresentation = false
    @StateObject private var state: DiffReviewState

    init(
        patch: String, path: String, preferredSplit: Bool = false, wraps: Bool = false, wordDiffs: Bool = true,
        onComment: ((DiffLine) -> Void)? = nil, contextLoader: ((Int) async throws -> String)? = nil,
        projectPath: String? = nil, reveal: DiffSearchMatch? = nil, expandedPresentation: Bool = false,
        owningSession: HermesSession? = nil, comparison: DiffComparisonIdentity? = nil,
        revisionNotes: RevisionNoteStore? = nil, state: DiffReviewState? = nil
    ) {
        self.patch = patch
        self.path = path
        self.preferredSplit = preferredSplit
        self.wraps = wraps
        self.wordDiffs = wordDiffs
        self.onComment = onComment
        self.contextLoader = contextLoader
        self.projectPath = projectPath
        self.reveal = reveal
        self.expandedPresentation = expandedPresentation
        self.owningSession = owningSession
        self.comparison = comparison
        _state = StateObject(wrappedValue: state ?? DiffReviewState(revisionNotes: revisionNotes))
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.expandedReviewRouter) private var expandedRouter
    @Environment(\.chatContextRouter) private var router
    private var sourceIdentity: String {
        let document = state.document(path: path, patch: patch)
        return comparison?.documentID(document) ?? document.identity
    }
    private var canSplit: Bool { document.supportsSplitView && availableWidth >= 680 }

    private var document: DiffDocument { state.document(path: path, patch: state.contextPatch ?? patch) }

    private var viewportIdentity: String {
        let owner = owningSession ?? state.owner
        let session =
            owner.map { WorkspaceIdentity.session(profileID: $0.profileID, sessionID: $0.id) } ?? router?.model.map {
                WorkspaceIdentity.session($0)
            } ?? "local"
        return session + ":diff:" + (projectPath ?? "") + ":" + path
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expandedPresentation {
                DockPageHeader(title: (path as NSString).lastPathComponent, subtitle: (path as NSString).deletingLastPathComponent) {
                    Button("Close") {
                        if let expandedRouter { expandedRouter.close() } else { dismiss() }
                    }.buttonStyle(.dockCompact).keyboardShortcut(.cancelAction)
                }
                .help(path)
            }
            toolbar(isExpanded: expandedPresentation)
            if let notice = document.fileNotice {
                Text(notice).font(DockTypography.body).foregroundStyle(Color.dockSecondaryText).padding(12)
            }
            canvas
                .frame(
                    minHeight: expandedPresentation ? 400 : min(520, max(100, CGFloat(document.lines.count) * 21 + 20)),
                    maxHeight: expandedPresentation
                        ? .infinity : min(520, max(100, CGFloat(document.lines.count) * 21 + 20)))
            if document.isTruncated {
                Text("Partial diff · search covers loaded content only").font(DockTypography.metadata).foregroundStyle(
                    Color.dockWarning
                ).padding(8)
            }
            if document.missingFinalNewline {
                Text("Missing final newline").font(DockTypography.metadata).foregroundStyle(Color.dockSecondaryText)
                    .padding(8)
            }
            if let contextError = state.contextError {
                Text(contextError).font(DockTypography.body).foregroundStyle(Color.dockWarning).padding(8)
            }
            if !state.notes.isEmpty || state.revisionNotes.error != nil { noteTray }
        }
        .background(Color.dockCanvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onAppear {
            if state.owner == nil { state.owner = owningSession ?? router?.model?.workflowSession }
            state.activeSourceIdentity = sourceIdentity
            state.revisionNotes.register(path: path, identity: sourceIdentity)
        }
        .onChange(of: sourceIdentity) { _, value in
            state.activeSourceIdentity = value
            state.contextPatch = nil
            state.contextLines = 3
            state.contextError = nil
            state.revisionNotes.register(path: path, identity: value)
        }
        .task(id: viewportIdentity) {
            let identity = viewportIdentity
            if state.viewport.activeKey != identity {
                state.viewport.activeKey = identity
                if let saved = WorkspacePresentationStore.shared.loadReferences(
                    DiffViewportMetadata.self, identity: identity), saved.comparison == document.identity
                {
                    state.viewport.restore(saved)
                    state.objectWillChange.send()
                }
            }
            state.viewport.changed = { metadata in
                WorkspacePresentationStore.shared.saveReferences(metadata, identity: identity)
            }
        }
        .onDisappear {
            WorkspacePresentationStore.shared.saveReferences(state.viewport.metadata, identity: viewportIdentity)
        }
        .onChange(of: patch) { _, _ in
            state.contextPatch = nil
            state.contextLines = 3
            state.contextError = nil
        }
        .sheet(isPresented: $expanded) { expandedContent.modifier(ReviewSheetContext()) }
        .sheet(
            isPresented: Binding(
                get: {
                    state.pendingNote != nil && (expandedPresentation || (expandedRouter?.content == nil && !expanded))
                }, set: { if !$0 { state.cancelNote() } })
        ) {
            RevisionNoteEditor(state: state)
        }
    }

    private var expandedContent: some View {
        SharedDiffView(
            patch: patch, path: path, preferredSplit: preferredSplit, wraps: wraps, wordDiffs: wordDiffs,
            onComment: onComment, contextLoader: contextLoader, projectPath: projectPath, reveal: reveal,
            expandedPresentation: true, owningSession: owningSession, comparison: comparison, state: state)
    }
    private var toolbarStyle: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    private func toolbar(isExpanded: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                reviewControls
                Spacer(minLength: 0)
                expandControl(isExpanded: isExpanded)
            }
            DockChipFlow(spacing: 8) {
                reviewControls
                expandControl(isExpanded: isExpanded)
            }
        }.font(DockTypography.body)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
    }
    @ViewBuilder private var reviewControls: some View {
        HStack(spacing: 2) {
            DockTabButton(title: "Unified", isSelected: !canSplit || !(state.splitOverride ?? preferredSplit)) {
                state.splitOverride = false
            }
            DockTabButton(title: "Split", isSelected: canSplit && (state.splitOverride ?? preferredSplit)) {
                state.splitOverride = true
            }
            .disabled(!canSplit)
            .help(!document.supportsSplitView ? "This diff has only one side to display" : canSplit ? "Compare before and after side by side" : "Widen the review to compare side by side")
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Diff layout")
        Color.dockBorderLight.frame(width: DockLayout.hairline, height: 18)
        DockIconButton(icon: .textAlignLeft, label: "Wrap long lines", isProminent: state.wrapsOverride ?? wraps, style: toolbarStyle) {
            state.wrapsOverride = !(state.wrapsOverride ?? wraps)
        }
        .accessibilityValue((state.wrapsOverride ?? wraps) ? "On" : "Off")
        DockIconButton(icon: .magnifyingGlass, label: "Find in diff", style: toolbarStyle) {
            state.findRequest += 1
        }
        if let contextLoader {
            DockIconButton(icon: .rowsPlusTop, label: state.contextLines >= 200 ? "Context limit reached" : "Load more context", isBusy: state.loadingContext, style: toolbarStyle) {
                state.loadingContext = true
                let count = min(200, state.contextLines + 20)
                let captured = sourceIdentity
                Task { @MainActor in
                    defer { state.loadingContext = false }
                    do {
                        let loaded = try await contextLoader(count)
                        guard state.activeSourceIdentity == captured else { return }
                        state.contextPatch = loaded
                        state.contextLines = count
                        state.contextError = nil
                    } catch { state.contextError = error.localizedDescription }
                }
            }.disabled(state.loadingContext || state.contextLines >= 200)
        }
    }
    @ViewBuilder private func expandControl(isExpanded: Bool) -> some View {
        if !isExpanded {
            DockIconButton(icon: .arrowsOutSimple, label: "Expand review", style: toolbarStyle) {
                if expandedRouter?.present(expandedContent) != true { expanded = true }
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            NativeDiffCanvas(
                document: document, split: (state.splitOverride ?? preferredSplit) && geometry.size.width >= 680,
                wraps: state.wrapsOverride ?? wraps, wordDiffs: wordDiffs, findRequest: state.findRequest,
                reveal: reveal, viewport: state.viewport,
                onNote: { selection in
                    state.beginNote(
                        selection: selection, documentID: sourceIdentity, path: path, comparison: comparison)
                }, onComment: commentAction
            ).clipped()
        }
    }

    private var commentAction: ((DiffLine) -> Void)? {
        guard let onComment else { return nil }
        let captured = sourceIdentity
        return { line in
            guard state.activeSourceIdentity == captured else {
                state.contextError = "The comparison changed. Select a line in the refreshed diff before commenting."
                return
            }
            onComment(line)
        }
    }

    private var noteTray: some View {
        RevisionNotesTray(state: state, canSend: router?.model != nil) {
            guard let router else { return }
            let body = state.revisionNotes.prompt
            router.attach(
                ChatContext(
                    id: UUID().uuidString, title: "Revision notes",
                    body:
                        "Please revise the selected code using these review notes.\nRepository: "
                        + (comparison?.repository ?? projectPath ?? "Captured comparison") + "\n\n" + body,
                    projectPath: projectPath), to: state.owner)
            state.notes = []
        }
    }
}
