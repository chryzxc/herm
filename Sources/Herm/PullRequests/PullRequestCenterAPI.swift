import Foundation

/// Mutation boundary used by the detail model. Reads remain owned by the API
/// client; this narrow seam lets confirmation behavior be tested without a
/// live GitHub request.
// Isolate mutation requirements, not the conforming API and all of its read/parsing work.
protocol PullRequestMutationExecuting {
    @MainActor func postComment(_ body: String, on record: PullRequestRecord) async -> PullRequestComment?
    @MainActor func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> PullRequestRecord?
}

/// GitHub transport and response normalization for the pull-request workspace.
/// Keeping it separate from the SwiftUI surface makes request policy and data
/// parsing independently reviewable.
struct PullRequestCenterAPI: Sendable, PullRequestMutationExecuting {
    let client: GitHubClient

    init(transport: any GitHubIssueTransport = URLSession(configuration: .ephemeral)) {
        self.client = GitHubClient(transport: transport)
    }

    func resolve(_ reference: GitHubItemReference, localPath: String) async throws -> PullRequestRecord {
        guard let row = try await request(path: reference.repository.apiRepositoryPath + "/pulls/\(reference.number)") as? [String: Any], let record = parse(row, repository: reference.repository, localPath: localPath) else { throw GitHubRequestError.malformed }
        return record
    }

    func viewer() async -> String? {
        guard let row = try? await request(path: "/user") as? [String: Any] else { return nil }
        return row["login"] as? String
    }

    func searchPullRequests(viewerLogin: String, localPaths: [String: String]) async -> Result<[PullRequestRecord], PullRequestCenterFailure> {
        do {
            async let authored = search("is:pr is:open author:\(viewerLogin)", localPaths: localPaths)
            async let reviewing = search("is:pr is:open review-requested:\(viewerLogin)", localPaths: localPaths)
            // Recently merged is best-effort: a failure here must not hide open PRs.
            let since = Date.now.addingTimeInterval(-14 * 86_400).formatted(.iso8601.year().month().day())
            async let merged = try? search("is:pr is:merged involves:\(viewerLogin) merged:>=\(since)", localPaths: localPaths)
            var unique: [String: PullRequestRecord] = [:]
            let (authoredRows, reviewingRows) = try await (authored, reviewing)
            for record in await merged ?? [] { unique[record.id] = record }
            for record in authoredRows { unique[record.id] = record }
            // Search omits requested_reviewers; membership in this result is authoritative.
            for var record in reviewingRows {
                record.requestedReviewers = [viewerLogin]
                unique[record.id] = record
            }
            return .success(Array(unique.values))
        } catch { return .failure(PullRequestCenterFailure(repository: "GitHub account search")) }
    }

    func workPage(viewer: String, localPaths: [String: String]) async throws -> GitHubPage<PullRequestRecord> {
        async let authored = try? searchPage("is:pr is:open author:\(viewer)", localPaths: localPaths)
        async let other = try? searchPage("is:pr is:open review-requested:\(viewer)", localPaths: localPaths)
        let (a, b) = await (authored, other)
        try Task.checkCancellation()
        guard a != nil || b != nil else { throw GitHubRequestError.unavailable }
        var unique = Dictionary((a?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for var row in b?.items ?? [] { row.requestedReviewers = [viewer]; unique[row.id] = row }
        var coverage = GitHubCoverage(loaded: unique.count, partial: a == nil || b == nil || a?.coverage.partial == true || b?.coverage.partial == true)
        let since = Date.now.addingTimeInterval(-14 * 86_400).formatted(.iso8601.year().month().day())
        if let merged = try? await searchPage("is:pr is:merged involves:\(viewer) merged:>=\(since)", localPaths: localPaths) {
            for row in merged.items where unique[row.id] == nil { unique[row.id] = row }
            coverage.partial = coverage.partial || merged.coverage.partial
        } else { coverage.partial = true; coverage.message = "Open results loaded; recent merged history is unavailable." }
        coverage.loaded = unique.count
        return GitHubPage(items: Array(unique.values), coverage: coverage)
    }

    func searchPage(_ query: String, localPaths: [String: String]) async throws -> GitHubPage<PullRequestRecord> {
        let page = try await client.pages("/search/issues", query: ["q": query], key: "items", search: true)
        return GitHubPage(items: page.rows.compactMap { parseSearchItem($0, localPaths: localPaths) }, coverage: page.coverage)
    }
    private func search(_ query: String, localPaths: [String: String]) async throws -> [PullRequestRecord] {
        try await searchPage(query, localPaths: localPaths).items
    }

    func index(repository: GitHubRepositoryReference, localPath: String) async -> Result<[PullRequestRecord], PullRequestCenterFailure> {
        do {
            let page = try await client.pages(repository.apiRepositoryPath + "/pulls", query: ["state": "open"])
            return .success(page.rows.compactMap { parse($0, repository: repository, localPath: localPath) })
        } catch { return .failure(PullRequestCenterFailure(repository: repository.id)) }
    }

    func detail(_ record: PullRequestRecord) async -> PullRequestRecord? {
        guard var payload = try? await request(path: record.repository.apiRepositoryPath + "/pulls/\(record.number)") as? [String: Any] else { return nil }
        var warning: [String] = []
        if let sha = (payload["head"] as? [String: Any])?["sha"] as? String {
            async let runsLookup = try? client.pages(record.repository.apiRepositoryPath + "/commits/\(sha)/check-runs", key: "check_runs")
            async let statusLookup = try? client.pages(record.repository.apiRepositoryPath + "/commits/\(sha)/statuses")
            let (runs, statuses) = await (runsLookup, statusLookup)
            var checks = runs?.rows ?? []
            var contexts = Set<String>()
            for status in statuses?.rows ?? [] {
                let name = status["context"] as? String ?? "Status check"
                guard contexts.insert(name).inserted else { continue }
                let state = status["state"] as? String ?? "unknown"
                checks.append(["id": "status:\(status["id"] ?? name)", "name": name, "status": state == "pending" ? "in_progress" : "completed", "conclusion": state, "details_url": status["target_url"] as Any])
            }
            payload["checks"] = checks
            payload["checks_available"] = runs != nil && statuses != nil && runs?.coverage.partial != true && statuses?.coverage.partial != true
            if payload["checks_available"] as? Bool != true { warning.append("Some check sources are unavailable or incomplete.") }
        }
        if let reviews = try? await client.pages(record.repository.apiRepositoryPath + "/pulls/\(record.number)/reviews") {
            payload["reviews"] = reviews.rows; payload["reviews_available"] = !reviews.coverage.partial
            if reviews.coverage.partial { warning.append("Review history is incomplete.") }
        } else { warning.append("Reviews are unavailable.") }
        var result = parse(payload, repository: record.repository, localPath: record.localPath)
        if let nodeID = result?.nodeID,
           let data = try? await client.graphQL("query($id:ID!){node(id:$id){... on PullRequest{headRefOid baseRefOid mergeable mergeStateStatus reviewDecision}}}", variables: ["id": nodeID]),
           let node = data["node"] as? [String: Any], node["headRefOid"] as? String == result?.headRevision {
            result?.mergeState = node["mergeStateStatus"] as? String
            result?.reviewDecision = node["reviewDecision"] as? String
            result?.mergeability = GitHubMergeability(rawValue: (node["mergeable"] as? String ?? "UNKNOWN").lowercased()) ?? .unknown
        }
        result?.detailWarning = warning.isEmpty ? nil : warning.joined(separator: " ")
        return result
    }

    func files(_ record: PullRequestRecord) async -> [PullRequestFile]? {
        do {
            var page = 1
            var files: [PullRequestFile] = []
            while true {
                try Task.checkCancellation()
                let payload = try await request(path: record.repository.apiRepositoryPath + "/pulls/\(record.number)/files", query: ["per_page": "100", "page": "\(page)"])
                try Task.checkCancellation()
                guard let batch = Self.parseFilesPayload(payload) else { throw GitHubCodeHostError.malformedResponse }
                files.append(contentsOf: batch)
                guard batch.count == 100 && page < 30 else { break }
                page += 1
            }
            try Task.checkCancellation()
            return files
        } catch {
            return nil
        }
    }

    nonisolated static func parseFilesPayload(_ payload: Any) -> [PullRequestFile]? {
        guard let rows = payload as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let path = row["filename"] as? String else { return nil }
            return PullRequestFile(
                path: path,
                status: row["status"] as? String ?? "modified",
                additions: (row["additions"] as? NSNumber)?.intValue ?? 0,
                deletions: (row["deletions"] as? NSNumber)?.intValue ?? 0,
                patch: row["patch"] as? String,
                webURL: (row["blob_url"] as? String).flatMap(URL.init)
            )
        }
    }

    func comments(_ record: PullRequestRecord) async -> [PullRequestComment]? {
        guard let payload = try? await completeRows(record.repository.apiRepositoryPath + "/issues/\(record.number)/comments") else { return nil }
        return payload.compactMap { row in
            guard let id = row["id"] else { return nil }
            let user = row["user"] as? [String: Any]
            return PullRequestComment(id: String(describing: id), body: row["body"] as? String ?? "", author: user?["login"] as? String ?? "Unknown", authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init), createdAt: date(row["created_at"]), webURL: (row["html_url"] as? String).flatMap(URL.init))
        }
    }

    func commits(_ record: PullRequestRecord) async -> [PullRequestCommit]? {
        guard let payload = try? await completeRows(record.repository.apiRepositoryPath + "/pulls/\(record.number)/commits") else { return nil }
        return payload.compactMap { row in
            guard let sha = row["sha"] as? String else { return nil }
            let commit = row["commit"] as? [String: Any]; let commitAuthor = commit?["author"] as? [String: Any]; let author = row["author"] as? [String: Any]
            return PullRequestCommit(id: sha, message: (commit?["message"] as? String ?? sha).components(separatedBy: "\n").first ?? sha, author: author?["login"] as? String ?? commitAuthor?["name"] as? String ?? "Unknown", authorAvatarURL: (author?["avatar_url"] as? String).flatMap(URL.init), committedAt: date(commitAuthor?["date"]), webURL: (row["html_url"] as? String).flatMap(URL.init))
        }
    }

    func events(_ record: PullRequestRecord) async -> [PullRequestEvent]? {
        guard let payload = try? await completeRows(record.repository.apiRepositoryPath + "/issues/\(record.number)/events") else { return nil }
        return payload.compactMap { row in
            guard let id = row["id"], let kind = row["event"] as? String else { return nil }
            let detail = (row["label"] as? [String: Any])?["name"] as? String
                ?? (row["assignee"] as? [String: Any])?["login"] as? String
                ?? (row["requested_reviewer"] as? [String: Any])?["login"] as? String
                ?? (row["rename"] as? [String: Any])?["to"] as? String
            return PullRequestEvent(id: String(describing: id), kind: kind, actor: (row["actor"] as? [String: Any])?["login"] as? String ?? "Someone", detail: detail, createdAt: date(row["created_at"]), actorAvatarURL: ((row["actor"] as? [String: Any])?["avatar_url"] as? String).flatMap(URL.init))
        }
    }

    nonisolated func postComment(_ body: String, on record: PullRequestRecord) async -> PullRequestComment? {
        guard let payload = try? await request(path: record.repository.apiRepositoryPath + "/issues/\(record.number)/comments", method: "POST", body: ["body": body]) as? [String: Any] else { return nil }
        let user = payload["user"] as? [String: Any]
        return PullRequestComment(id: String(describing: payload["id"] ?? UUID().uuidString), body: payload["body"] as? String ?? body, author: user?["login"] as? String ?? "You", authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init), createdAt: date(payload["created_at"]), webURL: (payload["html_url"] as? String).flatMap(URL.init))
    }

    nonisolated func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> PullRequestRecord? {
        do {
            if status == .draft || status == .readyForReview {
                var id = record.nodeID
                if id == nil { id = (try await client.request(record.repository.apiRepositoryPath + "/pulls/\(record.number)") as? [String: Any])?["node_id"] as? String }
                guard let id else { return nil }
                let operation = status == .draft ? "convertPullRequestToDraft" : "markPullRequestReadyForReview"
                _ = try await client.graphQL("mutation($id:ID!){\(operation)(input:{pullRequestId:$id}){pullRequest{id}}}", variables: ["id": id])
            } else {
                _ = try await client.request(record.repository.apiRepositoryPath + "/pulls/\(record.number)", method: "PATCH", body: ["state": status == .closed ? "closed" : "open"])
            }
            return await detail(record)
        } catch { return nil }
    }

    func completeRows(_ path: String) async throws -> [[String: Any]] {
        let page = try await client.pages(path)
        guard !page.coverage.partial else { throw GitHubRequestError.unavailable }
        return page.rows
    }

    func request(path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        try await client.request(path, query: query, method: method, body: body)
    }

    private func parseSearchItem(_ row: [String: Any], localPaths: [String: String]) -> PullRequestRecord? {
        guard let number = row["number"] as? Int, let title = row["title"] as? String, let repository = repositoryReference(from: row) else { return nil }
        let user = row["user"] as? [String: Any]
        var record = PullRequestRecord(repository: repository, localPath: localPaths[repository.id] ?? "", number: number, title: title, body: row["body"] as? String ?? "", author: user?["login"] as? String ?? "Unknown", authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init), headBranch: "unknown", baseBranch: "unknown", updatedAt: date(row["updated_at"]), isDraft: row["draft"] as? Bool ?? false, webURL: (row["html_url"] as? String).flatMap(URL.init), requestedReviewers: [], comments: row["comments"] as? Int ?? 0, additions: nil, deletions: nil, changedFiles: nil, checks: [], reviews: [], mergedAt: date((row["pull_request"] as? [String: Any])?["merged_at"]))
        record.createdAt = (row["created_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        record.nodeID = row["node_id"] as? String
        record.state = row["state"] as? String ?? "open"
        record.labels = (row["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return record

    }

    private func repositoryReference(from row: [String: Any]) -> GitHubRepositoryReference? {
        let fullName = ((row["repository"] as? [String: Any])?["full_name"] as? String) ?? (row["repository_url"] as? String).flatMap { urlString in
            guard let components = URL(string: urlString)?.pathComponents else { return nil }
            let parts = components.first == "/" ? Array(components.dropFirst()) : components
            return (parts.first == "repos" ? Array(parts.dropFirst()) : parts).joined(separator: "/")
        }
        guard let fullName else { return nil }
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]); let name = String(parts[1])
        return GitHubRepositoryReference(owner: owner, name: name, webURL: URL(string: "https://github.com/\(owner)/\(name)")!)
    }

    func parse(_ row: [String: Any], repository: GitHubRepositoryReference, localPath: String) -> PullRequestRecord? {
        guard let number = row["number"] as? Int, let title = row["title"] as? String else { return nil }
        let user = row["user"] as? [String: Any]
        let checks = (row["checks"] as? [[String: Any]] ?? []).compactMap { check -> GitHubCheckSummary? in guard let name = check["name"] as? String else { return nil }; return GitHubCheckSummary(id: String(describing: check["id"] ?? name), name: name, status: check["status"] as? String ?? "unknown", conclusion: check["conclusion"] as? String, detailsURL: (check["details_url"] as? String).flatMap(URL.init)) }
        let reviews = (row["reviews"] as? [[String: Any]] ?? []).compactMap { review -> GitHubReviewSummary? in guard let state = review["state"] as? String else { return nil }; let author = ((review["user"] as? [String: Any])?["login"] as? String) ?? "Unknown"; return GitHubReviewSummary(id: String(describing: review["id"] ?? author), author: author, state: state, submittedAt: date(review["submitted_at"]), webURL: (review["html_url"] as? String).flatMap(URL.init), body: review["body"] as? String ?? "", commitID: review["commit_id"] as? String, authorAvatarURL: ((review["user"] as? [String: Any])?["avatar_url"] as? String).flatMap(URL.init)) }
        var record = PullRequestRecord(repository: repository, localPath: localPath, number: number, title: title, body: row["body"] as? String ?? "", author: user?["login"] as? String ?? "Unknown", authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init), headBranch: ((row["head"] as? [String: Any])?["ref"] as? String) ?? "unknown", baseBranch: ((row["base"] as? [String: Any])?["ref"] as? String) ?? "unknown", updatedAt: date(row["updated_at"]), isDraft: row["draft"] as? Bool ?? false, webURL: (row["html_url"] as? String).flatMap(URL.init), requestedReviewers: (row["requested_reviewers"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }, comments: row["comments"] as? Int ?? 0, additions: row["additions"] as? Int, deletions: row["deletions"] as? Int, changedFiles: row["changed_files"] as? Int, checks: checks, reviews: reviews, mergedAt: date(row["merged_at"]))
        record.createdAt = (row["created_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        record.nodeID = row["node_id"] as? String
        record.state = row["state"] as? String ?? "open"
        record.headRevision = (row["head"] as? [String: Any])?["sha"] as? String
        record.baseRevision = (row["base"] as? [String: Any])?["sha"] as? String
        if let mergeable = row["mergeable"] as? Bool { record.mergeability = mergeable ? .mergeable : .conflicting }
        record.mergeState = row["mergeable_state"] as? String
        record.checksAvailable = row["checks_available"] as? Bool ?? false
        record.reviewsAvailable = row["reviews_available"] as? Bool ?? false
        record.refreshedAt = .now
        record.labels = (row["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return record

    }

    private func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { try? Date($0, strategy: .iso8601) }
    }
}
