import Foundation

enum GitHubRequestError: Error, LocalizedError, Equatable {
    case unauthorized, forbidden, insufficientScopes, notFound, unavailable, malformed, changed
    case rateLimited(Date?)
    var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub sign-in is required. Check your credentials and retry."
        case .insufficientScopes: "Your GitHub credential needs additional permissions for this operation."
        case .forbidden: "GitHub denied access to this operation. Check repository or Projects permissions."
        case .notFound: "This GitHub resource was not found or is not accessible."
        case .unavailable: "GitHub is unavailable. Your last successful data has been retained."
        case .malformed: "GitHub returned an unreadable response."
        case .changed: "This item changed on GitHub. Refresh and review your changes before saving again."
        case .rateLimited(let date):
            date.map { "GitHub rate limit reached. Retry after \($0.formatted(date: .omitted, time: .shortened))." }
                ?? "GitHub rate limit reached. Retry later."
        }
    }
}

struct GitHubCoverage: Equatable, Sendable {
    var total: Int? = nil
    var loaded = 0
    var partial = false
    var message: String? = nil
    var label: String? {
        partial ? (message ?? "Showing \(loaded) loaded results. Narrow your search for complete coverage.") : nil
    }
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
    /// One session for every client so GitHub requests reuse warm TLS connections.
    static let sharedSession = URLSession(configuration: .ephemeral)
    init(transport: any GitHubIssueTransport = GitHubClient.sharedSession) { self.transport = transport }

    func request(
        _ path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil,
        accept: String = "application/vnd.github+json"
    ) async throws -> Any {
        try await response(path, query: query, method: method, body: body, accept: accept).payload
    }

    private func response(
        _ path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil,
        accept: String = "application/vnd.github+json"
    ) async throws -> (payload: Any, http: HTTPURLResponse) {
        try Task.checkCancellation()
        try await rateLimit.check()
        // Compare routes contain `...`; reject traversal segments rather than filename punctuation.
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?"), !path.contains("#"),
            let decoded = path.removingPercentEncoding, !decoded.contains("\\"),
            !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
            var components = URLComponents(string: "https://api.github.com" + path)
        else { throw GitHubRequestError.malformed }
        components.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        guard let url = components.url else { throw GitHubRequestError.malformed }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = GitHubCodeHostService.requestTimeout
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await GitHubCodeHostService.localGitHubToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GitHubRequestError.unavailable }
        if http.statusCode == 429
            || ((http.statusCode == 403)
                && (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                    || http.value(forHTTPHeaderField: "Retry-After") != nil))
        {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map {
                Date.now.addingTimeInterval($0)
            }
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init).map(
                Date.init(timeIntervalSince1970:))
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
        if data.isEmpty { return ([String: Any](), http) }
        guard data.count <= 16 * 1_024 * 1_024 else { throw GitHubRequestError.malformed }
        return (try JSONSerialization.jsonObject(with: data), http)
    }

    func viewerLogin() async -> Result<String, GitHubRequestError> {
        do {
            guard let row = try await request("/user") as? [String: Any],
                let login = row["login"] as? String, !login.isEmpty
            else { return .failure(.malformed) }
            return .success(login)
        } catch let error as GitHubRequestError { return .failure(error) } catch { return .failure(.unavailable) }
    }

    func graphQL(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard
            let payload = try await request("/graphql", method: "POST", body: ["query": query, "variables": variables])
                as? [String: Any]
        else { throw GitHubRequestError.malformed }
        if let errors = payload["errors"] as? [[String: Any]], !errors.isEmpty {
            if errors.contains(where: { ($0["type"] as? String) == "RATE_LIMITED" }) {
                await rateLimit.deferRequests(until: nil)
                throw GitHubRequestError.rateLimited(nil)
            }
            if errors.contains(where: { ($0["type"] as? String) == "INSUFFICIENT_SCOPES" }) {
                throw GitHubRequestError.insufficientScopes
            }
            if errors.contains(where: { ($0["type"] as? String) == "FORBIDDEN" }) { throw GitHubRequestError.forbidden }
            throw GitHubRequestError.unavailable
        }
        guard let data = payload["data"] as? [String: Any] else { throw GitHubRequestError.malformed }
        return data
    }

    func pages(_ path: String, query: [String: String] = [:], key: String? = nil, search: Bool = false) async throws
        -> GitHubRawPage
    {
        var rows: [[String: Any]] = []
        var coverage = GitHubCoverage()
        let limit = search ? 10 : 30
        func parameters(page: Int) -> [String: String] {
            var parameters = query
            parameters["per_page"] = "100"
            parameters["page"] = String(page)
            if search {
                parameters["sort"] = "updated"
                parameters["order"] = "desc"
            }
            return parameters
        }
        func batch(_ raw: Any) throws -> [[String: Any]] {
            guard let batch = (key.flatMap { (raw as? [String: Any])?[$0] } ?? raw) as? [[String: Any]] else {
                throw GitHubRequestError.malformed
            }
            return batch
        }
        /// Folds one page in; returns false once the listing is exhausted.
        func append(_ raw: Any) throws -> Bool {
            let rowsInPage = try batch(raw)
            let payload = raw as? [String: Any]
            rows += rowsInPage
            coverage.loaded = rows.count
            coverage.total = (payload?["total_count"] as? Int) ?? coverage.total
            if payload?["incomplete_results"] as? Bool == true { coverage.partial = true }
            return rowsInPage.count == 100
        }
        func keepPartial(after error: Error) throws -> GitHubRawPage {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            guard !rows.isEmpty else { throw error }
            coverage.partial = true
            coverage.message = "Some results could not be loaded. \(error.localizedDescription)"
            return GitHubRawPage(rows: rows, coverage: coverage)
        }

        let first = try await response(path, query: parameters(page: 1))
        guard try append(first.payload) else { return GitHubRawPage(rows: rows, coverage: coverage) }
        // Once page 1 states the page count, fetch the rest concurrently instead of one round trip at a time.
        if let last = Self.lastPage(first.http, total: coverage.total, search: search), last > 1 {
            let pageNumbers = Array(2...min(last, limit))
            let fetch: @Sendable (Int, [String: String]) async -> PageResult = { [self] page, query in
                do { return PageResult(page: page, result: .success(try await request(path, query: query))) } catch {
                    return PageResult(page: page, result: .failure(error))
                }
            }
            let results = await withTaskGroup(of: PageResult.self) { group in
                var next = pageNumbers.map { ($0, parameters(page: $0)) }.makeIterator()
                for _ in 0..<6 {
                    guard let (page, query) = next.next() else { break }
                    group.addTask { await fetch(page, query) }
                }
                var results: [Int: Result<Any, Error>] = [:]
                while let fetched = await group.next() {
                    results[fetched.page] = fetched.result
                    if let (page, query) = next.next() { group.addTask { await fetch(page, query) } }
                }
                return results
            }
            for page in pageNumbers {
                do {
                    guard try append(try results[page, default: .failure(GitHubRequestError.unavailable)].get()) else {
                        return GitHubRawPage(rows: rows, coverage: coverage)
                    }
                } catch { return try keepPartial(after: error) }
            }
        } else {
            for page in 2...limit {
                do {
                    guard try append(try await request(path, query: parameters(page: page))) else {
                        return GitHubRawPage(rows: rows, coverage: coverage)
                    }
                } catch { return try keepPartial(after: error) }
            }
        }
        coverage.partial = coverage.partial || (coverage.total.map { $0 > rows.count } ?? true)
        return GitHubRawPage(rows: rows, coverage: coverage)
    }

    /// Freshly parsed JSON owned by one page fetch; it is never mutated after parsing.
    private struct PageResult: @unchecked Sendable {
        let page: Int
        let result: Result<Any, Error>
    }

    /// The final page number from search `total_count` or the REST `Link: rel="last"` header, when known.
    nonisolated static func lastPage(_ response: HTTPURLResponse, total: Int?, search: Bool) -> Int? {
        if search, let total { return (total + 99) / 100 }
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"last\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end,
                let components = URLComponents(string: String(part[part.index(after: start)..<end]))
            else { return nil }
            return components.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init)
        }
        return nil
    }
}
