import Foundation
import SwiftUI

enum GitHubIssueFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case authored = "Authored"
    case assigned = "Assigned"
    var id: Self { self }
}

struct GitHubIssueRecord: Identifiable, Equatable, Sendable {
    let repository: GitHubRepositoryReference
    let localPath: String
    let number: Int
    var title: String
    var body: String
    var state: String
    var author: String
    var assignee: String?
    var assignees: [String]
    var updatedAt: Date?
    var webURL: URL?
    var createdAt: Date? = nil
    var nodeID: String? = nil
    var labels: [String] = []
    var reference: GitHubItemReference { .init(repository: repository, number: number, kind: .issue, nodeID: nodeID) }
    var id: String { "github:\(repository.id)#\(number)" }
    var displayNumber: String { String(number) }

    init(repository: GitHubRepositoryReference, localPath: String, number: Int, title: String, body: String, state: String, author: String, assignee: String?, assignees: [String] = [], updatedAt: Date?, webURL: URL?) {
        self.repository = repository; self.localPath = localPath; self.number = number; self.title = title; self.body = body; self.state = state; self.author = author; self.assignee = assignee
        self.assignees = assignees.isEmpty ? (assignee.map { [$0] } ?? []) : assignees
        self.updatedAt = updatedAt; self.webURL = webURL
    }
}

enum GitHubIssueParser {
    static func parse(_ payload: [String: Any], localPaths: [String: String] = [:]) -> GitHubIssueRecord? {
        guard let number = payload["number"] as? Int,
              number > 0,
              let title = bounded(payload["title"] as? String),
              let state = bounded(payload["state"] as? String),
              let repository = repositoryReference(from: payload) else { return nil }
        let user = payload["user"] as? [String: Any]
        let primaryAssignee = ((payload["assignee"] as? [String: Any])?["login"] as? String).flatMap(bounded)
        let assignees = (payload["assignees"] as? [[String: Any] ])?.compactMap { bounded($0["login"] as? String) } ?? []
        let allAssignees = assignees.isEmpty ? (primaryAssignee.map { [$0] } ?? []) : assignees
        var record = GitHubIssueRecord(
            repository: repository,
            localPath: localPaths[repository.id] ?? "",
            number: number,
            title: title,
            body: payload["body"] as? String ?? "",
            state: state,
            author: bounded(user?["login"] as? String) ?? "Unknown",
            assignee: primaryAssignee,
            assignees: allAssignees,
            updatedAt: (payload["updated_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) },
            webURL: (payload["html_url"] as? String).flatMap(URL.init)
        )
        record.createdAt = (payload["created_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        record.nodeID = payload["node_id"] as? String
        record.labels = (payload["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return record
    }

    private static func repositoryReference(from payload: [String: Any]) -> GitHubRepositoryReference? {
        let fullName = ((payload["repository"] as? [String: Any])?["full_name"] as? String)
            ?? (payload["repository_url"] as? String).flatMap { URL(string: $0)?.pathComponents.dropFirst().dropFirst().joined(separator: "/") }
        guard let fullName else { return nil }
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]); let name = String(parts[1])
        guard let webURL = URL(string: "https://github.com/\(owner)/\(name)") else { return nil }
        return GitHubRepositoryReference(owner: owner, name: name, webURL: webURL)
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return trimmed
    }
}

struct IssueContext: Equatable, Sendable {
    let repositoryID: String
    let number: Int
    let title: String
    let webURL: URL?
    var id: String { "github:\(repositoryID)#\(number)" }
    var prompt: String {
        """
        Issue #\(number), "\(title)", in \(repositoryID).
        Issue: \(webURL?.absoluteString ?? "Unavailable")

        Review the issue context and propose next steps. Do not modify files unless I ask.
        """
    }

    init(issue: GitHubIssueRecord) {
        repositoryID = issue.repository.id; number = issue.number; title = issue.title; webURL = issue.webURL
    }

    init(repositoryID: String, number: Int, title: String, webURL: URL?) {
        self.repositoryID = repositoryID; self.number = number; self.title = title; self.webURL = webURL
    }
}

