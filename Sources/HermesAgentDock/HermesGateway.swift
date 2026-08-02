import Foundation

@MainActor
final class HermesGateway: NSObject {
    enum GatewayError: LocalizedError {
        case backendUnavailable, malformedResponse, disconnected
        var errorDescription: String? {
            switch self {
            case .backendUnavailable: "Hermes could not start its local backend."
            case .malformedResponse: "Hermes returned an unreadable response."
            case .disconnected: "The connection to Hermes was lost."
            }
        }
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    private var backend: Process?
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var port: Int?
    private var token = ""
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var backendOutput = ""
    private var backendStartWaiters: [CheckedContinuation<Void, Error>] = []

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
            return
        }
        DebugLog.write("connect: starting")
        try await startBackendIfNeeded()
        guard let port else { throw GatewayError.backendUnavailable }
        DebugLog.write("connect: backend ready on port \(port)")
        let url = URL(string: "ws://127.0.0.1:\(port)/api/ws?token=\(token)")!
        let session = URLSession(configuration: .ephemeral)
        urlSession = session
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        DebugLog.write("connect: WebSocket task resumed")
        receiveNext()
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        DebugLog.write("request: \(method)")
        if socket == nil { try await connect() }
        let data = try await send(method: method, params: params)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        urlSession = nil
        socket = nil
        backend?.terminate()
        backend = nil
        port = nil
        pending.values.forEach { $0.resume(throwing: GatewayError.disconnected) }
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
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
                try? await Task.sleep(for: .seconds(15))
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

    private func receiveNext() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    DebugLog.write("receive: WebSocket failed")
                    self.socket = nil
                    self.urlSession?.invalidateAndCancel()
                    self.urlSession = nil
                    self.pending.values.forEach { $0.resume(throwing: GatewayError.disconnected) }
                    self.pending.removeAll()
                    self.timeoutTasks.values.forEach { $0.cancel() }
                    self.timeoutTasks.removeAll()
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(object)
                    } else {
                        DebugLog.write("receive: non-JSON or binary message")
                    }
                    self.receiveNext()
                }
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
        guard object["method"] as? String == "event",
              let params = object["params"] as? [String: Any],
              let type = params["type"] as? String else { return }
        DebugLog.write("receive: event \(type)")
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
            var environment = ProcessInfo.processInfo.environment
            let currentPath = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
            if !currentPath.split(separator: ":").contains("/Users/christian/.local/bin") {
                environment["PATH"] = "/Users/christian/.local/bin:\(currentPath)"
            }
            environment["HERMES_DASHBOARD_SESSION_TOKEN"] = token
            environment["HERMES_DESKTOP"] = "1"
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stdout
            backend = process

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
                Task { @MainActor in
                    self?.backendOutput += text
                    DebugLog.write("backend output: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                    guard let output = self?.backendOutput else { return }
                    let pattern = #"(?:HERMES_BACKEND_READY port=|listening on 127\.0\.0\.1:)(\d+)"#
                    guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                          let portRange = Range(match.range(at: 1), in: output),
                          let value = Int(output[portRange]) else { return }
                    stdout.fileHandleForReading.readabilityHandler = nil
                    self?.port = value
                    DebugLog.write("backend: discovered port \(value)")
                    let waiters = self?.backendStartWaiters ?? []
                    self?.backendStartWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard self?.port == nil else { return }
                    self?.backend = nil
                    let waiters = self?.backendStartWaiters ?? []
                    self?.backendStartWaiters.removeAll()
                    waiters.forEach { $0.resume(throwing: GatewayError.backendUnavailable) }
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
