import SwiftUI

struct PlanArtifactsInspectorView: View {
    let repositoryPath: String?

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

    var body: some View {
        Group {
            if let repositoryPath {
                content(repositoryPath: repositoryPath)
            } else {
                emptyState(title: "No repository context", detail: "Select a session or project with a local repository to browse .hermes/plans.")
            }
        }
        .background(Color.scifiCanvas)
        .task(id: repositoryPath) { await refresh() }
        .onDisappear { refreshGeneration = UUID() }
    }

    @ViewBuilder
    private func content(repositoryPath: String) -> some View {
        if artifacts.isEmpty, errorMessage == nil {
            emptyState(title: "No plan artifacts", detail: "No Markdown files were found under \(repositoryPath)/.hermes/plans.")
        } else {
            HStack(spacing: 0) {
                artifactList
                    .frame(width: 190)
                Divider().overlay(Color.scifiBorderLight)
                detail(repositoryPath: repositoryPath)
            }
        }
    }

    private var artifactList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(artifacts) { artifact in
                    Button {
                        selectedPath = artifact.relativePath
                        Task { await loadSelected() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artifact.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.scifiFg)
                                .lineLimit(2)
                            Text(artifact.relativePath)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.scifiMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 5) {
                                Circle().fill(artifact.state == .available ? Color.scifiAccent : Color.scifiWarning).frame(width: 5, height: 5)
                                Text(artifact.sha256.map { String($0.prefix(8)) } ?? "UNAVAILABLE")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(Color.scifiTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(selectedPath == artifact.relativePath ? Color.scifiAccent.opacity(0.12) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.scifiPress)
                    .accessibilityLabel("Plan artifact \(artifact.title)")
                }
            }
            .padding(10)
        }
        .background(Color.scifiSurface2.opacity(0.45))
    }

    @ViewBuilder
    private func detail(repositoryPath: String) -> some View {
        if let errorMessage {
            emptyState(title: "Artifact unavailable", detail: errorMessage)
        } else if let document, let presentation {
            VStack(alignment: .leading, spacing: 0) {
                header(document: document)
                Divider().overlay(Color.scifiBorderLight)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        outline(presentation)
                        MarkdownMessageView(markdown: document.contents)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        reviewPanel(document: document)
                        ProvenanceInspectorView(presentation: ProvenancePresentation(sessionID: nil, projectID: nil, repositoryPath: repositoryPath, branch: nil, sourceLabel: "CANONICAL PLAN ARTIFACT", verified: true))
                        if let revisionDraft {
                            revisionPanel(revisionDraft)
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color.scifiCanvas)
        } else {
            emptyState(title: "Select a plan", detail: "Choose a plan artifact to inspect its outline and review history.")
        }
    }

    private func header(document: PlanArtifactDocument) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.summary.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.scifiFg)
                    .lineLimit(1)
                Text("CANONICAL · \(document.relativePath)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.scifiMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("SHA-256 \(document.sha256.map { String($0.prefix(16)) } ?? "UNAVAILABLE")")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            }
            Spacer(minLength: 6)
            Button("NEW REVISION") { revisionDraft = PlanArtifactService(projectRoot: URL(fileURLWithPath: repositoryPathForCurrentDocument)).revisionDraft(for: document) }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .buttonStyle(.scifiPress)
                .foregroundStyle(Color.scifiAccent)
                .accessibilityLabel("Create revision without overwriting canonical plan")
        }
        .padding(12)
    }

    private func outline(_ presentation: PlanArtifactPresentation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("OUTLINE", systemImage: "list.bullet.indent")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
            ForEach(presentation.headings.prefix(12)) { heading in
                Text(heading.title)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(heading.level <= 2 ? Color.scifiFg : Color.scifiMuted)
                    .padding(.leading, CGFloat(max(0, heading.level - 1) * 8))
                    .lineLimit(1)
            }
            if !presentation.acceptanceIDs.isEmpty {
                Text("ACCEPTANCE · \(presentation.acceptanceIDs.joined(separator: ", "))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.scifiTertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.scifiSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func reviewPanel(document: PlanArtifactDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("REVIEW COMMENTS", systemImage: "text.bubble")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.scifiAccent)
                Spacer()
                if let presentation, presentation.staleCommentCount > 0 {
                    Text("\(presentation.staleCommentCount) STALE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.scifiWarning)
                }
            }
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.body)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.scifiFg)
                    Text(comment.anchor.map { "ANCHOR · \($0)" } ?? "GENERAL COMMENT")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(comment.isStale(comparedWith: document.sha256) ? Color.scifiWarning : Color.scifiTertiary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.scifiCanvas)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            TextField("Add a review comment…", text: $commentDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .padding(8)
                .background(Color.scifiCanvas)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            HStack {
                Spacer()
                Button(isSaving ? "SAVING…" : "SAVE COMMENT") { saveComment(document) }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .buttonStyle(.scifiPress)
                    .foregroundStyle(Color.scifiAccent)
                    .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(10)
        .background(Color.scifiSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func revisionPanel(_ draft: PlanRevisionDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("REVISION DRAFT · \(draft.relativePath)", systemImage: "doc.badge.gearshape")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.scifiAccent)
            Text("Saving creates a new plan and preserves the canonical source.")
                .font(.system(size: 10))
                .foregroundStyle(Color.scifiMuted)
            Button("SAVE NEW REVISION") { saveRevision(draft) }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .buttonStyle(.scifiPress)
                .foregroundStyle(Color.scifiAccent)
        }
        .padding(10)
        .background(Color.scifiSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.scifiFg)
            Text(detail).font(.system(size: 10)).foregroundStyle(Color.scifiMuted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var repositoryPathForCurrentDocument: String { repositoryPath ?? "" }

    private func refresh() async {
        let generation = UUID()
        refreshGeneration = generation
        guard let repositoryPath else { return }
        let service = PlanArtifactService(projectRoot: URL(fileURLWithPath: repositoryPath))
        let values = service.list()
        guard generation == refreshGeneration else { return }
        artifacts = values
        if selectedPath == nil || !values.contains(where: { $0.relativePath == selectedPath }) { selectedPath = values.first?.relativePath }
        await loadSelected()
    }

    private func loadSelected() async {
        guard let repositoryPath, let selectedPath else { return }
        let service = PlanArtifactService(projectRoot: URL(fileURLWithPath: repositoryPath))
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
        guard let repositoryPath else { return }
        isSaving = true
        let service = PlanArtifactService(projectRoot: URL(fileURLWithPath: repositoryPath))
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
        guard let repositoryPath else { return }
        do {
            _ = try PlanArtifactService(projectRoot: URL(fileURLWithPath: repositoryPath)).saveRevision(draft)
            revisionDraft = nil
            Task { await refresh() }
        } catch { errorMessage = error.localizedDescription }
    }
}
