import Foundation

struct PendingReviewComment: Identifiable {
    let id = UUID()
    let target: GitHubInlineCommentTarget
    let body: String
}
