import AppKit
import SwiftUI
import Testing
import WebKit

@testable import Herm

@MainActor
struct BrowserViewportTests {
    @Test func mirroredPageCursorDistinguishesControlsTextAndWhitespace() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        web.loadHTMLString(
            """
            <style>body { margin: 0 } p { width: 500px }</style>
            <button id="button"><span>Button</span></button>
            <a id="link" href="#"><span>Link</span></a>
            <input id="input"><p id="text">Readable text</p>
            <script>window.ready = true</script>
            """, baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.evaluateJavaScript(
            "window.hermPage = value => window.lastCursor = JSON.parse(value).cursor; void 0")
        _ = try await web.evaluateJavaScript(AgentBrowser.worldScript)
        _ = try await web.evaluateJavaScript("window.__hermPage.setUserInput(true)")
        for (target, expected) in [
            ("#button span", "default"), ("#link span", "pointer"), ("#input", "text"), ("#text", "text"),
        ] {
            let result =
                try await web.evaluateJavaScript(
                    """
                    (() => { const el = document.querySelector('\(target)'); const r = el.getBoundingClientRect();
                      el.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: r.left + 2, clientY: r.top + r.height / 2 }));
                      return window.lastCursor; })()
                    """) as? String
            #expect(result == expected)
        }
        let whitespace =
            try await web.evaluateJavaScript(
                """
                (() => { const el = document.querySelector('#text'); const r = el.getBoundingClientRect();
                  el.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: r.right - 2, clientY: r.top + r.height / 2 }));
                  return window.lastCursor; })()
                """) as? String
        #expect(whitespace == "default")
    }

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

    @Test func reusedCanvasMovesItsViewerToTheNewSessionBrowser() {
        let first = AgentBrowser(profileID: "canvas-first")
        let second = AgentBrowser(profileID: "canvas-second")
        let canvas = AgentBrowserCanvas(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        canvas.browser = first
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        defer { window.contentView = nil }
        #expect(first.viewers == 1)
        canvas.surfaceVisible = false
        #expect(first.viewers == 0)
        canvas.surfaceVisible = true
        #expect(first.viewers == 1)
        canvas.browser = second
        #expect(first.viewers == 0)
        #expect(second.viewers == 1)
        #expect(second.panelSize == NSSize(width: 640, height: 400))
        canvas.browser = second
        #expect(second.viewers == 1)
        window.contentView = nil
        #expect(second.viewers == 0)
    }

    @Test func chromiumCanvasForwardsFrameChangesWithoutNeedingALayoutPass() {
        let browser = AgentBrowser(profileID: "viewport")
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
        let browser = AgentBrowser(profileID: "fractional-viewport")
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
        let browser = AgentBrowser(profileID: "agent-cursor")
        let canvas = AgentBrowserCanvas(frame: .zero)
        canvas.browser = browser
        canvas.setFrameSize(NSSize(width: 640, height: 400))
        browser.onFrame?(NSImage(size: NSSize(width: 1280, height: 800)), CGSize(width: 1280, height: 800))
        let cursor = try #require(canvas.subviews.compactMap { $0 as? AgentCursorView }.first)
        #expect(cursor.isHidden)

        browser.inputLocked = true
        browser.updatePointer(AgentPointer(kind: .down, point: CGPoint(x: 640, y: 400)))
        #expect(!cursor.isHidden)
        // The page is half size, so CSS (640, 400) lands at the canvas centre.
        let tip = CGPoint(x: 320, y: 200)
        #expect(canvas.hitTest(canvas.convert(tip, to: nil)) === canvas)

        browser.inputLocked = false
        #expect(!cursor.isHidden)
        #expect(browser.lastPointer?.kind == .move)
        let remounted = AgentBrowserCanvas(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        remounted.browser = browser
        let restored = try #require(remounted.subviews.compactMap { $0 as? AgentCursorView }.first)
        #expect(!restored.isHidden)
        remounted.setFrameSize(NSSize(width: 320, height: 200))
        #expect(restored.frame.origin == CGPoint(x: 160 - AgentCursorView.tip.x, y: 100 - AgentCursorView.tip.y))
        browser.takeOver()
        #expect(browser.lastPointer == nil)
        for _ in 0..<40 where !restored.isHidden { try await Task.sleep(for: .milliseconds(25)) }
        #expect(restored.isHidden)
    }

    @Test func userInputAndBrowserShutdownClearTheObservedAgentPointer() {
        let browser = AgentBrowser(profileID: "pointer-lifecycle")
        let pointer = AgentPointer(kind: .move, point: CGPoint(x: 12, y: 30))
        browser.updatePointer(pointer)
        browser.mouse("mouseMoved", at: .zero, modifiers: 0)
        #expect(browser.lastPointer == nil)
        browser.updatePointer(pointer)
        browser.key(["type": "keyDown", "key": "Tab"])
        #expect(browser.lastPointer == nil)
        browser.updatePointer(pointer)
        browser.stop()
        #expect(browser.lastPointer == nil)
    }

    @Test func onlyTopLevelNavigationClearsTheAgentCursor() {
        let browser = AgentBrowser(profileID: "cursor-navigation")
        let pointer = AgentPointer(kind: .move, point: CGPoint(x: 20, y: 30))
        browser.updatePointer(pointer)
        browser.receiveNavigation("Page.frameNavigated", params: ["frame": ["id": "child", "parentId": "main"]])
        #expect(browser.lastPointer == pointer)
        browser.receiveNavigation("Page.frameNavigated", params: ["frame": ["id": "main"]])
        #expect(browser.lastPointer == nil)
    }

    @Test func pageEventsParseOnlyWellFormedReports() {
        let select = AgentPageEvent(
            json: #"{"type":"select","id":3,"rect":{"x":1,"y":2,"width":90,"height":20},"selected":1,"#
                + #""options":[{"label":"One","disabled":false},{"label":"Two","disabled":true,"group":"G"}]}"#)
        #expect(
            select
                == .select(
                    id: 3, rect: CGRect(x: 1, y: 2, width: 90, height: 20), selected: 1,
                    options: [
                        .init(label: "One", disabled: false, group: nil),
                        .init(label: "Two", disabled: true, group: "G"),
                    ]
                ))
        #expect(
            AgentPageEvent(json: #"{"type":"select","id":3,"rect":{"x":1,"y":2,"width":9,"height":2},"options":[]}"#)
                == nil)
        #expect(AgentPageEvent(json: #"{"type":"cursor","cursor":"pointer"}"#) == .cursor("pointer"))
        #expect(AgentPageEvent(json: #"{"type":"field","rect":{"x":1,"y":2,"width":3}}"#) == nil)
        #expect(AgentPageEvent(json: "nope") == nil)
    }

    @Test func pageCursorsMapToSystemCursors() {
        #expect(AgentBrowserCanvas.cursor(css: "pointer") == .pointingHand)
        #expect(AgentBrowserCanvas.cursor(css: "text") == .iBeam)
        #expect(AgentBrowserCanvas.cursor(css: "ew-resize") == .resizeLeftRight)
        #expect(AgentBrowserCanvas.cursor(css: "wait") == .arrow)
    }
}
