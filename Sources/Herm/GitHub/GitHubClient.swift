import Foundation

enum GitHubRequestError: Error, LocalizedError, Equatable {
    case unauthorized, forbidden, notFound, unavailable, malformed, changed
    case rateLimited(Date?)
    var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub sign-in is required. Check your credentials and retry."
        case .forbidden: "GitHub denied access to this operation. Check repository or Projects permissions."
        case .notFound: "This GitHub resource was not found or is not accessible."
        case .unavailable: "GitHub is unavailable. Your last successful data has been retained."
        case .malformed: "GitHub returned an unreadable response."
        case .changed: "This item changed on GitHub. Refresh and review your changes before saving again."
        case .rateLimited(let date): date.map { "GitHub rate limit reached. Retry after \($0.formatted(date: .omitted, time: .shortened))." } ?? "GitHub rate limit reached. Retry later."
        }
    }
}

struct GitHubCoverage: Equatable, Sendable {
    var total: Int? = nil
    var loaded = 0
    var partial = false
    var message: String? = nil
    var label: String? { partial ? (message ?? "Showing \(loaded) loaded results. Narrow your search for complete coverage.") : nil }
}

struct GitHubPage<Item: Sendable>: Sendable {
    var items: [Item]
    var coverage: GitHubCoverage
}

/// Raw payloads never escape the adapter layer into a view or durable state.
struct GitHubRawPage {
    var rows: [[String: Any]]
    var coverage: GitHubCoverage
}

private actor GitHubRateLimitGate {
    private var retryAt: Date?
    func check() throws {
        if let retryAt, retryAt > .now { throw GitHubRequestError.rateLimited(retryAt) }
        retryAt = nil
    }
    func deferRequests(until date: Date?) { retryAt = date ?? .now.addingTimeInterval(60) }
}

struct GitHubClient: Sendable {
    private let rateLimit = GitHubRateLimitGate()
    let transport: any GitHubIssueTransport
    init(transport: any GitHubIssueTransport = URLSession(configuration: .ephemeral)) { self.transport = transport }

    func request(_ path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        try Task.checkCancellation()
        try await rateLimit.check()
        guard path.hasPrefix("/"), !path.contains(".."), var components = URLComponents(string: "https://api.github.com" + path) else { throw GitHubRequestError.malformed }
        components.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        guard let url = components.url else { throw GitHubRequestError.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = GitHubCodeHostService.requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await GitHubCodeHostService.localGitHubToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GitHubRequestError.unavailable }
        if http.statusCode == 429 || ((http.statusCode == 403) && (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.value(forHTTPHeaderField: "Retry-After") != nil)) {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { Date.now.addingTimeInterval($0) }
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            await rateLimit.deferRequests(until: retry ?? reset)
            throw GitHubRequestError.rateLimited(retry ?? reset)
        }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw GitHubRequestError.unauthorized
        case 403: throw GitHubRequestError.forbidden
        case 404: throw GitHubRequestError.notFound
        case 409, 412: throw GitHubRequestError.changed
        default: throw GitHubRequestError.unavailable
        }
        if data.isEmpty { return [String: Any]() }
        guard data.count <= 16 * 1_024 * 1_024 else { throw GitHubRequestError.malformed }
        return try JSONSerialization.jsonObject(with: data)
    }

    func graphQL(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard let payload = try await request("/graphql", method: "POST", body: ["query": query, "variables": variables]) as? [String: Any] else { throw GitHubRequestError.malformed }
        if let errors = payload["errors"] as? [[String: Any]], !errors.isEmpty {
            if errors.contains(where: { ($0["type"] as? String) == "RATE_LIMITED" }) {
                await rateLimit.deferRequests(until: nil); throw GitHubRequestError.rateLimited(nil)
            }
            if errors.contains(where: { ($0["type"] as? String) == "FORBIDDEN" }) { throw GitHubRequestError.forbidden }
            throw GitHubRequestError.unavailable
        }
        guard let data = payload["data"] as? [String: Any] else { throw GitHubRequestError.malformed }
        return data
    }

    func pages(_ path: String, query: [String: String] = [:], key: String? = nil, search: Bool = false) async throws -> GitHubRawPage {
        var rows: [[String: Any]] = []
        var coverage = GitHubCoverage()
        let limit = search ? 10 : 30
        for page in 1...limit {
            var parameters = query; parameters["per_page"] = "100"; parameters["page"] = String(page)
            if search { parameters["sort"] = "updated"; parameters["order"] = "desc" }
            do {
                let raw = try await request(path, query: parameters)
                let payload = raw as? [String: Any]
                guard let batch = (key.flatMap { payload?[$0] } ?? raw) as? [[String: Any]] else { throw GitHubRequestError.malformed }
                rows += batch
                coverage.loaded = rows.count
                coverage.total = (payload?["total_count"] as? Int) ?? coverage.total
                if payload?["incomplete_results"] as? Bool == true { coverage.partial = true }
                if batch.count < 100 { return GitHubRawPage(rows: rows, coverage: coverage) }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                guard !rows.isEmpty else { throw error }
                coverage.partial = true; coverage.message = "Some results could not be loaded. \(error.localizedDescription)"
                return GitHubRawPage(rows: rows, coverage: coverage)
            }
        }
        coverage.partial = coverage.partial || (coverage.total.map { $0 > rows.count } ?? true)
        return GitHubRawPage(rows: rows, coverage: coverage)
    }
}
