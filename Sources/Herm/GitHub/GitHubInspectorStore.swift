import SwiftUI

/// Disposable, session-scoped detail state; global GitHub lists keep their own selection.
@MainActor
final class GitHubInspectorStore: ObservableObject {
    @MainActor
    final class Item {
        let pullRequests: PullRequestCenterModel
        let issues: IssueCenterModel

        init(transport: any GitHubIssueTransport) {
            pullRequests = PullRequestCenterModel(api: PullRequestCenterAPI(transport: transport), details: .shared)
            issues = IssueCenterModel(api: GitHubIssueCenterAPI(transport: transport))
        }
        var reference: GitHubItemReference?
        var generation = UUID()
    }

    @Published private(set) var revision = UUID()
    private let transport: any GitHubIssueTransport

    init(transport: any GitHubIssueTransport = URLSession(configuration: .ephemeral)) {
        self.transport = transport
    }

    private var items: [String: Item] = [:]

    func item(for session: String) -> Item? { items[session] }

    func open(_ reference: GitHubItemReference, session: String) async -> Bool {
        let item = items[session] ?? Item(transport: transport)
        items[session] = item
        let generation = UUID()
        item.generation = generation
        let opened: Bool
        if reference.kind == .pullRequest {
            opened = await item.pullRequests.open(reference)
        } else {
            opened = await item.issues.open(reference)
        }
        guard opened, item.generation == generation, !Task.isCancelled else { return false }
        item.reference = reference
        revision = UUID()
        return true
    }
}
