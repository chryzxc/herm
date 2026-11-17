import AppKit
import Testing

@testable import Herm

@MainActor
struct BrowserPageRenderingReproductionTests {
    @Test func becomingVisibleReplaysCachedFrameAndPointer() throws {
        let browser = AgentBrowser(profileID: "cached-replay")
        let canvas = AgentBrowserCanvas(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        canvas.browser = browser
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        defer { window.contentView = nil }
        let cached = try frame()
        browser.receiveFrame(cached, css: NSSize(width: 1280, height: 800))
        browser.updatePointer(AgentPointer(kind: .down, point: CGPoint(x: 640, y: 400)))
        canvas.surfaceVisible = false
        canvas.setFrameSize(NSSize(width: 500, height: 400))
        browser.frameUpdates.send((try frame(), NSSize(width: 1280, height: 2000)))
        #expect(canvas.pageRect.width == 256)
        canvas.surfaceVisible = true
        #expect(canvas.pageRect.width == 500)
        #expect(canvas.subviews.first?.layer?.contents as? NSImage === cached)
        #expect(browser.panelSize == canvas.bounds.size)
        #expect(browser.lastPointer?.kind == .move)
        let cursor = try #require(canvas.subviews.compactMap { $0 as? AgentCursorView }.first)
        #expect(!cursor.isHidden)
    }

    @Test func hiddenCanvasDoesNotReceivePageFieldEvents() {
        let browser = AgentBrowser(profileID: "hidden-page-events")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let visible = AgentBrowserCanvas(frame: container.bounds)
        let hidden = AgentBrowserCanvas(frame: container.bounds)
        hidden.surfaceVisible = false
        visible.browser = browser
        hidden.browser = browser
        container.addSubview(visible)
        container.addSubview(hidden)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil }
        let range = NSRange(location: 0, length: 0)
        let hiddenBefore = hidden.firstRect(forCharacterRange: range, actualRange: nil)
        let visibleBefore = visible.firstRect(forCharacterRange: range, actualRange: nil)
        browser.pageEventUpdates.send(.field(CGRect(x: 100, y: 120, width: 200, height: 40)))
        #expect(hidden.firstRect(forCharacterRange: range, actualRange: nil) == hiddenBefore)
        #expect(visible.firstRect(forCharacterRange: range, actualRange: nil) != visibleBefore)
    }

    @Test func hiddenCanvasDoesNotStealTheFirstVisibleFrame() throws {
        let browser = AgentBrowser(profileID: "render-reproduction")
        let first = AgentBrowserCanvas(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        first.browser = browser
        let second = AgentBrowserCanvas(frame: first.frame)
        second.surfaceVisible = false
        second.browser = browser
        let window = NSWindow(
            contentRect: first.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = first
        defer { window.contentView = nil }
        let image = try frame()
        browser.frameUpdates.send((image, NSSize(width: 1280, height: 800)))
        let page = try #require(first.subviews.first)
        print("REPRO visible viewers=\(browser.viewers) visibleHasFrame=\(page.layer?.contents != nil)")
        #expect(page.layer?.contents != nil)
    }

    @Test func returningToASessionCanvasUpdatesItsStaleFrameGeometry() throws {
        let browser = AgentBrowser(profileID: "return-reproduction")
        let first = AgentBrowserCanvas(frame: NSRect(x: 0, y: 0, width: 640, height: 1000))
        first.browser = browser
        let window = NSWindow(
            contentRect: first.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = first
        defer { window.contentView = nil }
        let image = try frame()
        browser.frameUpdates.send((image, NSSize(width: 1280, height: 2000)))
        let second = AgentBrowserCanvas(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        second.browser = browser
        window.contentView = second
        first.surfaceVisible = false
        second.surfaceVisible = true
        browser.frameUpdates.send((image, NSSize(width: 1280, height: 800)))
        window.contentView = first
        second.surfaceVisible = false
        first.surfaceVisible = true
        first.setFrameSize(NSSize(width: 640, height: 400))
        browser.frameUpdates.send((image, NSSize(width: 1280, height: 800)))
        print("REPRO returned panel=\(first.bounds.size) visiblePage=\(first.pageRect)")
        #expect(first.pageRect.width == 640)
        #expect(first.pageRect.height == 400)
        second.browser = nil
        browser.frameUpdates.send((image, NSSize(width: 1000, height: 800)))
        #expect(first.pageRect.width == 500)
    }

    @Test func hiddenCanvasResizeDoesNotOverrideTheVisibleViewport() {
        let browser = AgentBrowser(profileID: "hidden-metrics")
        let visible = AgentBrowserCanvas(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        visible.browser = browser
        let window = NSWindow(
            contentRect: visible.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = visible
        defer { window.contentView = nil }
        let hidden = AgentBrowserCanvas(frame: .zero)
        hidden.surfaceVisible = false
        hidden.browser = browser
        hidden.setFrameSize(NSSize(width: 320, height: 1000))
        print("REPRO visible panel=\(visible.bounds.size) sharedViewport=\(browser.panelSize)")
        #expect(browser.panelSize == visible.bounds.size)
    }

    @Test func liveChromiumFramesFillTheDesktopPreviewAfterResizing() async throws {
        let executable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            Issue.record("Local Chrome unavailable for browser rendering reproduction")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herm-render-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = Process()
        chrome.executableURL = executable
        chrome.arguments = [
            "--headless=new", "--remote-debugging-port=0", "--user-data-dir=\(root.path)",
            "--no-first-run", "--no-default-browser-check", "about:blank",
        ]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        try chrome.run()
        defer {
            chrome.terminate()
            chrome.waitUntilExit()
        }
        let portFile = root.appendingPathComponent("DevToolsActivePort")
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
        let browser = AgentBrowser(profileID: "render-metrics")
        browser.presetWidth = 1280
        let canvas = AgentBrowserCanvas(frame: .zero)
        canvas.browser = browser
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        defer { window.contentView = nil }
        var frames = 0
        var reportedSize = CGSize.zero
        cdp.onEvent = { method, params, eventSession in
            guard method == "Page.screencastFrame", eventSession == session,
                let decoded = params["decodedFrame"] as? CDPConnection.Frame,
                let metadata = params["metadata"] as? [String: Any],
                let width = metadata["deviceWidth"] as? Double,
                let height = metadata["deviceHeight"] as? Double
            else { return }
            reportedSize = CGSize(width: width, height: height)
            frames += 1
            browser.frameUpdates.send((NSImage(cgImage: decoded.image, size: .zero), reportedSize))
        }
        _ = try await cdp.send("Page.enable", session: session)
        _ = try await cdp.send(
            "Page.navigate",
            ["url": "data:text/html,<style>html,body{margin:0;width:100%;height:100%;background:rgb(255,0,0)}</style>"],
            session: session)
        let sizes = [NSSize(width: 640, height: 400), NSSize(width: 900, height: 500)]
        for (index, size) in sizes.enumerated() {
            canvas.setFrameSize(size)
            let viewport = browser.captureViewportSize
            let previous = frames
            _ = try await cdp.send(
                "Emulation.setDeviceMetricsOverride",
                [
                    "width": Int(viewport.width), "height": Int(viewport.height), "deviceScaleFactor": 2,
                    "screenWidth": Int(viewport.width), "screenHeight": Int(viewport.height), "mobile": false,
                ], session: session)
            // Mirrors AgentBrowser.applyViewport: a static page may not repaint for new metrics,
            // so a size change restarts the screencast to get a frame at that size.
            if index > 0 { _ = try await cdp.send("Page.stopScreencast", session: session) }
            _ = try await cdp.send(
                "Page.startScreencast",
                ["format": "png", "everyNthFrame": 1, "maxWidth": 8192, "maxHeight": 8192], session: session)
            for _ in 0..<200 {
                if frames > previous, reportedSize == viewport { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let page = try #require(canvas.subviews.first)
            print("REPRO panel=\(size) requested=\(viewport) metadata=\(reportedSize)")
            print("REPRO page=\(page.frame) frames=\(frames)")
            #expect(frames > previous)
            #expect(reportedSize == viewport)
            #expect(abs(canvas.pageRect.width - size.width) < 1)
            #expect(abs(canvas.pageRect.height - size.height) < 1)
            #expect(page.layer?.contents != nil)
        }
    }

    private func frame() throws -> NSImage {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 20, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<20 {
            for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 255
            }
        }
        return NSImage(cgImage: try #require(bitmap.cgImage), size: .zero)
    }
}
