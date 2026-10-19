import Foundation

@MainActor
final class HermesConnectionGate {
    private var inFlight: Task<Void, Error>?

    func perform(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        if let inFlight {
            try await inFlight.value
            return
        }

        let task = Task { @MainActor in
            try await operation()
        }
        inFlight = task
        do {
            try await task.value
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
    }
}

@MainActor
final class HermesGateway: NSObject {
    enum GatewayError: LocalizedError {
        case backendUnavailable, malformedResponse, disconnected
        case imageAttachFailed(String)
        case httpError(Int)
        case httpRefused(Int, String)
        var errorDescription: String? {
            switch self {
            case .backendUnavailable: "Hermes could not start its local backend."
            case .malformedResponse: "Hermes returned an unreadable response."
            case .disconnected: "The connection to Hermes was lost."
            case .imageAttachFailed(let message): message
            case .httpError(let statusCode): "Hermes returned HTTP status \(statusCode)."
            case .httpRefused(_, let detail): detail
            }
        }
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private let workingDirectory: URL?
    private let connectionSettings: GatewayConnectionSettings
    private let connectionSettingsError: String?
    private var baseURL: URL?
    private var sshBridge: GatewaySSHBridge?
    private var backend: Process?
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var port: Int?
    private var token = ""
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var backendOutput = ""
    private var backendStartWaiters: [CheckedContinuation<Void, Error>] = []
    private let connectionGate = HermesConnectionGate()
    private static let maximumBackendOutputLength = 32_768
    /// `URLSessionWebSocketTask` rejects frames over 1 MiB by default and
    /// fails the receive, which tears down the socket. A cold
    /// `session.resume` returns the whole display transcript in one frame, so
    /// long sessions (thousands of messages) exceeded that and surfaced as
    /// "The connection to Hermes was lost." Hermes itself accepts frames up
    /// to 16 MiB for attachments; allow comfortably more than that inbound.
    static let maximumWebSocketMessageSize = 256 * 1024 * 1024

    init(workingDirectory: URL? = nil, connectionSettings: GatewayConnectionSettings? = nil, sessionToken: String? = nil) {
        self.workingDirectory = workingDirectory
        self.connectionSettings = connectionSettings ?? GatewayConnectionStore.shared.launchSettings
        self.connectionSettingsError = connectionSettings == nil ? GatewayConnectionStore.shared.error : nil
        self.token = sessionToken ?? (connectionSettings == nil ? GatewayConnectionStore.shared.launchToken : nil) ?? ""
        super.init()
    }

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        backend?.terminate()
        backendStartWaiters.forEach { $0.resume(throwing: GatewayError.disconnected) }
        backendStartWaiters.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
    }

    func connect() async throws {
        if socket != nil {
            DebugLog.write("connect: socket already exists")
            onConnectionChange?(true)
            return
        }
        try await connectionGate.perform { [weak self] in
            guard let self else { throw GatewayError.disconnected }
            guard self.socket == nil else { return }
            try await self.establishConnection()
        }
    }

    private func establishConnection() async throws {
        DebugLog.write("connect: starting")
        try await prepareEndpoint()
        guard let baseURL else { throw GatewayError.backendUnavailable }
        let request: URLRequest
        if usesBrowserSignIn {
            let (status, json) = try await GatewayHTTP.request(GatewayConnectionSettings.endpoint(baseURL, "/api/auth/ws-ticket"), method: "POST", signIn: true, authBase: baseURL)
            guard (200..<300).contains(status) else { throw GatewayError.httpError(status) }
            guard let ticket = json["ticket"] as? String, !ticket.isEmpty else { throw GatewayError.malformedResponse }
            request = try Self.webSocketRequest(baseURL: baseURL, credential: ticket, ticket: true)
        } else {
            request = try Self.webSocketRequest(baseURL: baseURL, credential: token)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: GatewaySessionDelegate(), delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumWebSocketMessageSize
        socket = task
        task.resume()
        onConnectionChange?(true)
        DebugLog.write("connect: WebSocket task resumed")
        receiveNext()
        // Hermes fails approval/clarify requests fast for a WebSocket client
        // that never says it answers server→client requests.
        Task { [weak self] in
            _ = try? await self?.request("client.capabilities", params: ["server_requests": true])
        }
    }

    /// Hermes asks approval and clarify questions as server→client JSON-RPC
    /// requests (`{id: "srq-…", method, params}`). Project them onto the
    /// `approval.request` / `clarify.request` events the models already
    /// handle; the request id is the one `request.answer` resolves.
    static func event(forServerRequest frame: [String: Any]) -> (type: String, params: [String: Any])? {
        guard let id = frame["id"] as? String, let method = frame["method"] as? String else { return nil }
        var payload = frame["params"] as? [String: Any] ?? [:]
        let sessionID = payload["session_id"] as? String ?? ""
        switch method {
        case "approval":
            // Cancellation identifies the server request; answering identifies the tool approval.
            payload["server_request_id"] = id
        case "clarify":
            // A batch keeps `questions`; the first one also fills the single-question
            // fields for surfaces that show one question (Inbox, notifications).
            if payload["question"] == nil, let first = (payload["questions"] as? [[String: Any]])?.first {
                payload["question"] = first["question"]
                payload["choices"] = first["choices"]
                payload["multi_select"] = first["multi_select"]
            }
            payload["request_id"] = id
        case _ where ValuePrompt.methods.contains(method):
            payload["request_id"] = id
            payload["method"] = method
            return ("prompt.request", ["session_id": sessionID, "payload": payload])
        default:
            return nil
        }
        return ("\(method).request", ["session_id": sessionID, "payload": payload])
    }

    static func webSocketRequest(port: Int, token: String) -> URLRequest {
        // Hermes Agent authenticates the loopback WebSocket upgrade with its
        // per-spawn session token in the URL query. Some Hermes versions also
        // run HTTP middleware before the upgrade and require Bearer auth
        // there, while the /api/ws handler itself rejects header-only auth.
        // Supplying both forms is required for compatibility across those
        // versions.
        try! webSocketRequest(baseURL: URL(string: "http://127.0.0.1:\(port)")!, credential: token)
    }

    static func webSocketRequest(baseURL: URL, credential: String, ticket: Bool = false) throws -> URLRequest {
        guard !credential.isEmpty, !credential.contains("\r"), !credential.contains("\n") else { throw GatewayConnectionError.missingToken }
        var parts = URLComponents(url: try GatewayConnectionSettings.endpoint(baseURL, "/api/ws"), resolvingAgainstBaseURL: false)!
        parts.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: ticket ? "ticket" : "token", value: credential)]
        // Hermes decodes queries as form data; a literal plus would become a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw GatewayError.malformedResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if !ticket { request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        DebugLog.write("request: \(method)")
        if socket == nil { try await connect() }
        let data = try await send(method: method, params: params)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GatewayError.malformedResponse
        }
        return result
    }

    func close() {
        reconnectTask?.cancel(); reconnectTask = nil
        connectionGate.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        urlSession = nil
        socket = nil
        backend?.terminate()
        backend = nil
        port = nil
        baseURL = nil
        sshBridge?.close()
        sshBridge = nil
        backendOutput = ""
        backendStartWaiters.forEach { $0.resume(throwing: GatewayError.disconnected) }
        backendStartWaiters.removeAll()
        pending.values.forEach { $0.resume(throwing: GatewayError.disconnected) }
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        onConnectionChange?(false)
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        try await connect()
        guard let baseURL else { throw GatewayError.backendUnavailable }
        let (status, result) = try await GatewayHTTP.request(GatewayConnectionSettings.endpoint(baseURL, path), token: usesBrowserSignIn ? nil : token, signIn: usesBrowserSignIn, authBase: baseURL)
        guard (200..<300).contains(status) else { throw GatewayError.httpError(status) }
        return result
    }

    /// Authenticated JSON write to the local backend. A refusal's FastAPI
    /// `detail` is surfaced verbatim so the user sees why (e.g. open parents).
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        try await sendHTTP(method, path: path, body: body, timeout: 15)
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await connect()
        guard let baseURL else { throw GatewayError.backendUnavailable }
        let (status, json) = try await GatewayHTTP.request(GatewayConnectionSettings.endpoint(baseURL, path), method: method, token: usesBrowserSignIn ? nil : token, signIn: usesBrowserSignIn, authBase: baseURL, body: body, timeout: timeout)
        guard (200..<300).contains(status) else {
            if let detail = json["detail"] as? String, !detail.isEmpty {
                throw GatewayError.httpRefused(status, detail)
            }
            throw GatewayError.httpError(status)
        }
        return json
    }

    private var usesBrowserSignIn: Bool {
        connectionSettings.mode == .cloud || (connectionSettings.mode == .remote && connectionSettings.authentication == .signIn)
    }

    private func prepareEndpoint() async throws {
        if let connectionSettingsError { throw GatewayConnectionError.unavailable(connectionSettingsError) }
        if baseURL != nil { return }
        switch connectionSettings.mode {
        case .local:
            try await startBackendIfNeeded()
            guard let port else { throw GatewayError.backendUnavailable }
            baseURL = URL(string: "http://127.0.0.1:\(port)")
        case .remote, .cloud:
            let url = try GatewayConnectionSettings.normalizedURL(connectionSettings.remoteURL)
            if !usesBrowserSignIn, token.isEmpty { token = try GatewayConnectionStore.shared.token(for: connectionSettings) }
            baseURL = url
        case .ssh:
            let bridge = GatewaySSHBridge()
            sshBridge = bridge
            let endpoint = try await bridge.connect(connectionSettings)
            baseURL = endpoint.0
            token = endpoint.1
        }
    }

    func testConnection() async throws {
        _ = try await fetchHTTP("/api/status")
        guard let socket else { throw GatewayError.disconnected }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// Relay delivery can wait for an entire agent turn, unlike control RPCs.
    static func requestTimeout(for method: String) -> TimeInterval {
        method == HermesFeatureIDs.ID.botRelayDeliver.rawValue ? 1500 : 15
    }

    private func send(method: String, params: [String: Any]) async throws -> Data {
        guard let socket else { throw GatewayError.disconnected }
        nextID += 1
        let id = nextID
        DebugLog.write("send: id=\(id) method=\(method)")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: body)
        guard let text = String(data: data, encoding: .utf8) else { throw GatewayError.malformedResponse }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.requestTimeout(for: method)))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                    self.timeoutTasks.removeValue(forKey: id)
                    waiting.resume(throwing: NSError(domain: "Hermes", code: 408, userInfo: [NSLocalizedDescriptionKey: "Hermes did not respond in time."]))
                }
            }
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    DebugLog.write("send: id=\(id) failed: \(error.localizedDescription)")
                    self?.timeoutTasks.removeValue(forKey: id)?.cancel()
                    self?.pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        }
    }

    private func sendFrame(_ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func receiveNext() {
        guard let current = socket else { return }
        current.receive { [weak self] result in
            switch result {
            case .failure:
                Task { @MainActor in
                    // A closed or replaced socket's failure is not a drop.
                    guard let self, self.socket === current else { return }
                    self.handleReceiveFailure()
                }
            case .success(let message):
                // Streaming turns deliver many WebSocket frames; decoding off
                // the main actor keeps JSON parsing from contending with UI work.
                let object = Self.decodeWebSocketMessage(message)
                Task { @MainActor in
                    guard let self else { return }
                    if let object {
                        self.handle(object)
                    } else {
                        DebugLog.write("receive: non-JSON or binary message")
                    }
                    if self.socket === current { self.receiveNext() }
                }
            }
        }
    }

    nonisolated private static func decodeWebSocketMessage(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func handleReceiveFailure() {
        DebugLog.write("receive: WebSocket failed")
        onConnectionChange?(false)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        pending.values.forEach { $0.resume(throwing: GatewayError.disconnected) }
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        scheduleReconnect()
    }

    /// A dropped socket otherwise stays dropped until the next request, so a
    /// running turn's events (steps, todos, Bot activity) freeze while Hermes
    /// keeps working. Reconnecting fires `onConnectionChange(true)`, which
    /// replays the missed events.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            var delay = 1.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.socket == nil else { return }
                do { try await self.connect(); return } catch {
                    DebugLog.write("reconnect: failed, retrying in \(Int(min(delay * 2, 30)))s")
                }
                delay = min(delay * 2, 30)
            }
        }
    }

    private func handle(_ object: [String: Any]) {
        let responseID = (object["id"] as? Int) ?? (object["id"] as? NSNumber)?.intValue
        if let id = responseID, let continuation = pending.removeValue(forKey: id) {
            DebugLog.write("receive: response id=\(id)")
            timeoutTasks.removeValue(forKey: id)?.cancel()
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                continuation.resume(throwing: NSError(domain: "Hermes", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
            } else {
                let result = object["result"] as? [String: Any] ?? [:]
                let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
                continuation.resume(returning: data)
            }
            return
        }
        if let requestID = object["id"] as? String, let method = object["method"] as? String {
            if let event = Self.event(forServerRequest: object) {
                DebugLog.write("receive: server request \(method)")
                onEvent?(event.type, event.params)
            } else {
                // Unhandled requests (desktop previews, tours, …) must not park the agent until its deadline.
                sendFrame(["jsonrpc": "2.0", "id": requestID,
                           "error": ["code": -32601, "message": "Herm does not handle \(method) requests"]])
            }
            return
        }
        guard object["method"] as? String == "event",
              var params = object["params"] as? [String: Any],
              var type = params["type"] as? String else { return }
        // A withdrawn server request (answered elsewhere, timed out, interrupted).
        if type == "request.cancel", let payload = params["payload"] as? [String: Any],
           let method = payload["method"] as? String,
           method == "clarify" || method == "approval" || ValuePrompt.methods.contains(method) {
            type = ValuePrompt.methods.contains(method) ? "prompt.expire" : "\(method).expire"
            params["payload"] = ["request_id": payload["id"] ?? "", "reason": payload["reason"] ?? ""]
        }
        // Background-process output (e.g. a dev server's webpack progress)
        // arrives per chunk and Herm renders none of it; routing each chunk
        // through the models re-rendered SwiftUI every frame and froze the app.
        if type == "agent.terminal.output" { return }
        // Delta frames arrive at stream rate; logging each one would put
        // console and file I/O on the main actor for every chunk of text.
        if !HermesHighFrequencyEvent.includes(type) {
            DebugLog.write("receive: event \(type)")
        }
        onEvent?(type, params)
    }

    private func startBackendIfNeeded() async throws {
        if port != nil { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            backendStartWaiters.append(continuation)
            guard backend == nil else { return }

            DebugLog.write("backend: launching hermes serve")
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let process = Process()
            let stdout = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["hermes", "serve", "--host", "127.0.0.1", "--port", "0"]
            process.currentDirectoryURL = workingDirectory
            var environment = HermesEnvironment.processEnvironment()
            environment["HERMES_DASHBOARD_SESSION_TOKEN"] = token
            environment["HERMES_DESKTOP"] = "1"
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stdout
            backend = process

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                // At EOF the handler keeps firing with empty data; left
                // installed it spins a core until the app quits.
                guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
                guard let text = String(data: chunk, encoding: .utf8) else { return }
                Task { @MainActor in
                    // Keep draining after the port is known: an unread pipe
                    // fills at 64 KB and blocks `hermes serve` on its next log write.
                    guard self?.port == nil else { return }
                    self?.backendOutput += text
                    if let outputLength = self?.backendOutput.count,
                       outputLength > Self.maximumBackendOutputLength {
                        self?.backendOutput.removeFirst(outputLength - Self.maximumBackendOutputLength)
                    }
                    DebugLog.write("backend: output received")
                    guard let output = self?.backendOutput else { return }
                    let pattern = #"(?:HERMES_BACKEND_READY port=|listening on 127\.0\.0\.1:)(\d+)"#
                    guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                          let portRange = Range(match.range(at: 1), in: output),
                          let value = Int(output[portRange]) else { return }
                    self?.port = value
                    DebugLog.write("backend: discovered port \(value)")
                    let waiters = self?.backendStartWaiters ?? []
                    self?.backendStartWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }
            process.terminationHandler = { [weak self, weak process] _ in
                Task { @MainActor in
                    guard let self, let process, self.backend === process else { return }
                    let wasReady = self.port != nil
                    self.backend = nil
                    self.port = nil
                    self.baseURL = nil
                    self.backendOutput = ""
                    self.onConnectionChange?(false)
                    let waiters = self.backendStartWaiters
                    self.backendStartWaiters.removeAll()
                    waiters.forEach { $0.resume(throwing: GatewayError.backendUnavailable) }
                    guard wasReady else { return }

                    DebugLog.write("backend: process terminated unexpectedly")
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    self.socket = nil
                    self.urlSession?.invalidateAndCancel()
                    self.urlSession = nil
                    self.pending.values.forEach { $0.resume(throwing: GatewayError.disconnected) }
                    self.pending.removeAll()
                    self.timeoutTasks.values.forEach { $0.cancel() }
                    self.timeoutTasks.removeAll()
                }
            }
            do { try process.run() } catch {
                backend = nil
                let waiters = backendStartWaiters
                backendStartWaiters.removeAll()
                waiters.forEach { $0.resume(throwing: error) }
            }

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.port == nil, self.backend != nil else { return }
                    DebugLog.write("backend: startup timed out")
                    self.backend?.terminate()
                    let waiters = self.backendStartWaiters
                    self.backendStartWaiters.removeAll()
                    waiters.forEach { $0.resume(throwing: GatewayError.backendUnavailable) }
                }
            }
        }
    }
}
