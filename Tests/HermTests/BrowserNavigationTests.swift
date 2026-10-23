import Testing
import WebKit

@testable import Herm

struct BrowserNavigationTests {
    @Test func addressEntryRecognizesLocalServersAndPreservesDestinations() {
        for address in [
            "localhost:5173/preview", "127.0.0.1:8080", "[::1]:3000/path", "demo.localhost:4000",
        ] {
            #expect(BrowserAddress.url(for: address)?.absoluteString == "http://\(address)")
        }
        #expect(
            BrowserAddress.url(for: " example.com/path ")?.absoluteString
                == "https://example.com/path")
        let exact = "http://localhost:5173/preview_(draft)?next=%2Ffoo%3Fa%3D1#section-2"
        #expect(BrowserAddress.url(for: exact)?.absoluteString == exact)
        #expect(BrowserAddress.url(for: " \n ") == nil)
        #expect(BrowserAddress.url(for: "file:///private/example") == nil)
    }

    @Test func searchKeepsAmpersandsAndFragmentsInTheQuery() throws {
        let query = "CSS grid & width #responsive + layout?"
        let url = try #require(BrowserAddress.url(for: query))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "q", value: query)])
        #expect(components.fragment == nil)
    }

    @Test func loadingTracksOnlyTheMainFrameAndSettlesForSameDocumentNavigation() {
        var state = BrowserNavigationState()
        state.receiveCDP(
            "Page.frameStartedLoading", params: ["frameId": "child"], mainFrameID: "main")
        #expect(!state.isLoading)
        state.receiveCDP(
            "Page.frameStartedLoading", params: ["frameId": "main"], mainFrameID: "main")
        #expect(state.isLoading)
        state.receiveCDP(
            "Page.frameStoppedLoading", params: ["frameId": "child"], mainFrameID: "main")
        #expect(state.isLoading)
        state.receiveCDP(
            "Page.navigatedWithinDocument", params: ["frameId": "main"], mainFrameID: "main")
        #expect(!state.isLoading)
        state.start()
        state.receiveCDP(
            "Page.frameStoppedLoading", params: ["frameId": "main"], mainFrameID: "main")
        #expect(!state.isLoading)
    }

    @Test func failedPagesRetainRecoveryFeedbackUntilTheNextAttempt() {
        var state = BrowserNavigationState()
        state.start()
        state.receiveCDP(
            "Page.frameNavigated",
            params: [
                "frame": [
                    "id": "child", "parentId": "main", "unreachableUrl": "https://example.invalid",
                ]
            ], mainFrameID: "main")
        #expect(state.error == nil)
        state.receiveCDP(
            "Page.frameNavigated",
            params: ["frame": ["id": "main", "unreachableUrl": "https://example.invalid"]],
            mainFrameID: "main")
        #expect(!state.isLoading)
        #expect(state.error != nil)
        state.finish()
        #expect(state.error != nil)
        state.start()
        #expect(state.error == nil)
        #expect(state.isLoading)
    }

    @Test func historyAvailabilityFollowsTheActiveEntryAndRejectsMalformedResults() {
        var state = BrowserNavigationState()
        let entries: [[String: Any]] = [["id": 10], ["id": 20], ["id": 30]]
        for index in 0..<3 {
            state.updateHistory(["currentIndex": index, "entries": entries])
            #expect(state.canGoBack == (index > 0))
            #expect(state.canGoForward == (index < 2))
        }
        for result: [String: Any] in [
            [:], ["currentIndex": -1, "entries": entries], ["currentIndex": 3, "entries": entries],
        ] {
            state.updateHistory(result)
            #expect(!state.canGoBack && !state.canGoForward)
        }
    }

    @MainActor @Test func webKitPublishesLoadingHistoryAndNavigationFailures() async throws {
        let browser = BrowserController(
            key: .init(profileID: nil, sessionID: "navigation-test"), dataStore: .nonPersistent())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.html")
        let second = directory.appendingPathComponent("second.html")
        try "<p id='content'>Loaded</p>".write(to: first, atomically: true, encoding: .utf8)
        try "<p id='content'>Second</p>".write(to: second, atomically: true, encoding: .utf8)
        let firstNavigation = browser.web.loadFileURL(first, allowingReadAccessTo: directory)
        for _ in 0..<200 {
            if (try? await browser.web.evaluateJavaScript(
                "document.getElementById('content')?.textContent")) as? String == "Loaded",
                !browser.navigation.isLoading
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!browser.navigation.isLoading)
        #expect(
            try await browser.web.evaluateJavaScript(
                "document.getElementById('content').textContent")
                as? String == "Loaded")
        let navigation = browser.web.loadFileURL(second, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if browser.navigation.canGoBack, browser.currentURL == second.absoluteString,
                !browser.navigation.isLoading
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(browser.navigation.canGoBack)
        _ = try await browser.web.evaluateJavaScript("history.pushState({}, '', '#details')")
        for _ in 0..<100 {
            if browser.currentURL?.hasSuffix("#details") == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(browser.currentURL?.hasSuffix("#details") == true)
        browser.webView(
            browser.web, didFailProvisionalNavigation: firstNavigation,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        #expect(browser.navigation.error == nil)
        browser.webView(
            browser.web, didFailProvisionalNavigation: navigation,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        #expect(browser.navigation.error != nil)
        browser.clearNavigationError()
        browser.webView(
            browser.web, didFailProvisionalNavigation: navigation,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(browser.navigation.error == nil)
        browser.open(URL(string: "about:blank")!)
        #expect(browser.navigation.isLoading)
        browser.stopLoading()
        #expect(!browser.navigation.isLoading)
    }
}
