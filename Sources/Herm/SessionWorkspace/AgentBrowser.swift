import AppKit
import Combine
import ImageIO
import SwiftUI

/// A headless Chromium shared with Hermes: Herm launches it, points Hermes' browser
/// tools at it (`browser.manage connect`, same as `/browser connect`) and mirrors the
/// active tab into the Browser panel by CDP screencast, so you can watch Hermes work
/// and take over with the mouse and keyboard.
@MainActor
final class AgentBrowser: ObservableObject {
    let key: SessionBrowserKey
    private static var connectionTask: Task<Void, Never>?
    private static var preferredPortOwner: SessionBrowserKey?
    private static let world = "herm"

    enum State: Equatable {
        case off, starting, running
        case failed(String)
    }

    struct Page: Identifiable, Equatable {
        let id: String
        var title: String
        var url: String

        init?(info: [String: Any]) {
            guard info["type"] as? String == "page", let id = info["targetId"] as? String else { return nil }
            self.id = id
            title = info["title"] as? String ?? ""
            url = info["url"] as? String ?? ""
        }
    }

    @Published private(set) var state = State.off
    @Published private(set) var pages: [Page] = []
    @Published private(set) var activeTargetID: String?
    @Published private(set) var consoleErrors: [String] = []
    @Published private(set) var navigation = BrowserNavigationState()
    /// A page's alert/confirm/prompt/beforeunload; the page is frozen until it's answered.
    @Published private(set) var dialog: Dialog?
    /// You took the page over from Hermes; the pane offers to hand it back.
    @Published var userHasControl = false
    /// Hermes is mid-step: your input would race its clicks, so the canvas drops it.
    var inputLocked = false

    struct Dialog: Equatable {
        let type: String, message: String, defaultPrompt: String
    }
    @Published var annotating = false { didSet { if annotating != oldValue { applyAnnotating() } } }
    /// 0 fits the panel; otherwise the emulated CSS width.
    @Published var presetWidth = 0 { didSet { if presetWidth != oldValue { scheduleViewport() } } }
    weak var model: DockModel?
    /// Frames bypass SwiftUI: the canvas draws them directly at screencast rate.
    var onFrame: ((NSImage, CGSize) -> Void)?
    /// A remounted canvas paints this at once; a static page sends no new screencast frame.
    private(set) var lastFrame: (image: NSImage, css: CGSize)?
    /// Canvases on screen. The screencast only runs while someone is watching, so a
    /// hidden Browser tab costs nothing; Hermes' own CDP use is unaffected.
    var viewers = 0 { didSet { if (viewers > 0) != (oldValue > 0) { scheduleViewport() } } }

    var activePage: Page? { pages.first { $0.id == activeTargetID } }
    var isOn: Bool { state != .off }
    /// Starting or running: the Browser tab shows the agent view (a failure falls back to WebKit).
    var isActive: Bool { state == .starting || state == .running }
    /// Navigation requested before the browser finished starting.
    private(set) var pendingURL: URL?
    private var cdpURL: String?

    /// A restarted Hermes gateway forgets the connection; point it back at this browser.
    func reconnectHermes() {
        guard state == .running, let cdpURL, let model else { return }
        let previous = Self.connectionTask
        Self.connectionTask = Task { [weak self] in
            await previous?.value
            guard let self, model.browserSessionKey == key, state == .running, self.cdpURL == cdpURL else { return }
            do { try await model.setHermesBrowser(cdpURL: cdpURL) } catch {
                if model.browserSessionKey == key { fail(error.localizedDescription) }
            }
        }
    }

    private var startupTask: Task<Void, Never>?
    private var process: Process?
    private var cdp: CDPConnection?
    private var sessionID: String?
    private var mainFrameID: String?
    private var annotateContextID: Int?
    private(set) var panelSize = CGSize(width: 1280, height: 800)
    private var backingScale: CGFloat = 2
    private var viewportTask: Task<Void, Never>?
    private var themeCancellable: AnyCancellable?
    private var navigationRequestID = UUID()
    private var historyRequestID = UUID()

    init(key: SessionBrowserKey) {
        self.key = key
        themeCancellable = DockThemeStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.annotating else { return }
                self.applyAnnotating()
            }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.terminate() }
        }
    }

    // MARK: Lifecycle

    func start() {
        switch state {
        case .starting, .running: return
        default: break
        }
        state = .starting
        startupTask = Task {
            do {
                guard model != nil else { throw Self.error("No Hermes session is available.") }
                let endpoint = try await launch()
                try Task.checkCancellation()
                let cdp = CDPConnection(url: endpoint.ws)
                cdp.onEvent = { [weak self] method, params, session in self?.handle(method, params, session) }
                cdp.onClose = { [weak self] in self?.relaunch() }
                self.cdp = cdp
                _ = try await cdp.send("Target.setDiscoverTargets", ["discover": true])
                let infos = try await cdp.send("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
                try Task.checkCancellation()
                for page in infos.compactMap(Page.init(info:)) where !pages.contains(where: { $0.id == page.id }) {
                    pages.append(page)
                }
                if let first = pages.first {
                    try await attach(first.id)
                } else if let id = try await cdp.send("Target.createTarget", ["url": "about:blank"])["targetId"]
                    as? String
                {
                    try await attach(id)
                }
                try Task.checkCancellation()
                cdpURL = "http://127.0.0.1:\(endpoint.port)"
                state = .running
                reconnectHermes()
                if let url = pendingURL {
                    pendingURL = nil
                    navigate(url)
                }
            } catch {
                if !Task.isCancelled { fail(error.localizedDescription) }
            }
        }
    }

    func stop() {
        let model = model
        let previous = Self.connectionTask
        Self.connectionTask = Task {
            await previous?.value
            guard model?.browserSessionKey == key else { return }
            try? await model?.setHermesBrowser(cdpURL: nil)
        }
        teardown()
        state = .off
    }

    private var relaunches: [Date] = []

    /// Chrome went away underneath us (Hermes' browser cleanup closes the browser it's
    /// connected to, or it crashed): bring it back on the same page. Gives up after
    /// three quick deaths so a browser that can't stay up doesn't loop.
    private func relaunch() {
        relaunches = relaunches.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        guard relaunches.count <= 3 else { return fail("The browser keeps closing.") }
        let url = activePage.flatMap { URL(string: $0.url) }.flatMap { $0.scheme == "about" ? nil : $0 }
        teardown()
        state = .off
        start()
        if let url { navigate(url) }
    }

    private func fail(_ message: String) {
        guard state != .off else { return }
        teardown()
        state = .failed(HermesDiagnosticsService.safeSummary(message))
    }

    private func teardown() {
        startupTask?.cancel()
        startupTask = nil
        if let cdp {
            cdp.onEvent = nil
            cdp.onClose = nil
            // Also closes a browser reused from an earlier Herm run, which `process` doesn't own.
            cdp.fire("Browser.close")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cdp.close() }
        }
        cdp = nil
        lastFrame = nil
        process?.terminate()
        process = nil
        sessionID = nil
        mainFrameID = nil
        annotateContextID = nil
        navigationRequestID = UUID()
        historyRequestID = UUID()
        navigation = BrowserNavigationState()
        activeTargetID = nil
        pages = []
        consoleErrors = []
        dialog = nil
        annotating = false
    }

    private struct Endpoint {
        let port: Int
        let ws: URL
    }
    static let preferredPort = 9333

    nonisolated static var profileRoot: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Herm/AgentBrowser", isDirectory: true)
    }

    /// A Herm that dies without quitting (crash, force quit, debug relaunch) never sends
    /// willTerminate, so its Chromes get reparented to launchd and keep running forever.
    /// Run at launch, before any session starts a browser.
    nonisolated static func reapOrphans() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-ax", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let orphans = orphanPIDs(psOutput: output, profileRoot: profileRoot.path)
        for pid in orphans { kill(pid, SIGTERM) }
        if !orphans.isEmpty {
            let count = orphans.count
            Task { @MainActor in DebugLog.write("agent browser: reaped \(count) orphaned Chrome processes") }
        }
    }

    /// Top-level Chromes (parent is launchd) on a Herm agent-browser profile. Helpers die with them.
    nonisolated static func orphanPIDs(psOutput: String, profileRoot: String) -> [pid_t] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, fields[1] == "1",
                fields[2].contains("--user-data-dir=\(profileRoot)/")
            else { return nil }
            return pid_t(fields[0])
        }
    }

    private func launch() async throws -> Endpoint {
        let profile = Self.profileRoot.appendingPathComponent(key.profileDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let portFile = profile.appendingPathComponent("DevToolsActivePort")
        // A browser left running by an earlier Herm keeps the profile locked; reuse it.
        if let live = await Self.endpoint(portFile) { return live }
        try? FileManager.default.removeItem(at: portFile)
        guard let executable = Self.chromiumExecutable() else {
            throw Self.error("No Chromium-family browser found. Install Google Chrome, Brave, Edge or Chromium.")
        }
        // A fixed port lets other CDP clients (e.g. chrome-devtools-mcp --browserUrl) share
        // this browser; fall back to any free port when something else holds it.
        // Reserve before probing: two sessions can launch before either Chrome is listening.
        if Self.preferredPortOwner == nil { Self.preferredPortOwner = key }
        let busy: Bool
        if Self.preferredPortOwner == key {
            busy =
                (try? await URLSession.shared.data(
                    from: URL(string: "http://127.0.0.1:\(Self.preferredPort)/json/version")!)) != nil
        } else {
            busy = true
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--headless=new", "--remote-debugging-port=\(busy ? 0 : Self.preferredPort)",
            "--user-data-dir=\(profile.path)",
            "--no-first-run", "--no-default-browser-check", "--window-size=1280,800",
            // Emulated DPR alone leaves headless screencast frames at 1x; the compositor must render at 2x too.
            "--force-device-scale-factor=2",
            // Headless Chrome announces itself (HeadlessChrome UA, navigator.webdriver), and sites
            // like Google answer with a degraded no-JS page. Look like the regular browser.
            "--disable-blink-features=AutomationControlled", "--user-agent=\(Self.userAgent(for: executable))",
            "about:blank",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if let live = await Self.endpoint(portFile) { return live }
            if !process.isRunning { break }
        }
        throw Self.error("The browser didn't start remote debugging.")
    }

    /// Chrome writes "<port>\n/devtools/browser/<id>" once it listens; a stale file fails the probe.
    private static func endpoint(_ file: URL) async -> Endpoint? {
        guard let lines = try? String(contentsOf: file, encoding: .utf8).split(separator: "\n"), lines.count >= 2,
            let port = Int(lines[0]), let ws = URL(string: "ws://127.0.0.1:\(port)\(lines[1])"),
            let probe = URL(string: "http://127.0.0.1:\(port)/json/version"),
            let (_, response) = try? await URLSession.shared.data(from: probe),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return Endpoint(port: port, ws: ws)
    }

    /// Same browsers Hermes' `/browser connect` looks for, then Playwright's Chrome for Testing.
    private static func chromiumExecutable() -> URL? {
        let fm = FileManager.default
        let apps = ["Google Chrome", "Chromium", "Brave Browser", "Microsoft Edge"]
            .map { "/Applications/\($0).app/Contents/MacOS/\($0)" }
        let playwright = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ms-playwright")
        let builds = ((try? fm.contentsOfDirectory(atPath: playwright.path)) ?? [])
            .filter { $0.hasPrefix("chromium-") }.sorted(by: >)
            .flatMap { build in
                ["chrome-mac-arm64", "chrome-mac"].flatMap { dir in
                    [
                        "\(playwright.path)/\(build)/\(dir)/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
                        "\(playwright.path)/\(build)/\(dir)/Chromium.app/Contents/MacOS/Chromium",
                    ]
                }
            }
        return (apps + builds).first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// The UA the same browser sends when not headless (Chrome's reduced form: major version only).
    private static func userAgent(for executable: URL) -> String {
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let major = version.split(separator: ".").first.flatMap { Int($0) } ?? 140
        return
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Herm.AgentBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Page session

    /// Mirrors `targetID`: one flat CDP session at a time, with the annotate world and screencast.
    private func attach(_ targetID: String) async throws {
        guard let cdp else { return }
        if let old = sessionID {
            sessionID = nil
            cdp.fire("Target.detachFromTarget", ["sessionId": old])
        }
        guard
            let sid = try await cdp.send("Target.attachToTarget", ["targetId": targetID, "flatten": true])["sessionId"]
                as? String
        else {
            throw Self.error("Could not attach to the browser tab.")
        }
        sessionID = sid
        activeTargetID = targetID
        navigationRequestID = UUID()
        navigation = BrowserNavigationState()
        consoleErrors = []
        dialog = nil
        annotateContextID = nil
        _ = try await cdp.send("Page.enable", session: sid)
        _ = try await cdp.send(
            "Runtime.addBinding", ["name": "hermAnnotate", "executionContextName": Self.world], session: sid)
        _ = try await cdp.send(
            "Page.addScriptToEvaluateOnNewDocument", ["source": BrowserAnnotation.script, "worldName": Self.world],
            session: sid)
        let tree = try await cdp.send("Page.getFrameTree", session: sid)
        mainFrameID = ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String
        refreshHistory()
        if let mainFrameID,
            let context = try await cdp.send(
                "Page.createIsolatedWorld", ["frameId": mainFrameID, "worldName": Self.world], session: sid)[
                    "executionContextId"] as? Int
        {
            annotateContextID = context
            _ = try await cdp.send(
                "Runtime.evaluate", ["expression": BrowserAnnotation.script, "contextId": context], session: sid)
        }
        _ = try await cdp.send("Runtime.enable", session: sid)
        if let document = try? await cdp.send(
            "Runtime.evaluate", ["expression": "document.readyState", "returnByValue": true], session: sid),
            sessionID == sid, let readyState = (document["result"] as? [String: Any])?["value"] as? String
        {
            navigation.isLoading = readyState != "complete"
        }
        applyAnnotating()
        try await applyViewport()
        if state == .running, let url = pendingURL { navigate(url) }
    }

    func resize(to size: CGSize, scale: CGFloat) {
        guard size.width > 10, size.height > 10, size != panelSize || scale != backingScale else { return }
        panelSize = size
        backingScale = scale
        scheduleViewport()
    }

    /// Debounced: live panel resizes would otherwise restart the screencast every frame.
    private func scheduleViewport() {
        viewportTask?.cancel()
        viewportTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            try? await applyViewport()
        }
    }

    var captureViewportSize: CGSize {
        let width = presetWidth > 0 ? CGFloat(presetWidth) : panelSize.width.rounded(.down)
        // Wider than the panel scales down; narrower keeps the panel's height at 1:1.
        let height = (panelSize.height * max(1, width / panelSize.width)).rounded(.down)
        return CGSize(width: width, height: height)
    }

    private func applyViewport() async throws {
        guard let cdp, let sid = sessionID else { return }
        let size = captureViewportSize
        _ = try await cdp.send(
            "Emulation.setDeviceMetricsOverride",
            [
                "width": Int(size.width), "height": Int(size.height), "deviceScaleFactor": backingScale,
                "screenWidth": Int(size.width), "screenHeight": Int(size.height),
                "mobile": presetWidth > 0 && presetWidth < 800,
            ], session: sid)
        guard !Task.isCancelled, sessionID == sid else { return }
        cdp.fire("Page.stopScreencast", session: sid)
        guard viewers > 0 else { return }
        cdp.fire(
            "Page.startScreencast",
            [
                "format": "png", "everyNthFrame": 2,  // Lossless text at ~30fps while the pane is visible.
                "maxWidth": Int(size.width * backingScale), "maxHeight": Int(size.height * backingScale),
            ], session: sid)
    }

    private func handle(_ method: String, _ params: [String: Any], _ session: String?) {
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard let page = (params["targetInfo"] as? [String: Any]).flatMap(Page.init(info:)) else { return }
            if let index = pages.firstIndex(where: { $0.id == page.id }) {
                pages[index] = page
            } else {
                pages.append(page)
                // Follow the tab Hermes just opened.
                if state == .running { Task { try? await attach(page.id) } }
            }
        case "Target.targetDestroyed":
            guard let id = params["targetId"] as? String else { return }
            pages.removeAll { $0.id == id }
            guard id == activeTargetID else { return }
            sessionID = nil
            activeTargetID = nil
            if let next = pages.last {
                Task { try? await attach(next.id) }
            } else {
                cdp?.fire("Target.createTarget", ["url": "about:blank"])
            }
        default:
            break
        }
        guard let session, session == sessionID else { return }
        receiveNavigation(method, params: params)
        switch method {
        case "Page.screencastFrame":
            if let ack = params["sessionId"] {
                cdp?.fire("Page.screencastFrameAck", ["sessionId": ack], session: session)
            }
            guard let decoded = params["decodedFrame"] as? CDPConnection.Frame else { return }
            let image = NSImage(cgImage: decoded.image, size: .zero)
            let meta = params["metadata"] as? [String: Any]
            let css = CGSize(
                width: meta?["deviceWidth"] as? Double ?? image.size.width,
                height: meta?["deviceHeight"] as? Double ?? image.size.height)
            lastFrame = (image, css)
            onFrame?(image, css)
        case "Page.frameNavigated":
            guard let frame = params["frame"] as? [String: Any], frame["parentId"] == nil else { return }
            mainFrameID = frame["id"] as? String
            consoleErrors = []
            if let index = pages.firstIndex(where: { $0.id == activeTargetID }), let url = frame["url"] as? String {
                pages[index].url = frame["unreachableUrl"] as? String ?? (url + (frame["urlFragment"] as? String ?? ""))
            }
            refreshHistory()
        case "Page.navigatedWithinDocument", "Page.frameStoppedLoading":
            guard params["frameId"] as? String == mainFrameID else { return }
            if let url = params["url"] as? String, let index = pages.firstIndex(where: { $0.id == activeTargetID }) {
                pages[index].url = url
            }
            refreshHistory()
        case "Page.javascriptDialogOpening":
            dialog = Dialog(
                type: params["type"] as? String ?? "alert", message: params["message"] as? String ?? "",
                defaultPrompt: params["defaultPrompt"] as? String ?? "")
        case "Page.javascriptDialogClosed":
            // Also fires when Hermes answers it with its own dialog tool.
            dialog = nil
        case "Runtime.executionContextCreated":
            guard let context = params["context"] as? [String: Any], context["name"] as? String == Self.world,
                (context["auxData"] as? [String: Any])?["frameId"] as? String == mainFrameID,
                let id = context["id"] as? Int
            else { return }
            annotateContextID = id
            applyAnnotating()
        case "Runtime.executionContextsCleared":
            annotateContextID = nil
        case "Runtime.bindingCalled":
            // Only our isolated world has the binding; the context check drops iframes.
            guard params["name"] as? String == "hermAnnotate",
                params["executionContextId"] as? Int == annotateContextID,
                let payload = params["payload"] as? String
            else { return }
            receive(payload)
        case "Runtime.consoleAPICalled":
            guard params["type"] as? String == "error" else { return }
            let args = (params["args"] as? [[String: Any]] ?? []).map { arg in
                arg["value"].map { "\($0)" } ?? arg["description"] as? String ?? ""
            }
            appendConsole(args.joined(separator: " "))
        case "Runtime.exceptionThrown":
            let details = params["exceptionDetails"] as? [String: Any]
            appendConsole(
                (details?["exception"] as? [String: Any])?["description"] as? String
                    ?? details?["text"] as? String ?? "Uncaught exception")
        default:
            break
        }
    }

    // Mutating a @Published struct publishes even when the event changes nothing.
    func receiveNavigation(_ method: String, params: [String: Any]) {
        var next = navigation
        next.receiveCDP(method, params: params, mainFrameID: mainFrameID)
        if next != navigation { navigation = next }
    }

    private func appendConsole(_ line: String) {
        consoleErrors = Array((consoleErrors + [String(line.prefix(2000))]).suffix(50))
    }

    // MARK: Annotate

    private func applyAnnotating() {
        evaluate("window.__hermAnnotate?.setEnabled(\(annotating), \(BrowserAnnotation.themeJSON))")
    }

    private func receive(_ json: String) {
        switch BrowserPageMessage(json: json) {
        case .modeOff:
            annotating = false
        case .annotation(let annotation):
            Task {
                let image = await screenshot(annotation)
                evaluate("window.__hermAnnotate?.done()")
                if let model, model.browserSessionKey == key {
                    BrowserAnnotation.deliver(annotation.context, image: image, to: model)
                }
            }
        case nil:
            break
        }
    }

    private func screenshot(_ annotation: BrowserAnnotation) async -> NSImage? {
        let rect = annotation.rect
        guard let cdp, let sid = sessionID, rect.width >= 2, rect.height >= 2 else { return nil }
        // `clip` is in document coordinates, so add the scroll offset.
        let clip: [String: Any] = [
            "x": rect.x + annotation.scrollX, "y": rect.y + annotation.scrollY,
            "width": rect.width, "height": rect.height, "scale": 1,
        ]
        guard
            let result = try? await cdp.send("Page.captureScreenshot", ["format": "png", "clip": clip], session: sid),
            let base64 = result["data"] as? String, let data = Data(base64Encoded: base64)
        else { return nil }
        return NSImage(data: data)
    }

    func selection() async -> String {
        guard let cdp, let sid = sessionID, let context = annotateContextID,
            let result = try? await cdp.send(
                "Runtime.evaluate",
                [
                    "expression": "window.__hermAnnotate?.selection() ?? ''", "contextId": context,
                    "returnByValue": true,
                ], session: sid)
        else { return "" }
        return (result["result"] as? [String: Any])?["value"] as? String ?? ""
    }

    private func evaluate(_ expression: String) {
        guard let cdp, let sid = sessionID, let context = annotateContextID else { return }
        cdp.fire("Runtime.evaluate", ["expression": expression, "contextId": context], session: sid)
    }

    // MARK: Navigation and input

    func navigate(_ url: URL) {
        guard state == .running, sessionID != nil else {
            pendingURL = url
            return
        }
        pendingURL = nil
        performNavigation("Page.navigate", ["url": url.absoluteString])
    }
    func answerDialog(accept: Bool, text: String? = nil) {
        var params: [String: Any] = ["accept": accept]
        if let text { params["promptText"] = text }
        fire("Page.handleJavaScriptDialog", params)
        dialog = nil
    }

    /// Interrupts Hermes so you can finish a step (a login, a captcha) yourself.
    func takeOver() {
        _ = model?.stop()
        userHasControl = true
        inputLocked = false
    }

    /// Resumes Hermes' turn from the page you left it on.
    func handBack() {
        userHasControl = false
        guard let model, let sessionID = model.sessionID else { return }
        let page = activePage.map { " The browser is now on \($0.url)." } ?? ""
        model.send(
            QueuedPrompt(
                sessionID: sessionID,
                text: "I've finished that step in the browser myself.\(page) Continue where you left off.",
                images: [], pdfURL: nil))
    }

    func goBack() {
        guard navigation.canGoBack else { return }
        performNavigation("Runtime.evaluate", ["expression": "history.back()"])
    }
    func goForward() {
        guard navigation.canGoForward else { return }
        performNavigation("Runtime.evaluate", ["expression": "history.forward()"])
    }
    func reload() { performNavigation("Page.reload") }
    func stopLoading() {
        navigationRequestID = UUID()
        fire("Page.stopLoading")
        navigation.finish()
    }
    func clearNavigationError() { navigation.error = nil }

    private func performNavigation(_ method: String, _ params: [String: Any] = [:]) {
        guard let cdp, let sessionID else { return }
        let requestID = UUID()
        navigationRequestID = requestID
        navigation.start()
        Task {
            do {
                let result = try await cdp.send(method, params, session: sessionID)
                guard self.sessionID == sessionID, navigationRequestID == requestID else { return }
                if let error = result["errorText"] as? String, error != "net::ERR_ABORTED" {
                    navigation.fail(HermesDiagnosticsService.safeSummary(error))
                } else if method == "Page.navigate", result["loaderId"] == nil {
                    navigation.finish()  // Same-document navigation has no new loader.
                }
            } catch {
                guard self.sessionID == sessionID, navigationRequestID == requestID else { return }
                navigation.fail(HermesDiagnosticsService.safeSummary(error.localizedDescription))
            }
        }
    }

    private func refreshHistory() {
        guard let cdp, let sessionID else { return }
        let requestID = UUID()
        historyRequestID = requestID
        Task {
            guard let result = try? await cdp.send("Page.getNavigationHistory", session: sessionID),
                self.sessionID == sessionID, historyRequestID == requestID
            else { return }
            navigation.updateHistory(result)
        }
    }
    func select(_ page: Page) { Task { try? await attach(page.id) } }
    func newTab() { fire("Target.createTarget", ["url": "about:blank"], browserLevel: true) }

    func mouse(
        _ type: String, at point: CGPoint, button: String = "none", buttons: Int = 0, clicks: Int = 0,
        modifiers: Int, delta: CGPoint = .zero
    ) {
        var params: [String: Any] = [
            "type": type, "x": point.x, "y": point.y, "button": button,
            "buttons": buttons, "clickCount": clicks, "modifiers": modifiers,
        ]
        if type == "mouseWheel" {
            params["deltaX"] = delta.x
            params["deltaY"] = delta.y
        }
        fire("Input.dispatchMouseEvent", params)
    }

    func key(_ params: [String: Any]) { fire("Input.dispatchKeyEvent", params) }
    func insertText(_ text: String) { fire("Input.insertText", ["text": text]) }

    /// Fire-and-forget keeps input events in order (each awaits nothing).
    private func fire(_ method: String, _ params: [String: Any] = [:], browserLevel: Bool = false) {
        guard let cdp else { return }
        if browserLevel { return cdp.fire(method, params) }
        guard let sid = sessionID else { return }
        cdp.fire(method, params, session: sid)
    }
}

/// Minimal Chrome DevTools Protocol client: JSON over a websocket, flat sessions.
@MainActor
final class CDPConnection {
    struct Frame: Sendable { let image: CGImage }

    private let task: URLSessionWebSocketTask
    private var nextID = 0
    /// CDP results are plain JSON values, only touched on the main actor.
    private struct Reply: @unchecked Sendable { let value: [String: Any] }
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    var onEvent: ((String, [String: Any], String?) -> Void)?
    var onClose: (() -> Void)?

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        // Screencast frames and screenshots are base64 images, well past the 1 MB default.
        task.maximumMessageSize = 64 << 20
        task.resume()
        receiveNext()
    }

    func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            pending[write(method, params, session: session)] = continuation
        }.value
    }

    func fire(_ method: String, _ params: [String: Any] = [:], session: String? = nil) {
        write(method, params, session: session)
    }

    func close() {
        onEvent = nil
        onClose = nil
        task.cancel(with: .goingAway, reason: nil)
        failPending(CancellationError())
    }

    @discardableResult
    private func write(_ method: String, _ params: [String: Any], session: String?) -> Int {
        nextID += 1
        let id = nextID
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
            let text = String(data: data, encoding: .utf8)
        else { return id }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
        return id
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            switch result {
            case .failure:
                Task { @MainActor in
                    guard let self else { return }
                    self.failPending(URLError(.networkConnectionLost))
                    self.onClose?()
                }
            case .success(let message):
                let object = Self.decode(message)
                Task { @MainActor in
                    guard let self else { return }
                    if let object { self.dispatch(object) }
                    self.receiveNext()
                }
            }
        }
    }

    nonisolated private static func decode(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data? =
            switch message {
            case .string(let text): text.data(using: .utf8)
            case .data(let data): data
            @unknown default: nil
            }
        guard let data, var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object["method"] as? String == "Page.screencastFrame",
            var params = object["params"] as? [String: Any]
        {
            // Decode on the socket callback, before handing the frame to the main actor.
            params["decodedFrame"] = (params.removeValue(forKey: "data") as? String).flatMap(decodeFrame).map {
                Frame(image: $0)
            }
            object["params"] = params
        }
        return object
    }

    nonisolated static func decodeFrame(_ base64: String) -> CGImage? {
        guard let data = Data(base64Encoded: base64),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func dispatch(_ object: [String: Any]) {
        if let id = object["id"] as? Int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(
                    throwing: NSError(
                        domain: "Herm.CDP", code: error["code"] as? Int ?? 0,
                        userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "CDP error"]))
            } else {
                continuation.resume(returning: Reply(value: object["result"] as? [String: Any] ?? [:]))
            }
        } else if let method = object["method"] as? String {
            onEvent?(method, object["params"] as? [String: Any] ?? [:], object["sessionId"] as? String)
        }
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }
}

/// Live view of the agent browser: draws screencast frames and forwards input as CDP events.
final class AgentBrowserCanvas: NSView {
    var browser: AgentBrowser? {
        didSet {
            if let frame = browser?.lastFrame {
                image = frame.image
                cssSize = frame.css
                needsDisplay = true
            }
            browser?.onFrame = { [weak self] image, css in
                self?.image = image
                self?.cssSize = css
                self?.needsDisplay = true
            }
        }
    }
    private var image: NSImage?
    private var cssSize = CGSize(width: 1280, height: 800)
    private var isViewing = false
    private var pressedButtons = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        browser?.resize(to: bounds.size, scale: window?.backingScaleFactor ?? 2)
        let viewing = window != nil
        guard viewing != isViewing else { return }
        isViewing = viewing
        browser?.viewers += viewing ? 1 : -1
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fit the page into the panel, never scaled above 1 CSS px per point; top-centred.
    var pageRect: CGRect {
        guard cssSize.width > 0, cssSize.height > 0 else { return bounds }
        let scale = min(1, bounds.width / cssSize.width, bounds.height / cssSize.height)
        let size = CGSize(width: cssSize.width * scale, height: cssSize.height * scale)
        let backingScale = window?.backingScaleFactor ?? 2
        let x = (((bounds.width - size.width) / 2) * backingScale).rounded() / backingScale
        return CGRect(x: x, y: 0, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(
            in: pageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high])
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        browser?.resize(to: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        browser?.resize(to: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    private func cssPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = pageRect
        return CGPoint(
            x: (point.x - rect.minX) / rect.width * cssSize.width,
            y: (point.y - rect.minY) / rect.height * cssSize.height)
    }

    /// CDP modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8.
    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0)
            | (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
    }

    private func press(_ event: NSEvent, _ type: String, button: String, bit: Int) {
        guard browser?.inputLocked != true else { return }
        if type == "mousePressed" {
            window?.makeFirstResponder(self)
            pressedButtons |= bit
        } else {
            pressedButtons &= ~bit
        }
        browser?.mouse(
            type, at: cssPoint(event), button: button, buttons: pressedButtons,
            clicks: event.clickCount, modifiers: Self.modifiers(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) { press(event, "mousePressed", button: "left", bit: 1) }
    override func mouseUp(with event: NSEvent) { press(event, "mouseReleased", button: "left", bit: 1) }
    override func rightMouseDown(with event: NSEvent) { press(event, "mousePressed", button: "right", bit: 2) }
    override func rightMouseUp(with event: NSEvent) { press(event, "mouseReleased", button: "right", bit: 2) }
    override func mouseDragged(with event: NSEvent) { move(event, button: "left") }
    override func rightMouseDragged(with event: NSEvent) { move(event, button: "right") }
    override func mouseMoved(with event: NSEvent) { move(event, button: "none") }

    private func move(_ event: NSEvent, button: String) {
        guard browser?.inputLocked != true else { return }
        browser?.mouse(
            "mouseMoved", at: cssPoint(event), button: button, buttons: pressedButtons,
            modifiers: Self.modifiers(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard browser?.inputLocked != true else { return }
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        browser?.mouse(
            "mouseWheel", at: cssPoint(event), modifiers: Self.modifiers(event.modifierFlags),
            delta: CGPoint(x: -event.scrollingDeltaX * factor, y: -event.scrollingDeltaY * factor))
    }

    /// Mac key code → DOM key name, Windows virtual key code, and the text it types.
    private static let specialKeys: [UInt16: (key: String, code: Int, text: String?)] = [
        36: ("Enter", 13, "\r"), 76: ("Enter", 13, "\r"), 51: ("Backspace", 8, nil), 117: ("Delete", 46, nil),
        48: ("Tab", 9, nil), 53: ("Escape", 27, nil), 123: ("ArrowLeft", 37, nil), 124: ("ArrowRight", 39, nil),
        125: ("ArrowDown", 40, nil), 126: ("ArrowUp", 38, nil), 115: ("Home", 36, nil), 119: ("End", 35, nil),
        116: ("PageUp", 33, nil), 121: ("PageDown", 34, nil),
    ]

    override func keyDown(with event: NSEvent) {
        guard browser?.inputLocked != true else { return }
        let modifiers = Self.modifiers(event.modifierFlags)
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) { browser?.insertText(text) }
            case "a":
                browser?.key([
                    "type": "rawKeyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65,
                    "modifiers": modifiers, "commands": ["selectAll"],
                ])
            default:
                super.keyDown(with: event)
            }
            return
        }
        if let special = Self.specialKeys[event.keyCode] {
            var down: [String: Any] = [
                "type": special.text == nil ? "rawKeyDown" : "keyDown", "key": special.key,
                "code": special.key, "windowsVirtualKeyCode": special.code, "modifiers": modifiers,
            ]
            if let text = special.text { down["text"] = text }
            browser?.key(down)
            browser?.key([
                "type": "keyUp", "key": special.key, "code": special.key,
                "windowsVirtualKeyCode": special.code, "modifiers": modifiers,
            ])
        } else if let text = event.characters, !text.isEmpty {
            browser?.key(["type": "keyDown", "text": text, "unmodifiedText": text, "key": text, "modifiers": modifiers])
            browser?.key(["type": "keyUp", "key": text, "modifiers": modifiers])
        }
    }
}

private struct AgentCanvasView: NSViewRepresentable {
    let browser: AgentBrowser
    func makeNSView(context: Context) -> AgentBrowserCanvas {
        let canvas = AgentBrowserCanvas(frame: .zero)
        canvas.browser = browser
        return canvas
    }
    func updateNSView(_ nsView: AgentBrowserCanvas, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentBrowserCanvas, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// The Browser tab in agent mode: live view, start/failure states, and what Hermes is doing.
struct AgentBrowserPane: View {
    @ObservedObject var browser: AgentBrowser
    @ObservedObject var model: DockModel

    var body: some View {
        ZStack(alignment: .bottom) {
            AgentCanvasView(browser: browser)
            switch browser.state {
            case .starting:
                ProgressView("Starting the agent browser…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message).dockFont(.body).foregroundStyle(Color.dockSecondaryText).multilineTextAlignment(
                        .center)
                    Button("Try Again") { browser.start() }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .off, .running:
                EmptyView()
            }
        }
        .overlay(alignment: .top) {
            if step != nil { DockShimmerTrack(tone: .working).transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            Group {
                if browser.userHasControl { controlPill } else if let step { activityPill(step) }
            }
            .padding(12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .overlay {
            if let dialog = browser.dialog {
                AgentDialogCard(dialog: dialog) { browser.answerDialog(accept: $0, text: $1) }
                    .padding(16)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(.dockEase(duration: 0.2), value: step != nil)
        .animation(.dockEase(duration: 0.2), value: browser.userHasControl)
        .animation(.dockEase(duration: 0.16), value: browser.dialog)
        .background(Color.dockCanvas)
        .onChange(of: step != nil, initial: true) { _, browsing in
            // A step still finishing after Take over keeps your control; a new one is Hermes driving again.
            if browsing, browser.userHasControl, model.interruptState != .requesting { browser.userHasControl = false }
            browser.inputLocked = browsing && !browser.userHasControl
        }
    }

    private var palette: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }

    /// Shown after Take over until you hand the page back to Hermes.
    private var controlPill: some View {
        HStack(spacing: 8) {
            DockIcon(.handPointing, size: 12, color: Color.dockAccent)
            Text("You're in control")
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .fixedSize()
            Button("Hand back to Herm") { browser.handBack() }
                .buttonStyle(DockPrimaryButtonStyle())
                .controlSize(.small)
            DockIconButton(icon: .x, label: "Dismiss", size: 22, style: palette) { browser.userHasControl = false }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .dockHUDPanel()
        .accessibilityElement(children: .contain)
    }

    private var step: (icon: Ph, title: String, detail: String?)? {
        model.activeBrowserCall.map(ToolStep.describe)
    }

    /// Live status for the page Hermes is driving, drawn as a theme HUD panel.
    private func activityPill(_ step: (icon: Ph, title: String, detail: String?)) -> some View {
        HStack(spacing: 8) {
            DockStatusDot(tone: .working, size: 7, pulses: true)
            Text("Herm is browsing")
                .dockFont(.body, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
                .fixedSize()
            HStack(spacing: 4) {
                DockIcon(step.icon, size: 11, color: Color.dockSecondaryText)
                Text(step.title)
                    .dockFont(.body)
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentTransition(.opacity)
            .animation(.dockEase(duration: 0.18), value: step.title)
            Button("Take over") { browser.takeOver() }
                .buttonStyle(DockSecondaryButtonStyle())
                .controlSize(.small)
                .help("Pause Herm and use the page yourself")
            DockIconButton(icon: .stop, label: "Stop Herm", size: 22, style: palette) { model.stop() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .dockHUDPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Herm is browsing: \(step.title)")
    }
}

/// A page's JavaScript dialog, answered from the panel (headless Chrome has no UI for it).
private struct AgentDialogCard: View {
    let dialog: AgentBrowser.Dialog
    let answer: (Bool, String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var title: String {
        dialog.type == "beforeunload" ? "Leave this page?" : "This page says"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .dockFont(.navigation, weight: .semibold)
                .foregroundStyle(Color.dockPrimaryText)
            if !dialog.message.isEmpty {
                ScrollView {
                    Text(dialog.message)
                        .dockFont(.body)
                        .foregroundStyle(Color.dockSecondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            if dialog.type == "prompt" {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { answer(true, text) }
            }
            HStack(spacing: 8) {
                Spacer()
                if dialog.type != "alert" {
                    Button(dialog.type == "beforeunload" ? "Stay" : "Cancel") { answer(false, nil) }
                        .buttonStyle(DockSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                Button(dialog.type == "beforeunload" ? "Leave" : "OK") {
                    answer(true, dialog.type == "prompt" ? text : nil)
                }
                .buttonStyle(DockPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: 340)
        .dockHUDPanel()
        .onAppear {
            text = dialog.defaultPrompt
            focused = dialog.type == "prompt"
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(dialog.message)")
    }
}

extension DockModel {
    /// The browser tool Hermes is running right now, if any.
    var activeBrowserCall: ActiveToolCall? {
        activeToolCalls.last { !$0.isComplete && $0.name.hasPrefix("browser_") }
    }
}
