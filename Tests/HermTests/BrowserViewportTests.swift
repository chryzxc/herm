import AppKit
import SwiftUI
import Testing
import WebKit

@testable import Herm

@MainActor
struct BrowserViewportTests {
    @Test func fitPageReflowsOnEveryPanelResizeWithoutReloading() async throws {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let host = NSHostingView(rootView: BrowserWebView(web: web))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        web.loadHTMLString(
            """
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>body{margin:0}main{width:100%}@media(min-width:600px){main{display:grid;grid-template-columns:1fr 1fr}}</style>
            <main><input id="draft"><p>Responsive page</p></main>
            <script>window.pageToken='retained'</script>
            """, baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.pageToken")) as? String == "retained" {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.evaluateJavaScript("document.getElementById('draft').value='unsent text'")
        for width in [320, 900, 390, 1280] {
            window.setContentSize(NSSize(width: width, height: 480))
            host.layoutSubtreeIfNeeded()
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("innerWidth")) as? Int == width { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(web.frame.width == CGFloat(width))
            #expect(try await web.evaluateJavaScript("innerWidth") as? Int == width)
            #expect(
                try await web.evaluateJavaScript(
                    "getComputedStyle(document.querySelector('main')).display") as? String
                    == (width >= 600 ? "grid" : "block"))
            #expect(
                try await web.evaluateJavaScript("document.getElementById('draft').value")
                    as? String == "unsent text")
            #expect(try await web.evaluateJavaScript("window.pageToken") as? String == "retained")
        }
    }

    @Test func devicePreviewKeepsItsCSSWidthThenAutoUsesTheWholePanel() {
        let web = WKWebView()
        let container = BrowserPageContainer(web: web, viewport: .phone)
        for width in [300.0, 900.0] {
            container.setFrameSize(NSSize(width: width, height: 480))
            #expect(abs(web.frame.width / web.pageZoom - 390) < 0.1)
            #expect(abs(web.frame.midX - width / 2) < 0.1)
        }
        container.viewport = .desktop
        #expect(abs(web.frame.width / web.pageZoom - 1280) < 0.1)
        container.viewport = .fit
        #expect(web.frame.width == 900)
        #expect(web.pageZoom == 1)
        container.setFrameSize(NSSize(width: 1100, height: 600))
        #expect(web.frame.size == NSSize(width: 1100, height: 600))
    }

    @Test func chromiumCanvasForwardsFrameChangesWithoutNeedingALayoutPass() {
        let browser = AgentBrowser(key: .init(profileID: nil, sessionID: "viewport"))
        let canvas = AgentBrowserCanvas(frame: .zero)
        canvas.browser = browser
        for width in [320.0, 900.0, 390.0, 1280.0] {
            let size = NSSize(width: width, height: 480)
            canvas.setFrameSize(size)
            #expect(browser.panelSize == size)
        }
        canvas.setFrameSize(.zero)
        #expect(browser.panelSize == NSSize(width: 1280, height: 480))
    }
}
