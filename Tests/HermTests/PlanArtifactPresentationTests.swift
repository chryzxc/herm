import Foundation
import Testing

@testable import Herm

struct PlanArtifactPresentationTests {
    @Test func extractsOutlineTasksAcceptanceAndDependencySummary() {
        let document = makeDocument(
            """
            # Control Tower
            ## Phase P1
            ### Task P1.1: Read plans
            Acceptance: AC-09
            ```text
            P1 -> P2
            ```
            """)
        let presentation = PlanArtifactPresentation.make(document: document)
        #expect(presentation.title == "Control Tower")
        #expect(presentation.headings.map(\.title) == ["Control Tower", "Phase P1", "Task P1.1: Read plans"])
        #expect(presentation.tasks.first?.label == "P1.1")
        #expect(presentation.acceptanceIDs == ["AC-09"])
        #expect(presentation.dependencySummary == "P1 -> P2")
    }

    @Test func malformedMarkdownAndDuplicateHeadingsRemainDeterministic() {
        let document = makeDocument("## Same\n## Same\nplain text")
        let presentation = PlanArtifactPresentation.make(document: document)
        #expect(presentation.headings.map(\.line) == [1, 2])
        #expect(presentation.headings.map(\.anchor) == ["same", "same"])
        #expect(presentation.tasks.isEmpty)
    }

    @Test func staleCommentCountUsesCanonicalHash() {
        let document = makeDocument("# Plan")
        let comments = [
            PlanReviewComment(
                id: UUID(), planPath: "plan.md", planSHA256: "old", anchor: nil, body: "stale", createdAt: .now),
            PlanReviewComment(
                id: UUID(), planPath: "plan.md", planSHA256: document.sha256!, anchor: nil, body: "current",
                createdAt: .now),
        ]
        #expect(PlanArtifactPresentation.make(document: document, comments: comments).staleCommentCount == 1)
    }

    private func makeDocument(_ contents: String) -> PlanArtifactDocument {
        PlanArtifactDocument(
            summary: PlanArtifactSummary(
                relativePath: "plan.md",
                title: contents.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map {
                    String($0.dropFirst(2))
                } ?? "plan", modifiedAt: nil, byteCount: contents.utf8.count, sha256: "hash", state: .available),
            contents: contents)
    }
}
