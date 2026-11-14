import AppKit
import SwiftUI
import Testing
import WebKit

@testable import Herm

@MainActor
private final class WidgetLifecycleRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var prompts = 0
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "prompt.submit" {
            prompts += 1
            return ["status": "streaming"]
        }
        return [:]
    }
}

@MainActor
@Suite(.serialized)
struct WidgetLifecycleTests {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func waitForSheet(_ window: NSWindow) async throws -> NSWindow {
        for _ in 0..<100 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(window.attachedSheet)
    }

    @Test func nativeSheetShowsExactValuesAndReleasesLease() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let approval = GeneratedHTMLActionApproval()
        let prompt = "first line\nsecond line / exact"
        let first = Task {
            await approval.approve(.submitPrompt(prompt: prompt, conversation: "test chat"), window: window)
        }
        let sheet = try await waitForSheet(window)
        let views = descendants(try #require(sheet.contentView))
        #expect(views.compactMap { $0 as? NSTextView }.contains { $0.string == prompt })
        #expect(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("test chat") })
        let confirm = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Send message" })
        confirm.performClick(nil)
        #expect(await first.value)
        let url = URL(string: "https://example.com/path?q=exact%20value")!
        let second = Task { await approval.approve(.openLink(url: url, source: "server"), window: window) }
        let sheet2 = try await waitForSheet(window)
        let views2 = descendants(try #require(sheet2.contentView))
        #expect(views2.compactMap { $0 as? NSTextView }.contains { $0.string == url.absoluteString })
        let cancel = try #require(views2.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
        #expect(cancel.keyEquivalent == "\u{1b}")
        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet2.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
            )
        )
        let handled = sheet2.performKeyEquivalent(with: escape)
        if !handled { cancel.performClick(nil) }
        #expect(handled)
        #expect(!(await second.value))
        let third = Task { await approval.approve(.openLink(url: url, source: "server"), window: window) }
        _ = try await waitForSheet(window)
        approval.invalidate()
        #expect(!(await third.value))
        let fourth = Task { await approval.approve(.openLink(url: url, source: "server"), window: window) }
        _ = try await waitForSheet(window)
        window.close()
        #expect(!(await fourth.value))
    }

    @Test func replacedWidgetCannotUsePreviousFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.html")
        let b = root.appendingPathComponent("b.html")
        try "<body>UNIQUE_A<script>window.aExecuted=true</script></body>".write(
            to: a, atomically: true, encoding: .utf8)
        try "<body>UNIQUE_B<script>window.bExecuted=true</script></body>".write(
            to: b, atomically: true, encoding: .utf8)
        let host = NSHostingView(rootView: HermesInlinePreviewView(file: a.path))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func currentWeb() -> WKWebView? { descendants(host).compactMap { $0 as? WKWebView }.first }
        for _ in 0..<100 where currentWeb() == nil { try await Task.sleep(for: .milliseconds(20)) }
        let first = try #require(currentWeb())
        var initialLoaded = false
        for _ in 0..<100 {
            if (try? await first.evaluateJavaScript("document.querySelector('iframe')?.srcdoc") as? String)?
                .contains("UNIQUE_A") == true
            {
                initialLoaded = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(initialLoaded, "Initial A document did not load")
        host.rootView = HermesInlinePreviewView(file: b.path)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if let current = currentWeb(), current !== first,
                let doc = try? await current.evaluateJavaScript("document.querySelector('iframe')?.srcdoc") as? String
            {
                #expect(!doc.contains("UNIQUE_A"))
                if doc.contains("UNIQUE_B") { return }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Replacement B did not load")
    }

    @Test func navigationDismissesPendingSheetAndDeniesLateAction() async throws {
        let html = """
            <script>addEventListener('message',e=>{if(e.data.go) location.href='about:blank'});
            addEventListener('load',()=>parent.postMessage({type:'hermes-inline-preview-intent',id:1,prompt:'pending'},'*'));</script>
            """
        let bridge = HermesPreviewBridge()
        var submitted = 0
        bridge.submit = { _ in
            submitted += 1
            return true
        }
        let state = GeneratedHTMLLoadState()
        let coordinator = GeneratedHTMLWebView.Coordinator(html: html, state: state)
        coordinator.bridge = bridge
        let web = coordinator.makeWebView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
            window.close()
        }
        coordinator.load()
        let sheet = try await waitForSheet(window)
        let content = try #require(sheet.contentView)
        let confirm = try #require(
            descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Send message" })
        _ = try await web.evaluateJavaScript(
            "document.querySelector('iframe').contentWindow.postMessage({go:true},'*')")
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(window.attachedSheet == nil)
        confirm.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(submitted == 0)
    }

    @Test func invalidatedMCPDeniesSuspendedApproval() async throws {
        let call = MCPApp.Call(
            server: "s", toolName: "t", toolTitle: nil, html: "", requestedDomains: [],
            arguments: Data("{}".utf8), result: Data("{}".utf8))
        let bridge = MCPAppBridge(call: call) { [:] }
        var continuation: CheckedContinuation<Bool, Never>?
        var opened = 0
        bridge.openLink = { _ in opened += 1 }
        bridge.authorize = { _ in await withCheckedContinuation { continuation = $0 } }
        bridge.receive(["jsonrpc": "2.0", "id": 1, "method": "ui/open-link", "params": ["url": "https://example.com"]])
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        bridge.invalidate()
        try #require(continuation).resume(returning: true)
        for _ in 0..<100 { await Task.yield() }
        #expect(opened == 0)
    }

    @Test func competingOwnersAndStaleSheetCannotCompleteNewLease() async throws {
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        firstWindow.orderFrontRegardless()
        secondWindow.orderFrontRegardless()
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }
        let firstOwner = GeneratedHTMLActionApproval()
        let secondOwner = GeneratedHTMLActionApproval()
        let action = GeneratedHTMLActionApproval.Action.submitPrompt(prompt: "first", conversation: "chat")
        let first = Task { await firstOwner.approve(action, window: firstWindow) }
        let oldSheet = try await waitForSheet(firstWindow)
        let oldContent = try #require(oldSheet.contentView)
        let oldButton = try #require(
            descendants(oldContent).compactMap { $0 as? NSButton }.first { $0.title == "Send message" })
        #expect(!(await secondOwner.approve(action, window: secondWindow)))
        #expect(secondWindow.attachedSheet == nil)
        firstOwner.invalidate()
        #expect(!(await first.value))
        let next = Task { await firstOwner.approve(action, window: secondWindow) }
        let newSheet = try await waitForSheet(secondWindow)
        oldButton.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(secondWindow.attachedSheet === newSheet)
        let newContent = try #require(newSheet.contentView)
        let newButton = try #require(
            descendants(newContent).compactMap { $0 as? NSButton }.first { $0.title == "Send message" })
        newButton.performClick(nil)
        #expect(await next.value)
        #expect(await secondOwner.approve(action, window: nil) == false)
    }

    @Test func failedOrDestroyedCoordinatorDismissesSheetAndReleasesLease() async throws {
        for failure in [true, false] {
            let bridge = HermesPreviewBridge()
            var submitted = 0
            bridge.submit = { _ in
                submitted += 1
                return true
            }
            let coordinator = GeneratedHTMLWebView.Coordinator(
                html: "<body>widget</body>", state: GeneratedHTMLLoadState())
            coordinator.bridge = bridge
            let web = coordinator.makeWebView()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = web
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            bridge.receive(["type": "hermes-inline-preview-intent", "id": 1, "prompt": "pending"])
            let sheet = try await waitForSheet(window)
            let content = try #require(sheet.contentView)
            let button = try #require(
                descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Send message" })
            if failure {
                coordinator.webViewWebContentProcessDidTerminate(web)
            } else {
                GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
            }
            #expect(window.attachedSheet == nil)
            button.performClick(nil)
            try await Task.sleep(for: .milliseconds(100))
            #expect(submitted == 0)
            let replacement = GeneratedHTMLActionApproval()
            let action = GeneratedHTMLActionApproval.Action.submitPrompt(prompt: "next", conversation: "chat")
            let next = Task { await replacement.approve(action, window: window) }
            _ = try await waitForSheet(window)
            replacement.invalidate()
            #expect(!(await next.value))
            if failure { GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator) }
        }
    }

    @Test func nativeMCPApprovesDisplayedURLOnceAndRejectsOverlap() async throws {
        let call = MCPApp.Call(
            server: "s", toolName: "t", toolTitle: nil, html: "", requestedDomains: [],
            arguments: Data("{}".utf8), result: Data("{}".utf8))
        let bridge = MCPAppBridge(call: call) { [:] }
        var opened: [URL] = []
        bridge.openLink = { opened.append($0) }
        let coordinator = GeneratedHTMLWebView.Coordinator(html: "<body>app</body>", state: GeneratedHTMLLoadState())
        coordinator.bridge = bridge
        let web = coordinator.makeWebView()
        var replies: [[String: Any]] = []
        bridge.send = { replies.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
            window.orderOut(nil)
        }
        let url = URL(string: "https://example.com/exact?q=a%20b")!
        bridge.receive(["jsonrpc": "2.0", "id": 1, "method": "ui/open-link", "params": ["url": url.absoluteString]])
        let sheet = try await waitForSheet(window)
        let content = try #require(sheet.contentView)
        #expect(descendants(content).compactMap { $0 as? NSTextView }.contains { $0.string == url.absoluteString })
        bridge.receive(["jsonrpc": "2.0", "id": 2, "method": "ui/open-link", "params": ["url": "https://example.org"]])
        #expect(replies.contains { $0["id"] as? Int == 2 && $0["error"] != nil })
        let button = try #require(
            descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Open link" })
        button.performClick(nil)
        button.performClick(nil)
        for _ in 0..<100 where opened.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(opened == [url])
    }

    @Test func approvedNativeSheetSubmitsExactlyOnce() async throws {
        let bridge = HermesPreviewBridge()
        var prompts: [String] = []
        bridge.submit = {
            prompts.append($0)
            return true
        }
        let coordinator = GeneratedHTMLWebView.Coordinator(html: "<body>widget</body>", state: GeneratedHTMLLoadState())
        coordinator.bridge = bridge
        let web = coordinator.makeWebView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        defer {
            GeneratedHTMLWebView.dismantleNSView(web, coordinator: coordinator)
            window.orderOut(nil)
        }
        coordinator.load()
        for _ in 0..<100 where coordinator.state.loading { try await Task.sleep(for: .milliseconds(20)) }
        bridge.receive(["type": "hermes-inline-preview-intent", "id": 1, "prompt": "one approved message"])
        let sheet = try await waitForSheet(window)
        let content = try #require(sheet.contentView)
        let confirm = try #require(
            descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Send message" })
        confirm.performClick(nil)
        confirm.performClick(nil)
        for _ in 0..<100 where prompts.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(prompts == ["one approved message"])
    }

    @Test func staleReplyContextCannotSubmitAfterNativeApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("widget.html")
        try "<script>addEventListener('load',()=>hermes.send('review me'))</script>".write(
            to: file, atomically: true, encoding: .utf8)
        let rpc = WidgetLifecycleRPC()
        let model = DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!, initialSessionID: "owner",
            botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: rpc)
        model.status = .idle
        let message = ChatMessage(role: .hermes, text: "Original")
        model.messages = [message]
        let context = RichReplyContext(model: model, message: message, state: RichReplyState())
        #expect(context.isCurrent)
        let host = NSHostingView(
            rootView: HermesInlinePreviewView(file: file.path).environment(\.richReplyContext, context))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            model.shutdown()
        }
        let sheet = try await waitForSheet(window)
        model.messages = [ChatMessage(id: message.id, role: .hermes, text: "Changed")]
        #expect(!context.isCurrent)
        let content = try #require(sheet.contentView)
        let confirm = try #require(
            descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Send message" })
        confirm.performClick(nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rpc.prompts == 0)
    }
}
