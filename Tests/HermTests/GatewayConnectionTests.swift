import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct GatewayConnectionTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "GatewayConnectionTests.\(UUID().uuidString)")!
    }

    @Test func validatesRemoteURLsAndPreservesProxyPrefixes() throws {
        let base = try GatewayConnectionSettings.normalizedURL("  https://EXAMPLE.com/hermes///  ")
        #expect(base.absoluteString == "https://example.com/hermes")
        #expect(
            try GatewayConnectionSettings.endpoint(base, "/api/status?profile=iris").absoluteString
                == "https://example.com/hermes/api/status?profile=iris")
        #expect(try GatewayConnectionSettings.normalizedURL("myhost:9119").absoluteString == "https://myhost:9119")
        for text in [
            "", "file:///tmp/token", "ftp://example.com", "https://user:password@example.com",
            "https://example.com?token=secret", "https://example.com#secret", "http://example.com:0",
            "http://example.com:70000",
        ] {
            #expect(throws: (any Error).self) { try GatewayConnectionSettings.normalizedURL(text) }
        }
    }

    @Test func requiresEncryptionOutsideLoopback() throws {
        for host in ["127.0.0.1", "localhost", "[::1]"] {
            #expect(try GatewayConnectionSettings.normalizedURL("http://\(host):9119/proxy").scheme == "http")
            #expect(try GatewayConnectionSettings.normalizedURL("\(host):9119").scheme == "http")
        }
        for host in ["example.com", "192.168.1.20", "localhost.evil.test", "127.0.0.1.evil.test", "[::]", "0.0.0.0"] {
            let url = URL(string: "http://\(host):9119")!
            #expect(throws: (any Error).self) { try GatewayConnectionSettings.normalizedURL(url.absoluteString) }
            #expect(throws: (any Error).self) { try HermesGateway.webSocketRequest(baseURL: url, credential: "secret") }
            #expect(throws: (any Error).self) { try GatewayConnectionSettings.endpoint(url, "/auth/native/token") }
        }
    }

    @Test func buildsAuthenticatedWebSocketsWithoutCorruptingCredentials() throws {
        let base = try GatewayConnectionSettings.normalizedURL("https://example.com/hermes")
        let credential = "token+with&characters=?#"
        let request = try HermesGateway.webSocketRequest(baseURL: base, credential: credential)
        let url = try #require(request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "wss")
        #expect(parts.path == "/hermes/api/ws")
        #expect(parts.queryItems == [URLQueryItem(name: "token", value: credential)])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential)")
        let ticket = try HermesGateway.webSocketRequest(baseURL: base, credential: credential, ticket: true)
        #expect(
            URLComponents(url: try #require(ticket.url), resolvingAgainstBaseURL: false)?.queryItems == [
                URLQueryItem(name: "ticket", value: credential)
            ])
        #expect(ticket.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func savesMetadataSeparatelyFromSecretsAndKeepsLaunchSettingsStable() throws {
        let defaults = defaults()
        var secrets: [String: String] = [:]
        let store = GatewayConnectionStore(
            defaults: defaults, environment: [:], readToken: { secrets[$0] }, writeToken: { secrets[$0] = $1 })
        let launch = store.launchSettings
        var remote = GatewayConnectionSettings()
        remote.mode = .remote
        remote.remoteURL = "https://one.example/hermes/"
        remote.name = "Office"
        try store.save(remote, token: "secret-token")
        #expect(store.selected.remoteURL == "https://one.example/hermes")
        #expect(secrets["https://one.example/hermes"] == "secret-token")
        #expect(store.launchSettings == launch)
        for value in defaults.dictionaryRepresentation().values {
            if let data = value as? Data { #expect(!String(decoding: data, as: UTF8.self).contains("secret-token")) }
        }
        try store.save(remote, token: "")
        #expect(store.connections.count == 1)
        remote.remoteURL = "https://two.example"
        #expect(throws: (any Error).self) { try store.save(remote, token: "") }
        #expect(store.selected.remoteURL == "https://one.example/hermes")
        let restored = GatewayConnectionStore(
            defaults: defaults, environment: [:], readToken: { secrets[$0] }, writeToken: { secrets[$0] = $1 })
        #expect(restored.launchSettings == store.selected)
    }

    @Test func failedSecretWritesDoNotSwitchTheSavedBackend() throws {
        let store = GatewayConnectionStore(
            defaults: defaults(), environment: [:], readToken: { _ in nil },
            writeToken: { _, _ in throw GatewayConnectionError.storage(-1) })
        var remote = GatewayConnectionSettings()
        remote.mode = .remote
        remote.remoteURL = "https://example.com"
        #expect(throws: (any Error).self) { try store.save(remote, token: "secret") }
        #expect(store.selected.mode == .local)
        #expect(store.connections.isEmpty)
    }

    @Test func startupOverridesAreReadOnlyAndCorruptSettingsFailClosed() throws {
        let defaults = defaults()
        defaults.set(Data("broken".utf8), forKey: "gateway.connection")
        let broken = GatewayConnectionStore(defaults: defaults, environment: [:])
        #expect(broken.error != nil)
        let overridden = GatewayConnectionStore(
            defaults: defaults,
            environment: [
                "HERMES_DESKTOP_REMOTE_URL": "https://example.com", "HERMES_DESKTOP_REMOTE_TOKEN": "startup-token",
            ])
        #expect(overridden.environmentOverride)
        #expect(overridden.launchSettings.mode == .remote)
        #expect(overridden.launchToken == "startup-token")
        #expect(overridden.error == nil)
        #expect(throws: (any Error).self) { try overridden.save(GatewayConnectionSettings(), token: "") }
    }

    @Test func validatesSSHSettingsBeforeSpawningAndUsesSeparateOwnership() throws {
        var ssh = GatewayConnectionSettings()
        ssh.mode = .ssh
        ssh.sshHost = "user@my-host"
        #expect(try ssh.validated().sshHost == "user@my-host")
        for host in ["-oProxyCommand=bad", "host;bad", "host\ncommand", "ssh user@host"] {
            ssh.sshHost = host
            #expect(throws: (any Error).self) { try ssh.validated() }
        }
        ssh.sshHost = "host"
        ssh.sshPort = 70000
        #expect(throws: (any Error).self) { try ssh.validated() }
        #expect(GatewaySSHBridge.ownershipID("saved") != GatewaySSHBridge.ownershipID("probe"))
        #expect(GatewaySSHBridge.ownershipID("saved").count == 32)
        #expect(Bundle.module.url(forResource: "HermesSSHBridge", withExtension: "mjs") != nil)
    }

    @Test func scopesBrowserCookiesToHostPathAndTransport() throws {
        let cookie = try #require(
            HTTPCookie(properties: [
                .name: "hermes_session_at", .value: "secret", .domain: "gateway.example.com", .path: "/hermes",
                .secure: "TRUE",
            ]))
        #expect(
            GatewayWebAuthentication.matches(cookie, url: URL(string: "https://gateway.example.com/hermes/api/status")!)
        )
        for text in [
            "https://other.example.com/hermes/api/status", "https://evilgateway.example.com/hermes",
            "https://gateway.example.com/hermes-other", "http://gateway.example.com/hermes",
        ] {
            #expect(!GatewayWebAuthentication.matches(cookie, url: URL(string: text)!))
        }
    }

    @Test func validatesCloudInventoryAndDoesNotEnableMalformedAgentURLs() throws {
        let agents = try GatewayConnectionModel.parseAgents([
            ["id": "one", "name": "Work", "status": "running", "dashboardUrl": "https://agent.example.com"],
            ["id": "two", "status": "provisioning", "dashboardUrl": "javascript:bad"],
        ])
        #expect(agents[0].dashboardURL == "https://agent.example.com")
        #expect(agents[1].dashboardURL == nil)
        #expect(throws: (any Error).self) { try GatewayConnectionModel.parseAgents([["id": "one"], ["id": "one"]]) }
    }

    @Test func verifiesPKCEAndRejectsForgedCallbacks() throws {
        #expect(
            GatewayNativeAuthentication.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(
            try GatewayNativeAuthentication.callbackCode("/callback?code=correct&state=expected", state: "expected")
                == "correct")
        for path in [
            "/callback?code=wrong&state=forged", "/callback?state=expected",
            "/callback?code=wrong&state=expected&error=denied", "/elsewhere?code=wrong&state=expected",
        ] {
            #expect(throws: (any Error).self) { try GatewayNativeAuthentication.callbackCode(path, state: "expected") }
        }
    }

    @Test func rejectedCallbacksDoNotExhaustTheListener() async throws {
        let callback = GatewayOAuthCallback(state: "expected-state")
        let base = try await callback.start()
        defer { callback.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for index in 0..<12 {
            var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            parts.queryItems = [
                URLQueryItem(name: "state", value: "forged-\(index)"), URLQueryItem(name: "code", value: "wrong"),
            ]
            // Rejected requests close without a response, but must release their slot.
            _ = try? await session.data(from: parts.url!)
        }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "state", value: "expected-state"), URLQueryItem(name: "code", value: "valid-code"),
        ]
        let (_, response) = try await session.data(from: parts.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await callback.code() == "valid-code")
    }

    @Test func sharesRefreshRotationAndFencesSignOut() async throws {
        let base = URL(string: "https://gateway.example.com")!
        let expired = try GatewayNativeTokens([
            "access_token": "expired", "refresh_token": "refresh", "expires_at": 0, "provider": "nous",
        ])
        let secret = String(decoding: try JSONEncoder().encode(expired), as: UTF8.self)
        var calls = 0
        var writes = 0
        var release: CheckedContinuation<Void, Never>?
        let auth = GatewayNativeAuthentication(
            readSecret: { _ in secret }, writeSecret: { _, _ in writes += 1 }, removeSecret: { _ in },
            refreshTokens: { _, _ in
                calls += 1
                await withCheckedContinuation { release = $0 }
                return (
                    200,
                    [
                        "access_token": "fresh", "refresh_token": "rotated",
                        "expires_at": Date().timeIntervalSince1970 + 3600, "provider": "nous",
                    ]
                )
            })
        let first = Task { try await auth.accessToken(base) }
        while release == nil { await Task.yield() }
        let second = Task { try await auth.accessToken(base) }
        await Task.yield()
        release?.resume()
        release = nil
        #expect(try await first.value == "fresh")
        #expect(try await second.value == "fresh")
        #expect(calls == 1 && writes == 1)
        let refreshing = Task { try await auth.accessToken(base, force: true) }
        while release == nil { await Task.yield() }
        try auth.signOut(base)
        release?.resume()
        release = nil
        do {
            _ = try await refreshing.value
            Issue.record("A refresh completed after sign-out")
        } catch {}
        #expect(writes == 1)
        #expect(try !auth.hasSession(base))
    }

    @Test func renderConnectionSettings() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GATEWAY_SNAPSHOT_DIR"] else { return }
        let store = GatewayConnectionStore(defaults: defaults(), environment: [:])
        for mode in GatewayConnectionSettings.Mode.allCases {
            var settings = GatewayConnectionSettings()
            settings.mode = mode
            settings.name = mode.rawValue.capitalized
            settings.remoteURL = "https://gateway.example.com"
            settings.sshHost = "office"
            let tokenStore = GatewayConnectionStore(
                defaults: defaults(), environment: [:], readToken: { _ in "fake-for-render-only" },
                writeToken: { _, _ in })
            try tokenStore.save(settings, token: "")
            let content = GatewayConnectionSettingsView(store: mode == .local ? store : tokenStore, onRestart: {})
                .padding(20).frame(width: 540).background(Color.dockCanvas).dockThemedRoot()
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 540, height: host.fittingSize.height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("connection-\(mode.rawValue).png"))
            window.close()
        }
    }

    @Test func remoteTransportUsesTheProxyPrefixAndAuthenticatesBothProtocols() async throws {
        let fixture = try GatewayHTTPFixture()
        defer { fixture.stop() }
        var settings = GatewayConnectionSettings()
        settings.mode = .remote
        settings.remoteURL = "http://127.0.0.1:\(fixture.port)/proxy"
        let gateway = HermesGateway(connectionSettings: settings, sessionToken: "test+token&encoded=?")
        defer { gateway.close() }
        try await gateway.testConnection()
        let result = try await gateway.sendHTTP(
            "PUT", path: "/api/config", body: ["config": ["timezone": "Asia/Manila"]])
        #expect(result["saved"] as? String == "Asia/Manila")
        let capability = try await gateway.request("client.capabilities", params: ["server_requests": true])
        #expect(capability["ok"] as? Bool == true)
        let rejected = HermesGateway(connectionSettings: settings, sessionToken: "wrong-token")
        defer { rejected.close() }
        do {
            try await rejected.testConnection()
            Issue.record("Wrong credentials passed the connection test")
        } catch {}
    }
}

/// A real loopback HTTP/WS server keeps transport assertions independent of request builders.
private final class GatewayHTTPFixture {
    let process: Process
    let port: Int

    init() throws {
        process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.server]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 {
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)), (1...65535).contains(port) else {
            process.terminate()
            throw GatewayConnectionError.unavailable("Transport fixture did not start.")
        }
        self.port = port
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private static let server = #"""
        import base64, hashlib, http.server, json, struct, urllib.parse
        TOKEN = 'test+token&encoded=?'
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *args): pass
            def reply(self, code, payload):
                data = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers(); self.wfile.write(data)
            def read_exact(self, count):
                data = self.rfile.read(count)
                if len(data) != count: raise EOFError()
                return data
            def frame(self, opcode, payload):
                self.wfile.write(bytes([0x80 | opcode, len(payload)]) + payload)
                self.wfile.flush()
            def websocket(self):
                key = self.headers['Sec-WebSocket-Key']
                accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.send_response(101); self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
                self.send_header('Sec-WebSocket-Accept', accept); self.end_headers()
                try:
                    while True:
                        opcode, size = self.read_exact(2)
                        masked, length = size & 0x80, size & 127
                        if length == 126: length = struct.unpack('!H', self.read_exact(2))[0]
                        elif length == 127: length = struct.unpack('!Q', self.read_exact(8))[0]
                        mask = self.read_exact(4) if masked else None
                        payload = self.read_exact(length)
                        if mask: payload = bytes(v ^ mask[i % 4] for i, v in enumerate(payload))
                        if opcode & 15 == 8: return
                        if opcode & 15 == 9: self.frame(10, payload)
                        elif opcode & 15 == 1:
                            request = json.loads(payload)
                            self.frame(1, json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'ok': True}}).encode())
                except (EOFError, BrokenPipeError, ConnectionResetError): pass
            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if self.headers.get('Authorization') != 'Bearer '+TOKEN:
                    return self.reply(401, {'detail': 'auth required'})
                if parsed.path == '/proxy/api/ws':
                    if urllib.parse.parse_qs(parsed.query).get('token') != [TOKEN]: return self.reply(401, {'detail':'bad WS auth'})
                    return self.websocket()
                if parsed.path == '/proxy/api/status': return self.reply(200, {'version':'fixture'})
                self.reply(404, {'detail': 'unexpected path'})
            def do_PUT(self):
                data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if self.path != '/proxy/api/config' or self.headers.get('Authorization') != 'Bearer '+TOKEN:
                    return self.reply(403, {'detail': 'bad write'})
                self.reply(200, {'saved': data['config']['timezone']})
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """#
}
