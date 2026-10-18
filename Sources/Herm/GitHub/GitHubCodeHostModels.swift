import Foundation

enum GitHubCapabilityID: String, CaseIterable, Sendable {
    case remote = "github.remote"
    case pullRequestRead = "github.pr.read"
    case checksRead = "github.checks.read"
    case pullRequestWrite = "github.pr.write"

    var requiresConfirmation: Bool { self == .pullRequestWrite }
}

struct GitHubRepositoryReference: Equatable, Hashable, Codable, Identifiable, Sendable {
    let owner: String
    let name: String
    let webURL: URL

    var id: String { "\(owner)/\(name)" }
    var apiRepositoryPath: String { "/repos/\(owner)/\(name)" }
}

struct GitHubCheckSummary: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let status: String
    let conclusion: String?
    let detailsURL: URL?
}

struct GitHubReviewSummary: Equatable, Identifiable, Sendable {
    let id: String
    let author: String
    let state: String
    let submittedAt: Date?
    let webURL: URL?
    var body: String = ""
    var commitID: String? = nil
    var authorAvatarURL: URL? = nil
}

struct GitHubPullRequestSummary: Equatable, Identifiable, Sendable {
    let number: Int
    let title: String
    let state: String
    let isDraft: Bool
    let headBranch: String?
    let baseBranch: String?
    let headRevision: String?
    let webURL: URL?
    let changedFiles: Int?
    let mergeable: Bool?
    let checks: [GitHubCheckSummary]
    let reviews: [GitHubReviewSummary]

    var id: Int { number }

    var metadataLabel: String? {
        var parts: [String] = []
        if let changedFiles { parts.append("\(changedFiles) files") }
        if let mergeable { parts.append(mergeable ? "mergeable" : "merge blocked") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var blockingReasons: [String] {
        var reasons: [String] = []
        if isDraft { reasons.append("Draft PR") }
        let failed = checks.filter { check in
            guard let conclusion = check.conclusion?.lowercased() else { return false }
            return ["failure", "cancelled", "timed_out", "action_required"].contains(conclusion)
        }
        if !failed.isEmpty { reasons.append("Failed checks: \(failed.map(\.name).joined(separator: ", "))") }
        let pending = checks.filter { $0.status.lowercased() != "completed" }
        if !pending.isEmpty { reasons.append("Checks in progress: \(pending.map(\.name).joined(separator: ", "))") }
        if reviews.contains(where: { $0.state.uppercased() == "CHANGES_REQUESTED" }) { reasons.append("Changes requested") }
        if mergeable == false { reasons.append("Merge blocked") }
        if !isDraft, reviews.isEmpty || !reviews.contains(where: { $0.state.uppercased() == "APPROVED" }) { reasons.append("Approval pending") }
        return reasons
    }
}

enum GitHubIntegrationState: Equatable, Sendable {
    case noRemote
    case notLoaded
    case available
    case unavailable(GitHubCodeHostError)
    case stale(GitHubCodeHostError)
}

enum GitHubIntegrationPresentation {
    static func state(repository: GitHubRepositoryReference?, hasLoaded: Bool, error: GitHubCodeHostError?) -> GitHubIntegrationState {
        guard repository != nil else { return .noRemote }
        if let error { return hasLoaded ? .stale(error) : .unavailable(error) }
        return hasLoaded ? .available : .notLoaded
    }

    static func shouldResetLoadedState(current: GitHubRepositoryReference?, resolved: GitHubRepositoryReference?) -> Bool {
        current != resolved
    }
}

enum GitHubPullRequestMutationError: Error, Equatable, Sendable {
    case invalidTitle
    case invalidBody
    case invalidBranch
    case missingRepository
}

struct GitHubPullRequestMutation: Equatable, Sendable {
    enum Kind: String, Sendable { case createDraft, updateTitleAndBody }

    let kind: Kind
    let repository: GitHubRepositoryReference
    let number: Int?
    let title: String
    let body: String
    let headBranch: String?
    let baseBranch: String?
}

enum GitHubPullRequestMutationWire {
    static func method(for mutation: GitHubPullRequestMutation) -> String {
        mutation.kind == .createDraft ? "POST" : "PATCH"
    }

    static func path(for mutation: GitHubPullRequestMutation) -> String {
        switch mutation.kind {
        case .createDraft: return "/pulls"
        case .updateTitleAndBody: return "/pulls/\(mutation.number ?? 0)"
        }
    }

    static func payload(for mutation: GitHubPullRequestMutation) -> [String: Any] {
        switch mutation.kind {
        case .createDraft:
            return [
                "title": mutation.title,
                "body": mutation.body,
                "head": mutation.headBranch ?? "",
                "base": mutation.baseBranch ?? "",
                "draft": true
            ]
        case .updateTitleAndBody:
            return ["title": mutation.title, "body": mutation.body]
        }
    }
}

enum GitHubPullRequestMutationBuilder {
    static func createDraft(repository: GitHubRepositoryReference?, title: String, body: String, headBranch: String, baseBranch: String) -> Result<GitHubPullRequestMutation, GitHubPullRequestMutationError> {
        guard let repository else { return .failure(.missingRepository) }
        guard let title = valid(title, limit: 200) else { return .failure(.invalidTitle) }
        guard let body = validBody(body) else { return .failure(.invalidBody) }
        guard let headBranch = validBranch(headBranch), let baseBranch = validBranch(baseBranch) else { return .failure(.invalidBranch) }
        return .success(GitHubPullRequestMutation(kind: .createDraft, repository: repository, number: nil, title: title, body: body, headBranch: headBranch, baseBranch: baseBranch))
    }

    static func update(repository: GitHubRepositoryReference?, number: Int, title: String, body: String) -> Result<GitHubPullRequestMutation, GitHubPullRequestMutationError> {
        guard let repository else { return .failure(.missingRepository) }
        guard number > 0 else { return .failure(.missingRepository) }
        guard let title = valid(title, limit: 200) else { return .failure(.invalidTitle) }
        guard let body = validBody(body) else { return .failure(.invalidBody) }
        return .success(GitHubPullRequestMutation(kind: .updateTitleAndBody, repository: repository, number: number, title: title, body: body, headBranch: nil, baseBranch: nil))
    }

    private static func valid(_ value: String, limit: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= limit, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }

    private static func validBody(_ value: String) -> String? {
        let allowedWhitespace = CharacterSet(charactersIn: "\n\r\t")
        guard value.count <= 10_000, value.rangeOfCharacter(from: CharacterSet.controlCharacters.subtracting(allowedWhitespace)) == nil else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validBranch(_ value: String) -> String? {
        guard let branch = valid(value, limit: 240), !branch.contains(".."), !branch.contains("~"), !branch.contains("^") else { return nil }
        return branch
    }
}

enum GitHubRemoteParser {
    static func parse(_ raw: String) -> GitHubRepositoryReference? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { return nil }
        let path: String
        if value.hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else if let url = URL(string: value), ["https", "http", "ssh"].contains(url.scheme?.lowercased()), url.host?.lowercased() == "github.com" {
            if url.scheme?.lowercased() == "ssh", url.user?.lowercased() != "git" { return nil }
            if ["https", "http"].contains(url.scheme?.lowercased()), url.user != nil { return nil }
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return nil
        }
        let normalizedPath = path.lowercased().hasSuffix(".git") ? String(path.dropLast(4)) : path
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard components.count == 2,
              components.allSatisfy({ isSafeComponent($0) }) else { return nil }
        guard let webURL = URL(string: "https://github.com/\(components[0])/\(components[1])") else { return nil }
        return GitHubRepositoryReference(owner: components[0], name: components[1], webURL: webURL)
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.allSatisfy { $0.isLetter || $0.isNumber || "-_".contains($0) }
    }
}

enum GitHubPullRequestParser {
    static func parse(_ payload: [String: Any]) -> GitHubPullRequestSummary? {
        guard let number = payload["number"] as? Int,
              let title = bounded(payload["title"] as? String),
              let state = bounded(payload["state"] as? String) else { return nil }
        let head = (payload["head"] as? [String: Any])?["ref"] as? String
        let base = (payload["base"] as? [String: Any])?["ref"] as? String
        let url = (payload["html_url"] as? String).flatMap(URL.init)
        let checks = (payload["checks"] as? [[String: Any]] ?? []).compactMap(parseCheck)
        let reviews = (payload["reviews"] as? [[String: Any]] ?? []).compactMap(parseReview)
        let headRevision = (payload["head"] as? [String: Any])?["sha"] as? String
        let changedFiles = (payload["changed_files"] as? Int).flatMap { $0 >= 0 && $0 <= 100_000 ? $0 : nil }
        return GitHubPullRequestSummary(number: number, title: title, state: state, isDraft: payload["draft"] as? Bool ?? false, headBranch: head, baseBranch: base, headRevision: headRevision, webURL: url, changedFiles: changedFiles, mergeable: payload["mergeable"] as? Bool, checks: checks, reviews: reviews)
    }

    private static func parseCheck(_ row: [String: Any]) -> GitHubCheckSummary? {
        guard let id = bounded(String(describing: row["id"] ?? "")), let name = bounded(row["name"] as? String), let status = bounded(row["status"] as? String) else { return nil }
        return GitHubCheckSummary(id: id, name: name, status: status, conclusion: bounded(row["conclusion"] as? String), detailsURL: (row["details_url"] as? String).flatMap(URL.init))
    }

    private static func parseReview(_ row: [String: Any]) -> GitHubReviewSummary? {
        guard let id = bounded(String(describing: row["id"] ?? "")), let state = bounded(row["state"] as? String) else { return nil }
        let author = ((row["user"] as? [String: Any])?["login"] as? String).flatMap(bounded) ?? "Unknown reviewer"
        let submittedAt = (row["submitted_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return GitHubReviewSummary(id: id, author: author, state: state, submittedAt: submittedAt, webURL: (row["html_url"] as? String).flatMap(URL.init), authorAvatarURL: ((row["user"] as? [String: Any])?["avatar_url"] as? String).flatMap(URL.init))
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }
}

extension GitHubCheckSummary {
    var isFailure: Bool { ["failure", "error", "cancelled", "timed_out", "action_required", "startup_failure", "stale"].contains(conclusion?.lowercased() ?? "") }
    var isPending: Bool { status.lowercased() != "completed" || conclusion?.lowercased() == "pending" }
    var isSuccess: Bool { !isPending && ["success", "neutral", "skipped"].contains(conclusion?.lowercased() ?? "") }
}
