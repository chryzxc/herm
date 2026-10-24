import Foundation

struct PullRequestCommitDiffTarget: Identifiable {
    let repository: GitHubRepositoryReference
    let commit: PullRequestCommit
    var id: String { repository.id + ":" + commit.id }
}

struct PullRequestCommitDiffService {
    let client: GitHubClient

    func load(repository: GitHubRepositoryReference, sha: String) async throws -> GitHubPage<PullRequestFile> {
        guard [40, 64].contains(sha.count), sha.allSatisfy(\.isHexDigit) else {
            throw GitHubRequestError.malformed
        }
        let page = try await client.pages(repository.apiRepositoryPath + "/commits/" + sha, key: "files")
        guard let files = PullRequestCenterAPI.parseFilesPayload(page.rows), files.count == page.rows.count else {
            throw GitHubRequestError.malformed
        }
        return GitHubPage(items: files, coverage: page.coverage)
    }
}
