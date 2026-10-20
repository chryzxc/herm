import Foundation
import Network

/// A bounded loopback TCP handshake. No HTTP request, credentials, or browser navigation.
enum LocalPreviewProbe {
    static func reachable(_ server: LocalPreviewServer) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: server.port)),
            ["127.0.0.1", "::1"].contains(server.host)
        else { return false }
        return await withCheckedContinuation { continuation in
            let probe = Probe(
                connection: NWConnection(host: NWEndpoint.Host(server.host), port: port, using: .tcp),
                continuation: continuation)
            probe.start()
        }
    }
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private let connection: NWConnection
        private var continuation: CheckedContinuation<Bool, Never>?
        init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
            self.connection = connection
            self.continuation = continuation
        }
        func start() {
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(300)) { [self] in
                finish(false)
            }
        }
        private func finish(_ succeeded: Bool) {
            let result = lock.withLock {
                let result = continuation
                continuation = nil
                return result
            }
            guard let result else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
            result.resume(returning: succeeded)
        }
    }
}
