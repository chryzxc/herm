import Foundation
import SwiftUI
import Testing

@testable import Herm

struct PullRequestPresentationTests {
    private func record() -> PullRequestRecord {
        PullRequestCenterAPI().parse(
            [
                "number": 1, "title": "Fixture", "head": ["ref": "feature", "sha": String(repeating: "a", count: 40)],
                "base": ["ref": "main", "sha": String(repeating: "b", count: 40)],
            ], repository: GitHubReferenceParser.repository("owner/repo")!, localPath: "")!
    }

    @Test(arguments: ["clean", "draft", "failing", "unknown", "conflicted", "closed", "merged"])
    func conflictActionsRequireAnOpenConflictedSnapshot(state: String) {
        var pr = record()
        pr.mergeability = .mergeable
        switch state {
        case "draft": pr.isDraft = true
        case "failing":
            pr.mergeState = "UNSTABLE"
            pr.checks = [.init(id: "1", name: "Tests", status: "completed", conclusion: "failure", detailsURL: nil)]
        case "unknown": pr.mergeability = .unknown
        case "conflicted": pr.mergeability = .conflicting
        case "closed":
            pr.state = "closed"
            pr.mergeability = .conflicting
        case "merged":
            pr.state = "closed"
            pr.mergedAt = .now
            pr.mergeability = .conflicting
        default: break
        }
        #expect(pr.canAnalyzeConflicts == (state == "conflicted"))
        if state == "conflicted" {
            pr.baseRevision = nil
            #expect(!pr.canAnalyzeConflicts)
        }
    }

    @Test func lifecycleIconsStayIndependentOfReadiness() {
        var pr = record()
        #expect(pr.presentationIcon == .gitPullRequest)
        pr.checks = [.init(id: "1", name: "Build", status: "completed", conclusion: "failure", detailsURL: nil)]
        #expect(pr.presentationIcon == .gitPullRequest)
        pr.isDraft = true
        #expect(pr.presentationIcon == .pencilSimple)
        pr.state = "closed"
        #expect(pr.presentationIcon == .xCircle)
        pr.mergedAt = .now
        #expect(pr.presentationIcon == .gitMerge)
    }

    @Test func lifecycleAndReadinessHaveSeparateColors() {
        var pr = record()
        #expect(pr.presentationColor == Color.dockSuccess)
        #expect(pr.readinessColor == Color.dockSecondaryText)
        pr.isDraft = true
        #expect(pr.presentationColor == Color.dockSecondaryText)
        #expect(pr.readinessColor == Color.dockSecondaryText)
        pr.mergeability = .conflicting
        #expect(pr.readinessLabel == "Conflicts")
        #expect(pr.presentationColor == Color.dockSecondaryText)
        #expect(pr.readinessColor == Color.dockWarning)
        pr.isDraft = false
        pr.mergeability = .mergeable
        pr.checks = [.init(id: "1", name: "Tests", status: "completed", conclusion: "failure", detailsURL: nil)]
        #expect(pr.presentationColor == Color.dockSuccess)
        #expect(pr.readinessColor == Color.dockDestructive)
        pr.state = "closed"
        #expect(pr.presentationColor == Color.dockDestructive)
        #expect(pr.readinessColor == Color.dockDestructive)
        pr.mergedAt = .now
        #expect(pr.presentationColor == Color.dockMerged)
        #expect(pr.readinessColor == Color.dockMerged)
    }

    @Test func readinessDistinguishesReviewWorkFromWarningsAndUnknowns() {
        var pr = record()
        pr.checksAvailable = true
        pr.reviewDecision = "CHANGES_REQUESTED"
        #expect(pr.readinessColor == DockAccentColor.pink.color)
        #expect(pr.reviewColor == DockAccentColor.pink.color)
        pr.reviewDecision = "REVIEW_REQUIRED"
        #expect(pr.readinessColor == DockCategoryTone.review.color)
        #expect(pr.reviewColor == DockCategoryTone.review.color)
        pr.reviewDecision = nil
        #expect(pr.readinessLabel == "No checks")
        #expect(pr.readinessColor == Color.dockSecondaryText)
        pr.checks = [.init(id: "1", name: "Tests", status: "completed", conclusion: "success", detailsURL: nil)]
        #expect(pr.readinessColor == Color.dockSuccess)
    }

    @Test func changeCategoriesDoNotUseWarningOrInteractionColors() {
        #expect(PullRequestChangeCategory.docs.color == DockAccentColor.amber.color)
        #expect(PullRequestChangeCategory.config.color == DockAccentColor.cyan.color)
    }

    @Test func lifecycleMenusOfferOnlyApplicableTransitions() {
        var pr = record()
        #expect(pr.availableStatusActions == [.draft, .closed])
        pr.isDraft = true
        #expect(pr.availableStatusActions == [.readyForReview, .closed])
        pr.state = "closed"
        #expect(pr.availableStatusActions == [.reopened])
        pr.mergedAt = .now
        #expect(pr.availableStatusActions.isEmpty)
    }

    @Test func checksSummarySeparatesMissingCoverageFromNoChecksAndOmitsZeroCounts() {
        var pr = record()
        #expect(pr.checksSummary == "Check status incomplete")
        pr.checksAvailable = true
        #expect(pr.checksSummary == "No checks reported")
        pr.checks = [.init(id: "1", name: "Tests", status: "completed", conclusion: "failure", detailsURL: nil)]
        #expect(pr.checksSummary == "1 failed")
        pr.checksAvailable = false
        #expect(pr.checksSummary == "1 failed · Check status incomplete")
    }

    @Test func activityCountIncludesReviewsWithoutPhantomItemsOrRepeatedActor() {
        var pr = record()
        #expect(pr.activityItems(comments: [], commits: [], events: []).isEmpty)
        pr.reviews = [
            .init(
                id: "review", author: "ada", state: "APPROVED", submittedAt: Date(timeIntervalSince1970: 2), webURL: nil
            )
        ]
        let event = PullRequestEvent(
            id: "event", kind: "labeled", actor: "ada", detail: "bug", createdAt: Date(timeIntervalSince1970: 1))
        let items = pr.activityItems(comments: [], commits: [], events: [event])
        #expect(items.count == 2)
        #expect(items[0].summary == "added the bug label")
        #expect(items[0].author == "ada")
        #expect(items[1].id == "review:review")
    }
}
