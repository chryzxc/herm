import SwiftUI

struct PlanArtifactsInspectorView: View {
    let plansRoot: URL

    @State private var artifacts: [PlanArtifactSummary] = []
    @State private var selectedPath: String?
    @State private var document: PlanArtifactDocument?
    @State private var presentation: PlanArtifactPresentation?
    @State private var comments: [PlanReviewComment] = []
    @State private var commentDraft = ""
    @State private var revisionDraft: PlanRevisionDraft?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var refreshGeneration = UUID()
    @State private var isOutlineExpanded = false
    @State private var isReviewExpanded = false

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
                    .frame(width: 244)
                Divider().overlay(Color.dockBorderLight)
                detail
            }
        }
    }

    private var artifactList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PLAN LIBRARY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                    .tracking(0.8)
                Text("Artifacts")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text("\(artifacts.count) Markdown \(artifacts.count == 1 ? "document" : "documents")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            Divider().overlay(Color.dockBorderLight)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(artifacts) { artifact in
                        Button {
                            selectedPath = artifact.relativePath
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
        }
        .background(Color.dockSurface2.opacity(0.55))
    }

    @ViewBuilder
    private var detail: some View {
        if let errorMessage {
            emptyState(title: "Artifact unavailable", detail: errorMessage)
        } else if let document, let presentation {
            VStack(alignment: .leading, spacing: 0) {
                header(document: document)
                Divider().overlay(Color.dockBorderLight)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        documentUtilities(presentation)
                            .padding(.top, 18)

                        MarkdownMessageView(markdown: document.contents)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 24)

                        Divider().overlay(Color.dockBorderLight)
                            .padding(.vertical, 28)

                        reviewPanel(document: document)

                        if let revisionDraft {
                            revisionPanel(revisionDraft)
                                .padding(.top, 18)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .background(Color.dockCanvas)
        } else {
            emptyState(title: "Select a plan", detail: "Choose a plan artifact to inspect its outline and review history.")
        }
    }

    private func header(document: PlanArtifactDocument) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.summary.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                    .lineLimit(1)
                Text(document.relativePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button("New revision") { revisionDraft = PlanArtifactService(plansRoot: plansRoot).revisionDraft(for: document) }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.borderless)
                .foregroundStyle(Color.dockAccent)
                .accessibilityLabel("Create revision without overwriting canonical plan")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func documentUtilities(_ presentation: PlanArtifactPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Canonical artifact", systemImage: "checkmark.seal")
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
                Text("Document outline")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dockSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewPanel(document: PlanArtifactDocument) -> some View {
        DisclosureGroup(isExpanded: $isReviewExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(comment.body)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(comment.anchor.map { "ANCHOR · \($0)" } ?? "GENERAL COMMENT")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(comment.isStale(comparedWith: document.sha256) ? Color.dockWarning : Color.dockMetadataText)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                }
                TextField("Add a review comment…", text: $commentDraft, axis: .vertical)
                    .textFieldStyle(.dockGlass)
                    .lineLimit(2...5)
                HStack {
                    Spacer()
                    Button(isSaving ? "Saving…" : "Save comment") { saveComment(document) }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.dockAccent)
                        .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Label("Review notes", systemImage: "text.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text("\(comments.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dockMetadataText)
                if let presentation, presentation.staleCommentCount > 0 {
                    Text("\(presentation.staleCommentCount) stale")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.dockWarning)
                }
            }
        }
    }

    private func revisionPanel(_ draft: PlanRevisionDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Revision Draft · \(draft.relativePath)", systemImage: "doc.badge.gearshape")
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
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription; document = nil; presentation = nil }
    }

    private func saveComment(_ document: PlanArtifactDocument) {
        isSaving = true
        let service = PlanArtifactService(plansRoot: plansRoot)
        let comment = PlanReviewComment(id: UUID(), planPath: document.relativePath, planSHA256: document.sha256 ?? "", anchor: nil, body: commentDraft, createdAt: .now)
        do {
            _ = try service.saveComment(comment)
            commentDraft = ""
            comments = try service.comments(for: document)
            presentation = PlanArtifactPresentation.make(document: document, comments: comments)
        } catch { errorMessage = error.localizedDescription }
        isSaving = false
    }

    private func saveRevision(_ draft: PlanRevisionDraft) {
        do {
            _ = try PlanArtifactService(plansRoot: plansRoot).saveRevision(draft)
            revisionDraft = nil
            Task { await refresh() }
        } catch { errorMessage = error.localizedDescription }
    }
}
