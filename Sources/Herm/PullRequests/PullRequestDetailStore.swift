import Combine
import Foundation

/// Feature detail state is shared by app hosts; list scope and selection stay in each center.
@MainActor
final class PullRequestDetailStore: ObservableObject {
    static let shared = PullRequestDetailStore()
    @Published var records: [String: PullRequestRecord] = [:]
    @Published var files: [String: [PullRequestFile]] = [:]
    @Published var fileRevisions: [String: String] = [:]
    @Published var comments: [String: [PullRequestComment]] = [:]
    @Published var commits: [String: [PullRequestCommit]] = [:]
    @Published var events: [String: [PullRequestEvent]] = [:]
    @Published var drafts: [String: String] = [:]
    var reviews: [String: PullRequestReviewModel] = [:]
}

extension PullRequestRecord {
    var diffRevision: String? {
        guard let headRevision, let baseRevision else { return nil }
        return "\(baseRevision):\(headRevision)"
    }
}
