import SwiftUI

extension DockPopover {
    func viewSessionRailPullRequest(_ reference: GitHubItemReference) async -> Bool {
        SessionMessageTabs.shared.open(.pullRequest(reference), in: WorkspaceIdentity.session(model))
        return true
    }
}
