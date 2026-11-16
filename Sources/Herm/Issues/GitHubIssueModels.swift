import Foundation
import SwiftUI

enum GitHubIssueFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case authored = "Authored"
    case assigned = "Assigned"
    var id: Self { self }
}

struct GitHubIssueAssignee: Equatable, Sendable {
    let login: String
    let avatarURL: URL?
}

struct GitHubIssueRecord: Identifiable, Equatable, Sendable {
    let repository: GitHubRepositoryReference
    let localPath: String
    let number: Int
    var title: String
    var body: String
    var state: String
    var author: String
    var authorAvatarURL: URL? = nil
    var assignee: String?
    var assignees: [String]
    var updatedAt: Date?
    var webURL: URL?
    var createdAt: Date? = nil
    var nodeID: String? = nil
    var labels: [String] = []
    var labelRecords: [GitHubLabel] = []
    var assigneeAvatars: [GitHubIssueAssignee] = []
    var typeName: String? = nil
    var stateReason: String? = nil
    var reference: GitHubItemReference { .init(repository: repository, number: number, kind: .issue, nodeID: nodeID) }
    var id: String { "github:\(repository.id)#\(number)" }
    var displayNumber: String { String(number) }

    init(
        repository: GitHubRepositoryReference, localPath: String, number: Int, title: String, body: String,
        state: String, author: String, assignee: String?, assignees: [String] = [], updatedAt: Date?, webURL: URL?
    ) {
        self.repository = repository
        self.localPath = localPath
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.author = author
        self.assignee = assignee
        self.assignees = assignees.isEmpty ? (assignee.map { [$0] } ?? []) : assignees
        self.updatedAt = updatedAt
        self.webURL = webURL
    }
}

enum GitHubIssueParser {
    static func parse(_ payload: [String: Any], localPaths: [String: String] = [:]) -> GitHubIssueRecord? {
        guard let number = payload["number"] as? Int,
            number > 0,
            let title = bounded(payload["title"] as? String),
            let state = bounded(payload["state"] as? String),
            let repository = repositoryReference(from: payload)
        else { return nil }
        let user = payload["user"] as? [String: Any]
        let primaryAssignee = ((payload["assignee"] as? [String: Any])?["login"] as? String).flatMap(bounded)
        let assignees = (payload["assignees"] as? [[String: Any]])?.compactMap { bounded($0["login"] as? String) } ?? []
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
        record.authorAvatarURL = avatarURL(user?["avatar_url"] as? String)
        record.nodeID = payload["node_id"] as? String
        record.typeName = bounded((payload["type"] as? [String: Any])?["name"] as? String)
        record.stateReason = bounded(payload["state_reason"] as? String)
        var labelNames = Set<String>()
        record.labelRecords = (payload["labels"] as? [Any] ?? []).compactMap { value in
            let label = value as? [String: Any] ?? [:]
            guard let name = bounded((value as? String) ?? (label["name"] as? String)),
                labelNames.insert(name).inserted
            else { return nil }
            let color = label["color"] as? String
            return GitHubLabel(
                id: label["node_id"] as? String ?? name, name: name, description: "",
                color: color.flatMap { DockMetadataPillColor(hex: $0) == nil ? nil : $0 })
        }
        record.labels = record.labelRecords.map(\.name)
        let people =
            (payload["assignees"] as? [[String: Any]])
            ?? (payload["assignee"] as? [String: Any]).map { [$0] } ?? []
        record.assigneeAvatars = people.compactMap { person in
            guard let login = bounded(person["login"] as? String) else { return nil }
            return GitHubIssueAssignee(login: login, avatarURL: avatarURL(person["avatar_url"] as? String))
        }
        return record
    }

    private static func avatarURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https",
            url.host == "avatars.githubusercontent.com", url.user == nil, url.password == nil, url.port == nil
        else { return nil }
        return url
    }

    private static func repositoryReference(from payload: [String: Any]) -> GitHubRepositoryReference? {
        let fullName =
            ((payload["repository"] as? [String: Any])?["full_name"] as? String)
            ?? (payload["repository_url"] as? String).flatMap {
                URL(string: $0)?.pathComponents.dropFirst().dropFirst().joined(separator: "/")
            }
        guard let fullName else { return nil }
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let name = String(parts[1])
        guard let webURL = URL(string: "https://github.com/\(owner)/\(name)") else { return nil }
        return GitHubRepositoryReference(owner: owner, name: name, webURL: webURL)
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
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
        repositoryID = issue.repository.id
        number = issue.number
        title = issue.title
        webURL = issue.webURL
    }

    init(repositoryID: String, number: Int, title: String, webURL: URL?) {
        self.repositoryID = repositoryID
        self.number = number
        self.title = title
        self.webURL = webURL
    }
}
