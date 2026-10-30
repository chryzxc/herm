import Foundation
import Testing

@testable import Herm

/// Opt-in local Chromium smoke test; never connects to the user's browser or Hermes.
@MainActor
struct HermesBrowserPointerSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_BROWSER_POINTER_SMOKE"] == "1"))
    func observesSameAndCrossOriginFrames() async throws {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        try #require(FileManager.default.isExecutableFile(atPath: chromeURL.path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-browser-smoke-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Process()
        let serverOutput = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [
            "-u", "-c",
            """
            import http.server, os, sys
            os.chdir(sys.argv[1])
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), http.server.SimpleHTTPRequestHandler)
            print(server.server_port, flush=True)
            server.serve_forever()
            """, root.path,
        ]
        server.standardOutput = serverOutput
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        let portText = String(decoding: serverOutput.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try #require(Int(portText))
        try
            "<body style='margin:0'><button style='position:absolute;left:10px;top:10px;width:160px;height:60px'>Click</button></body>"
            .write(to: root.appendingPathComponent("child.html"), atomically: true, encoding: .utf8)
        try """
        <body style='margin:0'>
        <iframe style='position:absolute;left:20px;top:20px;width:200px;height:80px;border:4px solid' src='/child.html'></iframe>
        <iframe style='position:absolute;left:20px;top:140px;width:200px;height:80px;border:4px solid' src='http://127.0.0.1:\(port)/child.html'></iframe>
        </body>
        """.write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let profile = root.appendingPathComponent("profile")
        let chrome = Process()
        chrome.executableURL = chromeURL
        chrome.arguments = [
            "--headless=new", "--site-per-process", "--remote-debugging-port=0", "--user-data-dir=\(profile.path)",
            "--no-first-run", "--no-default-browser-check", "--window-size=800,600", "about:blank",
        ]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        try chrome.run()
        defer { if chrome.isRunning { chrome.terminate() } }
        let portFile = profile.appendingPathComponent("DevToolsActivePort")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: portFile.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let lines = try String(contentsOf: portFile, encoding: .utf8).split(separator: "\n")
        try #require(lines.count >= 2)
        let url = try #require(URL(string: "ws://127.0.0.1:\(lines[0])\(lines[1])"))
        let cdp = CDPConnection(url: url)
        defer { cdp.close() }
        let target = try await cdp.send("Target.createTarget", ["url": "about:blank"])
        let targetID = try #require(target["targetId"] as? String)
        let attached = try await cdp.send("Target.attachToTarget", ["targetId": targetID, "flatten": true])
        let session = try #require(attached["sessionId"] as? String)
        var pointers: [AgentPointer] = []
        let tracker = HermesBrowserPointerTracker(
            rootSession: session, send: { try await cdp.send($0, $1, session: $2) }, active: { true },
            deliver: { pointers.append($0) }, invalidatePointer: {})
        defer { tracker.stop() }
        cdp.onEvent = { tracker.receive($0, params: $1, session: $2) }
        await tracker.start()
        _ = try await cdp.send("Page.navigate", ["url": "http://localhost:\(port)/index.html"], session: session)
        for _ in 0..<200 where Set(tracker.contexts.keys.map(\.session)).count < 2 || tracker.contexts.count < 3 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(tracker.contexts.count >= 3)
        #expect(Set(tracker.contexts.keys.map(\.session)).count >= 2)
        func containsPointer(at y: Int) -> Bool {
            pointers.contains { pointer in
                pointer.kind == .down && abs(pointer.point.x - 70) < 2 && abs(pointer.point.y - CGFloat(y)) < 2
            }
        }
        for y in [55, 175] {
            _ = try await cdp.send(
                "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 70, "y": y], session: session)
            _ = try await cdp.send(
                "Input.dispatchMouseEvent",
                [
                    "type": "mousePressed", "x": 70, "y": y, "button": "left", "clickCount": 1,
                ], session: session)
            _ = try await cdp.send(
                "Input.dispatchMouseEvent",
                [
                    "type": "mouseReleased", "x": 70, "y": y, "button": "left", "clickCount": 1,
                ], session: session)
            for _ in 0..<200 where !containsPointer(at: y) {
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(containsPointer(at: y))
        }
    }
}
