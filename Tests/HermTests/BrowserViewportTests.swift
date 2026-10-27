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

    @Test func fractionalPanelBoundsKeepAutoAtOneCSSPixelPerPoint() {
        let browser = AgentBrowser(key: .init(profileID: nil, sessionID: "fractional-viewport"))
        let canvas = AgentBrowserCanvas(frame: .zero)
        canvas.browser = browser
        for size in [NSSize(width: 833.5, height: 501.75), NSSize(width: 390.25, height: 480.5)] {
            canvas.setFrameSize(size)
            let viewport = browser.captureViewportSize
            #expect(viewport.width == size.width.rounded(.down))
            #expect(viewport.height == size.height.rounded(.down))
            browser.onFrame?(NSImage(size: viewport), viewport)
            #expect(canvas.pageRect.size == viewport)
            #expect(canvas.pageRect.minX * 2 == (canvas.pageRect.minX * 2).rounded())
            #expect(canvas.bounds.contains(canvas.pageRect))
        }
        browser.presetWidth = 1280
        let viewport = browser.captureViewportSize
        #expect(viewport.width == 1280)
        browser.onFrame?(NSImage(size: viewport), viewport)
        #expect(canvas.pageRect.width <= canvas.bounds.width)
        #expect(canvas.pageRect.height <= canvas.bounds.height)
    }

    @Test func agentPointerParsesOnlyWellFormedPageReports() {
        #expect(
            AgentPointer(json: #"{"type":"down","x":12.5,"y":40}"#)
                == AgentPointer(kind: .down, point: CGPoint(x: 12.5, y: 40)))
        #expect(AgentPointer(json: #"{"type":"focus","x":0,"y":0}"#)?.kind == .focus)
        #expect(AgentPointer(json: #"{"type":"teleport","x":1,"y":1}"#) == nil)
        #expect(AgentPointer(json: #"{"type":"move","x":"1","y":1}"#) == nil)
        #expect(AgentPointer(json: "not json") == nil)
    }

    @Test func agentCursorFollowsHermesWhileInputStaysWithTheCanvas() async throws {
        let browser = AgentBrowser(key: .init(profileID: nil, sessionID: "agent-cursor"))
        let canvas = AgentBrowserCanvas(frame: .zero)
        canvas.browser = browser
        canvas.setFrameSize(NSSize(width: 640, height: 400))
        browser.onFrame?(NSImage(size: NSSize(width: 1280, height: 800)), CGSize(width: 1280, height: 800))
        let cursor = try #require(canvas.subviews.compactMap { $0 as? AgentCursorView }.first)
        #expect(cursor.isHidden)

        browser.inputLocked = true
        browser.onPointer?(AgentPointer(kind: .down, point: CGPoint(x: 640, y: 400)))
        #expect(!cursor.isHidden)
        // The page is half size, so CSS (640, 400) lands at the canvas centre.
        let tip = CGPoint(x: 320, y: 200)
        #expect(canvas.hitTest(canvas.convert(tip, to: nil)) === canvas)

        browser.inputLocked = false
        for _ in 0..<40 where !cursor.isHidden { try await Task.sleep(for: .milliseconds(25)) }
        #expect(cursor.isHidden)
    }
}
