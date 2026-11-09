import AppKit
import Testing

@testable import Herm

@MainActor
struct MCPAppTests {
    let id = String(repeating: "a", count: 32)
    let digest = String(repeating: "b", count: 64)

    func receipt(_ id: String, schema: String = MCPApp.schema) -> String {
        #"{"result":"done","herm_app":{"schema":"\#(schema)","id":"\#(id)"}}"#
    }

    @Test func receiptNeedsAnMCPToolTheSchemaAndASafeID() {
        #expect(MCPApp.receiptID(tool: "mcp__srv__show", result: receipt(id)) == id)
        #expect(MCPApp.receiptID(tool: "terminal", result: receipt(id)) == nil)
        #expect(MCPApp.receiptID(tool: "mcp__srv__show", result: receipt(id, schema: "other")) == nil)
        for unsafe in ["../" + String(repeating: "a", count: 29), String(repeating: "A", count: 32), "abc"] {
            #expect(MCPApp.receiptID(tool: "mcp__srv__show", result: receipt(unsafe)) == nil)
        }
        #expect(MCPApp.receiptID(tool: "mcp__srv__show", result: "plain text") == nil)
    }

    @Test func loadsTheCachedCallAndRejectsUnsafeDigests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "<p>hi</p>".write(to: directory.appendingPathComponent(digest + ".html"), atomically: true, encoding: .utf8)
        func write(html: String) throws {
            let call: [String: Any] = [
                "server": "srv", "tool": ["name": "show", "title": "Show"], "html": html,
                "csp": ["connectDomains": ["https://api.x"]], "arguments": ["q": 1],
                "result": ["content": [["type": "text", "text": "done"]]],
            ]
            try JSONSerialization.data(withJSONObject: call).write(to: directory.appendingPathComponent(id + ".json"))
        }
        try write(html: digest)
        let call = try #require(MCPApp.Call.load(id: id, directory: directory))
        #expect(call.html == "<p>hi</p>" && call.title == "Show" && call.server == "srv")
        #expect(call.requestedDomains == ["https://api.x"])
        try write(html: "../../etc/passwd")
        #expect(MCPApp.Call.load(id: id, directory: directory) == nil)
        #expect(MCPApp.Call.load(id: "missing", directory: directory) == nil)
    }

    @Test func bridgeInitializesThenSendsInputAndResult() throws {
        let call = MCPApp.Call(
            server: "srv", toolName: "show", toolTitle: nil, html: "", requestedDomains: [],
            arguments: Data(#"{"q":1}"#.utf8), result: Data(#"{"structuredContent":{"n":1}}"#.utf8))
        let bridge = MCPAppBridge(call: call) { ["theme": "dark"] }
        var sent: [[String: Any]] = []
        var height: CGFloat?
        var opened: URL?
        bridge.send = { sent.append($0) }
        bridge.resize = { height = $0 }
        bridge.openLink = { opened = $0 }

        bridge.receive(["jsonrpc": "2.0", "id": 1, "method": "ui/initialize", "params": [:]])
        let initialized = try #require(sent.last?["result"] as? [String: Any])
        #expect(initialized["protocolVersion"] as? String == MCPApp.protocolVersion)
        #expect((initialized["hostContext"] as? [String: Any])?["theme"] as? String == "dark")

        bridge.receive(["jsonrpc": "2.0", "method": "ui/notifications/initialized"])
        #expect(
            sent.suffix(2).map { $0["method"] as? String } == [
                "ui/notifications/tool-input", "ui/notifications/tool-result",
            ])
        #expect(((sent.last?["params"] as? [String: Any])?["structuredContent"] as? [String: Any])?["n"] as? Int == 1)

        bridge.receive(["jsonrpc": "2.0", "method": "ui/notifications/size-changed", "params": ["height": 240]])
        #expect(height == 240)

        bridge.receive(["jsonrpc": "2.0", "id": 2, "method": "ui/open-link", "params": ["url": "https://example.com"]])
        #expect(opened?.absoluteString == "https://example.com")
        bridge.receive(["jsonrpc": "2.0", "id": 3, "method": "ui/open-link", "params": ["url": "file:///etc/passwd"]])
        #expect((sent.last?["error"] as? [String: Any])?["code"] as? Int == -32602)

        bridge.receive(["id": 5, "method": "ping"])
        #expect(sent.last?["id"] as? Int != 5)
        bridge.receive(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "x"]])
        #expect((sent.last?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(sent.last?["id"] as? Int == 4)
    }

    @Test func realWebKitRelaysJSONRPCOnlyThroughTheIsolatedWorld() async throws {
        // The view runs the handshake, then echoes what it received as an (unsupported) request Herm answers.
        let view = """
            <script>
            const got = [];
            addEventListener('message', e => {
              if (e.source !== parent) return;
              got.push(e.data.method || e.data.result?.protocolVersion);
              if (e.data.id === 1) parent.postMessage({jsonrpc:'2.0', method:'ui/notifications/initialized'}, '*');
              if (e.data.method === 'ui/notifications/tool-result') {
                parent.postMessage({jsonrpc:'2.0', id:9, method:'test/report',
                  params:{got, handler: !!window.webkit?.messageHandlers?.hermBridge}}, '*');
              }
            });
            parent.postMessage({jsonrpc:'2.0', id:1, method:'ui/initialize', params:{}}, '*');
            </script>
            """
        let call = MCPApp.Call(
            server: "srv", toolName: "show", toolTitle: nil, html: view, requestedDomains: [],
            arguments: Data("{}".utf8), result: Data("{}".utf8))
        let bridge = MCPAppBridge(call: call) { [:] }
        let state = GeneratedHTMLLoadState()
        let coordinator = GeneratedHTMLWebView.Coordinator(html: view, state: state)
        coordinator.bridge = bridge
        let web = coordinator.makeWebView()
        let relay = bridge.send
        var sent: [[String: Any]] = []
        bridge.send = {
            sent.append($0)
            relay?($0)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
            window.orderOut(nil)
        }
        coordinator.load()
        for _ in 0..<100 where state.error == nil && !sent.contains(where: { $0["id"] as? Int == 9 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.error == nil)
        // Herm's error reply to the report proves the full view -> Herm -> view -> Herm round trip.
        let report = try #require(sent.first { $0["id"] as? Int == 9 })
        #expect((report["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(
            sent.compactMap { $0["method"] as? String } == [
                "ui/notifications/tool-input", "ui/notifications/tool-result",
            ])
        // Page-world scripts see no native handler.
        let pageHandler = try await web.evaluateJavaScript("!!window.webkit?.messageHandlers?.hermBridge") as? Bool
        #expect(pageHandler == false)
    }
}
