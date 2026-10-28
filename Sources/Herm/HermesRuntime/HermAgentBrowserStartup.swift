import Foundation

@MainActor
final class HermAgentBrowserStartup {
    struct Endpoint {
        let port: Int
        let ws: URL
    }

    private let now: () -> Duration
    private let sleep: (Duration) async throws -> Void
    private let load: (URLRequest) async throws -> (Data, URLResponse)
    private let session: URLSession?

    init(
        now: @escaping () -> Duration = {
            .seconds(ProcessInfo.processInfo.systemUptime)
        },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        load: ((URLRequest) async throws -> (Data, URLResponse))? = nil
    ) {
        self.now = now
        self.sleep = sleep
        if let load {
            self.load = load
            session = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 0.5
            configuration.timeoutIntervalForResource = 0.5
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration)
            self.session = session
            self.load = { try await session.data(for: $0) }
        }
    }

    func close() { session?.invalidateAndCancel() }

    func endpoint(_ file: URL, deadline: Duration) async throws -> Endpoint? {
        try Task.checkCancellation()
        let result = await Self.validatedEndpoint(file) { port in
            guard let probe = URL(string: "http://127.0.0.1:\(port)/json/version"),
                let result = try? await self.request(probe, deadline: deadline), result.1.statusCode == 200
            else { return nil }
            return result.0
        }
        try Task.checkCancellation()
        return result
    }

    static func validatedEndpoint(_ file: URL, fetchVersion: (Int) async -> Data?) async -> Endpoint? {
        guard let lines = try? String(contentsOf: file, encoding: .utf8).split(separator: "\n"), lines.count == 2,
            let port = Int(lines[0]), (1...65535).contains(port), lines[1].hasPrefix("/devtools/browser/"),
            let ws = URL(string: "ws://127.0.0.1:\(port)\(lines[1])"),
            ws.path == String(lines[1]), ws.query == nil, ws.fragment == nil,
            let data = await fetchVersion(port),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let value = json["webSocketDebuggerUrl"] as? String, value == ws.absoluteString
        else { return nil }
        return Endpoint(port: port, ws: ws)
    }

    func occupied(_ port: Int, deadline: Duration) async throws -> Bool {
        try await request(URL(string: "http://127.0.0.1:\(port)/json/version")!, deadline: deadline) != nil
    }

    private func request(_ url: URL, deadline: Duration) async throws -> (Data, HTTPURLResponse)? {
        try Task.checkCancellation()
        let remaining = deadline - now()
        guard remaining > .zero else { return nil }
        let components = remaining.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        var request = URLRequest(url: url)
        request.timeoutInterval = min(0.5, seconds)
        do {
            let (data, response) = try await load(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { return nil }
            return (data, response)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return nil
        }
    }

    func preflightDeadline() -> Duration { now() + .milliseconds(500) }

    func waitForEndpoint(_ file: URL, isRunning: () -> Bool) async throws -> Endpoint {
        let deadline = now() + .seconds(15)
        while now() < deadline {
            try Task.checkCancellation()
            guard isRunning() else { throw startupError() }
            let candidate = try await endpoint(file, deadline: deadline)
            try Task.checkCancellation()
            guard isRunning(), now() < deadline else { throw startupError() }
            if let candidate { return candidate }
            let remaining = deadline - now()
            if remaining > .zero { try await sleep(min(.milliseconds(50), remaining)) }
        }
        try Task.checkCancellation()
        throw startupError()
    }

    private func startupError() -> NSError {
        NSError(
            domain: "Herm.AgentBrowser", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "The browser didn't start remote debugging."
            ])
    }
}
