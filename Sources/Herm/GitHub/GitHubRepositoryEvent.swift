import Foundation

struct GitHubRepositoryEvent: Identifiable, Equatable, Sendable {
    let id: String
    let summary: String
    let detail: String?
    let date: Date
    let url: URL

    static func parse(_ row: [String: Any], repository: GitHubRepositoryReference) throws -> Self {
        guard let id = row["id"] as? String, !id.isEmpty,
            let type = row["type"] as? String, !type.isEmpty,
            let actor = (row["actor"] as? [String: Any])?["login"] as? String, !actor.isEmpty,
            let rawDate = row["created_at"] as? String, let date = ISO8601DateFormatter().date(from: rawDate)
        else { throw GitHubRequestError.malformed }
        let payload = row["payload"] as? [String: Any] ?? [:]
        let action = payload["action"] as? String ?? ""
        let verbs = [
            "opened", "closed", "reopened", "merged", "edited", "deleted", "assigned", "unassigned", "labeled",
            "unlabeled", "published", "created",
        ]
        let verb = verbs.contains(action) ? action : "updated"
        var summary: String
        var detail: String?
        var url = repository.webURL

        switch type {
        case "PushEvent":
            summary = "pushed changes"
            if let ref = payload["ref"] as? String {
                detail = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            }
            url = url.appendingPathComponent("commits")
        case "IssuesEvent", "IssueCommentEvent":
            let issue = payload["issue"] as? [String: Any] ?? [:]
            let isPullRequest = issue["pull_request"] is [String: Any]
            let target = isPullRequest ? "pull request" : "issue"
            let number = (issue["number"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let label = number.map { "\(target) #\($0)" } ?? (isPullRequest ? "a pull request" : "an issue")
            if type == "IssueCommentEvent" {
                summary = action == "created" ? "commented on \(label)" : "updated a comment on \(label)"
            } else {
                summary = "\(verb) \(label)"
            }
            detail = issue["title"] as? String
            if let number { url = url.appendingPathComponent("\(isPullRequest ? "pull" : "issues")/\(number)") }
        case "PullRequestEvent", "PullRequestReviewEvent", "PullRequestReviewCommentEvent":
            let pull = payload["pull_request"] as? [String: Any] ?? [:]
            let number = ((pull["number"] ?? payload["number"]) as? Int).flatMap { $0 > 0 ? $0 : nil }
            let label = number.map { "pull request #\($0)" } ?? "a pull request"
            if type == "PullRequestReviewEvent" {
                let state = (payload["review"] as? [String: Any])?["state"] as? String
                if action == "dismissed" {
                    summary = "dismissed a review on \(label)"
                } else if ["created", "submitted"].contains(action) {
                    if state == "approved" {
                        summary = "approved \(label)"
                    } else if state == "changes_requested" {
                        summary = "requested changes on \(label)"
                    } else {
                        summary = "reviewed \(label)"
                    }
                } else {
                    summary = "updated a review on \(label)"
                }
            } else if type == "PullRequestReviewCommentEvent" {
                summary = action == "created" ? "commented on \(label)" : "updated a comment on \(label)"
            } else {
                let merged = action == "merged" || (action == "closed" && pull["merged"] as? Bool == true)
                summary = "\(merged ? "merged" : verb) \(label)"
            }
            detail = pull["title"] as? String
            if let number { url = url.appendingPathComponent("pull/\(number)") }
        case "ReleaseEvent":
            summary = "\(verb) a release"
            detail = (payload["release"] as? [String: Any])?["tag_name"] as? String
            url = url.appendingPathComponent("releases")
        case "CreateEvent", "DeleteEvent":
            let refType = payload["ref_type"] as? String ?? ""
            let target = ["branch", "tag", "repository"].contains(refType) ? refType : "reference"
            summary = "\(type == "CreateEvent" ? "created" : "deleted") a \(target)"
            detail = payload["ref"] as? String
        case "ForkEvent":
            summary = "forked the repository"
            detail = (payload["forkee"] as? [String: Any])?["full_name"] as? String
            url = url.appendingPathComponent("forks")
        case "CommitCommentEvent":
            summary = "commented on a commit"
            url = url.appendingPathComponent("commits")
        case "MemberEvent":
            summary = "updated repository collaborators"
            detail = (payload["member"] as? [String: Any])?["login"] as? String
        case "WatchEvent":
            summary = action == "started" ? "starred the repository" : "updated repository stars"
        case "PublicEvent": summary = "made the repository public"
        case "GollumEvent":
            summary = "updated the wiki"
            url = url.appendingPathComponent("wiki")
        case "DiscussionEvent":
            summary = "\(verb) a discussion"
            detail = (payload["discussion"] as? [String: Any])?["title"] as? String
            url = url.appendingPathComponent("discussions")
        default: summary = "· \(type)"
        }
        return Self(id: id, summary: "\(actor) \(summary)", detail: detail, date: date, url: url)
    }
}
