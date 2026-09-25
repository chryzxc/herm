import Foundation

/// Mutation boundary used by the detail model. Reads remain owned by the API
/// client; this narrow seam lets confirmation behavior be tested without a
/// live GitHub request.
@MainActor
protocol PullRequestMutationExecuting {
    func postComment(_ body: String, on record: PullRequestRecord) async -> PullRequestComment?
    func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> PullRequestRecord?
}

/// GitHub transport and response normalization for the pull-request workspace.
/// Keeping it separate from the SwiftUI surface makes request policy and data
/// parsing independently reviewable.
struct PullRequestCenterAPI: Sendable, PullRequestMutationExecuting {
    private let session = URLSession(configuration: .ephemeral)

    func viewer() async -> String? {
        guard let row = try? await request(path: "/user") as? [String: Any] else { return nil }
        return row["login"] as? String
    }

    func searchPullRequests(viewerLogin: String, localPaths: [String: String]) async -> Result<[PullRequestRecord], PullRequestCenterFailure> {
        do {
            let queries = ["is:pr is:open author:\(viewerLogin)", "is:pr is:open review-requested:\(viewerLogin)"]
            var unique: [String: PullRequestRecord] = [:]
            for query in queries {
                var page = 1
                while !Task.isCancelled {
                    guard let payload = try await request(path: "/search/issues", query: ["q": query, "per_page": "100", "page": "\(page)"]) as? [String: Any], let items = payload["items"] as? [[String: Any]] else { throw GitHubCodeHostError.malformedResponse }
                    for item in items { if let record = parseSearchItem(item, localPaths: localPaths) { unique[record.id] = record } }
                    guard items.count == 100 else { break }
                    page += 1
                }
            }
            return .success(Array(unique.values))
        } catch { return .failure(PullRequestCenterFailure(repository: "GitHub account search")) }
    }

    func enrichIndex(_ records: [PullRequestRecord], batchSize: Int = 6) async -> [PullRequestRecord] {
        guard !records.isEmpty else { return [] }
        var enriched: [PullRequestRecord] = []
        enriched.reserveCapacity(records.count)
        for start in stride(from: 0, to: records.count, by: batchSize) {
            guard !Task.isCancelled else { break }
            let batch = Array(records[start..<min(start + batchSize, records.count)])
            let details = await withTaskGroup(of: (Int, PullRequestRecord?).self, returning: [(Int, PullRequestRecord?)].self) { group in
                for (offset, record) in batch.enumerated() { group.addTask { (offset, await detail(record)) } }
                var output: [(Int, PullRequestRecord?)] = []
                for await result in group { output.append(result) }
                return output.sorted { $0.0 < $1.0 }
            }
            enriched.append(contentsOf: details.map { $0.1 ?? batch[$0.0] })
        }
        return enriched
    }

    func index(repository: GitHubRepositoryReference, localPath: String) async -> Result<[PullRequestRecord], PullRequestCenterFailure> {
        do {
            var page = 1; var rows: [PullRequestRecord] = []
            while !Task.isCancelled {
                let payload = try await request(path: repository.apiRepositoryPath + "/pulls", query: ["state": "open", "per_page": "100", "page": "\(page)"])
                let batch = (payload as? [[String: Any]] ?? []).compactMap { parse($0, repository: repository, localPath: localPath) }
                rows += batch
                guard batch.count == 100 else { break }
                page += 1
            }
            return .success(rows)
        } catch { return .failure(PullRequestCenterFailure(repository: repository.id)) }
    }

    func detail(_ record: PullRequestRecord) async -> PullRequestRecord? {
        guard var payload = try? await request(path: record.repository.apiRepositoryPath + "/pulls/\(record.number)") as? [String: Any] else { return nil }
        if let sha = (payload["head"] as? [String: Any])?["sha"] as? String {
            if let checkPayload = try? await request(path: record.repository.apiRepositoryPath + "/commits/\(sha)/check-runs", query: ["per_page": "100"]) as? [String: Any], let runs = checkPayload["check_runs"] as? [[String: Any]] { payload["checks"] = runs }
            else if let statusPayload = try? await request(path: record.repository.apiRepositoryPath + "/commits/\(sha)/status") as? [String: Any], let statuses = statusPayload["statuses"] as? [[String: Any]] {
                payload["checks"] = statuses.map { ["id": $0["id"] ?? UUID().uuidString, "name": $0["context"] ?? "Status check", "status": "completed", "conclusion": $0["state"] ?? "unknown", "details_url": $0["target_url"] as Any] }
            }
        }
        if let reviews = try? await request(path: record.repository.apiRepositoryPath + "/pulls/\(record.number)/reviews", query: ["per_page": "100"]) as? [[String: Any]] { payload["reviews"] = reviews }
        return parse(payload, repository: record.repository, localPath: record.localPath)
    }

    func files(_ record: PullRequestRecord) async -> [PullRequestFile]? {
        do {
            var page = 1
            var files: [PullRequestFile] = []
            while !Task.isCancelled {
                let payload = try await request(path: record.repository.apiRepositoryPath + "/pulls/\(record.number)/files", query: ["per_page": "100", "page": "\(page)"])
                guard let batch = Self.parseFilesPayload(payload) else { throw GitHubCodeHostError.malformedResponse }
                files.append(contentsOf: batch)
                guard batch.count == 100 else { break }
                page += 1
            }
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
        guard let payload = try? await request(path: record.repository.apiRepositoryPath + "/issues/\(record.number)/comments", query: ["per_page": "100"]) as? [[String: Any]] else { return nil }
        return payload.compactMap { row in
            guard let id = row["id"] else { return nil }
            let user = row["user"] as? [String: Any]
            return PullRequestComment(id: String(describing: id), body: row["body"] as? String ?? "", author: user?["login"] as? String ?? "Unknown", authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init), createdAt: date(row["created_at"]), webURL: (row["html_url"] as? String).flatMap(URL.init))
        }
    }

    func commits(_ record: PullRequestRecord) async -> [PullRequestCommit]? {
        guard let payload = try? await request(path: record.repository.apiRepositoryPath + "/pulls/\(record.number)/commits", query: ["per_page": "30"]) as? [[String: Any]] else { return nil }
        return payload.compactMap { row in
            guard let sha = row["sha"] as? String else { return nil }
            let commit = row["commit"] as? [String: Any]; let commitAuthor = commit?["author"] as? [String: Any]; let author = row["author"] as? [String: Any]
            return PullRequestCommit(id: sha, message: (commit?["message"] as? String ?? sha).components(separatedBy: "\n").first ?? sha, author: author?["login"] as? String ?? commitAuthor?["name"] as? String ?? "Unknown", authorAvatarURL: (author?["avatar_url"] as? String).flatMap(URL.init), committedAt: date(commitAuthor?["date"]), webURL: (row["html_url"] as? String).flatMap(URL.init))
        }
    }

    func postComment(_ body: String, on record: PullRequestRecord) async -> PullRequestComment? {
        guard let payload = try? await request(path: record.repository.apiRepositoryPath + "/issues/\(record.number)/comments", method: "POST", body: ["body": body]) as? [String: Any] else { return nil }
        let user = payload["user"] as? [String: Any]
        return PullRequestComment(id: String(describing: payload["id"] ?? UUID().uuidString), body: payload["body"] as? String ?? body, author: user?["login"] as? String ?? "You", authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init), createdAt: date(payload["created_at"]), webURL: (payload["html_url"] as? String).flatMap(URL.init))
    }

    func updateStatus(_ status: PullRequestStatus, for record: PullRequestRecord) async -> PullRequestRecord? {
        let path: String; let method: String; let body: [String: Any]?
        switch status {
        case .draft: return record.isDraft ? record : nil
        case .readyForReview: guard record.isDraft else { return record }; path = record.repository.apiRepositoryPath + "/pulls/\(record.number)/ready_for_review"; method = "POST"; body = nil
        case .closed: path = record.repository.apiRepositoryPath + "/pulls/\(record.number)"; method = "PATCH"; body = ["state": "closed"]
        }
        guard let payload = try? await request(path: path, method: method, body: body) as? [String: Any] else { return nil }
        return parse(payload, repository: record.repository, localPath: record.localPath)
    }

    private func request(path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        var components = URLComponents(string: "https://api.github.com\(path)")!; components.queryItems = query.map(URLQueryItem.init)
        var request = URLRequest(url: components.url!); request.timeoutInterval = GitHubCodeHostService.requestTimeout; request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept"); request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await GitHubCodeHostService.localGitHubToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw GitHubCodeHostError.unavailable }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func parseSearchItem(_ row: [String: Any], localPaths: [String: String]) -> PullRequestRecord? {
        guard let number = row["number"] as? Int, let title = row["title"] as? String, let repository = repositoryReference(from: row) else { return nil }
        let user = row["user"] as? [String: Any]
        return PullRequestRecord(repository: repository, localPath: localPaths[repository.id] ?? "", number: number, title: title, body: row["body"] as? String ?? "", author: user?["login"] as? String ?? "Unknown", authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init), headBranch: "unknown", baseBranch: "unknown", updatedAt: date(row["updated_at"]), isDraft: row["draft"] as? Bool ?? false, webURL: (row["html_url"] as? String).flatMap(URL.init), requestedReviewers: [], comments: row["comments"] as? Int ?? 0, additions: nil, deletions: nil, changedFiles: nil, checks: [], reviews: [])
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

    private func parse(_ row: [String: Any], repository: GitHubRepositoryReference, localPath: String) -> PullRequestRecord? {
        guard let number = row["number"] as? Int, let title = row["title"] as? String else { return nil }
        let user = row["user"] as? [String: Any]
        let checks = (row["checks"] as? [[String: Any]] ?? []).compactMap { check -> GitHubCheckSummary? in guard let name = check["name"] as? String else { return nil }; return GitHubCheckSummary(id: String(describing: check["id"] ?? name), name: name, status: check["status"] as? String ?? "unknown", conclusion: check["conclusion"] as? String, detailsURL: (check["details_url"] as? String).flatMap(URL.init)) }
        let reviews = (row["reviews"] as? [[String: Any]] ?? []).compactMap { review -> GitHubReviewSummary? in guard let state = review["state"] as? String else { return nil }; let author = ((review["user"] as? [String: Any])?["login"] as? String) ?? "Unknown"; return GitHubReviewSummary(id: String(describing: review["id"] ?? author), author: author, state: state, submittedAt: nil, webURL: nil) }
        return PullRequestRecord(repository: repository, localPath: localPath, number: number, title: title, body: row["body"] as? String ?? "", author: user?["login"] as? String ?? "Unknown", authorAvatarURL: (user?["avatar_url"] as? String).flatMap(URL.init), headBranch: ((row["head"] as? [String: Any])?["ref"] as? String) ?? "unknown", baseBranch: ((row["base"] as? [String: Any])?["ref"] as? String) ?? "unknown", updatedAt: date(row["updated_at"]), isDraft: row["draft"] as? Bool ?? false, webURL: (row["html_url"] as? String).flatMap(URL.init), requestedReviewers: (row["requested_reviewers"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }, comments: row["comments"] as? Int ?? 0, additions: row["additions"] as? Int, deletions: row["deletions"] as? Int, changedFiles: row["changed_files"] as? Int, checks: checks, reviews: reviews)
    }

    private func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { try? Date($0, strategy: .iso8601) }
    }
}
