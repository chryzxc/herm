import Foundation

enum GitHubCodeHostError: Error, Equatable, Sendable {
    case invalidEndpoint
    case unavailable
    case unauthorized
    case malformedResponse
}

extension GitHubCodeHostError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidEndpoint: "invalid GitHub endpoint"
        case .unavailable: "GitHub API unavailable or rate-limited"
        case .unauthorized: "authentication required (private repository or expired credentials)"
        case .malformedResponse: "GitHub returned an unreadable response"
        }
    }
}

protocol GitHubCodeHostClient: Sendable {
    func pullRequests(for repository: GitHubRepositoryReference) async -> Result<[GitHubPullRequestSummary], GitHubCodeHostError>
    func createDraftPullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError>
    func updatePullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError>
}

struct GitHubCodeHostService: GitHubCodeHostClient, Sendable {
    nonisolated static let requestTimeout: TimeInterval = 15
    private let session: URLSession

    init(session: URLSession = .init(configuration: .ephemeral)) { self.session = session }

    private static func localGitHubToken() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let token = [environment["GH_TOKEN"], environment["GITHUB_TOKEN"]]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return token
        }

        // Reuse the user's existing GitHub CLI credential without persisting
        // or logging it. App bundles often have a reduced PATH, so check the
        // standard Homebrew locations explicitly and fall back to `gh`.
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", "gh"]
        for executable in candidates {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable == "gh" ? "/usr/bin/env" : executable)
            process.arguments = executable == "gh" ? ["gh", "auth", "token", "--hostname", "github.com"] : ["auth", "token", "--hostname", "github.com"]
            // GUI-launched apps may not inherit the shell's HOME. Pin gh to
            // the signed-in user's standard config directory so Dock and the
            // terminal consult the same hosts.yml.
            var environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            environment["HOME"] = home
            environment["GH_CONFIG_DIR"] = environment["GH_CONFIG_DIR"] ?? "\(home)/.config/gh"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { continue }
                let token = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let token, !token.isEmpty { return token }
            } catch {
                continue
            }
        }
        return nil
    }

    func pullRequests(for repository: GitHubRepositoryReference) async -> Result<[GitHubPullRequestSummary], GitHubCodeHostError> {
        let rows: [[String: Any]]
        do {
            guard let response = try await requestJSON(repository: repository, suffix: "/pulls", query: [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "per_page", value: "20")]) as? [[String: Any]] else { return .failure(.malformedResponse) }
            rows = response
        } catch let error as GitHubCodeHostError { return .failure(error) }
        catch { return .failure(.unavailable) }
        guard !rows.isEmpty else { return .success([]) }
        var result: [GitHubPullRequestSummary] = []
        for row in rows {
            guard let summary = GitHubPullRequestParser.parse(row) else { continue }
            result.append(await enrich(summary, repository: repository))
        }
        return .success(result)
    }

    func createDraftPullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError> {
        guard mutation.kind == .createDraft,
              mutation.headBranch != nil,
              mutation.baseBranch != nil else { return .failure(.malformedResponse) }
        return await mutate(repository: mutation.repository, suffix: GitHubPullRequestMutationWire.path(for: mutation), method: GitHubPullRequestMutationWire.method(for: mutation), payload: GitHubPullRequestMutationWire.payload(for: mutation))
    }

    func updatePullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError> {
        guard mutation.kind == .updateTitleAndBody, mutation.number != nil else { return .failure(.malformedResponse) }
        return await mutate(repository: mutation.repository, suffix: GitHubPullRequestMutationWire.path(for: mutation), method: GitHubPullRequestMutationWire.method(for: mutation), payload: GitHubPullRequestMutationWire.payload(for: mutation))
    }

    private func mutate(repository: GitHubRepositoryReference, suffix: String, method: String, payload: [String: Any]) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError> {
        do {
            guard let response = try await requestJSON(repository: repository, suffix: suffix, method: method, body: payload) as? [String: Any],
                  let summary = GitHubPullRequestParser.parse(response) else { return .failure(.malformedResponse) }
            return .success(summary)
        } catch let error as GitHubCodeHostError { return .failure(error) }
        catch { return .failure(.unavailable) }
    }

    private func enrich(_ summary: GitHubPullRequestSummary, repository: GitHubRepositoryReference) async -> GitHubPullRequestSummary {
        guard let detail = try? await requestJSON(repository: repository, suffix: "/pulls/\(summary.number)") as? [String: Any] else { return summary }
        var payload = detail
        if let sha = (detail["head"] as? [String: Any])?["sha"] as? String {
            if let checks = try? await requestJSON(repository: repository, suffix: "/commits/\(sha)/check-runs", query: [URLQueryItem(name: "per_page", value: "50")]) as? [String: Any], let rows = checks["check_runs"] as? [[String: Any]] {
                payload["checks"] = rows
            }
        }
        if let reviews = try? await requestJSON(repository: repository, suffix: "/pulls/\(summary.number)/reviews", query: [URLQueryItem(name: "per_page", value: "50")]) as? [[String: Any]] {
            payload["reviews"] = reviews
        }
        return GitHubPullRequestParser.parse(payload) ?? summary
    }

    private func requestJSON(repository: GitHubRepositoryReference, suffix: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Any {
        guard var components = URLComponents(url: repository.webURL, resolvingAgainstBaseURL: false) else { throw GitHubCodeHostError.invalidEndpoint }
        components.scheme = "https"
        components.path = repository.apiRepositoryPath + suffix
        components.queryItems = query
        guard let url = components.url else { throw GitHubCodeHostError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // Never persist credentials in the Dock. When supplied by the launch
        // environment, use a short-lived token for private repositories and
        // higher GitHub API limits. GH_TOKEN is the GitHub CLI convention;
        // GITHUB_TOKEN supports CI and other launchers.
        let token = Self.localGitHubToken()
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubCodeHostError.unavailable }
        // GitHub intentionally returns 404 for private repositories when the
        // caller is unauthenticated, so treat it like an auth failure too.
        if http.statusCode == 401 || http.statusCode == 403 || http.statusCode == 404 { throw GitHubCodeHostError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw GitHubCodeHostError.unavailable }
        return try JSONSerialization.jsonObject(with: data)
    }
}
