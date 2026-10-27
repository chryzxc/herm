import SwiftUI

struct GitHubRepositoryCommit: Identifiable, Equatable, Sendable {
    let sha: String
    let title: String
    let author: String?
    let date: Date?
    var id: String { sha }

    static func parse(_ row: [String: Any]) throws -> Self {
        guard let sha = row["sha"] as? String, [40, 64].contains(sha.count),
            sha.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }),
            let commit = row["commit"] as? [String: Any], let message = commit["message"] as? String,
            let title = message.split(whereSeparator: \.isNewline).first, !title.isEmpty
        else { throw GitHubRequestError.malformed }
        let author = commit["author"] as? [String: Any]
        return Self(
            sha: sha, title: String(title),
            author: (row["author"] as? [String: Any])?["login"] as? String ?? author?["name"] as? String,
            date: (author?["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
    }
}

struct GitHubRepositoryRelease: Equatable, Sendable {
    let name: String
    let tag: String
    let publishedAt: Date?
    let draft: Bool
    let prerelease: Bool
    let url: URL

    static func parse(_ row: [String: Any], repository: GitHubRepositoryReference) throws -> Self {
        guard let tag = row["tag_name"] as? String, !tag.isEmpty,
            let draft = row["draft"] as? Bool, let prerelease = row["prerelease"] as? Bool,
            let rawURL = row["html_url"] as? String, let url = URL(string: rawURL),
            url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.port == nil,
            url.path.hasPrefix(repository.webURL.path + "/releases/")
        else { throw GitHubRequestError.malformed }
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? tag, tag: tag,
            publishedAt: (row["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            draft: draft, prerelease: prerelease, url: url)
    }
}

private enum GitHubRepositorySection<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable(String)
}

private struct GitHubRepositoryDetailsService: Sendable {
    let client: GitHubClient

    func commits(_ repository: GitHubRepositorySummary) async -> GitHubRepositorySection<[GitHubRepositoryCommit]> {
        do {
            var query = ["per_page": "5"]
            if let branch = repository.defaultBranch, !branch.isEmpty { query["sha"] = branch }
            guard
                let rows = try await client.request(repository.reference.apiRepositoryPath + "/commits", query: query)
                    as? [[String: Any]]
            else { throw GitHubRequestError.malformed }
            return .available(try rows.map(GitHubRepositoryCommit.parse))
        } catch { return .unavailable(HermesDiagnosticsService.safeSummary(error.localizedDescription)) }
    }

    func events(_ repository: GitHubRepositorySummary) async -> GitHubRepositorySection<[GitHubRepositoryEvent]> {
        do {
            guard
                let rows = try await client.request(
                    repository.reference.apiRepositoryPath + "/events", query: ["per_page": "10"]) as? [[String: Any]]
            else { throw GitHubRequestError.malformed }
            let events = try rows.map { try GitHubRepositoryEvent.parse($0, repository: repository.reference) }
            var seen = Set<String>()
            return .available(
                Array(
                    events.sorted {
                        $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
                    }.filter { seen.insert($0.id).inserted }.prefix(10)))
        } catch { return .unavailable(HermesDiagnosticsService.safeSummary(error.localizedDescription)) }
    }

    func release(_ repository: GitHubRepositorySummary) async -> GitHubRepositorySection<GitHubRepositoryRelease?> {
        do {
            guard
                let rows = try await client.request(
                    repository.reference.apiRepositoryPath + "/releases", query: ["per_page": "1"])
                    as? [[String: Any]]
            else { throw GitHubRequestError.malformed }
            return .available(
                try rows.first.map { try GitHubRepositoryRelease.parse($0, repository: repository.reference) })
        } catch { return .unavailable(HermesDiagnosticsService.safeSummary(error.localizedDescription)) }
    }
}

@MainActor
final class GitHubRepositoryDetailsModel: ObservableObject {
    private let service: GitHubRepositoryDetailsService
    @Published private(set) var events: [GitHubRepositoryEvent]?
    @Published private(set) var activityError: String?
    @Published private(set) var commits: [GitHubRepositoryCommit]?
    @Published private(set) var release: GitHubRepositoryRelease?
    @Published private(set) var commitError: String?
    @Published private(set) var releaseError: String?
    @Published private(set) var loading = false
    @Published private(set) var hasLoaded = false

    init(client: GitHubClient = GitHubClient()) { service = GitHubRepositoryDetailsService(client: client) }

    func refresh(_ repository: GitHubRepositorySummary) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        async let commitsResult = service.commits(repository)
        async let releaseResult = service.release(repository)
        async let eventsResult = service.events(repository)
        let (commits, release, events) = await (commitsResult, releaseResult, eventsResult)
        guard !Task.isCancelled else { return }
        switch commits {
        case .available(let rows):
            self.commits = rows
            commitError = nil
        case .unavailable(let message): commitError = message
        }
        switch release {
        case .available(let row):
            self.release = row
            releaseError = nil
        case .unavailable(let message): releaseError = message
        }
        switch events {
        case .available(let rows):
            self.events = rows
            activityError = nil
        case .unavailable(let message): activityError = message
        }
        hasLoaded = true
    }
}
