import SwiftUI

/// Line comments share the review model with the Reviews tab and remain local until submission.
struct PullRequestInlineReview: View {
    @ObservedObject var model: PullRequestReviewModel
    let record: PullRequestRecord
    let document: DiffDocument
    @Binding var target: GitHubInlineCommentTarget?

    private var activeTarget: GitHubInlineCommentTarget? {
        target.flatMap { $0.path == document.path && $0.revision == record.headRevision ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let activeTarget {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Add to review").dockFont(.body, weight: .semibold)
                        Spacer()
                        Text("Line \(activeTarget.line) · \(activeTarget.side == "LEFT" ? "old" : "new")")
                            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
                    }
                    if let source = activeTarget.source(in: document) {
                        ScrollView(.horizontal) {
                            Text(DiffDocument.source(source)).dockFont(.body, weight: .regular, design: .monospaced)
                                .textSelection(.enabled).padding(8)
                        }.background(Color.dockSurface2)
                    }
                    GitHubMarkdownDraft(
                        text: Binding(
                            get: { model.inlineDrafts[activeTarget.id] ?? "" },
                            set: { model.inlineDrafts[activeTarget.id] = $0 }),
                        placeholder: "Leave feedback on this line…", minimumHeight: 80
                    )
                    .frame(height: 128)
                    .disabled(model.busy || model.uncertainSubmission)
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            draftHint
                            Spacer(minLength: 12)
                            editorActions(activeTarget)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            draftHint
                            HStack {
                                Spacer()
                                editorActions(activeTarget)
                            }
                        }
                    }
                }
                .padding(12)
                .id("inline-review:" + document.path)
                .background(Color.dockSurface)
                .overlay(alignment: .top) { Color.dockBorderLight.frame(height: DockLayout.hairline) }
            }
            ForEach(model.pendingComments.filter { $0.target.path == document.path }) { comment in
                PullRequestReviewDraftRow(model: model, record: record, comment: comment) {
                    if model.beginInline(comment.target, record: record) { target = comment.target }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }.dockFont(.body).foregroundStyle(Color.dockPrimaryText)
    }

    private var draftHint: some View {
        Text("Private until you submit the review.")
            .dockFont(.metadata).foregroundStyle(Color.dockSecondaryText)
    }

    private func editorActions(_ target: GitHubInlineCommentTarget) -> some View {
        HStack(spacing: 8) {
            Button("Close") { self.target = nil }.buttonStyle(.dockCompact)
            Button("Save draft") {
                if model.stageInline(target, record: record) { self.target = nil }
            }
            .buttonStyle(.dockPrimary)
            .disabled(
                model.busy || model.uncertainSubmission
                    || (model.inlineDrafts[target.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (model.inlineDrafts[target.id] ?? "").count > 10_000)
        }.fixedSize()
    }
}

struct PullRequestReviewDraftRow: View {
    @ObservedObject var model: PullRequestReviewModel
    let record: PullRequestRecord
    let comment: PendingReviewComment
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(comment.target.locationLabel).dockFont(.body, weight: .semibold)
                        .lineLimit(2).textSelection(.enabled)
                    Text(
                        comment.target.revision == record.headRevision
                            ? "Draft · not published" : "Draft · source revision changed"
                    )
                    .dockFont(.metadata)
                    .foregroundStyle(
                        comment.target.revision == record.headRevision ? Color.dockSecondaryText : Color.dockWarning)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button("Edit", action: onEdit).buttonStyle(.dockCompact)
                        .disabled(comment.target.revision != record.headRevision)
                    Button("Remove") { model.pendingComments.removeAll { $0.id == comment.id } }
                        .buttonStyle(.dockCompact)
                }.disabled(model.busy || model.uncertainSubmission)
            }
            MarkdownMessageView(markdown: comment.body, bodySize: 12)
        }.dockCard(padding: 10)
    }
}
