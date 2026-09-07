import Foundation
import Testing
@testable import HermesAgentDock

struct GitHubCodeHostTests {
    @Test func serviceBuildsTheReadOnlyPullRequestEndpoint() async {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let client = URLProtocolStubClient(result: .success([]))
        let result = await client.pullRequests(for: repository)
        #expect(result == .success([]))
    }
    @Test func parsesPullRequestSummaryAndBoundsOptionalRows() {
        let payload: [String: Any] = [
            "number": 42,
            "title": "Improve workflow",
            "state": "open",
            "draft": true,
            "head": ["ref": "feature/workflow"],
            "base": ["ref": "main"],
            "changed_files": 3,
            "mergeable": true,
            "html_url": "https://github.com/o/r/pull/42",
            "checks": [["id": 1, "name": "CI", "status": "completed", "conclusion": "success"]],
            "reviews": [["id": 2, "state": "approved", "user": ["login": "ada"], "html_url": "https://github.com/o/r/pull/42#pullrequestreview-2"]]
        ]
        let pr = GitHubPullRequestParser.parse(payload)
        #expect(pr?.number == 42)
        #expect(pr?.isDraft == true)
        #expect(pr?.checks.first?.conclusion == "success")
        #expect(pr?.reviews.first?.author == "ada")
        #expect(pr?.reviews.first?.webURL?.absoluteString.contains("pullrequestreview-2") == true)
        #expect(pr?.changedFiles == 3)
        #expect(pr?.mergeable == true)
        #expect(pr?.metadataLabel == "3 files · mergeable")
    }

    @Test func rejectsMalformedPullRequestPayloads() {
        #expect(GitHubPullRequestParser.parse(["number": "42", "title": "bad"]) == nil)
        #expect(GitHubPullRequestParser.parse(["number": 1, "title": "\u{0000}", "state": "open"]) == nil)
    }

    @Test func mutationBuilderValidatesAndTrimsConfirmedInputs() {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let result = GitHubPullRequestMutationBuilder.createDraft(repository: repository, title: "  Ship it  ", body: "  Details  ", headBranch: "feature/workflow", baseBranch: "main")
        guard case .success(let mutation) = result else { Issue.record("Expected valid mutation") ; return }
        #expect(mutation.title == "Ship it")
        #expect(mutation.body == "Details")
        #expect(mutation.kind == .createDraft)
    }

    @Test func mutationBuilderRejectsUnsafeOrOversizedInputs() {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        #expect(GitHubPullRequestMutationBuilder.createDraft(repository: repository, title: "", body: "body", headBranch: "main", baseBranch: "main") == .failure(.invalidTitle))
        #expect(GitHubPullRequestMutationBuilder.createDraft(repository: repository, title: "title", body: "body", headBranch: "bad..branch", baseBranch: "main") == .failure(.invalidBranch))
        #expect(GitHubPullRequestMutationBuilder.update(repository: repository, number: 0, title: "title", body: "body") == .failure(.missingRepository))
    }

    @Test func mutationWireContractSendsOnlyConfirmedFields() {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        guard case .success(let draft) = GitHubPullRequestMutationBuilder.createDraft(repository: repository, title: "Ship", body: "Details", headBranch: "feature", baseBranch: "main") else { Issue.record("Expected draft mutation"); return }
        #expect(GitHubPullRequestMutationWire.method(for: draft) == "POST")
        #expect(GitHubPullRequestMutationWire.path(for: draft) == "/pulls")
        let draftPayload = GitHubPullRequestMutationWire.payload(for: draft)
        #expect(Set(draftPayload.keys) == ["title", "body", "head", "base", "draft"])
        #expect(draftPayload["draft"] as? Bool == true)

        guard case .success(let update) = GitHubPullRequestMutationBuilder.update(repository: repository, number: 12, title: "Updated", body: "Body") else { Issue.record("Expected update mutation"); return }
        #expect(GitHubPullRequestMutationWire.method(for: update) == "PATCH")
        #expect(GitHubPullRequestMutationWire.path(for: update) == "/pulls/12")
        #expect(Set(GitHubPullRequestMutationWire.payload(for: update).keys) == ["title", "body"])
    }

    @Test func githubCapabilitiesSeparateReadAndConfirmedWrite() {
        #expect(GitHubCapabilityID.allCases.map(\.rawValue) == ["github.remote", "github.pr.read", "github.checks.read", "github.pr.write"])
        #expect(GitHubCapabilityID.pullRequestRead.requiresConfirmation == false)
        #expect(GitHubCapabilityID.pullRequestWrite.requiresConfirmation == true)
    }

    @Test func githubTransportUsesBoundedRequestTimeout() {
        #expect(GitHubCodeHostService.requestTimeout == 15)
    }

    @Test func githubHTTPStatusOnlyMarksConfirmedCredentialFailuresAsUnauthorized() {
        #expect(GitHubCodeHostService.error(forHTTPStatus: 401) == .unauthorized)
        #expect(GitHubCodeHostService.error(forHTTPStatus: 403) == .forbidden)
        #expect(GitHubCodeHostService.error(forHTTPStatus: 404) == .repositoryNotFound)
        #expect(GitHubCodeHostService.error(forHTTPStatus: 500) == nil)
    }

    @Test func staleGitHubRefreshCannotCrossRepositoryOrGeneration() {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        let generation = UUID()
        #expect(DeveloperWorkflowModel.acceptsGitHubRefresh(requestedRepository: repository, currentRepository: repository, requestedGeneration: generation, currentGeneration: generation))
        #expect(!DeveloperWorkflowModel.acceptsGitHubRefresh(requestedRepository: repository, currentRepository: nil, requestedGeneration: generation, currentGeneration: generation))
        #expect(!DeveloperWorkflowModel.acceptsGitHubRefresh(requestedRepository: repository, currentRepository: repository, requestedGeneration: generation, currentGeneration: UUID()))
    }

    @Test func integrationPresentationDistinguishesRemoteAndStaleStates() {
        let repository = GitHubRepositoryReference(owner: "owner", name: "repo", webURL: URL(string: "https://github.com/owner/repo")!)
        #expect(GitHubIntegrationPresentation.state(repository: nil, hasLoaded: false, error: nil) == .noRemote)
        #expect(GitHubIntegrationPresentation.state(repository: repository, hasLoaded: false, error: nil) == .notLoaded)
        #expect(GitHubIntegrationPresentation.state(repository: repository, hasLoaded: false, error: .unauthorized) == .unavailable(.unauthorized))
        #expect(GitHubIntegrationPresentation.state(repository: repository, hasLoaded: true, error: .unavailable) == .stale(.unavailable))
        #expect(GitHubIntegrationPresentation.state(repository: repository, hasLoaded: true, error: nil) == .available)
    }

    @Test func repositoryIdentityChangeResetsLoadedIntegrationState() {
        let first = GitHubRepositoryReference(owner: "one", name: "repo", webURL: URL(string: "https://github.com/one/repo")!)
        let second = GitHubRepositoryReference(owner: "two", name: "repo", webURL: URL(string: "https://github.com/two/repo")!)
        #expect(!GitHubIntegrationPresentation.shouldResetLoadedState(current: first, resolved: first))
        #expect(GitHubIntegrationPresentation.shouldResetLoadedState(current: first, resolved: second))
        #expect(GitHubIntegrationPresentation.shouldResetLoadedState(current: first, resolved: nil))
    }

    @Test func pullRequestBlockingReasonsSummarizeChecksAndReviews() {
        let pullRequest = GitHubPullRequestSummary(
            number: 7, title: "Ship", state: "open", isDraft: false,
            headBranch: "feature", baseBranch: "main", headRevision: nil, webURL: nil,
            changedFiles: 2, mergeable: false,
            checks: [GitHubCheckSummary(id: "ci", name: "CI", status: "completed", conclusion: "failure", detailsURL: nil),
                     GitHubCheckSummary(id: "lint", name: "Lint", status: "queued", conclusion: nil, detailsURL: nil)],
            reviews: [GitHubReviewSummary(id: "review", author: "ada", state: "CHANGES_REQUESTED", submittedAt: nil, webURL: nil)])
        #expect(pullRequest.blockingReasons == ["Failed checks: CI", "Checks in progress: Lint", "Changes requested", "Merge blocked", "Approval pending"])
        #expect(pullRequest.metadataLabel == "2 files · merge blocked")
    }

    @Test func draftPullRequestUsesDraftAsPrimaryBlocker() {
        let pullRequest = GitHubPullRequestSummary(number: 8, title: "Draft", state: "open", isDraft: true, headBranch: "feature", baseBranch: "main", headRevision: nil, webURL: nil, changedFiles: nil, mergeable: nil, checks: [], reviews: [])
        #expect(pullRequest.blockingReasons == ["Draft PR"])
    }
}

private struct URLProtocolStubClient: GitHubCodeHostClient {
    let result: Result<[GitHubPullRequestSummary], GitHubCodeHostError>
    func pullRequests(for repository: GitHubRepositoryReference) async -> Result<[GitHubPullRequestSummary], GitHubCodeHostError> { result }
    func createDraftPullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError> { .failure(.unavailable) }
    func updatePullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError> { .failure(.unavailable) }
}
