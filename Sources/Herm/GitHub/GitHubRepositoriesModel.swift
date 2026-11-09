import SwiftUI

struct GitHubRepositorySummary: Identifiable, Equatable, Sendable {
    let reference: GitHubRepositoryReference
    let description: String
    let isPrivate: Bool
    let archived: Bool
    let language: String?
    let stars: Int
    let forks: Int?
    let openIssuesAndPullRequests: Int?
    let defaultBranch: String?
    let pushedAt: Date?
    let updatedAt: Date?
    let license: String?
    let access: String?
    let hasIssues: Bool?

    var owner: String { String(reference.id.split(separator: "/").first ?? "") }
    var name: String { String(reference.id.split(separator: "/").last ?? "") }
    var id: String { reference.id }
    var cloneURL: String { reference.webURL.absoluteString + ".git" }

    static func parse(_ row: [String: Any]) throws -> Self {
        guard let name = row["full_name"] as? String,
            let reference = GitHubReferenceParser.repository(name),
            let isPrivate = row["private"] as? Bool, let archived = row["archived"] as? Bool
        else { throw GitHubRequestError.malformed }
        let permissions = row["permissions"] as? [String: Any] ?? [:]
        let access = [
            ("admin", "Admin"), ("maintain", "Maintain"), ("push", "Write"), ("triage", "Triage"), ("pull", "Read"),
        ]
        .first { permissions[$0.0] as? Bool == true }?.1
        return Self(
            reference: reference, description: row["description"] as? String ?? "",
            isPrivate: isPrivate, archived: archived, language: row["language"] as? String,
            stars: row["stargazers_count"] as? Int ?? 0,
            forks: row["forks_count"] as? Int,
            openIssuesAndPullRequests: row["open_issues_count"] as? Int,
            defaultBranch: row["default_branch"] as? String,
            pushedAt: (row["pushed_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            updatedAt: (row["updated_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            license: (row["license"] as? [String: Any])?["name"] as? String,
            access: access, hasIssues: row["has_issues"] as? Bool)
    }
}

@MainActor
final class GitHubRepositoriesModel: ObservableObject {
    let client: GitHubClient
    @Published var query = ""
    @Published var visibility = "All"
    @Published var owner = "All owners"
    var owners: [String] { Array(Set(repositories.map(\.owner))).sorted() }
    @Published var includesArchived = false
    /// Owned here, not by the view, so window back/forward can restore it.
    @Published var selectedID: String?
    @Published private(set) var repositories: [GitHubRepositorySummary] = []
    /// Lowercased `owner/name` of the viewer's GitHub profile pins, in profile order.
    @Published private(set) var pinned: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var error: String?
    @Published private(set) var coverage: String?
    @Published private(set) var accessRequirement: GitHubAccessRequirement?

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    /// Profile pins first in GitHub's pinned order, then everything else by last update.
    var visible: [GitHubRepositorySummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.pinnedFirst(repositories, pinned: pinned).filter {
            (owner == "All owners" || $0.owner == owner)
                && (includesArchived || !$0.archived)
                && (visibility == "All" || ($0.isPrivate ? visibility == "Private" : visibility == "Public"))
                && (needle.isEmpty || $0.id.localizedStandardContains(needle)
                    || $0.description.localizedStandardContains(needle))
        }
    }

    func isPinned(_ repository: GitHubRepositorySummary) -> Bool { pinned.contains(repository.id.lowercased()) }

    nonisolated static func pinnedFirst(_ repositories: [GitHubRepositorySummary], pinned: [String])
        -> [GitHubRepositorySummary]
    {
        let rank = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return repositories.enumerated().sorted {
            switch (rank[$0.element.id.lowercased()], rank[$1.element.id.lowercased()]) {
            case (let left?, let right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): $0.offset < $1.offset
            }
        }.map(\.element)
    }

    /// Pins are optional decoration: a failed read keeps the last known pins and never fails the list.
    private func loadPinned() async -> [String]? {
        let query =
            "query { viewer { pinnedItems(first: 6, types: REPOSITORY) { nodes { ... on Repository { nameWithOwner } } } } }"
        guard let data = try? await client.graphQL(query),
            let nodes = ((data["viewer"] as? [String: Any])?["pinnedItems"] as? [String: Any])?["nodes"]
                as? [[String: Any]]
        else { return nil }
        return nodes.compactMap { ($0["nameWithOwner"] as? String)?.lowercased() }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        async let pins = loadPinned()
        do {
            let page = try await client.pages(
                "/user/repos",
                query: [
                    "sort": "updated", "direction": "desc", "visibility": "all",
                    "affiliation": "owner,collaborator,organization_member",
                ])
            let rows = try page.rows.map(GitHubRepositorySummary.parse)
            try Task.checkCancellation()
            var seen = Set<String>()
            repositories = rows.filter { seen.insert($0.id).inserted }.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
                }
                return $0.id < $1.id
            }
            if let pins = await pins { pinned = pins }
            coverage = page.coverage.label.map(HermesDiagnosticsService.safeSummary)
            error = nil
            accessRequirement = nil
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = HermesDiagnosticsService.safeSummary(error.localizedDescription)
            accessRequirement = GitHubAccessRequirement(error: error)
        }
    }
}
