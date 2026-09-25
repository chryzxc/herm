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
    func pullRequests(for repository: GitHubRepositoryReference) async -> Result<[GitHubPullRequestSummary], GitHubCodeHostError>
    func createDraftPullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError>
    func updatePullRequest(_ mutation: GitHubPullRequestMutation) async -> Result<GitHubPullRequestSummary, GitHubCodeHostError>
}

struct GitHubCodeHostService: GitHubCodeHostClient, Sendable {
    nonisolated static let requestTimeout: TimeInterval = 15
    private let session: URLSession

    init(session: URLSession = .init(configuration: .ephemeral)) { self.session = session }

    /// Shared by the read-only pull-request center. Tokens are never stored
    /// by Dock; this only consults the launch environment or `gh` keychain.
    ///
    /// The `gh` lookup spawns subprocesses and blocks on `waitUntilExit()`,
    /// so it runs on a detached task and is cached briefly — called from a
    /// `@MainActor` refresh, the synchronous prefix of this call otherwise
    /// ran on the main thread and produced multi-second UI hangs.
    static func localGitHubToken() async -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let token = [environment["GH_TOKEN"], environment["GITHUB_TOKEN"]]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return token
        }
        if let cached = await GitHubTokenCache.shared.cachedToken() {
            return cached
        }
        let token = await Task.detached(priority: .utility) { resolveGHCLIToken() }.value
        await GitHubTokenCache.shared.store(token)
        return token
    }

    private static func resolveGHCLIToken() -> String? {
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
        let token = await Self.localGitHubToken()
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubCodeHostError.unavailable }
        if let error = Self.error(forHTTPStatus: http.statusCode) { throw error }
        guard (200..<300).contains(http.statusCode) else { throw GitHubCodeHostError.unavailable }
        return try JSONSerialization.jsonObject(with: data)
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
private actor GitHubTokenCache {
    static let shared = GitHubTokenCache()
    private var token: String?
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 60

    func cachedToken() -> String?? {
        guard let fetchedAt, Date().timeIntervalSince(fetchedAt) < ttl else { return nil }
        return .some(token)
    }

    func store(_ token: String?) {
        self.token = token
        self.fetchedAt = Date()
    }
}
