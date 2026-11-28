import AppKit
import Combine
import Foundation
import Testing
import os

@testable import Herm

@MainActor
struct BrowserFramePerformanceTests {
    @Test func resizedStreamWaitsForTheNewViewportAndRetriesAStaleRasterOnce() {
        let css = CGSize(width: 900, height: 700)
        let pixels = CGSize(width: 1632, height: 1269)
        let viewport = BrowserScreencast.Viewport(cssSize: css, pixelSize: pixels, backingScale: 2, isMobile: false)
        var stream = BrowserScreencast(sessionID: "resizing", viewport: viewport)

        #expect(stream.receive(cssSize: CGSize(width: 432, height: 780), pixelSize: pixels) == .ignore)
        #expect(stream.receive(cssSize: css, pixelSize: CGSize(width: 864, height: 672)) == .restart)
        #expect(stream.receive(cssSize: css, pixelSize: CGSize(width: 864, height: 1269)) == .ignore)
        #expect(stream.receive(cssSize: css, pixelSize: pixels) == .display)
    }

    @Test func aCorrectlyProportionedFrameIsUsableAfterOneRetry() {
        let css = CGSize(width: 900, height: 700)
        let viewport = BrowserScreencast.Viewport(
            cssSize: css, pixelSize: CGSize(width: 1632, height: 1269), backingScale: 2, isMobile: false)
        var stream = BrowserScreencast(sessionID: "fallback", viewport: viewport)
        let smaller = CGSize(width: 864, height: 672)
        #expect(stream.receive(cssSize: css, pixelSize: smaller) == .restart)
        #expect(stream.receive(cssSize: css, pixelSize: smaller) == .display)
    }

    @Test func screencastMatchesSmallPanesAndBoundsLargeFrames() {
        let browser = AgentBrowser(profileID: "frame-size")
        browser.resize(to: CGSize(width: 640, height: 400), scale: 2)
        let native = CGSize(width: 1280, height: 800)
        #expect(browser.screencastPixelSize(for: browser.captureViewportSize) == native)

        browser.presetWidth = 1280
        #expect(browser.captureViewportSize == native)
        #expect(browser.screencastPixelSize(for: browser.captureViewportSize) == native)

        browser.presetWidth = 0
        browser.resize(to: native, scale: 2)
        let pixels = browser.screencastPixelSize(for: browser.captureViewportSize)
        #expect(browser.captureViewportSize == native)
        #expect(pixels.width > native.width)
        #expect(pixels.width * pixels.height <= 1920 * 1080)
        #expect(abs(pixels.width / pixels.height - native.width / native.height) < 0.002)
    }

    @Test func frameAndRuntimeEventsDoNotPublishNavigationChanges() {
        let browser = AgentBrowser(profileID: "frame-publications")
        var publications = 0
        let subscription = browser.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<120 {
            browser.receiveNavigation("Page.screencastFrame", params: [:])
            browser.receiveNavigation("Runtime.consoleAPICalled", params: [:])
        }
        #expect(publications == 0)
        let failure: [String: Any] = ["frame": ["unreachableUrl": "https://example.invalid"]]
        browser.receiveNavigation("Page.frameNavigated", params: failure)
        #expect(publications == 1)
        #expect(browser.navigation.error != nil)
        browser.receiveNavigation("Page.frameNavigated", params: failure)
        #expect(publications == 1)
    }

    @Test func repeatedTargetInfoPublishesOnlyRealChanges() {
        let browser = AgentBrowser(profileID: "target-publications")
        var publications = 0
        let subscription = browser.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        func info(_ title: String) -> [String: Any] {
            ["targetInfo": ["type": "page", "targetId": "tab", "title": title, "url": "https://example.com/"]]
        }
        browser.handle("Target.targetCreated", info("Example"), nil)
        #expect(publications == 1)
        for _ in 0..<20 { browser.handle("Target.targetInfoChanged", info("Example"), nil) }
        #expect(publications == 1)
        browser.handle("Target.targetInfoChanged", info("Example, renamed"), nil)
        #expect(publications == 2)
        #expect(browser.pages.map(\.title) == ["Example, renamed"])
    }

    /// Chat deltas publish on `DockModel` many times a second; the Browser tab must not redraw for them.
    @Test func browserViewsDoNotObserveTheChatModel() {
        let model = DockModel(initialSessionID: "browser-observation")
        let workspace = SessionBrowserWorkspace(
            key: SessionBrowserKey(profileID: nil, sessionID: "browser-observation"))
        let views: [Any] = [
            SessionBrowserView(model: model, workspace: workspace),
            AgentBrowserPane(browser: workspace.agent, model: model),
        ]
        for view in views {
            let stored = Mirror(reflecting: view).children.first { $0.label == "model" || $0.label == "_model" }
            #expect(stored?.label == "model")
            #expect(stored?.value is DockModel)
        }
    }

    @Test func losslessFramesDecodeAwayFromTheMainActor() async throws {
        let base64 = try losslessFramePayload()
        let event: [String: Any] = [
            "method": "Page.screencastFrame", "sessionId": "visible",
            "params": ["data": base64, "sessionId": 12],
        ]
        let message = URLSessionWebSocketTask.Message.data(try JSONSerialization.data(withJSONObject: event))
        let discarded = CDPConnection.decode(message) { _ in false }?["params"] as? [String: Any]
        #expect(discarded?["data"] == nil)
        #expect(discarded?["decodedFrame"] == nil)
        #expect(discarded?["sessionId"] as? Int == 12)
        let accepted = CDPConnection.decode(message) { $0 == "visible" }?["params"] as? [String: Any]
        #expect((accepted?["decodedFrame"] as? CDPConnection.Frame)?.image.width == 32)
        #expect(
            AgentBrowser.screencastParameters(pixelSize: CGSize(width: 32, height: 16))["everyNthFrame"] as? Int == 1)

        let decoded = await Task.detached { CDPConnection.decodeFrame(base64) }.value
        let image = try #require(decoded)
        #expect(image.width == 32)
        #expect(image.height == 16)
        let pixel = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0))
        #expect(pixel.redComponent == 1)
        #expect(pixel.greenComponent == 0)
        #expect(CDPConnection.decodeFrame("invalid base64") == nil)
        #expect(CDPConnection.decodeFrame(Data("not an image".utf8).base64EncodedString()) == nil)
    }

    @Test func frameCreditPrecedesPayloadHandling() throws {
        let base64 = try losslessFramePayload()
        let enqueued = OSAllocatedUnfairLock(initialState: [String]())
        let writer = CDPConnection.Writer { text, _ in enqueued.withLock { $0.append(text) } }
        func commands() throws -> [WireCommand] {
            try enqueued.withLock { $0 }.map { try JSONDecoder().decode(WireCommand.self, from: Data($0.utf8)) }
        }

        writer.write("Page.enable", session: "visible")
        var expected = [WireCommand(id: 1, method: "Page.enable", sessionId: "visible", params: [:])]
        let wanted = try frameMessage(session: "visible", frame: 12, payload: base64)
        expected.append(
            WireCommand(id: 2, method: "Page.screencastFrameAck", sessionId: "visible", params: ["sessionId": 12]))
        let decoded = CDPConnection.decode(wanted, writer: writer) { session in
            #expect((try? commands()) == expected, "Expected matching frame credit enqueued before payload handling")
            return session == "visible"
        }
        let params = try #require(decoded?["params"] as? [String: Any])
        #expect((params["decodedFrame"] as? CDPConnection.Frame)?.image.width == 32)
        writer.write("Target.getTargets")
        expected.append(WireCommand(id: 3, method: "Target.getTargets", sessionId: nil, params: [:]))
        #expect(try commands() == expected)

        for (session, frame, payload) in [("stale", 13, base64), ("visible", 14, "invalid base64")] {
            let message = try frameMessage(session: session, frame: frame, payload: payload)
            let decoded = CDPConnection.decode(message, writer: writer) { $0 == "visible" }
            let params = try #require(decoded?["params"] as? [String: Any])
            #expect(params["decodedFrame"] == nil)
            expected.append(
                WireCommand(
                    id: expected.count + 1, method: "Page.screencastFrameAck", sessionId: session,
                    params: ["sessionId": frame]))
            #expect(try commands() == expected)
        }

        let invalidIDs: [(session: Any?, frame: Any?)] = [(nil, 12), (42, 12), ("visible", nil), ("visible", "12")]
        for (session, frame) in invalidIDs {
            let message = try frameMessage(session: session, frame: frame, payload: base64)
            _ = try #require(CDPConnection.decode(message, writer: writer) { _ in true })
            #expect(try commands() == expected)
        }

        let reply: [String: Any] = ["id": 1, "sessionId": "visible", "result": ["sessionId": 12]]
        let message = URLSessionWebSocketTask.Message.data(try JSONSerialization.data(withJSONObject: reply))
        let decodedReply = try #require(CDPConnection.decode(message, writer: writer) { _ in true })
        #expect(decodedReply as NSDictionary == reply as NSDictionary)
        #expect(try commands() == expected)
    }

    private struct WireCommand: Decodable, Equatable {
        let id: Int
        let method: String
        let sessionId: String?
        let params: [String: Int]
    }

    private func frameMessage(session: Any?, frame: Any?, payload: String) throws -> URLSessionWebSocketTask.Message {
        var params: [String: Any] = ["data": payload]
        params["sessionId"] = frame
        var event: [String: Any] = ["method": "Page.screencastFrame", "params": params]
        event["sessionId"] = session
        return .data(try JSONSerialization.data(withJSONObject: event))
    }

    private func losslessFramePayload() throws -> String {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 16, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        // Avoid AppKit color conversion: it can yield transparent pixels without an app color space.
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<16 {
            for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 255
            }
        }
        return try #require(bitmap.representation(using: .png, properties: [:])).base64EncodedString()
    }
}
