import CryptoKit
import Foundation

/// Runs Desktop's bundled Electron-free lifecycle; secrets travel through private pipes.
@MainActor
final class GatewaySSHBridge {
    private var process: Process?
    private var input: FileHandle?
    private var output = Data()
    private var pending: CheckedContinuation<(URL, String), Error>?
    private var timeout: Task<Void, Never>?

    static func ownershipID(_ id: String) -> String {
        SHA256.hash(data: Data(("herm:" + id).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func connect(_ settings: GatewayConnectionSettings) async throws -> (URL, String) {
        if process != nil { throw GatewayConnectionError.unavailable("SSH connection is already starting.") }
        let settings = try settings.validated()
        guard let script = Bundle.herm.url(forResource: "HermesSSHBridge", withExtension: "mjs") else {
            throw GatewayConnectionError.unavailable("Herm's SSH helper is missing. Reinstall Herm.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".hermes/node/bin/node").path, "/opt/homebrew/bin/node", "/usr/local/bin/node",
        ]
        guard let node = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw GatewayConnectionError.unavailable(
                "SSH connections require Node.js 20 or newer. Install it, or use Hermes' bundled Node runtime.")
        }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path]
        process.environment = HermesEnvironment.processEnvironment()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        self.process = process
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in if let process, self?.process === process { self?.consume(data) } }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor in
                guard let process, self?.process === process else { return }
                self?.finish(
                    .failure(
                        GatewayConnectionError.unavailable(
                            "SSH helper stopped. Check the host and key-based SSH access, then retry.")))
                self?.process = nil
            }
        }
        do { try process.run() } catch {
            close()
            throw error
        }
        let config: [String: Any] = [
            "host": settings.sshHost, "user": settings.sshUser, "port": settings.sshPort,
            "keyPath": NSString(string: settings.sshKeyPath).expandingTildeInPath,
            "remoteHermesPath": settings.remoteHermesPath, "remoteProfile": settings.remoteProfile,
            "ownershipId": Self.ownershipID(settings.id),
        ]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.finish(
                        .failure(
                            GatewayConnectionError.unavailable(
                                "SSH startup timed out. Check the remote Hermes installation and try again.")))
                    self?.close()
                }
                do {
                    var data = try JSONSerialization.data(withJSONObject: [
                        "id": 1, "command": "connect", "config": config,
                    ])
                    data.append(10)
                    try input?.write(contentsOf: data)
                } catch {
                    finish(.failure(error))
                    close()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
                self?.close()
            }
        }
    }

    private func consume(_ data: Data) {
        output.append(data)
        guard output.count <= 131_072 else {
            finish(.failure(HermesGateway.GatewayError.malformedResponse))
            close()
            return
        }
        while let end = output.firstIndex(of: 10) {
            let line = output[..<end]
            output.removeSubrange(...end)
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any], frame["id"] as? Int == 1
            else { continue }
            if let error = frame["error"] as? String {
                finish(.failure(GatewayConnectionError.unavailable(error)))
                close()
                return
            }
            guard let result = frame["result"] as? [String: Any], let text = result["baseUrl"] as? String,
                let url = URL(string: text), url.scheme == "http", url.host == "127.0.0.1",
                url.port.map({ (1...65535).contains($0) }) == true,
                let token = result["token"] as? String, !token.isEmpty, !token.contains("\r"), !token.contains("\n")
            else {
                finish(.failure(HermesGateway.GatewayError.malformedResponse))
                close()
                return
            }
            finish(.success((url, token)))
        }
    }

    private func finish(_ result: Result<(URL, String), Error>) {
        timeout?.cancel()
        timeout = nil
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }

    func close() {
        finish(.failure(HermesGateway.GatewayError.disconnected))
        try? input?.close()
        input = nil
        guard let process else { return }
        self.process = nil
        // EOF asks the helper to verify and stop only its owned remote backend.
        Task {
            try? await Task.sleep(for: .seconds(20))
            if process.isRunning { process.terminate() }
        }
    }
}
