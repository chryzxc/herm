import Foundation

/// Only a WebSocket announced by the launched Chrome process can identify its listener.
final class AgentBrowserAnnouncement: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var announced: URL?

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        while let end = buffer.firstIndex(of: "\n") {
            let line = buffer[..<end]
            let prefix = "DevTools listening on "
            if line.hasPrefix(prefix) {
                let address = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                announced = URL(string: address)
            }
            buffer.removeSubrange(...end)
        }
        if buffer.utf8.count > 8192 { buffer = "" }
    }

    func matches(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return announced == url
    }
}

struct AgentBrowserEndpoint {
    let port: Int
    let ws: URL

    static func discoverLaunched(
        portFile: URL, fixedPort: Int?, process: Process, announcement: AgentBrowserAnnouncement,
        session: URLSession = .shared
    ) async -> Self? {
        guard process.isRunning,
            let endpoint = await discover(portFile: portFile, fixedPort: fixedPort, session: session),
            process.isRunning
        else { return nil }
        if fixedPort != nil && !announcement.matches(endpoint.ws) { return nil }
        return endpoint
    }

    static func discover(portFile: URL, fixedPort: Int? = nil, session: URLSession = .shared) async -> Self? {
        if let fixedPort {
            return await fixedPortEndpoint(fixedPort, session: session)
        }
        guard let lines = try? String(contentsOf: portFile, encoding: .utf8).split(separator: "\n"), lines.count >= 2,
            let port = Int(lines[0]), let ws = URL(string: "ws://127.0.0.1:\(port)\(lines[1])"),
            let probe = URL(string: "http://127.0.0.1:\(port)/json/version"),
            let (_, response) = try? await session.data(from: probe),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Self(port: port, ws: ws)
    }

    private static func fixedPortEndpoint(_ port: Int, session: URLSession) async -> Self? {
        guard let probe = URL(string: "http://127.0.0.1:\(port)/json/version"),
            let (data, response) = try? await session.data(from: probe),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return validatedFixedPort(port, data: data)
    }

    static func validatedFixedPort(_ port: Int, data: Data) -> Self? {
        guard
            let version = try? JSONDecoder().decode(Version.self, from: data),
            let components = URLComponents(string: version.webSocketDebuggerUrl),
            components.scheme == "ws", let host = components.host,
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()),
            components.port == port, components.user == nil, components.password == nil,
            components.fragment == nil, components.query == nil,
            components.path.hasPrefix("/devtools/browser/"),
            !components.path.dropFirst("/devtools/browser/".count).isEmpty,
            !components.path.dropFirst("/devtools/browser/".count).contains("/"),
            let ws = components.url
        else { return nil }
        return Self(port: port, ws: ws)
    }

    private struct Version: Decodable {
        let webSocketDebuggerUrl: String
    }
}
