import AppKit
import CryptoKit
import Network

struct GatewayNativeTokens: Codable, Equatable {
    let access: String
    let refresh: String
    let expiresAt: Double
    let provider: String

    init(_ json: [String: Any]) throws {
        guard let access = json["access_token"] as? String, !access.isEmpty, !access.contains("\r"),
            !access.contains("\n")
        else {
            throw HermesGateway.GatewayError.malformedResponse
        }
        self.access = access
        refresh = json["refresh_token"] as? String ?? ""
        expiresAt = (json["expires_at"] as? NSNumber)?.doubleValue ?? 0
        provider = json["provider"] as? String ?? ""
    }
}

@MainActor
final class GatewayNativeAuthentication {
    static let shared = GatewayNativeAuthentication()
    private var cached: [URL: GatewayNativeTokens] = [:]
    private var loaded = Set<URL>()
    private var refreshing: [URL: Task<String?, Error>] = [:]
    private var generations: [URL: Int] = [:]
    private let readSecret: (String) throws -> String?
    private let writeSecret: (String, String) throws -> Void
    private let removeSecret: (String) throws -> Void
    private let refreshTokens: (URL, GatewayNativeTokens) async throws -> (Int, [String: Any])

    init(
        readSecret: @escaping (String) throws -> String? = GatewayTokenStore.read,
        writeSecret: @escaping (String, String) throws -> Void = GatewayTokenStore.write,
        removeSecret: @escaping (String) throws -> Void = GatewayTokenStore.remove,
        refreshTokens: @escaping (URL, GatewayNativeTokens) async throws -> (Int, [String: Any]) = { base, tokens in
            try await GatewayHTTP.request(
                GatewayConnectionSettings.endpoint(base, "/auth/native/refresh"), method: "POST",
                body: ["refresh_token": tokens.refresh, "provider": tokens.provider])
        }
    ) {
        self.readSecret = readSecret
        self.writeSecret = writeSecret
        self.removeSecret = removeSecret
        self.refreshTokens = refreshTokens
    }

    static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func callbackCode(_ path: String, state: String) throws -> String {
        guard let url = URLComponents(string: "http://127.0.0.1" + path), url.path == "/callback",
            !state.isEmpty, url.queryItems?.first(where: { $0.name == "state" })?.value == state,
            url.queryItems?.first(where: { $0.name == "error" }) == nil,
            let code = url.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else {
            throw GatewayConnectionError.unavailable("The gateway sign-in callback was invalid. Try signing in again.")
        }
        return code
    }

    func hasSession(_ base: URL) throws -> Bool { try load(base) != nil }

    private func load(_ base: URL) throws -> GatewayNativeTokens? {
        if !loaded.contains(base) {
            if let text = try readSecret("oauth:" + base.absoluteString) {
                cached[base] = try JSONDecoder().decode(GatewayNativeTokens.self, from: Data(text.utf8))
            }
            loaded.insert(base)
        }
        return cached[base]
    }

    private func store(_ tokens: GatewayNativeTokens, base: URL) throws {
        let data = try JSONEncoder().encode(tokens)
        try writeSecret("oauth:" + base.absoluteString, String(decoding: data, as: UTF8.self))
        loaded.insert(base)
        cached[base] = tokens
    }

    func signOut(_ base: URL) throws {
        try removeSecret("oauth:" + base.absoluteString)
        generations[base, default: 0] += 1
        refreshing.removeValue(forKey: base)?.cancel()
        loaded.insert(base)
        cached[base] = nil
    }

    func accessToken(_ base: URL, force: Bool = false) async throws -> String? {
        guard let tokens = try load(base) else { return nil }
        if !force && tokens.expiresAt > Date().timeIntervalSince1970 + 60 { return tokens.access }
        if let task = refreshing[base] { return try await task.value }
        guard !tokens.refresh.isEmpty else { return tokens.access }
        let generation = generations[base, default: 0]
        let task = Task { @MainActor in
            let (status, json) = try await self.refreshTokens(base, tokens)
            guard self.generations[base, default: 0] == generation else { throw CancellationError() }
            if status == 401 {
                try self.signOut(base)
                return nil as String?
            }
            guard (200..<300).contains(status) else { throw HermesGateway.GatewayError.httpError(status) }
            let refreshed = try GatewayNativeTokens(json)
            try self.store(refreshed, base: base)
            return refreshed.access
        }
        refreshing[base] = task
        defer { if generations[base, default: 0] == generation { refreshing[base] = nil } }
        return try await task.value
    }

    func signIn(_ base: URL) async throws {
        let generation = generations[base, default: 0]
        let state = UUID().uuidString + UUID().uuidString
        let verifier =
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let callback = GatewayOAuthCallback(state: state)
        let redirect = try await callback.start()
        defer { callback.stop() }
        var authorize = URLComponents(
            url: try GatewayConnectionSettings.endpoint(base, "/auth/native/authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "code_challenge", value: Self.challenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = authorize.url, NSWorkspace.shared.open(url) else {
            throw GatewayConnectionError.unavailable("Could not open the browser for gateway sign-in.")
        }
        let code = try await callback.code()
        let (status, json) = try await GatewayHTTP.request(
            GatewayConnectionSettings.endpoint(base, "/auth/native/token"), method: "POST",
            body: ["code": code, "code_verifier": verifier])
        guard (200..<300).contains(status) else { throw HermesGateway.GatewayError.httpError(status) }
        guard generations[base, default: 0] == generation else { throw CancellationError() }
        generations[base, default: 0] += 1
        refreshing.removeValue(forKey: base)?.cancel()
        try store(GatewayNativeTokens(json), base: base)
    }
}

@MainActor
final class GatewayOAuthCallback {
    private let state: String
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var waiting: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timer: Task<Void, Never>?
    private var connections: [NWConnection] = []

    init(state: String) { self.state = state }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] status in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = status, let port = listener?.port,
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/callback")
                {
                    self.ready?.resume(returning: url)
                    self.ready = nil
                } else if case .failed(let error) = status {
                    self.finish(.failure(error))
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                self?.finish(.failure(GatewayConnectionError.unavailable("Browser sign-in timed out. Try again.")))
            }
            listener.start(queue: .main)
        }
    }

    func code() async throws -> String {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else {
            connection.cancel()
            return
        }
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .failed = state { connection.cancel() }
            if case .cancelled = state {
                Task { @MainActor in self?.connections.removeAll { $0 === connection } }
            }
        }
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 8192, error == nil else {
                    connection.cancel()
                    return
                }
                let text = String(decoding: buffer, as: UTF8.self)
                if !text.contains("\r\n\r\n") {
                    if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                    return
                }
                let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard parts.count == 3, parts[0] == "GET" else {
                    connection.cancel()
                    return
                }
                do {
                    let code = try GatewayNativeAuthentication.callbackCode(String(parts[1]), state: self.state)
                    let body = "Signed in to Herm. You can close this browser tab."
                    let response =
                        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(
                        content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    self.finish(.success(code))
                } catch {
                    // An unsolicited loopback request cannot abort the real OAuth flow.
                    connection.cancel()
                }
            }
        }
    }

    private func finish(_ value: Result<String, Error>) {
        guard result == nil else { return }
        result = value
        timer?.cancel()
        timer = nil
        if case .failure(let error) = value {
            ready?.resume(throwing: error)
            ready = nil
        }
        waiting?.resume(with: value)
        waiting = nil
        listener?.cancel()
    }

    func stop() {
        finish(.failure(CancellationError()))
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }
}
