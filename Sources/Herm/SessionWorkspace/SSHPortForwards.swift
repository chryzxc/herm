import Darwin
import Foundation

/// In SSH mode `localhost` belongs to the backend host, so the Browser tab
/// forwards each loopback port it opens (`ssh -L port:localhost:port`). The
/// same port keeps the URL, origin and cookies identical to what the agent printed.
@MainActor
final class SSHPortForwards {
    static let shared = SSHPortForwards()
    private var tunnels: [Int: Process] = [:]
    private var starting: [Int: Task<String?, Never>] = [:]

    /// The backend port a loopback URL needs forwarded, or nil when it loads as is.
    nonisolated static func remotePort(for url: URL, backend: GatewayConnectionSettings) -> Int? {
        guard backend.mode == .ssh, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host?.lowercased(),
            host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
        else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        // Ports below 1024 cannot be bound on this Mac without root.
        return (1024...65535).contains(port) ? port : nil
    }

    nonisolated static func arguments(port: Int, backend: GatewayConnectionSettings) -> [String] {
        // `cat` holds the session open until Herm exits and closes its stdin,
        // so a quit or crash never leaves an orphaned tunnel bound to the port.
        ["-T", "-o", "ExitOnForwardFailure=yes", "-L", "\(port):localhost:\(port)"] + backend.sshOptions + ["cat"]
    }

    /// Nil once the port reaches the backend; otherwise a message for the tab.
    func prepare(_ url: URL, backend: GatewayConnectionSettings = GatewayConnectionStore.backendSettings) async
        -> String?
    {
        guard let port = Self.remotePort(for: url, backend: backend) else { return nil }
        if tunnels[port]?.isRunning == true { return nil }
        if let pending = starting[port] { return await pending.value }
        let task = Task { await self.start(port: port, backend: backend) }
        starting[port] = task
        let result = await task.value
        starting[port] = nil
        return result
    }

    private func start(port: Int, backend: GatewayConnectionSettings) async -> String? {
        guard !Self.acceptsConnections(port: port) else {
            return "Port \(port) is already in use on this Mac, so Herm can't show the SSH host's server there."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(port: port, backend: backend)
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return "Could not start ssh: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
        }
        for _ in 0..<60 {
            if Self.acceptsConnections(port: port) {
                tunnels[port] = process
                return nil
            }
            guard process.isRunning else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        process.terminate()
        return "Could not forward port \(port) from the SSH host. Check that the server is running there."
    }

    nonisolated static func acceptsConnections(port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { Darwin.close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
