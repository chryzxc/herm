import AppKit
import Foundation
import Testing
import WebKit

@testable import Herm

@MainActor
struct SessionBrowserTests {
    @Test func startupNeverAttachesToUnrelatedFixedPort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("DevToolsActivePort")
        let version = Data(#"{"webSocketDebuggerUrl":"ws://127.0.0.1:9333/devtools/browser/test-id"}"#.utf8)
        let endpoint = await AgentBrowser.startupEndpoint(file) { _ in version }
        #expect(endpoint == nil)
        try "9333\n/devtools/browser/owned-id\n".write(to: file, atomically: true, encoding: .utf8)
        let rejected = await AgentBrowser.startupEndpoint(file) { _ in version }
        #expect(rejected == nil)
        let owned = Data(#"{"webSocketDebuggerUrl":"ws://127.0.0.1:9333/devtools/browser/owned-id"}"#.utf8)
        let reused = await AgentBrowser.startupEndpoint(file) { _ in owned }
        #expect(reused?.ws.absoluteString == "ws://127.0.0.1:9333/devtools/browser/owned-id")
    }
    @Test func sessionSwitchesRetainBrowsersAndShareSignIns() {
        let store = SessionBrowserStore()
        let a = SessionBrowserKey(profileID: nil, sessionID: "a")
        let b = SessionBrowserKey(profileID: nil, sessionID: "b")
        let first = store.workspace(for: a)
        let extra = first.addTab()
        let second = store.workspace(for: b)
        let returned = store.workspace(for: a)

        #expect(returned === first)
        #expect(returned.primary.web === first.primary.web)
        #expect(returned.agent === first.agent)
        #expect(returned.extras.first === extra)
        // Hermes connects one browser per profile; its sessions share that Chrome.
        #expect(first.agent === second.agent)
        #expect(
            first.primary.web.configuration.websiteDataStore
                === second.primary.web.configuration.websiteDataStore)
        #expect(first.primary.web.configuration.websiteDataStore.isPersistent)
        #expect(
            first.primary.web.configuration.websiteDataStore === extra.web.configuration.websiteDataStore)
        first.closeTab(extra.id)
        #expect(first.extras.isEmpty)
        #expect(store.workspace(for: b) === second)
    }

    @Test func leavingReleasesOnlyUnusedBrowsers() {
        let store = SessionBrowserStore()
        let unused = SessionBrowserKey(profileID: nil, sessionID: "unused")
        let tabbed = SessionBrowserKey(profileID: nil, sessionID: "tabbed")
        let presented = SessionBrowserKey(profileID: nil, sessionID: "presented")
        let released = store.workspace(for: unused)
        let withTab = store.workspace(for: tabbed)
        _ = withTab.addTab()
        let shown = store.workspace(for: presented)
        store.presentation = presented

        for key in [unused, tabbed, presented] { store.releaseIfUnused(key) }

        #expect(!released.isInUse)
        #expect(store.workspace(for: unused) !== released)
        #expect(store.workspace(for: tabbed) === withTab)
        #expect(store.workspace(for: presented) === shown)
    }

    @Test func profileBrowserOutlivesItsSessionsUntilTheLastGoes() {
        let store = SessionBrowserStore()
        let a = SessionBrowserKey(profileID: nil, sessionID: "a")
        let agent = store.workspace(for: a).agent
        _ = store.workspace(for: SessionBrowserKey(profileID: nil, sessionID: "b"))
        store.delete(a)
        #expect(store.workspace(for: SessionBrowserKey(profileID: nil, sessionID: "b")).agent === agent)
        store.delete(SessionBrowserKey(profileID: nil, sessionID: "b"))
        #expect(store.workspace(for: a).agent !== agent)
    }

    @Test func reapsOnlyOrphanedAgentBrowserChromes() {
        let root = "/Users/me/Library/Application Support/Herm/AgentBrowser"
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new"
        let ps = """
              3099     1 \(chrome) --user-data-dir=\(root)/abc --no-first-run
              3148  3099 Google Chrome Helper --user-data-dir=\(root)/abc
             10580 75208 \(chrome) --user-data-dir=\(root)/def
               500     1 \(chrome) --user-data-dir=/tmp/other
               600     1 /usr/sbin/cfprefsd agent
            """
        #expect(AgentBrowser.orphanPIDs(psOutput: ps, profileRoot: root) == [3099])
    }

    @Test func botProfilesHaveSeparateBrowserIdentities() {
        let a = SessionBrowserKey(profileID: "one", sessionID: "chat")
        let b = SessionBrowserKey(profileID: "two", sessionID: "chat")
        let store = SessionBrowserStore()
        #expect(store.workspace(for: a) !== store.workspace(for: b))
        #expect(store.workspace(for: a).agent !== store.workspace(for: b).agent)
        #expect(
            SessionBrowserKey.browserDirectory(profileID: "one") != SessionBrowserKey.browserDirectory(profileID: "two")
        )
        #expect(SessionBrowserKey.browserDirectory(profileID: "one") != a.profileDirectory)
        #expect(a.profileDirectory != b.profileDirectory)
        #expect(
            a.profileDirectory == SessionBrowserKey(profileID: "one", sessionID: "chat").profileDirectory)
        #expect(!a.profileDirectory.contains("chat"))
    }

    @Test func runtimeAliasesKeepTheStoredSessionsBrowser() {
        let model = DockModel(initialSessionID: "stored-session")
        let key = model.browserSessionKey
        model.sessionID = "runtime-alias"
        #expect(model.browserSessionKey == key)
    }

    @Test(arguments: ["browser-bot-a", "browser-bot-b"])
    func browserHandoffAndDisconnectStayInTheSelectedProfile(profile: String) async throws {
        let client = BrowserHandoffRPCClient()
        let suite = "BrowserHandoffTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults, initialSessionID: "browser-chat", rpcClient: client)
        model.profileScopeID = profile
        defer { model.delegationMonitoringTask?.cancel() }

        try await model.setHermesBrowser(cdpURL: client.endpoint)
        try await model.setHermesBrowser(cdpURL: nil)

        #expect(!client.requests.isEmpty)
        for request in client.requests {
            #expect(request["profile"] as? String == profile)
        }
    }

    @Test func browserHandoffLifecyclePreservesRunningBrowserAndIgnoresStaleCompletion() async throws {
        let client = BrowserHandoffRPCClient()
        let suite = "BrowserHandoffTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults, initialSessionID: "browser-chat", rpcClient: client)
        model.profileScopeID = "lifecycle-test"
        defer { model.delegationMonitoringTask?.cancel() }
        let browser = AgentBrowser(profileID: "lifecycle-test")
        browser.model = model
        client.statusFails = true
        let failed = browser.browserDidStart(endpoint: client.endpoint)
        await failed?.value
        #expect(browser.state == .running)
        #expect(browser.handoffFailed)
        client.statusFails = false
        let retry = browser.reconnectHermes()
        await retry?.value
        #expect(browser.state == .running)
        #expect(!browser.handoffFailed)
        client.holdStatus = true
        client.statusFails = true
        let switched = browser.reconnectHermes()
        await client.waitForStatus()
        model.profileScopeID = "other-profile"
        client.releaseStatus()
        await switched?.value
        #expect(!browser.handoffFailed)
        model.profileScopeID = "lifecycle-test"
        client.holdStatus = true
        client.statusFails = true
        let stale = browser.reconnectHermes()
        await client.waitForStatus()
        browser.stop()
        let restarted = browser.browserDidStart(endpoint: client.endpoint)
        client.statusFails = false
        client.releaseStatus(keepHolding: true)
        await stale?.value
        await client.waitForStatus()
        #expect(browser.state == .running)
        #expect(!browser.handoffFailed)
        client.releaseStatus()
        await restarted?.value
        #expect(!browser.handoffFailed)
        browser.stop()
    }

    @Test func browserHandoffDoesNotReconnectAnAlreadySharedBrowser() async throws {
        let client = BrowserHandoffRPCClient()
        client.connected = true
        let suite = "BrowserHandoffTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DockModel(defaults: defaults, initialSessionID: "browser-chat", rpcClient: client)
        model.profileScopeID = "browser-bot"
        defer { model.delegationMonitoringTask?.cancel() }

        // Gateway reconnect and repeated presentation must not reissue a destructive connect.
        try await model.setHermesBrowser(cdpURL: client.endpoint)
        try await model.setHermesBrowser(cdpURL: client.endpoint)

        let actions = client.requests.compactMap { $0["action"] as? String }
        #expect(actions == ["status", "status"])
        #expect(!actions.contains("connect"))
        #expect(!actions.contains("disconnect"))
    }

    @Test(arguments: ["disconnected", "missing-connected", "missing-url", "other", "matching"])
    func browserHandoffStatusControlsConnect(caseName: String) async throws {
        let client = BrowserHandoffRPCClient()
        switch caseName {
        case "disconnected": client.status = ["connected": false, "url": client.endpoint]
        case "missing-connected": client.status = ["url": client.endpoint]
        case "missing-url": client.status = ["connected": true]
        case "other": client.status = ["connected": true, "url": "http://127.0.0.1:19334"]
        default: client.status = ["connected": true, "url": client.endpoint]
        }
        let model = DockModel(initialSessionID: "browser-chat", rpcClient: client)
        defer { model.delegationMonitoringTask?.cancel() }
        try await model.setHermesBrowser(cdpURL: client.endpoint)
        let actions = client.requests.compactMap { $0["action"] as? String }
        #expect(actions == (caseName == "matching" ? ["status"] : ["status", "connect"]))
        if caseName != "matching" { #expect(client.requests.last?["url"] as? String == client.endpoint) }
    }

    @Test func browserHandoffStatusFailureDoesNotConnect() async throws {
        let client = BrowserHandoffRPCClient()
        client.statusFails = true
        let model = DockModel(initialSessionID: "browser-chat", rpcClient: client)
        defer { model.delegationMonitoringTask?.cancel() }
        await #expect(throws: HermesGateway.GatewayError.self) {
            try await model.setHermesBrowser(cdpURL: client.endpoint)
        }
        #expect(client.requests.compactMap { $0["action"] as? String } == ["status"])
    }

    @Test func browserHandoffCapturesProfileDuringStatus() async throws {
        let client = BrowserHandoffRPCClient()
        let model = DockModel(initialSessionID: "browser-chat", rpcClient: client)
        model.profileScopeID = "original-profile"
        model.sessionProfileID = "stale-profile"
        client.holdStatus = true
        defer { model.delegationMonitoringTask?.cancel() }
        let handoff = Task { try await model.setHermesBrowser(cdpURL: client.endpoint) }
        await client.waitForStatus()
        model.profileScopeID = "new-profile"
        client.releaseStatus()
        try await handoff.value
        #expect(client.requests.compactMap { $0["profile"] as? String } == ["original-profile", "original-profile"])
    }

    @Test(arguments: [nil, ""] as [String?])
    func browserHandoffDefaultScopeAndDisconnect(profile: String?) async throws {
        let client = BrowserHandoffRPCClient()
        let model = DockModel(initialSessionID: "browser-chat", rpcClient: client)
        model.profileScopeID = profile
        defer { model.delegationMonitoringTask?.cancel() }
        try await model.setHermesBrowser(cdpURL: client.endpoint)
        try await model.setHermesBrowser(cdpURL: nil)
        #expect(client.requests.compactMap { $0["action"] as? String } == ["status", "connect", "disconnect"])
        #expect(client.requests.allSatisfy { $0["profile"] == nil })
    }

    @Test(arguments: [true, false])
    func browserHandoffRejectedConnectReportsError(withMessage: Bool) async throws {
        let client = BrowserHandoffRPCClient()
        client.connectResult = withMessage ? ["connected": false, "messages": ["rejected"]] : ["connected": false]
        let model = DockModel(initialSessionID: "browser-chat", rpcClient: client)
        defer { model.delegationMonitoringTask?.cancel() }
        do {
            try await model.setHermesBrowser(cdpURL: client.endpoint)
            Issue.record("Expected rejected connection")
        } catch {
            let expected = withMessage ? "rejected" : "Hermes could not connect to the browser."
            #expect(error.localizedDescription == expected)
        }
    }

    @Test func liveDocumentAndFormSurviveSessionSwitchAndViewRecreation() async throws {
        let store = SessionBrowserStore()
        let a = SessionBrowserKey(profileID: nil, sessionID: "a")
        let first = store.workspace(for: a)
        let tab = first.addTab()
        let web = tab.web
        web.loadHTMLString(
            "<input id='draft'><script>window.pageToken = 'original';</script>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.pageToken")) as? String == "original" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.evaluateJavaScript(
            "document.getElementById('draft').value = 'unfinished form'; window.pageToken = 'retained'")
        let model = DockModel(initialSessionID: "a")
        var view: SessionBrowserView? = SessionBrowserView(model: model, workspace: first, browser: tab)
        view = nil
        _ = store.workspace(for: SessionBrowserKey(profileID: nil, sessionID: "b"))
        let returned = store.workspace(for: a)
        view = SessionBrowserView(model: model, workspace: returned, browser: returned.extras[0])
        #expect(view != nil)
        #expect(try await web.evaluateJavaScript("window.pageToken") as? String == "retained")
        #expect(
            try await web.evaluateJavaScript("document.getElementById('draft').value") as? String
                == "unfinished form")
    }

    @Test func chatLinkWhileStartingKeepsItsExactDestination() throws {
        let store = SessionBrowserStore()
        let workspace = store.workspace(for: SessionBrowserKey(profileID: nil, sessionID: "chat"))
        let destination = try #require(
            URL(string: "http://localhost:5173/preview_(draft)?next=%2Ffoo%3Fa%3D1&token=a%2Bb#section-2")
        )
        workspace.primary.address = "https://previous.example/"
        // No model: the asynchronous startup exits before launching Chromium.
        workspace.agent.start()
        workspace.open(destination)
        _ = store.workspace(for: SessionBrowserKey(profileID: nil, sessionID: "other"))
        _ = SessionBrowserView(model: DockModel(initialSessionID: "chat"), workspace: workspace)
        #expect(workspace.agent.pendingURL == destination)
        #expect(workspace.primary.address == destination.absoluteString)
        #expect(workspace.primary.web.url == nil)
    }

    @Test func markdownClicksRouteTheLinkDestinationWithoutReparsingIt() throws {
        let destination = try #require(
            URL(string: "https://example.com/a_(b)?next=%2Fx%3Fy%3D1&token=a%2Bb#part-2"))
        let rendered = NativeMarkdownMessageView.Coordinator.attributedString(
            for: "[Open preview](\(destination.absoluteString))")
        let range = (rendered.string as NSString).range(of: "Open preview")
        let link = try #require(rendered.attribute(.link, at: range.location, effectiveRange: nil))
        let expected = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        #expect(expected == destination)
        var received: URL?
        let observer = NotificationCenter.default.addObserver(
            forName: .hermOpenInBrowser, object: nil, queue: .main
        ) { notification in
            let url = notification.object as? URL
            MainActor.assumeIsolated {
                received = url
                InAppBrowser.handled = true
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NativeMarkdownTextView().clicked(onLink: link, at: range.location)
        #expect(received == destination)
        received = nil
        NativeMarkdownTextSectionView().clicked(onLink: link, at: range.location)
        #expect(received == destination)
    }
}

@MainActor
private final class BrowserHandoffRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    let endpoint = "http://127.0.0.1:19333"
    var connected = false
    var status: [String: Any]?
    var statusFails = false
    var connectResult: [String: Any]?
    var holdStatus = false
    private var statusStarted: CheckedContinuation<Void, Never>?
    private var statusRelease: CheckedContinuation<Void, Never>?
    private(set) var requests: [[String: Any]] = []

    func connect() async throws {}
    func close() {}

    func waitForStatus() async {
        if statusRelease != nil { return }
        await withCheckedContinuation { statusStarted = $0 }
    }

    func releaseStatus(keepHolding: Bool = false) {
        holdStatus = keepHolding
        statusRelease?.resume()
        statusRelease = nil
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "browser.manage" else { throw HermesGateway.GatewayError.malformedResponse }
        requests.append(params)
        switch params["action"] as? String {
        case "connect":
            if let connectResult { return connectResult }
            connected = true
        case "disconnect": connected = false
        case "status":
            let fails = statusFails
            if holdStatus {
                await withCheckedContinuation { continuation in
                    statusRelease = continuation
                    statusStarted?.resume()
                    statusStarted = nil
                }
            }
            if fails { throw HermesGateway.GatewayError.malformedResponse }
            if let status { return status }
        default: throw HermesGateway.GatewayError.malformedResponse
        }
        return ["connected": connected, "url": endpoint]
    }
}
