import AppKit
import SwiftUI

struct PlanArtifactsInspectorView: View {
    let plansRoot: URL

    @State private var artifacts: [PlanArtifactSummary] = []
    @State private var selectedPath: String?
    @State private var document: PlanArtifactDocument?
    @State private var presentation: PlanArtifactPresentation?
    @State private var comments: [PlanReviewComment] = []
    @State private var artifactQuery = ""
    @State private var commentDraft = ""
    @State private var selectedAnnotationText: String?
    @State private var revisionDraft: PlanRevisionDraft?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var refreshGeneration = UUID()
    @State private var isOutlineExpanded = false

    var body: some View {
        Group {
            content
        }
        .background(Color.dockCanvas)
        .task(id: plansRoot.path) { await refresh() }
        .onDisappear { refreshGeneration = UUID() }
    }

    @ViewBuilder
    private var content: some View {
        if artifacts.isEmpty, errorMessage == nil {
            emptyState(title: "No plan artifacts", detail: "No Markdown files were found under \(plansRoot.path).")
        } else {
            HStack(spacing: 0) {
                artifactList
                    .frame(width: 288)
                Divider().overlay(Color.dockBorderLight)
                detail
            }
        }
    }

    private var artifactList: some View {
        VStack(spacing: 0) {
            libraryHeader

            Divider().overlay(Color.dockBorderLight)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredArtifacts) { artifact in
                        Button {
                            selectedPath = artifact.relativePath
                            clearAnnotationSelection()
                            Task { await loadSelected() }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Circle()
                                        .fill(artifact.state == .available ? Color.dockAccent : Color.dockWarning)
                                        .frame(width: 6, height: 6)
                                    Text(artifact.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.dockPrimaryText)
                                        .lineLimit(2)
                                }
                                Text(artifact.relativePath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.dockSecondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(artifact.sha256.map { "REV \(String($0.prefix(8)))" } ?? "UNAVAILABLE")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.dockMetadataText)
                            }
                            .dockListRow(isHighlighted: selectedPath == artifact.relativePath)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Plan artifact \(artifact.title)")
                    }
                }
                .padding(8)
            }

            Divider().overlay(Color.dockBorderLight)
            HStack(spacing: 6) {
                DockIcon(.fileText)
                    .font(.system(size: 10))
                Text("\(filteredArtifacts.count) shown")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(Color.dockMetadataText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .background(Color.dockSurface2.opacity(0.55))
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PLAN LIBRARY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                        .tracking(0.8)
                    Text("Artifacts")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Text("\(artifacts.count) canonical \(artifacts.count == 1 ? "document" : "documents")")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dockSecondaryText)
                }
                Spacer(minLength: 4)
                Button { Task { await refresh() } } label: {
                    DockIcon(.arrowsClockwise)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .accessibilityLabel("Refresh artifacts")
            }
            TextField("Filter documents", text: $artifactQuery)
                .textFieldStyle(.dockGlass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var filteredArtifacts: [PlanArtifactSummary] {
        let query = artifactQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return artifacts }
        return artifacts.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.relativePath.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let errorMessage {
            emptyState(title: "Artifact unavailable", detail: errorMessage)
        } else if let document, let presentation {
            VStack(alignment: .leading, spacing: 0) {
                header(document: document)
                Divider().overlay(Color.dockBorderLight)
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            documentUtilities(presentation)
                                .padding(.top, 22)

                            MarkdownMessageView(markdown: document.contents)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 28)
                                .background {
                                    DocumentSelectionMonitor(documentContents: document.contents) { selection in
                                        updateAnnotationSelection(selection)
                                    }
                                }

                            if let revisionDraft {
                                revisionPanel(revisionDraft)
                                    .padding(.top, 28)
                            }
                        }
                        .frame(maxWidth: 780, alignment: .leading)
                        .padding(.horizontal, 36)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    if let selectedAnnotationText {
                        Divider().overlay(Color.dockBorderLight)
                        selectionAnnotationPanel(selectedText: selectedAnnotationText, document: document)
                            .frame(width: 304)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .background(Color.dockCanvas)
        } else {
            emptyState(title: "Select a plan", detail: "Choose a plan artifact to inspect its outline and review history.")
        }
    }

    private func header(document: PlanArtifactDocument) -> some View {
        HStack(spacing: 14) {
            DockIcon(.fileText)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.dockAccent)
                .frame(width: 36, height: 36)
                .background(Color.dockAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(document.summary.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Text(document.relativePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button {
                revisionDraft = PlanArtifactService(plansRoot: plansRoot).revisionDraft(for: document)
            } label: {
                DockIconLabel("New revision", icon: .plus)
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.dockAccent)
            .accessibilityLabel("Create revision without overwriting canonical plan")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 15)
    }

    private func documentUtilities(_ presentation: PlanArtifactPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                DockIconLabel("Canonical artifact", icon: .sealCheck)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dockAccent)
                Text("SHA \(presentation.summary.sha256.map { String($0.prefix(12)) } ?? "unavailable")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                if !presentation.acceptanceIDs.isEmpty {
                    Text("· \(presentation.acceptanceIDs.count) acceptance \(presentation.acceptanceIDs.count == 1 ? "item" : "items")")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.dockSecondaryText)
                }
            }

            DisclosureGroup(isExpanded: $isOutlineExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(presentation.headings.prefix(12)) { heading in
                        Text(heading.title)
                            .font(.system(size: 11))
                            .foregroundStyle(heading.level <= 2 ? Color.dockPrimaryText : Color.dockSecondaryText)
                            .padding(.leading, CGFloat(max(0, heading.level - 1) * 12))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 10)
            } label: {
                DockIconLabel("Document outline · \(presentation.headings.count)", icon: .listBullets)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionAnnotationPanel(selectedText: String, document: PlanArtifactDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    DockIconLabel("Add annotation", icon: .listPlus)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dockPrimaryText)
                    Spacer()
                    Button(action: clearAnnotationSelection) {
                        DockIcon(.x)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.dockSecondaryText)
                    .accessibilityLabel("Cancel annotation")
                }
                Text("Selected text")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .tracking(0.6)
                Text(selectedText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(5)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.dockCanvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(18)

            Divider().overlay(Color.dockBorderLight)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Write a comment…", text: $commentDraft, axis: .vertical)
                    .textFieldStyle(.dockGlass)
                    .lineLimit(4...7)
                HStack {
                    if let presentation, presentation.staleCommentCount > 0 {
                        Text("\(presentation.staleCommentCount) stale")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.dockWarning)
                    }
                    Spacer()
                    Button(isSaving ? "Saving…" : "Save comment") { saveComment(document) }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .padding(18)

            let matchingComments = comments.filter { $0.anchor == selectedText }
            if !matchingComments.isEmpty {
                Divider().overlay(Color.dockBorderLight)
                VStack(alignment: .leading, spacing: 10) {
                    Text("EXISTING ANNOTATIONS · \(matchingComments.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.dockMetadataText)
                    ForEach(matchingComments.sorted { $0.createdAt > $1.createdAt }) { comment in
                        Text(comment.body)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dockPrimaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            Spacer(minLength: 0)
        }
        .background(Color.dockSurface2.opacity(0.5))
    }

    private func revisionPanel(_ draft: PlanRevisionDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DockIconLabel("Revision Draft · \(draft.relativePath)", icon: .fileText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.dockAccent)
            Text("Saving creates a new plan and preserves the canonical source.")
                .font(.system(size: 10))
                .foregroundStyle(Color.dockSecondaryText)
            Button("Save New Revision") { saveRevision(draft) }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
        }
        .dockCard(padding: 12)
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.dockPrimaryText)
            Text(detail).font(.system(size: 10)).foregroundStyle(Color.dockSecondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var repositoryPathForCurrentDocument: String { plansRoot.path }

    private func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        let service = PlanArtifactService(plansRoot: plansRoot)
        let values = service.list()
        guard generation == refreshGeneration else { return }
        artifacts = values
        if selectedPath == nil || !values.contains(where: { $0.relativePath == selectedPath }) { selectedPath = values.first?.relativePath }
        await loadSelected()
    }

    private func loadSelected() async {
        guard let selectedPath else { return }
        let service = PlanArtifactService(plansRoot: plansRoot)
        do {
            let loaded = try service.load(relativePath: selectedPath)
            let loadedComments = try service.comments(for: loaded)
            document = loaded
            comments = loadedComments
            presentation = PlanArtifactPresentation.make(document: loaded, comments: loadedComments)
            clearAnnotationSelection()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription; document = nil; presentation = nil }
    }

    private func saveComment(_ document: PlanArtifactDocument) {
        guard let selectedAnnotationText else { return }
        isSaving = true
        let service = PlanArtifactService(plansRoot: plansRoot)
        let comment = PlanReviewComment(id: UUID(), planPath: document.relativePath, planSHA256: document.sha256 ?? "", anchor: selectedAnnotationText, body: commentDraft, createdAt: .now)
        do {
            _ = try service.saveComment(comment)
            let reloadedComments = try service.comments(for: document)
            comments = reloadedComments
            presentation = PlanArtifactPresentation.make(document: document, comments: reloadedComments)
            clearAnnotationSelection()
        } catch { errorMessage = error.localizedDescription }
        isSaving = false
    }

    private func updateAnnotationSelection(_ selection: String?) {
        guard let selection else {
            if commentDraft.isEmpty { selectedAnnotationText = nil }
            return
        }
        let normalized = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        selectedAnnotationText = String(normalized.prefix(500))
    }

    private func clearAnnotationSelection() {
        selectedAnnotationText = nil
        commentDraft = ""
    }

    private func saveRevision(_ draft: PlanRevisionDraft) {
        do {
            _ = try PlanArtifactService(plansRoot: plansRoot).saveRevision(draft)
            revisionDraft = nil
            Task { await refresh() }
        } catch { errorMessage = error.localizedDescription }
    }
}

/// Observes native AppKit selection changes produced by SwiftUI's selectable
/// Markdown text. It only forwards selected text that appears in the current
/// artifact; typing in the comment field cannot open or replace an anchor.
private struct DocumentSelectionMonitor: NSViewRepresentable {
    let documentContents: String
    let onSelection: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(documentContents: documentContents, onSelection: onSelection) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.documentContents = documentContents
        context.coordinator.onSelection = onSelection
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var documentContents: String
        var onSelection: (String?) -> Void
        private var eventMonitor: Any?

        init(documentContents: String, onSelection: @escaping (String?) -> Void) {
            self.documentContents = documentContents
            self.onSelection = onSelection
        }

        func start() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                self?.captureSelection()
                return event
            }
        }

        func stop() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        private func captureSelection() {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            guard selectedRange.length > 0,
                  let range = Range(selectedRange, in: textView.string),
                  let selected = String(textView.string[range]).nilIfBlank,
                  documentContents.contains(selected) else { return }
            onSelection(selected)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
