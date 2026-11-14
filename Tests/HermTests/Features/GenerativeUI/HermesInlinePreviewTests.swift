import AppKit
import Testing

@testable import Herm

@MainActor
struct HermesInlinePreviewTests {
    @Test func loneDirectiveLinesBecomePreviewsOnceFinished() {
        let text = "Here's the table.\n\n::preview{file=\"/tmp/jobs.html\" height=\"480\"}\n\nTap Apply."
        #expect(RichDocument.mentionsSurface(text))
        #expect(
            RichDocument(text).segments == [
                .markdown("Here's the table.\n"), .preview("/tmp/jobs.html"), .markdown("\nTap Apply."),
            ])
        #expect(RichDocument(text).plainText.contains("::preview{file=\"/tmp/jobs.html\"}"))
        #expect(RichDocument(text, streaming: true).segments == [.markdown(text)])
        #expect(RichDocument.previewFile("  ::preview{file='/a b.html'}") == "/a b.html")
        #expect(RichDocument.previewFile("::preview{file=/a.html}") == "/a.html")
        #expect(RichDocument.previewFile("see ::preview{file=\"/a.html\"}") == nil)
        #expect(RichDocument.previewFile("::preview{height=\"3\"}") == nil)
        let fenced = "```\n::preview{file=\"/a.html\"}\n```"
        #expect(RichDocument(fenced).segments == [.markdown(fenced)])
    }

    @Test func onlyAbsoluteHTMLFilesFrameInline() {
        #expect(HermesInlinePreview.htmlURL("/tmp/a.HTML")?.path == "/tmp/a.HTML")
        #expect(HermesInlinePreview.htmlURL("~/a.htm") != nil)
        #expect(HermesInlinePreview.htmlURL("a.html") == nil)
        #expect(HermesInlinePreview.htmlURL("/tmp/a.png") == nil)
        #expect(HermesInlinePreview.htmlURL("https://x.dev/a.html") == nil)
        let doc = HermesInlinePreview.document("<p>x</p></BODY></html>")
        #expect(doc.hasPrefix("<style>") && doc.hasSuffix(HermesInlinePreview.script + "</BODY></html>"))
    }

    @Test func bridgeSizesAndGatesIntents() async throws {
        let bridge = HermesPreviewBridge()
        var sent: [[String: Any]] = []
        var heights: [CGFloat] = []
        var prompts: [String] = []
        var clock = Date(timeIntervalSince1970: 100)
        bridge.send = { sent.append($0) }
        bridge.resize = { heights.append($0) }
        bridge.authorize = { _ in true }
        bridge.submit = {
            prompts.append($0)
            return true
        }
        bridge.now = { clock }
        func ack() -> [String: Any]? { sent.last?["ack"] as? [String: Any] }

        for height in [40, 300, 5000] { bridge.receive(["type": "hermes-inline-preview-size", "height": height]) }
        bridge.receive(["type": "hermes-inline-preview-size", "height": -1])
        #expect(heights == [120, 300, 1200])

        bridge.receive(["type": "hermes-inline-preview-intent", "id": 1, "prompt": "  "])
        #expect(ack()?["error"] as? String == "invalid")
        bridge.receive(["type": "hermes-inline-preview-intent", "id": 2, "prompt": String(repeating: "x", count: 501)])
        #expect(ack()?["error"] as? String == "too_long")
        bridge.receive(["type": "hermes-inline-preview-intent", "id": 3, "prompt": " apply 1 "])
        for _ in 0..<50 where sent.last?["id"] as? Int != 3 { await Task.yield() }
        #expect(prompts == ["apply 1"] && ack()?["ok"] as? Bool == true)
        clock += 0.4
        bridge.receive(["type": "hermes-inline-preview-intent", "id": 4, "prompt": "apply 2"])
        #expect(ack()?["error"] as? String == "throttled" && ack()?["retryAfterMs"] as? Int == 600)
        #expect(sent.last?["type"] as? String == "hermes-inline-preview-intent-ack")
    }

    @Test func contentSizedFramesPassWheelEventsToTheTranscript() throws {
        final class Catcher: NSResponder {
            var wheels = 0
            override func scrollWheel(with event: NSEvent) { wheels += 1 }
        }
        let catcher = Catcher()
        let web = GeneratedHTMLWebKitView(frame: .zero)
        web.nextResponder = catcher
        let wheel = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -20, wheel2: 0, wheel3: 0
            ).flatMap(NSEvent.init(cgEvent:)))
        web.passesScroll = true
        web.scrollWheel(with: wheel)
        #expect(catcher.wheels == 1)
    }

    @Test func realWebKitSizesTheFrameAndDeliversDataHermesSend() async throws {
        let widget = """
            <div style="height:340px">rows</div>
            <button id="b" data-hermes-send="apply job 7">Apply</button>
            <script>
            addEventListener('load', () => document.getElementById('b').click());
            </script>
            """
        let bridge = HermesPreviewBridge()
        var height: CGFloat?
        var prompts: [String] = []
        bridge.resize = { height = $0 }
        bridge.submit = {
            prompts.append($0)
            return true
        }
        let state = GeneratedHTMLLoadState()
        let html = HermesInlinePreview.document(widget)
        let coordinator = GeneratedHTMLWebView.Coordinator(html: html, state: state)
        coordinator.bridge = bridge
        let web = coordinator.makeWebView()
        bridge.authorize = { _ in true }
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
        for _ in 0..<100 where state.error == nil && (prompts.isEmpty || (height ?? 0) < 340) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.error == nil)
        #expect((height ?? 0) >= 340)
        #expect(prompts == ["apply job 7"])
    }
}
