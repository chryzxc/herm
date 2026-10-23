import Foundation

enum GitHubCodeHostError: Error, Equatable, Sendable {
    case invalidEndpoint
    case unavailable
    case unauthorized
    case forbidden
    case repositoryNotFound
    case malformedResponse
}

extension GitHubCodeHostError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidEndpoint: "invalid GitHub endpoint"
        case .unavailable: "GitHub API unavailable or rate-limited"
        case .unauthorized: "authentication required (private repository or expired credentials)"
        case .forbidden: "GitHub access was denied or rate-limited"
        case .repositoryNotFound: "GitHub repository was not found or is not accessible"
        case .malformedResponse: "GitHub returned an unreadable response"
        }
    }
}

protocol GitHubCodeHostClient: Sendable {
    func pullRequests(for repository: GitHubRepositoryReference) async -> Result<
        [GitHubPullRequestSummary], GitHubCodeHostError
    >
    func createDraftPullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<
        GitHubPullRequestSummary, GitHubCodeHostError
    >
    func updatePullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<
        GitHubPullRequestSummary, GitHubCodeHostError
    >
}

struct GitHubCodeHostService: GitHubCodeHostClient, Sendable {
    nonisolated static let requestTimeout: TimeInterval = 15
    private let session: URLSession
    private let apiClient: GitHubClient

    init(session: URLSession = .init(configuration: .ephemeral)) {
        self.session = session
        self.apiClient = GitHubClient(transport: session)
    }
    init(client: GitHubClient) {
        self.session = URLSession(configuration: .ephemeral)
        self.apiClient = client
    }

    /// Shared by the read-only pull-request center. Tokens are never stored
    /// by Dock; this only consults the launch environment or `gh` keychain.
    ///
    /// The `gh` lookup spawns a subprocess, so it runs on a detached task and
    /// is cached briefly. Concurrent callers share that lookup, and the
    /// subprocess has a deadline so credential resolution cannot pin a loading
    /// state indefinitely.
    static func localGitHubToken() async -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let token = [environment["GH_TOKEN"], environment["GITHUB_TOKEN"]]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        {
            return token
        }
        return await GitHubTokenCache.shared.token { resolveGHCLIToken() }
    }

    private static func resolveGHCLIToken() -> String? {
        // Reuse the user's existing GitHub CLI credential without persisting
        // or logging it. App bundles often have a reduced PATH, so check the
        // standard Homebrew locations explicitly and fall back to `gh`.
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", "gh"]
        for executable in candidates {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable == "gh" ? "/usr/bin/env" : executable)
            process.arguments =
                executable == "gh"
                ? ["gh", "auth", "token", "--hostname", "github.com"] : ["auth", "token", "--hostname", "github.com"]
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
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
                guard finished.wait(timeout: .now() + 5) == .success else {
                    process.terminate()
                    return nil
                }
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

    /// PRs the signed-in user merged in `[since, until)`, across every repository, in one search call.
    /// Empty when there is no token (`author:@me` needs one) or GitHub is unreachable; the calendar
    /// just shows no PRs then. ponytail: first 100 only, page through `Link` if a month ever exceeds that.
    func mergedPullRequests(since: Date, until: Date) async -> [WorkPullRequest] {
        guard let token = await Self.localGitHubToken(), !token.isEmpty else { return [] }
        let iso = ISO8601DateFormatter()
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value:
                    "is:pr is:merged author:@me merged:\(iso.string(from: since))..\(iso.string(from: until.addingTimeInterval(-1)))"
            ),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let items = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let number = item["number"] as? Int, let title = item["title"] as? String,
                let repoURL = item["repository_url"] as? String,
                let merged = ((item["pull_request"] as? [String: Any])?["merged_at"] as? String)
                    ?? (item["closed_at"] as? String),
                let date = WorkCalendarIndex.parseDate(merged)
            else { return nil }
            return WorkPullRequest(
                repo: String(repoURL.split(separator: "/").last ?? ""), number: number, title: title,
                url: (item["html_url"] as? String).flatMap(URL.init), mergedAt: date)
        }
    }

    func pullRequests(for repository: GitHubRepositoryReference) async -> Result<
        [GitHubPullRequestSummary], GitHubCodeHostError
    > {
        let rows: [[String: Any]]
        do {
            guard
                let response = try await requestJSON(
                    repository: repository, suffix: "/pulls",
                    query: [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "per_page", value: "20")])
                    as? [[String: Any]]
            else { return .failure(.malformedResponse) }
            rows = response
        } catch let error as GitHubCodeHostError { return .failure(error) } catch { return .failure(.unavailable) }
        guard !rows.isEmpty else { return .success([]) }
        var result: [GitHubPullRequestSummary] = []
        for row in rows {
            guard let summary = GitHubPullRequestParser.parse(row) else { continue }
            result.append(await enrich(summary, repository: repository))
        }
        return .success(result)
    }

    func createDraftPullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<
        GitHubPullRequestSummary, GitHubCodeHostError
    > {
        guard mutation.kind == .createDraft,
            mutation.headBranch != nil,
            mutation.baseBranch != nil
        else { return .failure(.malformedResponse) }
        return await mutate(
            repository: mutation.repository, suffix: GitHubPullRequestMutationWire.path(for: mutation),
            method: GitHubPullRequestMutationWire.method(for: mutation),
            payload: GitHubPullRequestMutationWire.payload(for: mutation))
    }

    func updatePullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<
        GitHubPullRequestSummary, GitHubCodeHostError
    > {
        guard mutation.kind == .updateTitleAndBody, mutation.number != nil else { return .failure(.malformedResponse) }
        return await mutate(
            repository: mutation.repository, suffix: GitHubPullRequestMutationWire.path(for: mutation),
            method: GitHubPullRequestMutationWire.method(for: mutation),
            payload: GitHubPullRequestMutationWire.payload(for: mutation))
    }

    private func mutate(repository: GitHubRepositoryReference, suffix: String, method: String, payload: [String: Any])
        async -> Result<GitHubPullRequestSummary, GitHubCodeHostError>
    {
        do {
            guard
                let response = try await requestJSON(
                    repository: repository, suffix: suffix, method: method, body: payload) as? [String: Any],
                let summary = GitHubPullRequestParser.parse(response)
            else { return .failure(.malformedResponse) }
            return .success(summary)
        } catch let error as GitHubCodeHostError { return .failure(error) } catch { return .failure(.unavailable) }
    }

    private func enrich(_ summary: GitHubPullRequestSummary, repository: GitHubRepositoryReference) async
        -> GitHubPullRequestSummary
    {
        guard
            let detail = try? await requestJSON(repository: repository, suffix: "/pulls/\(summary.number)")
                as? [String: Any]
        else { return summary }
        var payload = detail
        if let sha = (detail["head"] as? [String: Any])?["sha"] as? String {
            if let checks = try? await requestJSON(
                repository: repository, suffix: "/commits/\(sha)/check-runs",
                query: [URLQueryItem(name: "per_page", value: "50")]) as? [String: Any],
                let rows = checks["check_runs"] as? [[String: Any]]
            {
                payload["checks"] = rows
            }
        }
        if let reviews = try? await requestJSON(
            repository: repository, suffix: "/pulls/\(summary.number)/reviews",
            query: [URLQueryItem(name: "per_page", value: "50")]) as? [[String: Any]]
        {
            payload["reviews"] = reviews
        }
        return GitHubPullRequestParser.parse(payload) ?? summary
    }

    private func requestJSON(
        repository: GitHubRepositoryReference, suffix: String, method: String = "GET", query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Any {
        var parameters: [String: String] = [:]
        for item in query { parameters[item.name] = item.value }
        do {
            return try await apiClient.request(
                repository.apiRepositoryPath + suffix, query: parameters, method: method, body: body)
        } catch GitHubRequestError.unauthorized { throw GitHubCodeHostError.unauthorized } catch GitHubRequestError
            .forbidden
        { throw GitHubCodeHostError.forbidden } catch GitHubRequestError.notFound {
            throw GitHubCodeHostError.repositoryNotFound
        } catch { throw GitHubCodeHostError.unavailable }
    }

    /// Only an HTTP 401 is proof that the credential itself needs attention.
    /// GitHub uses 403 and 404 for several authenticated states, including
    /// missing repository permissions and a private repository that is hidden
    /// from the current account. Treating those as a sign-out prompt caused
    /// the Dock to ask signed-in people to reset their GitHub session.
    static func error(forHTTPStatus statusCode: Int) -> GitHubCodeHostError? {
        switch statusCode {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .repositoryNotFound
        default: nil
        }
    }
}

/// Short-lived cache for the resolved `gh` CLI token so repeated refreshes
/// don't each spawn subprocesses. `nil` results are cached too, so an
/// unsigned-in `gh` doesn't get re-probed on every refresh.
actor GitHubTokenCache {
    static let shared = GitHubTokenCache()
    private var token: String?
    private var fetchedAt: Date?
    private var inFlight: Task<String?, Never>?
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    func token(resolving resolver: @escaping @Sendable () -> String?) async -> String? {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl {
            return token
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task.detached(priority: .utility, operation: resolver)
        inFlight = task
        let token = await task.value
        inFlight = nil
        self.token = token
        self.fetchedAt = Date()
        return token
    }
}
