import Foundation
import Testing

@testable import Herm

private final class EndpointProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let port = request.url?.port ?? 0
        let body: String
        switch port {
        case 9333: body = "{\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9333/devtools/browser/abc\"}"
        case 9334: body = "{\"webSocketDebuggerUrl\":\"ws://remote.example:9334/devtools/browser/abc\"}"
        case 9337: body = "not json"
        case 9338: body = "{\"webSocketDebuggerUrl\":42}"
        case 9339: body = "{\"webSocketDebuggerUrl\":\"http://127.0.0.1:9339/devtools/browser/abc\"}"
        case 9340: body = "{\"webSocketDebuggerUrl\":\"wss://127.0.0.1:9340/devtools/browser/abc\"}"
        case 9341: body = "{\"webSocketDebuggerUrl\":\"ws://127.0.0.1:1/devtools/browser/abc\"}"
        case 9342: body = "{\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9342/devtools/page/abc\"}"
        case 9343: body = "{\"webSocketDebuggerUrl\":\"ws://user@127.0.0.1:9343/devtools/browser/abc\"}"
        case 9344: body = "{\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9344/devtools/browser/abc#fragment\"}"
        case 9345: body = "{\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9345/devtools/browser/\"}"
        default: body = "{}"
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: port == 9335 ? 500 : 200,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RetryEndpointProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let count = Self.requests
        Self.lock.unlock()
        let body = count == 1 ? "{}" : "{\"webSocketDebuggerUrl\":\"ws://127.0.0.1:9350/devtools/browser/fresh\"}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct AgentBrowserEndpointTests {
    @Test func retryUsesFreshResponseOnSameSessionAndPort() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetryEndpointProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(await AgentBrowserEndpoint.discover(portFile: file, fixedPort: 9350, session: session) == nil)
        let endpoint = await AgentBrowserEndpoint.discover(portFile: file, fixedPort: 9350, session: session)
        #expect(endpoint?.ws.absoluteString == "ws://127.0.0.1:9350/devtools/browser/fresh")
    }

    @Test func competingListenerIsNotAccepted() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EndpointProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        let announcement = AgentBrowserAnnouncement()
        announcement.consume(Data("DevTools listening on ws://127.0.0.1:9333/devtools/browser/own\n".utf8))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(
            await AgentBrowserEndpoint.discoverLaunched(
                portFile: file, fixedPort: 9333, process: child, announcement: announcement, session: session) == nil)
        announcement.consume(Data("DevTools listening on ws://127.0.0.1:9333/devtools/browser/abc\n".utf8))
        #expect(
            await AgentBrowserEndpoint.discoverLaunched(
                portFile: file, fixedPort: 9333, process: child, announcement: announcement, session: session)?.port
                == 9333)
    }
    @Test func fixedPortWithoutFile() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EndpointProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let endpoint = await AgentBrowserEndpoint.discover(portFile: file, fixedPort: 9333, session: session)
        #expect(endpoint?.port == 9333)
        #expect(endpoint?.ws.absoluteString == "ws://127.0.0.1:9333/devtools/browser/abc")
    }

    @Test func existingFileDiscoveryAndInvalidFixedPorts() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EndpointProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "9333\n/devtools/browser/file".write(to: file, atomically: true, encoding: .utf8)
        let fileEndpoint = await AgentBrowserEndpoint.discover(portFile: file, session: session)
        #expect(fileEndpoint?.ws.absoluteString == "ws://127.0.0.1:9333/devtools/browser/file")
        for port in [9334, 9335, 9336, 9337, 9338, 9339, 9340, 9341, 9342, 9343, 9344, 9345] {
            #expect(await AgentBrowserEndpoint.discover(portFile: file, fixedPort: port, session: session)?.port == nil)
        }
        let fixed = await AgentBrowserEndpoint.discover(portFile: file, fixedPort: 9333, session: session)
        #expect(fixed?.ws.absoluteString == "ws://127.0.0.1:9333/devtools/browser/abc")
        try "not-a-port\n/devtools/browser/file".write(to: file, atomically: true, encoding: .utf8)
        #expect(await AgentBrowserEndpoint.discover(portFile: file, session: session) == nil)
        try "9333".write(to: file, atomically: true, encoding: .utf8)
        #expect(await AgentBrowserEndpoint.discover(portFile: file, session: session) == nil)
        try "9335\n/devtools/browser/file".write(to: file, atomically: true, encoding: .utf8)
        #expect(await AgentBrowserEndpoint.discover(portFile: file, session: session) == nil)
        try FileManager.default.removeItem(at: file)
        #expect(await AgentBrowserEndpoint.discover(portFile: file, session: session) == nil)
        #expect(await AgentBrowserEndpoint.discover(portFile: file, fixedPort: 9334, session: session) == nil)
        #expect(await AgentBrowserEndpoint.discover(portFile: file, fixedPort: 9333, session: session)?.port == 9333)
    }
}
