import AppKit
import Testing

@testable import Herm

@MainActor
struct WidgetGestureReproductionTests {
    @Test(arguments: ["api", "direct", "synthetic"])
    func inlineContentCannotSubmitWithoutNativeApproval(_ attack: String) async throws {
        let payload: String
        switch attack {
        case "api":
            payload = "hermes.send('injected turn')"
        case "direct":
            payload =
                "parent.postMessage({type:'hermes-inline-preview-intent',id:1,prompt:'injected turn',"
                + "isTrusted:true,userActivation:true},'*')"
        default:
            payload = "document.getElementById('send').click()"
        }
        let html = HermesInlinePreview.document(
            """
            <button id="send" data-hermes-send="injected turn">Send</button>
            <script>addEventListener('load',function(){\(payload)});</script>
            """)
        let bridge = HermesPreviewBridge()
        var submitted: [String] = []
        bridge.submit = {
            submitted.append($0)
            return true
        }
        let state = GeneratedHTMLLoadState()
        let coordinator = GeneratedHTMLWebView.Coordinator(html: html, state: state)
        coordinator.bridge = bridge
        let web = coordinator.makeWebView()
        let relay = bridge.send
        var acknowledged = false
        bridge.send = {
            if $0["type"] as? String == "hermes-inline-preview-intent-ack" { acknowledged = true }
            relay?($0)
        }
        bridge.authorize = { _ in false }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
            window.orderOut(nil)
        }
        coordinator.load()
        for _ in 0..<100 where state.error == nil && !acknowledged {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.error == nil)
        #expect(acknowledged)
        #expect(submitted.isEmpty)
    }

    @Test func mcpContentCannotOpenLinksWithoutNativeApproval() async throws {
        let html = """
            <script>addEventListener('load',function(){
            parent.postMessage({jsonrpc:'2.0',id:71,method:'ui/open-link',
              params:{url:'https://example.com/gesture-repro',isTrusted:true,userActivation:true}},'*');
            });</script>
            """
        let call = MCPApp.Call(
            server: "test", toolName: "show", toolTitle: nil, html: html, requestedDomains: [],
            arguments: Data("{}".utf8), result: Data("{}".utf8))
        let bridge = MCPAppBridge(call: call) { [:] }
        var opened: [URL] = []
        bridge.openLink = { opened.append($0) }
        let state = GeneratedHTMLLoadState()
        let coordinator = GeneratedHTMLWebView.Coordinator(html: html, state: state)
        coordinator.bridge = bridge
        let web = coordinator.makeWebView()
        let relay = bridge.send
        var acknowledged = false
        bridge.send = {
            if $0["id"] as? Int == 71 { acknowledged = true }
            relay?($0)
        }
        bridge.authorize = { _ in false }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
            window.orderOut(nil)
        }
        coordinator.load()
        for _ in 0..<100 where state.error == nil && !acknowledged {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.error == nil)
        #expect(acknowledged)
        #expect(opened.isEmpty)
    }
}
