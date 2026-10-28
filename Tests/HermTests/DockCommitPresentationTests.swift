import Testing

@testable import Herm

struct DockCommitPresentationTests {
    private let revision = String(repeating: "a", count: 40)

    private func check(_ status: String, _ conclusion: String?) -> GitHubCheckSummary {
        GitHubCheckSummary(id: status, name: status, status: status, conclusion: conclusion, detailsURL: nil)
    }

    @Test func statusMatrixRejectsAbsentOrMismatchedEvidence() {
        let success = check("completed", "success")
        func status(
            _ checks: [GitHubCheckSummary], complete: Bool = true, repo: String = "owner/repo",
            sha: String? = nil, target: String? = nil
        ) -> DockCommitCheckStatus? {
            let evidence = DockCommitCheckEvidence(
                repositoryID: repo, revision: sha ?? revision, checks: checks, isComplete: complete)
            return DockCommitPresentation.checkStatus(
                repositoryID: "owner/repo", revision: target ?? revision, evidence: evidence)
        }
        #expect(status([]) == nil)
        #expect(status([success], repo: "other") == nil)
        #expect(status([success], sha: String(repeating: "b", count: 40)) == nil)
        #expect(status([success], target: String(revision.prefix(7))) == nil)
        #expect(status([success], sha: revision.uppercased()) == .passed)
        #expect(status([success]) == .passed)
        #expect(status([success], complete: false) == .incomplete)
        #expect(status([check("completed", "neutral")]) == .unknown)
        #expect(status([check("completed", "skipped")]) == .unknown)
        #expect(status([check("mystery", nil)]) == .unknown)
        #expect(status([success, check("queued", nil)]) == .running)
        #expect(status([check("queued", nil), check("completed", "failure")]) == .failed)
        #expect(status([check("completed", "failure")], complete: false) == .failed)
        let long = String(repeating: "f", count: 64)
        #expect(status([success], sha: long, target: long) == .passed)
        #expect(
            DockCommitPresentation.checkStatus(repositoryID: "owner/repo", revision: revision, evidence: nil) == nil)
    }

    @Test func preservesSummaryContent() {
        #expect(DockCommitPresentation.summaryParts("abc1234  hello 🌍").hash == "abc1234")
        #expect(DockCommitPresentation.summaryParts("abc1234  hello 🌍").suffix == "  hello 🌍")
        #expect(DockCommitPresentation.summaryParts("xyz hello").hash == nil)
        #expect(DockCommitPresentation.summaryParts("abc hello").hash == nil)
        #expect(DockCommitPresentation.summaryParts("  abc1234 hello").suffix == "  abc1234 hello")
    }

    @Test func diffActionAccessibilityPreservesStatus() {
        let check = check("completed", "failure")
        let evidence = DockCommitCheckEvidence(
            repositoryID: "owner/repo", revision: revision, checks: [check], isComplete: false)
        #expect(
            DockCommitPresentation.diffActionLabel(revision: revision, repositoryID: "owner/repo", evidence: evidence)
                == "Show diff for commit aaaaaaa, Checks failed, Check status incomplete")
        #expect(
            DockCommitPresentation.diffActionLabel(revision: revision, repositoryID: "other/repo", evidence: evidence)
                == "Show diff for commit aaaaaaa")
    }
}
