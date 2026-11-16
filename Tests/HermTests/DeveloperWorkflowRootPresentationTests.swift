import Combine
import Testing

@testable import Herm

@Suite @MainActor
struct DeveloperWorkflowRootPresentationTests {
    @Test func emitsOnlyWhenRootReadFieldsChange() {
        let repository = CurrentValueSubject<RepositorySnapshot, Never>(
            RepositorySnapshot(
                path: "/tmp/project", branch: "main", changedFiles: 0, latestCommit: "a", isGitRepository: true))
        let worktrees = CurrentValueSubject<[RepositoryWorktreeSummary], Never>([])
        let unavailable = CurrentValueSubject<Bool, Never>(false)
        var emissions = 0
        let cancellable = DeveloperWorkflowModel.rootPresentationChanges(
            repository: repository, worktrees: worktrees, worktreesUnavailable: unavailable
        ).sink { emissions += 1 }
        defer { cancellable.cancel() }

        #expect(emissions == 0)
        // Agent file edits churn counts and commits; the root never reads them.
        var churned = repository.value
        churned.changedFiles = 12
        churned.latestCommit = "b"
        repository.send(churned)
        worktrees.send([])
        unavailable.send(false)
        #expect(emissions == 0)

        var moved = churned
        moved.path = "/tmp/other"
        repository.send(moved)
        #expect(emissions == 1)
        unavailable.send(true)
        #expect(emissions == 2)
    }
}
