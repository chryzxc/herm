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
    let license: String?

    var languageAccent: DockAccentColor {
        switch language?.lowercased() {
        case "swift": .orange
        case "python": .amber
        case "typescript", "javascript": .blue
        case "go", "rust": .teal
        case "html", "css": .violet
        default: .indigo
        }
    }
    var owner: String { String(reference.id.split(separator: "/").first ?? "") }
    var name: String { String(reference.id.split(separator: "/").last ?? "") }
    var id: String { reference.id }
    var cloneURL: String { reference.webURL.absoluteString + ".git" }

    static func parse(_ row: [String: Any]) throws -> Self {
        guard let name = row["full_name"] as? String,
            let reference = GitHubReferenceParser.repository(name),
            let isPrivate = row["private"] as? Bool, let archived = row["archived"] as? Bool
        else { throw GitHubRequestError.malformed }
        return Self(
            reference: reference, description: row["description"] as? String ?? "",
            isPrivate: isPrivate, archived: archived, language: row["language"] as? String,
            stars: row["stargazers_count"] as? Int ?? 0,
            forks: row["forks_count"] as? Int,
            openIssuesAndPullRequests: row["open_issues_count"] as? Int,
            defaultBranch: row["default_branch"] as? String,
            pushedAt: (row["pushed_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            license: (row["license"] as? [String: Any])?["name"] as? String)
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
    @Published private(set) var repositories: [GitHubRepositorySummary] = []
    @Published private(set) var loading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var error: String?
    @Published private(set) var coverage: String?
    @Published private(set) var accessRequirement: GitHubAccessRequirement?

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    var visible: [GitHubRepositorySummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return repositories.filter {
            (owner == "All owners" || $0.owner == owner)
                && (includesArchived || !$0.archived)
                && (visibility == "All" || ($0.isPrivate ? visibility == "Private" : visibility == "Public"))
                && (needle.isEmpty || $0.id.localizedStandardContains(needle)
                    || $0.description.localizedStandardContains(needle))
        }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
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
            repositories = rows.filter { seen.insert($0.id).inserted }
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
