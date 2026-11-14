import AppKit
import Testing

@testable import Herm

@MainActor
struct GeneratedHTMLActionApprovalTests {
    @Test func unavailableWindowDenies() async {
        let approval = GeneratedHTMLActionApproval()
        let result = await approval.approve(.submitPrompt(prompt: "hello", conversation: "chat"), window: nil)
        #expect(!result)
    }

    @Test func pendingWidgetCannotBeReplacedOrDeliveredAfterInvalidation() async throws {
        let bridge = HermesPreviewBridge()
        var continuation: CheckedContinuation<Bool, Never>?
        var submitted: [String] = []
        var replies: [[String: Any]] = []
        bridge.send = { replies.append($0) }
        bridge.submit = {
            submitted.append($0)
            return true
        }
        bridge.authorize = { action in
            if case .submitPrompt(let prompt, _) = action { #expect(prompt == "first") }
            return await withCheckedContinuation { continuation = $0 }
        }
        bridge.receive(["type": "hermes-inline-preview-intent", "id": 1, "prompt": " first "])
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        bridge.receive(["type": "hermes-inline-preview-intent", "id": 2, "prompt": "second"])
        #expect((replies.last?["ack"] as? [String: Any])?["error"] as? String == "busy")
        #expect(submitted.isEmpty)
        bridge.invalidate()
        try #require(continuation).resume(returning: true)
        for _ in 0..<100 { await Task.yield() }
        #expect(submitted.isEmpty)
    }

    @Test func mcpNotificationsAndMalformedIDsCannotOpenLinks() async {
        let call = MCPApp.Call(
            server: "s", toolName: "t", toolTitle: nil, html: "", requestedDomains: [],
            arguments: Data("{}".utf8), result: Data("{}".utf8))
        let bridge = MCPAppBridge(call: call) { [:] }
        var reviews = 0
        var opened: [URL] = []
        bridge.authorize = { _ in
            reviews += 1
            return true
        }
        bridge.openLink = { opened.append($0) }
        for id: Any in [NSNull(), true, ["bad": 1]] {
            bridge.receive([
                "jsonrpc": "2.0", "id": id, "method": "ui/open-link", "params": ["url": "https://example.com"],
            ])
        }
        bridge.receive(["jsonrpc": "2.0", "method": "ui/open-link", "params": ["url": "https://example.com"]])
        for _ in 0..<20 { await Task.yield() }
        #expect(reviews == 0 && opened.isEmpty)
    }
}
