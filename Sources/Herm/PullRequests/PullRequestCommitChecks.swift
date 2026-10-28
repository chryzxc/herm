import Foundation

extension PullRequestCenterModel {
    func commitCheckEvidence(for repository: GitHubRepositoryReference) -> DockCommitCheckEvidence? {
        guard let record = selected, record.repository.id == repository.id,
            !isRefreshing, !isLoadingDetail(for: record.id), errorMessage == nil,
            filesAreCurrent(for: record), let revision = record.headRevision,
            [40, 64].contains(revision.utf8.count),
            revision.utf8.allSatisfy(DockCommitPresentation.isHex),
            !record.checks.isEmpty
        else { return nil }
        return DockCommitCheckEvidence(
            repositoryID: repository.id, revision: revision, checks: record.checks, isComplete: record.checksAvailable)
    }
}
