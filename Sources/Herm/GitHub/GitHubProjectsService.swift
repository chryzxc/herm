import Foundation

struct GitHubProjectItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let reference: GitHubItemReference?
    let archived: Bool
    var statusID: String?

    static func parse(_ row: [String: Any]) throws -> Self {
        guard let id = row["id"] as? String else { throw GitHubRequestError.malformed }
        let content = row["content"] as? [String: Any]
        let type = content?["__typename"] as? String
        var reference: GitHubItemReference?
        if let repo = content?["repository"] as? [String: Any],
            let name = repo["nameWithOwner"] as? String,
            let repository = GitHubReferenceParser.repository(name), let number = content?["number"] as? Int,
            type == "Issue" || type == "PullRequest"
        {
            reference = GitHubItemReference(
                repository: repository, number: number, kind: type == "Issue" ? .issue : .pullRequest)
        }
        return Self(
            id: id, title: content?["title"] as? String ?? "Restricted item",
            body: content?["body"] as? String ?? "", reference: reference,
            archived: row["isArchived"] as? Bool ?? false,
            statusID: (row["fieldValueByName"] as? [String: Any])?["optionId"] as? String)
    }
}

struct GitHubProjectBoard: Sendable {
    let project: GitHubProject
    var items: [GitHubProjectItem]
}

struct GitHubProjectsService: Sendable {
    let client: GitHubClient

    func projects(owner: String) async throws -> [GitHubProject] {
        var result: [GitHubProject] = []
        var cursor: String?
        for _ in 0..<30 {
            let connection =
                "projectsV2(first:100,after:$after){nodes{\(GitHubMetadataService.projectFields)} pageInfo{hasNextPage endCursor}}"
            let scope =
                owner.isEmpty
                ? "viewer{\(connection)}"
                : "repositoryOwner(login:$owner){... on User{\(connection)} ... on Organization{\(connection)}}"
            let declaration = owner.isEmpty ? "$after:String" : "$after:String,$owner:String!"
            var variables: [String: Any] = ["after": cursor as Any? ?? NSNull()]
            if !owner.isEmpty { variables["owner"] = owner }
            let data = try await client.graphQL("query(\(declaration)){\(scope)}", variables: variables)
            guard let account = data[owner.isEmpty ? "viewer" : "repositoryOwner"] as? [String: Any],
                let page = account["projectsV2"] as? [String: Any], let rows = page["nodes"] as? [[String: Any]]
            else { throw GitHubRequestError.notFound }
            for row in rows {
                guard let project = GitHubProject.parse(row) else { throw GitHubRequestError.malformed }
                result.append(project)
            }
            guard let next = try Self.nextCursor(page, previous: cursor) else { return result }
            cursor = next
        }
        throw GitHubRequestError.unavailable
    }

    func board(_ id: String) async throws -> GitHubProjectBoard {
        var items: [GitHubProjectItem] = []
        var cursor: String?
        for _ in 0..<30 {
            let data = try await client.graphQL(
                """
                query($id:ID!,$after:String){node(id:$id){... on ProjectV2{
                \(GitHubMetadataService.projectFields)
                items(first:100,after:$after){nodes{id isArchived
                fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{optionId}}
                content{__typename ... on DraftIssue{title body}
                ... on Issue{title body number repository{nameWithOwner}}
                ... on PullRequest{title body number repository{nameWithOwner}}}}
                pageInfo{hasNextPage endCursor}}}}}
                """, variables: ["id": id, "after": cursor as Any? ?? NSNull()])
            guard let node = data["node"] as? [String: Any], let project = GitHubProject.parse(node),
                let page = node["items"] as? [String: Any], let rows = page["nodes"] as? [[String: Any]]
            else { throw GitHubRequestError.malformed }
            items += try rows.map(GitHubProjectItem.parse)
            guard let next = try Self.nextCursor(page, previous: cursor) else {
                return GitHubProjectBoard(project: project, items: items)
            }
            cursor = next
        }
        throw GitHubRequestError.unavailable
    }

    static func nextCursor(_ connection: [String: Any], previous: String?) throws -> String? {
        guard let info = connection["pageInfo"] as? [String: Any], let more = info["hasNextPage"] as? Bool else {
            throw GitHubRequestError.malformed
        }
        guard more else { return nil }
        guard let cursor = info["endCursor"] as? String, !cursor.isEmpty, cursor != previous else {
            throw GitHubRequestError.malformed
        }
        return cursor
    }

    func setStatus(projectID: String, item: GitHubProjectItem, statusID: String?) async throws {
        let fresh = try await board(projectID)
        guard fresh.project.canEdit, !fresh.project.closed else { throw GitHubRequestError.forbidden }
        guard let current = fresh.items.first(where: { $0.id == item.id }), current.statusID == item.statusID,
            !current.archived, fresh.project.statusFieldID != nil
        else { throw GitHubRequestError.changed }
        var project = fresh.project
        project.itemID = item.id
        project.statusID = item.statusID
        try await GitHubMetadataService(client: client).changeProject(
            project, subjectID: "", included: true, statusID: statusID)
    }

    func createProject(title: String) async throws -> GitHubProject {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubRequestError.malformed
        }
        let viewer = try await client.graphQL("query{viewer{id}}")
        guard let id = (viewer["viewer"] as? [String: Any])?["id"] as? String else {
            throw GitHubRequestError.unauthorized
        }
        let data = try await client.graphQL(
            "mutation($owner:ID!,$title:String!){createProjectV2(input:{ownerId:$owner,title:$title}){projectV2{\(GitHubMetadataService.projectFields)}}}",
            variables: ["owner": id, "title": title])
        guard let payload = data["createProjectV2"] as? [String: Any],
            let row = payload["projectV2"] as? [String: Any], let project = GitHubProject.parse(row)
        else { throw GitHubRequestError.malformed }
        return project
    }

    func addDraft(projectID: String, title: String) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubRequestError.malformed
        }
        let fresh = try await board(projectID)
        guard fresh.project.canEdit, !fresh.project.closed else { throw GitHubRequestError.forbidden }
        let data = try await client.graphQL(
            "mutation($project:ID!,$title:String!){addProjectV2DraftIssue(input:{projectId:$project,title:$title}){projectItem{id}}}",
            variables: ["project": projectID, "title": title])
        guard let payload = data["addProjectV2DraftIssue"] as? [String: Any],
            (payload["projectItem"] as? [String: Any])?["id"] as? String != nil
        else { throw GitHubRequestError.malformed }
    }
}
