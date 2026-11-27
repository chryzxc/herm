import AppKit
import Testing

@testable import Herm

@MainActor
struct BrowserPageRenderingReproductionTests {
    @Test func becomingVisibleReplaysCachedFrameAndPointer() throws {
        let browser = AgentBrowser(profileID: "cached-replay")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let canvas = AgentBrowserCanvas(frame: container.bounds)
        let hidden = AgentBrowserCanvas(frame: container.bounds)
        canvas.browser = browser
        hidden.browser = browser
        container.addSubview(canvas)
        container.addSubview(hidden)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil }
        // Decoded frames arrive as CGImage-backed images; the layer shows that CGImage directly.
        let cachedImage = try #require(try frame().cgImage(forProposedRect: nil, context: nil, hints: nil))
        browser.receiveFrame(NSImage(cgImage: cachedImage, size: .zero), css: NSSize(width: 1280, height: 800))
        browser.updatePointer(AgentPointer(kind: .down, point: CGPoint(x: 640, y: 400)))
        hidden.surfaceVisible = false
        let visibleLayer = try #require(canvas.subviews.first?.layer)
        let hiddenLayer = try #require(hidden.subviews.first?.layer)
        #expect(ObjectIdentifier(try #require(hiddenLayer.contents) as CFTypeRef) == ObjectIdentifier(cachedImage))
        let images = try (0..<8).map { _ in
            try #require(try frame().cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
        var visibleChanges = 0
        var hiddenChanges = 0
        for image in images {
            browser.receiveFrame(NSImage(cgImage: image, size: .zero), css: NSSize(width: 1280, height: 800))
            if let shown = visibleLayer.contents, ObjectIdentifier(shown as CFTypeRef) == ObjectIdentifier(image) {
                visibleChanges += 1
            }
            let shown = try #require(hiddenLayer.contents)
            if ObjectIdentifier(shown as CFTypeRef) != ObjectIdentifier(cachedImage) {
                hiddenChanges += 1
            }
        }
        print("FRAME WORK visible=\(visibleChanges) hidden=\(hiddenChanges)")
        #expect(visibleChanges == 8)
        #expect(hiddenChanges == 0)
        #expect(browser.viewers == 1)
        let latest = try #require(browser.lastFrame?.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(ObjectIdentifier(latest) == ObjectIdentifier(images[7]))
        let replayImage = try #require(try frame().cgImage(forProposedRect: nil, context: nil, hints: nil))
        browser.receiveFrame(NSImage(cgImage: replayImage, size: .zero), css: NSSize(width: 1280, height: 2000))
        let replayPoint = CGPoint(x: 320, y: 1000)
        browser.updatePointer(AgentPointer(kind: .move, point: replayPoint))
        hidden.setFrameSize(NSSize(width: 500, height: 400))
        hidden.surfaceVisible = true
        #expect(hidden.pageRect.width == 256)
        #expect(hidden.pageRect.height == 400)
        let shown = try #require(hiddenLayer.contents)
        #expect(CFGetTypeID(shown as CFTypeRef) == CGImage.typeID)
        #expect(ObjectIdentifier(shown as CFTypeRef) == ObjectIdentifier(replayImage))
        #expect(browser.panelSize == hidden.bounds.size)
        #expect(browser.lastPointer?.kind == .move)
        let cursor = try #require(hidden.subviews.compactMap { $0 as? AgentCursorView }.first)
        #expect(!cursor.isHidden)
        #expect(browser.lastPointer?.point == replayPoint)
        #expect(
            cursor.frame.origin
                == CGPoint(
                    x: hidden.pageRect.minX + 64 - AgentCursorView.tip.x,
                    y: hidden.pageRect.minY + 200 - AgentCursorView.tip.y))
        let next = try #require(try frame().cgImage(forProposedRect: nil, context: nil, hints: nil))
        browser.receiveFrame(NSImage(cgImage: next, size: .zero), css: NSSize(width: 1280, height: 800))
        #expect(ObjectIdentifier(try #require(visibleLayer.contents) as CFTypeRef) == ObjectIdentifier(next))
        #expect(ObjectIdentifier(try #require(hiddenLayer.contents) as CFTypeRef) == ObjectIdentifier(next))
        hidden.isHidden = true
        let other = AgentBrowser(profileID: "hidden-rebind")
        other.receiveFrame(NSImage(cgImage: cachedImage, size: .zero), css: NSSize(width: 1280, height: 800))
        hidden.browser = other
        #expect(hiddenLayer.contents == nil)
        #expect(other.viewers == 0)
        hidden.isHidden = false
        #expect(other.viewers == 1)
        #expect(ObjectIdentifier(try #require(hiddenLayer.contents) as CFTypeRef) == ObjectIdentifier(cachedImage))
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
        try await withIsolatedChromium { cdp, session in
            try await verifyResizedPreview(cdp, session: session)
        }
    }

    private func withIsolatedChromium(_ body: (CDPConnection, String) async throws -> Void) async throws {
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
        try await body(cdp, session)
    }

    private func verifyResizedPreview(_ cdp: CDPConnection, session: String) async throws {
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
        var reportedPixels = CGSize.zero
        var stream: BrowserScreencast?
        cdp.onEvent = { method, params, eventSession in
            guard method == "Page.screencastFrame", eventSession == session,
                let decoded = params["decodedFrame"] as? CDPConnection.Frame,
                let metadata = params["metadata"] as? [String: Any],
                let width = metadata["deviceWidth"] as? Double,
                let height = metadata["deviceHeight"] as? Double
            else { return }
            let css = CGSize(width: width, height: height)
            let pixels = CGSize(width: decoded.image.width, height: decoded.image.height)
            switch stream?.receive(cssSize: css, pixelSize: pixels) {
            case .display: break
            case .restart:
                if let stream {
                    cdp.fire("Page.stopScreencast", session: session)
                    cdp.fire(
                        "Page.startScreencast", AgentBrowser.screencastParameters(pixelSize: stream.viewport.pixelSize),
                        session: session)
                }
                return
            case .ignore, nil: return
            }
            reportedSize = css
            reportedPixels = pixels
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
            browser.resize(to: size, scale: 2)
            let viewport = browser.captureViewportSize
            let pixels = browser.screencastPixelSize(for: viewport)
            let previous = frames
            _ = try await cdp.send(
                "Emulation.setDeviceMetricsOverride",
                [
                    "width": Int(viewport.width), "height": Int(viewport.height), "deviceScaleFactor": 2,
                    "screenWidth": Int(viewport.width), "screenHeight": Int(viewport.height), "mobile": false,
                ], session: session)
            _ = try await cdp.send("Page.getLayoutMetrics", session: session)
            if index > 0 { _ = try await cdp.send("Page.stopScreencast", session: session) }
            stream = BrowserScreencast(
                sessionID: session,
                viewport: BrowserScreencast.Viewport(
                    cssSize: viewport, pixelSize: pixels, backingScale: 2, isMobile: false))
            _ = try await cdp.send(
                "Page.startScreencast", AgentBrowser.screencastParameters(pixelSize: pixels), session: session)
            for _ in 0..<200 {
                if frames > previous, reportedSize == viewport { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let page = try #require(canvas.subviews.first)
            print("REPRO panel=\(size) requested=\(viewport) metadata=\(reportedSize)")
            print("REPRO page=\(page.frame) frames=\(frames)")
            #expect(frames > previous)
            #expect(reportedSize == viewport)
            #expect(reportedPixels.width <= pixels.width)
            #expect(reportedPixels.height <= pixels.height)
            // After retrying, Chrome can send a correctly proportioned frame at its native CSS resolution.
            let minimumArea = min(pixels.width * pixels.height, viewport.width * viewport.height)
            #expect(reportedPixels.width * reportedPixels.height >= minimumArea * 0.99)
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
