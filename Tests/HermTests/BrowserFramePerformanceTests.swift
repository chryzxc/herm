import AppKit
import Combine
import Testing

@testable import Herm

@MainActor
struct BrowserFramePerformanceTests {
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
        let base64 = try #require(bitmap.representation(using: .png, properties: [:])).base64EncodedString()
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
}
