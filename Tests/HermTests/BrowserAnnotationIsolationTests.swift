import AppKit
import Testing
import WebKit

@testable import Herm

@MainActor
struct BrowserAnnotationIsolationTests {
    @Test func pageScriptsCannotForgeSelectionsOrCancelAnnotationMode() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(
                source: "window.__posts = []; window.hermAnnotate = s => window.__posts.push(s);\n"
                    + BrowserAnnotation.script,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        defer {
            web.stopLoading()
            window.orderOut(nil)
        }
        web.loadHTMLString("<button id='target'>Page-controlled content</button>", baseURL: nil)
        var ready = false
        for _ in 0..<100 {
            ready =
                (try? await integer("Number(!!window.__hermAnnotate)", in: web)) == 1
            if ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ready)
        _ = try await integer("window.__hermAnnotate.setEnabled(true); 1", in: web)
        _ = try await web.evaluateJavaScript(
            """
            document.querySelector('#target').dispatchEvent(new MouseEvent('click', {bubbles:true, metaKey:true}));
            window.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}));
            """)
        try await Task.sleep(for: .milliseconds(100))
        let posts = try await integer("window.__posts.length", in: web)
        #expect(posts == 0)
    }

    private func integer(_ script: String, in web: WKWebView) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                continuation.resume(with: result.map { ($0 as? NSNumber)?.intValue ?? -1 })
            }
        }
    }

}
