import Foundation
import SwiftUI

struct GitHubLabel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    var color: String? = nil
}
struct GitHubMilestone: Identifiable, Equatable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL?
    let state: String
    let dueAt: Date?
    static func parse(_ row: [String: Any]) -> Self? {
        guard let number = row["number"] as? Int, let title = row["title"] as? String else { return nil }
        return Self(
            id: row["node_id"] as? String ?? String(number), number: number, title: title,
            url: (row["html_url"] as? String).flatMap(URL.init), state: row["state"] as? String ?? "open",
            dueAt: (row["due_on"] as? String).flatMap { try? Date($0, strategy: .iso8601) })
    }
}
struct GitHubDevelopmentLink: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let url: URL?
    let reference: GitHubItemReference?
    let state: String
    var manuallyLinked: Bool
}
struct GitHubMetadataSnapshot: Equatable, Sendable {
    var nodeID: String? = nil
    var labels: [GitHubLabel] = []
    var assignees: [String] = []
    var milestone: GitHubMilestone? = nil
    var canTriage = false
    var canUpdate = false
    var title = ""
    var body = ""
    var updatedAt: String? = nil
}

struct GitHubMetadataService: Sendable {
    let client: GitHubClient
    func basic(_ reference: GitHubItemReference) async throws -> GitHubMetadataSnapshot {
        guard let row = try await client.request(reference.issuePath) as? [String: Any] else {
            throw GitHubRequestError.malformed
        }
        var result = GitHubMetadataSnapshot()
        result.nodeID = row["node_id"] as? String
        result.title = row["title"] as? String ?? ""
        result.body = row["body"] as? String ?? ""
        result.updatedAt = row["updated_at"] as? String
        result.labels = (row["labels"] as? [[String: Any]] ?? []).compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return GitHubLabel(
                id: row["node_id"] as? String ?? name, name: name, description: row["description"] as? String ?? "",
                color: row["color"] as? String)
        }
        result.assignees = (row["assignees"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
        result.milestone = (row["milestone"] as? [String: Any]).flatMap(GitHubMilestone.parse)
        if let repository = try? await client.request(reference.repository.apiRepositoryPath) as? [String: Any],
            let permissions = repository["permissions"] as? [String: Any]
        {
            result.canTriage = ["triage", "push", "maintain", "admin"].contains { permissions[$0] as? Bool == true }
        }
        if let nodeID = result.nodeID {
            let type = reference.kind == .issue ? "Issue" : "PullRequest"
            if let data = try? await client.graphQL(
                "query($id:ID!){node(id:$id){... on \(type){viewerCanUpdate}}}", variables: ["id": nodeID]),
                let node = data["node"] as? [String: Any]
            {
                result.canUpdate = node["viewerCanUpdate"] as? Bool ?? false
            }
        }
        return result
    }

    func development(_ reference: GitHubItemReference, nodeID: String) async throws -> [GitHubDevelopmentLink] {
        var links: [GitHubDevelopmentLink] = []
        var cursor: String? = nil
        let type = reference.kind == .issue ? "Issue" : "PullRequest"
        let field = reference.kind == .issue ? "closedByPullRequestsReferences" : "closingIssuesReferences"
        let closed = reference.kind == .issue ? ",includeClosedPrs:true" : ""
        var manualIDs = Set<String>()
        // Fetch manual links independently so keyword-derived references are never removed through a manual unlink operation.
        var manualCursor: String? = nil
        for _ in 0..<30 {
            let q =
                "query($id:ID!,$after:String){node(id:$id){... on \(type){\(field)(first:100,after:$after,userLinkedOnly:true\(closed)){nodes{id} pageInfo{hasNextPage endCursor}}}}}"
            let data = try await client.graphQL(
                q, variables: ["id": nodeID, "after": manualCursor as Any? ?? NSNull()])
            guard let connection = (data["node"] as? [String: Any])?[field] as? [String: Any],
                let nodes = connection["nodes"] as? [[String: Any]]
            else { throw GitHubRequestError.malformed }
            manualIDs.formUnion(nodes.compactMap { $0["id"] as? String })
            let page = connection["pageInfo"] as? [String: Any]
            guard page?["hasNextPage"] as? Bool == true else { break }
            guard let next = page?["endCursor"] as? String, next != manualCursor else {
                throw GitHubRequestError.malformed
            }
            manualCursor = next
        }
        for _ in 0..<30 {
            let query =
                "query($id:ID!,$after:String){node(id:$id){... on \(type){\(field)(first:100,after:$after\(closed)){nodes{id number title state url repository{nameWithOwner url}} pageInfo{endCursor hasNextPage}}}}}"
            let data = try await client.graphQL(query, variables: ["id": nodeID, "after": cursor as Any? ?? NSNull()])
            guard let connection = (data["node"] as? [String: Any])?[field] as? [String: Any],
                let nodes = connection["nodes"] as? [[String: Any]]
            else { throw GitHubRequestError.malformed }
            for row in nodes {
                guard let id = row["id"] as? String, let number = row["number"] as? Int,
                    let title = row["title"] as? String, let repo = row["repository"] as? [String: Any],
                    let name = repo["nameWithOwner"] as? String, let repository = GitHubReferenceParser.repository(name)
                else { continue }
                let target = GitHubItemReference(
                    repository: repository, number: number, kind: reference.kind == .issue ? .pullRequest : .issue,
                    nodeID: id)
                links.append(
                    GitHubDevelopmentLink(
                        id: id, title: title, url: (row["url"] as? String).flatMap(URL.init), reference: target,
                        state: row["state"] as? String ?? "", manuallyLinked: manualIDs.contains(id)))
            }
            let page = connection["pageInfo"] as? [String: Any]
            guard page?["hasNextPage"] as? Bool == true else {
                if reference.kind == .issue { links += try await linkedBranches(nodeID) }
                return links
            }
            guard let next = page?["endCursor"] as? String, next != cursor else { throw GitHubRequestError.malformed }
            cursor = next
        }
        throw GitHubRequestError.unavailable
    }

    private func linkedBranches(_ id: String) async throws -> [GitHubDevelopmentLink] {
        var links: [GitHubDevelopmentLink] = []
        var cursor: String? = nil
        for _ in 0..<30 {
            let data = try await client.graphQL(
                "query($id:ID!,$after:String){node(id:$id){... on Issue{linkedBranches(first:100,after:$after){nodes{id ref{name repository{url}}} pageInfo{hasNextPage endCursor}}}}}",
                variables: ["id": id, "after": cursor as Any? ?? NSNull()])
            guard let connection = (data["node"] as? [String: Any])?["linkedBranches"] as? [String: Any],
                let nodes = connection["nodes"] as? [[String: Any]]
            else { throw GitHubRequestError.malformed }
            links += nodes.compactMap { row in
                guard let id = row["id"] as? String, let ref = row["ref"] as? [String: Any],
                    let name = ref["name"] as? String, let repo = ref["repository"] as? [String: Any],
                    let url = (repo["url"] as? String).flatMap(URL.init)
                else { return nil }
                return GitHubDevelopmentLink(
                    id: id, title: name, url: url.appendingPathComponent("tree").appendingPathComponent(name),
                    reference: nil, state: "Branch", manuallyLinked: false)
            }
            let page = connection["pageInfo"] as? [String: Any]
            guard page?["hasNextPage"] as? Bool == true else { return links }
            guard let next = page?["endCursor"] as? String, next != cursor else { throw GitHubRequestError.malformed }
            cursor = next
        }
        throw GitHubRequestError.unavailable
    }

    func labels(_ reference: GitHubItemReference) async throws -> [GitHubLabel] {
        let page = try await client.pages(reference.repository.apiRepositoryPath + "/labels")
        guard !page.coverage.partial else { throw GitHubRequestError.unavailable }
        return page.rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return GitHubLabel(
                id: row["node_id"] as? String ?? name, name: name, description: row["description"] as? String ?? "",
                color: row["color"] as? String)
        }
    }
    func milestones(_ reference: GitHubItemReference) async throws -> [GitHubMilestone] {
        let page = try await client.pages(
            reference.repository.apiRepositoryPath + "/milestones", query: ["state": "all"])
        guard !page.coverage.partial else { throw GitHubRequestError.unavailable }
        return page.rows.compactMap(GitHubMilestone.parse)
    }
    func assignees(_ reference: GitHubItemReference) async throws -> [String] {
        let page = try await client.pages(reference.repository.apiRepositoryPath + "/assignees")
        guard !page.coverage.partial else { throw GitHubRequestError.unavailable }
        return page.rows.compactMap { $0["login"] as? String }
    }
    func changeLabels(_ reference: GitHubItemReference, adding: Set<String>, removing: Set<String>) async throws {
        if !adding.isEmpty {
            _ = try await client.request(
                reference.issuePath + "/labels", method: "POST", body: ["labels": adding.sorted()])
        }
        for name in removing.sorted() {
            guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                throw GitHubRequestError.malformed
            }
            _ = try await client.request(reference.issuePath + "/labels/" + encoded, method: "DELETE")
        }
    }
    func changeAssignees(_ reference: GitHubItemReference, adding: Set<String>, removing: Set<String>) async throws {
        if !adding.isEmpty {
            _ = try await client.request(
                reference.issuePath + "/assignees", method: "POST", body: ["assignees": adding.sorted()])
        }
        if !removing.isEmpty {
            _ = try await client.request(
                reference.issuePath + "/assignees", method: "DELETE", body: ["assignees": removing.sorted()])
        }
    }
    func setMilestone(_ reference: GitHubItemReference, number: Int?) async throws {
        _ = try await client.request(
            reference.issuePath, method: "PATCH", body: ["milestone": number as Any? ?? NSNull()])
    }
    func link(_ source: GitHubItemReference, to target: GitHubItemReference, adding: Bool) async throws {
        guard source.kind != target.kind, let sourceID = source.nodeID, let targetID = target.nodeID else {
            throw GitHubRequestError.malformed
        }
        let issueID = source.kind == .issue ? sourceID : targetID
        let pullID = source.kind == .pullRequest ? sourceID : targetID
        let operation = adding ? "addCloseIssueReferences" : "removeCloseIssueReferences"
        _ = try await client.graphQL(
            "mutation($issue:ID!,$pr:ID!){\(operation)(input:{issueId:$issue,pullRequestIds:[$pr]}){issue{id}}}",
            variables: ["issue": issueID, "pr": pullID])
    }
    func resolve(_ reference: GitHubItemReference) async throws -> GitHubDevelopmentLink {
        guard let row = try await client.request(reference.issuePath) as? [String: Any],
            let id = row["node_id"] as? String, let title = row["title"] as? String
        else { throw GitHubRequestError.malformed }
        let kind: GitHubItemKind = row["pull_request"] == nil ? .issue : .pullRequest
        guard kind == reference.kind else { throw GitHubRequestError.malformed }
        var ref = reference
        ref.nodeID = id
        return GitHubDevelopmentLink(
            id: id, title: title, url: reference.webURL, reference: ref, state: row["state"] as? String ?? "",
            manuallyLinked: true)
    }
}

enum GitHubReferenceParser {
    static func repository(_ value: String) -> GitHubRepositoryReference? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2,
            parts.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
            }), let url = URL(string: "https://github.com/" + parts.joined(separator: "/"))
        else { return nil }
        return GitHubRepositoryReference(owner: parts[0], name: parts[1], webURL: url)
    }
    static func item(_ text: String, repository: GitHubRepositoryReference, kind: GitHubItemKind)
        -> GitHubItemReference?
    {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), url.scheme == "https", url.host == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count == 4, let repo = self.repository(parts[0] + "/" + parts[1]), let number = Int(parts[3]),
                number > 0, parts[2] == (kind == .issue ? "issues" : "pull")
            else { return nil }
            return GitHubItemReference(repository: repo, number: number, kind: kind)
        }
        let parts = value.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        let repo = parts.count == 2 && !parts[0].isEmpty ? self.repository(parts[0]) : repository
        guard let repo, let number = Int(parts.last ?? ""), number > 0, parts.count <= 2 else { return nil }
        return GitHubItemReference(repository: repo, number: number, kind: kind)
    }
}
