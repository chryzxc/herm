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
    /// Hermes' `browser.manage connect` is per profile, so each profile has one agent Chrome
    /// that its sessions share; Hermes' browser tools keep a session's work on its own tab.
    let profileID: String?
    private static var connectionTask: Task<Void, Never>?
    private static var preferredPortOwner: String?
    private static let world = "herm"
    /// Annotate plus the agent-cursor reporter: pointer moves (one per animation frame),
    /// presses, and focus not caused by a press, in viewport CSS pixels.
    private static let worldScript =
        BrowserAnnotation.script + """

            (() => {
              if (window.__hermPointer) return;
              window.__hermPointer = true;
              const send = (type, x, y) => {
                if (typeof window.hermPointer === 'function') window.hermPointer(JSON.stringify({ type, x, y }));
              };
              let pending = null, pressed = 0;
              // Trusted events only: a page's synthetic ones must not move Hermes' cursor.
              addEventListener('pointermove', (e) => {
                if (!e.isTrusted) return;
                const idle = !pending;
                pending = [e.clientX, e.clientY];
                if (idle) requestAnimationFrame(() => { send('move', ...pending); pending = null; });
              }, true);
              addEventListener('pointerdown', (e) => { if (!e.isTrusted) return; pressed = performance.now(); send('down', e.clientX, e.clientY); }, true);
              addEventListener('focusin', (e) => {
                const r = e.target.getBoundingClientRect?.();
                if (!e.isTrusted || performance.now() - pressed < 300 || !r || !r.width || !r.height) return;
                send('focus', r.left + Math.min(r.width / 2, 24), r.top + r.height / 2);
              }, true);
            })();
            (() => {
              // Your input only, in the top frame: Herm draws dropdowns headless Chrome paints
              // off-screen, mirrors the page's cursor, and anchors IME candidates to the field.
              if (window.__hermPage || window !== top) return;
              const post = (message) => {
                if (typeof window.hermPage === 'function') window.hermPage(JSON.stringify(message));
              };
              const rect = (el) => {
                const r = el.getBoundingClientRect();
                return { x: r.left, y: r.top, width: r.width, height: r.height };
              };
              const editable = (el) => el?.isContentEditable || el?.tagName === 'TEXTAREA' || (el?.tagName === 'INPUT'
                && !['button', 'checkbox', 'radio', 'submit', 'reset', 'image', 'file', 'color', 'range', 'hidden'].includes(el.type));
              let userInput = false, cursor = '', open = null, nextID = 0;
              window.__hermPage = {
                setUserInput(on) { userInput = on; if (!on) cursor = ''; },
                choose(id, index) {
                  const select = open?.id === id ? open.select.deref() : null;
                  open = null;
                  if (!select || select.selectedIndex === index || !select.options[index] || select.options[index].disabled) return;
                  select.selectedIndex = index;
                  select.dispatchEvent(new Event('input', { bubbles: true }));
                  select.dispatchEvent(new Event('change', { bubbles: true }));
                },
                copy() {
                  const el = document.activeElement;
                  if (editable(el) && typeof el.selectionStart === 'number') return el.value.slice(el.selectionStart, el.selectionEnd);
                  return String(getSelection());
                },
              };
              addEventListener('mousedown', (e) => {
                const select = e.target.closest?.('select');
                if (!userInput || !e.isTrusted || e.button !== 0 || !select || select.multiple || select.size > 1 || select.disabled) return;
                e.preventDefault();
                select.focus();
                open = { id: ++nextID, select: new WeakRef(select) };
                post({ type: 'select', id: open.id, rect: rect(select), selected: select.selectedIndex,
                  options: [...select.options].map((o) => ({
                    label: o.label || o.text, disabled: o.disabled || !!o.closest('optgroup')?.disabled,
                    group: o.parentElement.tagName === 'OPTGROUP' ? o.parentElement.label : null })) });
              }, true);
              addEventListener('pointermove', (e) => {
                if (!userInput || !(e.target instanceof Element)) return;
                let next = getComputedStyle(e.target).cursor.split(',').pop().trim();
                if (next === 'auto') next = editable(e.target) || [...e.target.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim()) ? 'text' : 'default';
                if (next !== cursor) post({ type: 'cursor', cursor: (cursor = next) });
              }, true);
              addEventListener('focusin', (e) => { if (editable(e.target)) post({ type: 'field', rect: rect(e.target) }); }, true);
            })();
            """

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
    var inputLocked = false {
        didSet {
            guard inputLocked != oldValue else { return }
            if inputLocked { onPageEvent?(.cursor("default")) }
            applyPageInput()
        }
    }
    /// Where Hermes' pointer or focus landed, in CSS pixels; nil hides the agent cursor.
    /// Like frames, this bypasses SwiftUI.
    var onPointer: ((AgentPointer?) -> Void)?
    private(set) var lastPointer: AgentPointer?

    /// Keep the last observed position between tool calls, without replaying a click on remount.
    func updatePointer(_ pointer: AgentPointer?) {
        lastPointer = pointer.map { AgentPointer(kind: .move, point: $0.point) }
        onPointer?(pointer)
    }
    /// What the page reports back about your own input: dropdowns to draw, cursor, focused field.
    var onPageEvent: ((AgentPageEvent) -> Void)?
    /// Where Hermes' browser downloads land; set explicitly rather than left to Chrome.
    nonisolated static var downloadsFolder: URL {
        (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true))
            .appendingPathComponent("Herm", isDirectory: true)
    }
    /// Prompts a headless page could otherwise leave for Hermes to accept on your behalf.
    static let deniedPermissions = [
        "geolocation", "notifications", "camera", "microphone", "midi", "display-capture", "clipboard-read",
        "window-management", "local-fonts", "idle-detection",
    ]

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
            guard let self, owns(model), state == .running, self.cdpURL == cdpURL else { return }
            do { try await model.setHermesBrowser(cdpURL: cdpURL) } catch {
                if owns(model) { fail(error.localizedDescription) }
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
    private var viewportDirty = false
    /// "<session>@<scale>" of the running screencast.
    private var screencast: String?
    private var themeCancellable: AnyCancellable?
    private var navigationRequestID = UUID()
    private var historyRequestID = UUID()
    /// The cookies this Chrome last agreed on with the shared jar; nil until restored.
    private var loginBaseline: BrowserCookieJar?
    /// Bumped whenever the jar pushes into this Chrome, so an in-flight read can't undo it.
    private var loginGeneration = 0
    private var loginSyncTask: Task<Void, Never>?
    private var loginsCancellable: AnyCancellable?

    /// The Hermes session whose tab is on screen; each remembers the tab it last showed.
    private var shownSession: String?
    private var tabs: [String: String] = [:]

    private func owns(_ model: DockModel?) -> Bool {
        model?.browserSessionKey.map { $0.profileID == profileID } ?? false
    }

    private var profileDirectory: String { SessionBrowserKey.browserDirectory(profileID: profileID) }

    init(profileID: String?) {
        self.profileID = profileID
        themeCancellable = DockThemeStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.annotating else { return }
                self.applyAnnotating()
            }
        loginsCancellable = SharedBrowserLogins.shared.changes.sink { [weak self] origin, change in
            guard let self, origin != ObjectIdentifier(self) else { return }
            self.receiveLogins(change)
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
                for name in Self.deniedPermissions {
                    cdp.fire("Browser.setPermission", ["permission": ["name": name], "setting": "denied"])
                }
                try? FileManager.default.createDirectory(
                    at: Self.downloadsFolder, withIntermediateDirectories: true)
                cdp.fire(
                    "Browser.setDownloadBehavior", ["behavior": "allow", "downloadPath": Self.downloadsFolder.path])
                await restoreLogins(cdp)
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
        let profileID = profileID
        Self.connectionTask = Task {
            await previous?.value
            guard model?.browserSessionKey.map({ $0.profileID == profileID }) == true else { return }
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
        loginSyncTask?.cancel()
        loginSyncTask = nil
        loginBaseline = nil
        lastFrame = nil
        process?.terminate()
        process = nil
        sessionID = nil
        mainFrameID = nil
        annotateContextID = nil
        updatePointer(nil)
        screencast = nil
        navigationRequestID = UUID()
        historyRequestID = UUID()
        navigation = BrowserNavigationState()
        activeTargetID = nil
        pages = []
        consoleErrors = []
        dialog = nil
        annotating = false
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

    /// Shows `session`'s tab: the one it last showed, else the current one becomes its tab.
    func show(session: String) {
        shownSession = session
        guard state == .running, let target = tabs[session], target != activeTargetID,
            pages.contains(where: { $0.id == target })
        else {
            if let activeTargetID { tabs[session] = activeTargetID }
            return
        }
        Task { try? await attach(target) }
    }

    /// Hermes deleted the session; its tab stays open in the shared browser.
    func forget(session: String) {
        tabs.removeValue(forKey: session)
        if shownSession == session { shownSession = nil }
    }

    private func launch() async throws -> AgentBrowserEndpoint {
        let profile = Self.profileRoot.appendingPathComponent(profileDirectory, isDirectory: true)
        // Profiles hold signed-in cookies: owner-only, including a root made by an older Herm.
        try FileManager.default.createDirectory(
            at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.profileRoot.path)
        let portFile = profile.appendingPathComponent("DevToolsActivePort")
        // A browser left running by an earlier Herm keeps the profile locked; reuse it.
        if let live = await AgentBrowserEndpoint.discover(portFile: portFile) { return live }
        try? FileManager.default.removeItem(at: portFile)
        guard let executable = Self.chromiumExecutable() else {
            throw Self.error("No Chromium-family browser found. Install Google Chrome, Brave, Edge or Chromium.")
        }
        // A fixed port lets other CDP clients (e.g. chrome-devtools-mcp --browserUrl) share
        // this browser; fall back to any free port when something else holds it.
        // Reserve before probing: two sessions can launch before either Chrome is listening.
        if Self.preferredPortOwner == nil { Self.preferredPortOwner = profileDirectory }
        let busy: Bool
        if Self.preferredPortOwner == profileDirectory {
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
        let announcement = AgentBrowserAnnouncement()
        let errors = Pipe()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { announcement.consume(data) }
        }
        process.standardError = errors
        try process.run()
        self.process = process
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if let live = await AgentBrowserEndpoint.discoverLaunched(
                portFile: portFile, fixedPort: busy ? nil : Self.preferredPort,
                process: process, announcement: announcement)
            {
                return live
            }
            if !process.isRunning { break }
        }
        throw Self.error("The browser didn't start remote debugging.")
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
        if let shownSession { tabs[shownSession] = targetID }
        navigationRequestID = UUID()
        navigation = BrowserNavigationState()
        consoleErrors = []
        dialog = nil
        annotateContextID = nil
        updatePointer(nil)
        _ = try await cdp.send("Page.enable", session: sid)
        for binding in ["hermAnnotate", "hermPointer", "hermPage"] {
            _ = try await cdp.send(
                "Runtime.addBinding", ["name": binding, "executionContextName": Self.world], session: sid)
        }
        _ = try await cdp.send(
            "Page.addScriptToEvaluateOnNewDocument", ["source": Self.worldScript, "worldName": Self.world],
            session: sid)
        // Headless pages never hold OS focus, so focus rings and carets would never paint.
        cdp.fire("Emulation.setFocusEmulationEnabled", ["enabled": true], session: sid)
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
                "Runtime.evaluate", ["expression": Self.worldScript, "contextId": context], session: sid)
        }
        _ = try await cdp.send("Runtime.enable", session: sid)
        if let document = try? await cdp.send(
            "Runtime.evaluate", ["expression": "document.readyState", "returnByValue": true], session: sid),
            sessionID == sid, let readyState = (document["result"] as? [String: Any])?["value"] as? String
        {
            navigation.isLoading = readyState != "complete"
        }
        applyAnnotating()
        applyPageInput()
        try await applyViewport()
        if state == .running, let url = pendingURL { navigate(url) }
    }

    func resize(to size: CGSize, scale: CGFloat) {
        guard size.width > 10, size.height > 10, size != panelSize || scale != backingScale else { return }
        panelSize = size
        backingScale = scale
        scheduleViewport()
    }

    /// Coalesced, not debounced: one metrics update in flight at a time, and the latest size
    /// goes next, so the page follows a live resize as fast as Chrome can lay it out.
    private func scheduleViewport() {
        viewportDirty = true
        guard viewportTask == nil else { return }
        viewportTask = Task {
            while viewportDirty {
                viewportDirty = false
                try? await applyViewport()
            }
            viewportTask = nil
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
        // A running screencast follows metric changes by itself; restart only for a new tab,
        // a new display scale, or the pane being shown or hidden.
        let screencast = viewers > 0 ? "\(sid)@\(backingScale)" : nil
        guard sessionID == sid, screencast != self.screencast else { return }
        cdp.fire("Page.stopScreencast", session: sid)
        self.screencast = screencast
        guard screencast != nil else { return }
        cdp.fire(
            "Page.startScreencast",
            [
                // Every frame: a keystroke or click damages one frame, and skipping alternate ones
                // held its echo until the next damage (~500ms) and always dropped the same caret blink phase.
                "format": "png", "everyNthFrame": 1,
                "maxWidth": 8192, "maxHeight": 8192,  // Caps only; frames match the emulated viewport.
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
                // Follow a tab Hermes opens for the chat on screen; another chat's stays in the tab strip.
                if state == .running, model?.activeBrowserCall != nil { Task { try? await attach(page.id) } }
            }
        case "Target.targetDestroyed":
            guard let id = params["targetId"] as? String else { return }
            pages.removeAll { $0.id == id }
            guard id == activeTargetID else { return }
            updatePointer(nil)
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
            scheduleLoginSync()
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
            applyPageInput()
        case "Runtime.executionContextsCleared":
            annotateContextID = nil
            updatePointer(nil)
        case "Runtime.bindingCalled":
            // Only our isolated world has the binding; the context check drops iframes.
            guard params["executionContextId"] as? Int == annotateContextID,
                let payload = params["payload"] as? String
            else { return }
            switch params["name"] as? String {
            case "hermAnnotate": receive(payload)
            // The canvas drops your input while Hermes holds the page, so this is Hermes.
            case "hermPointer": if inputLocked, let pointer = AgentPointer(json: payload) { updatePointer(pointer) }
            case "hermPage": if !inputLocked, let event = AgentPageEvent(json: payload) { onPageEvent?(event) }
            default: break
            }
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
        if method == "Page.frameNavigated", let frame = params["frame"] as? [String: Any], frame["parentId"] == nil {
            updatePointer(nil)
        } else if method == "Page.navigatedWithinDocument", let mainFrameID,
            params["frameId"] as? String == mainFrameID
        {
            updatePointer(nil)
        }
        var next = navigation
        next.receiveCDP(method, params: params, mainFrameID: mainFrameID)
        if next != navigation { navigation = next }
    }

    private func appendConsole(_ line: String) {
        consoleErrors = Array((consoleErrors + [String(line.prefix(2000))]).suffix(50))
    }

    // MARK: Shared logins

    /// Sign Out of All Sites count this profile has applied; a closed profile catches up on reopen.
    private var signOutsFile: URL {
        Self.profileRoot.appendingPathComponent(profileDirectory, isDirectory: true)
            .appendingPathComponent("HermSignOuts")
    }

    private func recordSignOuts(_ count: Int) {
        try? Data("\(count)".utf8).write(to: signOutsFile, options: .atomic)
    }

    /// The jar is authoritative for shared sites: a Chrome reopened on an old profile picks up
    /// their sign-ins and sign-outs since. This session's other sign-ins stay its own.
    /// Pushes are fire-only, so later ones stay ordered after these.
    private func restoreLogins(_ cdp: CDPConnection) async {
        guard await SharedBrowserLogins.shared.prepare(), self.cdp === cdp, !Task.isCancelled else { return }
        let jar = SharedBrowserLogins.shared.jar
        let applied = (try? String(contentsOf: signOutsFile, encoding: .utf8)).flatMap { Int($0) } ?? 0
        var current = BrowserCookieJar()
        if applied < jar.signOuts {
            cdp.fire("Storage.clearCookies")
        } else {
            let result = try? await cdp.send("Storage.getCookies")
            guard self.cdp === cdp, !Task.isCancelled else { return }
            current = BrowserCookieJar(
                (result?["cookies"] as? [[String: Any]] ?? []).compactMap(BrowserCookie.init(cdp:)))
        }
        recordSignOuts(jar.signOuts)
        // Read again: a change shared during the await was skipped while there was no baseline.
        let latest = SharedBrowserLogins.shared.jar
        let changes = BrowserCookieJar(current.cookies.values.filter(latest.shares)).changes(to: latest)
        Self.push(changes, to: cdp)
        current.apply(changes)
        loginBaseline = current
    }

    /// Shares (or stops sharing) a site's sign-in with every session, from this browser's cookies.
    func toggleSharing(_ site: String) {
        let logins = SharedBrowserLogins.shared
        guard !logins.jar.sites.contains(site) else { return logins.stopSharing(site) }
        let origin = ObjectIdentifier(self)
        guard let cdp else { return logins.share(site, cookies: [], from: origin) }
        Task {
            let result = try? await cdp.send("Storage.getCookies")
            let cookies = (result?["cookies"] as? [[String: Any]] ?? []).compactMap(BrowserCookie.init(cdp:))
            SharedBrowserLogins.shared.share(site, cookies: cookies, from: origin)
        }
    }

    /// One cookie per call: Chrome rejects a whole batch over a single bad cookie.
    private static func push(_ changes: BrowserCookieJar.Changes, to cdp: CDPConnection) {
        for param in changes.removed.map({ $0.cdpParam(expired: true) }) + changes.updated.map({ $0.cdpParam() }) {
            cdp.fire("Storage.setCookies", ["cookies": [param]])
        }
    }

    private func receiveLogins(_ change: SharedBrowserLogins.Change) {
        guard let cdp else { return }
        if case .prepared = change {
            guard loginBaseline == nil else { return }
            Task { [weak self] in await self?.restoreLogins(cdp) }
            return
        }
        loginGeneration += 1
        switch change {
        case .updated(let changes):
            guard var baseline = loginBaseline else { return }
            Self.push(changes, to: cdp)
            baseline.apply(changes)
            loginBaseline = baseline
        case .cleared:
            cdp.fire("Storage.clearCookies")
            loginBaseline = BrowserCookieJar()
            recordSignOuts(SharedBrowserLogins.shared.jar.signOuts)
        case .prepared: break
        }
    }

    /// After each top-level load, share what this page's sign-in (or sign-out) changed.
    private func scheduleLoginSync() {
        loginSyncTask?.cancel()
        loginSyncTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let cdp, loginBaseline != nil else { return }
            let generation = loginGeneration
            guard let result = try? await cdp.send("Storage.getCookies"), !Task.isCancelled, self.cdp === cdp,
                let baseline = loginBaseline
            else { return }
            guard loginGeneration == generation else { return scheduleLoginSync() }
            let current = BrowserCookieJar(
                (result["cookies"] as? [[String: Any]] ?? []).compactMap(BrowserCookie.init(cdp:)))
            loginBaseline = current
            SharedBrowserLogins.shared.record(baseline.changes(to: current), from: ObjectIdentifier(self))
        }
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
                if let model, owns(model) {
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

    // MARK: Your input

    private func applyPageInput() {
        evaluate("window.__hermPage?.setUserInput(\(!inputLocked))")
    }

    /// Applies an option picked from Herm's menu for a dropdown the page reported.
    func chooseOption(select id: Int, index: Int) {
        evaluate("window.__hermPage?.choose(\(id), \(index))")
    }

    /// The focused field's selected text, or the page selection.
    func selectedText() async -> String {
        guard let cdp, let sid = sessionID, let context = annotateContextID,
            let result = try? await cdp.send(
                "Runtime.evaluate",
                ["expression": "window.__hermPage?.copy() ?? ''", "contextId": context, "returnByValue": true],
                session: sid)
        else { return "" }
        return (result["result"] as? [String: Any])?["value"] as? String ?? ""
    }

    /// An input method's in-progress text (a dead key's accent, unconverted kana), shown in the field.
    func compose(_ text: String, selection: NSRange) {
        fire(
            "Input.imeSetComposition",
            ["text": text, "selectionStart": selection.location, "selectionEnd": NSMaxRange(selection)])
    }

    /// A ⌘ shortcut Chrome performs as an editing command (undo, redo, cut).
    func editCommand(_ command: String, key: String, code: Int, modifiers: Int) {
        let base: [String: Any] = [
            "key": key, "code": "Key\(key.uppercased())", "windowsVirtualKeyCode": code, "modifiers": modifiers,
        ]
        self.key(base.merging(["type": "rawKeyDown", "commands": [command]]) { $1 })
        self.key(base.merging(["type": "keyUp"]) { $1 })
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
        updatePointer(nil)
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
        updatePointer(nil)
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
        if method.hasPrefix("Input.") { updatePointer(nil) }
        guard let cdp else { return }
        if browserLevel { return cdp.fire(method, params) }
        guard let sid = sessionID else { return }
        cdp.fire(method, params, session: sid)
    }
}

/// Hermes' pointer as the page saw it, in viewport CSS pixels.
struct AgentPointer: Equatable {
    enum Kind: String { case move, down, focus }
    let kind: Kind
    let point: CGPoint

    init(kind: Kind, point: CGPoint) {
        self.kind = kind
        self.point = point
    }

    init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let kind = (object["type"] as? String).flatMap(Kind.init(rawValue:)),
            let x = object["x"] as? Double, let y = object["y"] as? Double, x.isFinite, y.isFinite
        else { return nil }
        self.init(kind: kind, point: CGPoint(x: x, y: y))
    }
}

/// What the page's Herm script reports about your own input, in viewport CSS pixels.
enum AgentPageEvent: Equatable {
    struct Option: Equatable {
        let label: String
        let disabled: Bool
        let group: String?
    }
    /// A dropdown you clicked; headless Chrome would paint its popup where the screencast can't see.
    case select(id: Int, rect: CGRect, selected: Int, options: [Option])
    /// The page's CSS cursor under your pointer, `auto` already resolved.
    case cursor(String)
    /// The editable field that took focus, for placing input-method candidates.
    case field(CGRect)

    init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        func rect(_ value: Any?) -> CGRect? {
            guard let value = value as? [String: Any], let x = value["x"] as? Double, let y = value["y"] as? Double,
                let width = value["width"] as? Double, let height = value["height"] as? Double,
                [x, y, width, height].allSatisfy(\.isFinite)
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        switch object["type"] as? String {
        case "select":
            guard let id = object["id"] as? Int, let rect = rect(object["rect"]),
                let options = object["options"] as? [[String: Any]], !options.isEmpty
            else { return nil }
            self = .select(
                id: id, rect: rect, selected: object["selected"] as? Int ?? -1,
                options: options.map {
                    Option(
                        label: String(($0["label"] as? String ?? "").prefix(200)),
                        disabled: $0["disabled"] as? Bool ?? false, group: $0["group"] as? String)
                })
        case "cursor":
            guard let cursor = object["cursor"] as? String else { return nil }
            self = .cursor(cursor)
        case "field":
            guard let rect = rect(object["rect"]) else { return nil }
            self = .field(rect)
        default:
            return nil
        }
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
                // Ack before the main-actor hop: Chrome encodes the next frame while this one is
                // drawn. Still one frame in flight, since the next receive waits for the dispatch.
                if object?["method"] as? String == "Page.screencastFrame",
                    let session = object?["sessionId"] as? String,
                    let frame = (object?["params"] as? [String: Any])?["sessionId"] as? Int
                {
                    Task { @MainActor in self?.fire("Page.screencastFrameAck", ["sessionId": frame], session: session) }
                }
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
    /// SwiftUI reuses one canvas across sessions, so rebinding moves the viewer to the new browser;
    /// otherwise the new one never streams and the old one streams to nobody.
    var browser: AgentBrowser? {
        didSet {
            guard browser !== oldValue else { return }
            if isViewing {
                oldValue?.viewers -= 1
                browser?.viewers += 1
            }
            oldValue?.onFrame = nil
            oldValue?.onPointer = nil
            oldValue?.onPageEvent = nil
            page.layer?.contents = nil
            if let frame = browser?.lastFrame { show(frame.image, css: frame.css) }
            browser?.onFrame = { [weak self] image, css in self?.show(image, css: css) }
            browser?.onPointer = { [weak self] pointer in self?.showPointer(pointer) }
            showPointer(browser?.lastPointer)
            browser?.onPageEvent = { [weak self] event in self?.receive(event) }
            if window != nil { browser?.resize(to: bounds.size, scale: window?.backingScaleFactor ?? 2) }
        }
    }
    private var pageCursor = NSCursor.arrow
    /// The focused field in CSS pixels, where input-method candidates appear.
    private var fieldRect: CGRect?
    private var markedText = ""
    /// The key being interpreted, so plain typing keeps its key events for the page.
    private var typingEvent: NSEvent?
    private var menuSelectID: Int?
    private var cssSize = CGSize(width: 1280, height: 800)
    private var isViewing = false
    private var pressedButtons = 0
    /// Layer-hosting: a frame is a texture swap for the GPU, with no main-thread redraw.
    private let page: NSView = {
        let view = NSView()
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        view.layer = layer
        view.wantsLayer = true
        return view
    }()
    private let cursor = AgentCursorView()
    private var cursorGeneration = 0
    private var pointerPosition: CGPoint?

    override var isFlipped: Bool { true }

    /// Page, cursor and ripples are decoration; every event belongs to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    private func show(_ image: NSImage, css: CGSize) {
        page.layer?.contents = image
        if css != cssSize {
            cssSize = css
            page.frame = pageRect
            positionCursor()
        }
    }

    private func positionCursor() {
        guard let pointerPosition else { return }
        let point = viewRect(css: CGRect(origin: pointerPosition, size: .zero)).origin
        cursor.setFrameOrigin(CGPoint(x: point.x - AgentCursorView.tip.x, y: point.y - AgentCursorView.tip.y))
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Glides the Herm cursor to where Hermes pointed; nil fades it out.
    private func showPointer(_ pointer: AgentPointer?) {
        pointerPosition = pointer?.point
        cursorGeneration += 1
        let generation = cursorGeneration
        guard let pointer else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.3
                cursor.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.cursorGeneration == generation { self?.cursor.isHidden = true }
                }
            }
            return
        }
        let point = viewRect(css: CGRect(origin: pointer.point, size: .zero)).origin
        let origin = CGPoint(x: point.x - AgentCursorView.tip.x, y: point.y - AgentCursorView.tip.y)
        if cursor.isHidden {
            cursor.setFrameOrigin(origin)
            cursor.alphaValue = 0
            cursor.isHidden = false
            cursor.needsDisplay = true  // Picks up a theme change since it was last shown.
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : pointer.kind == .move ? 0.14 : 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cursor.animator().setFrameOrigin(origin)
            cursor.animator().alphaValue = 1
        }
        if pointer.kind == .down, !reduceMotion { ripple(at: point) }
    }

    /// A rect in viewport CSS pixels, in canvas coordinates.
    private func viewRect(css: CGRect) -> CGRect {
        let rect = pageRect
        let scale = CGSize(width: rect.width / cssSize.width, height: rect.height / cssSize.height)
        return CGRect(
            x: rect.minX + css.minX * scale.width, y: rect.minY + css.minY * scale.height,
            width: css.width * scale.width, height: css.height * scale.height)
    }

    private func receive(_ event: AgentPageEvent) {
        switch event {
        case .select(let id, let rect, let selected, let options):
            showMenu(select: id, at: viewRect(css: rect), selected: selected, options: options)
        case .cursor(let css):
            pageCursor = Self.cursor(css: css)
            window?.invalidateCursorRects(for: self)
            if let window, pageRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                pageCursor.set()
            }
        case .field(let rect):
            fieldRect = rect
        }
    }

    /// Chrome's own dropdown would open off-screen in headless mode; a native menu stands in.
    private func showMenu(select id: Int, at rect: CGRect, selected: Int, options: [AgentPageEvent.Option]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = rect.width
        var group: String?
        for (index, option) in options.enumerated() {
            if option.group != group, let header = option.group { menu.addItem(.sectionHeader(title: header)) }
            group = option.group
            let item = NSMenuItem(title: option.label, action: #selector(chooseOption(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = !option.disabled
            item.state = index == selected ? .on : .off
            item.indentationLevel = option.group == nil ? 0 : 1
            menu.addItem(item)
        }
        menuSelectID = id
        let current = menu.items.first { $0.action != nil && $0.tag == selected }
        menu.popUp(positioning: current, at: CGPoint(x: rect.minX, y: rect.minY), in: self)
        menuSelectID = nil
        // The menu swallowed the release of the click that opened it.
        if pressedButtons & 1 != 0 {
            pressedButtons &= ~1
            browser?.mouse(
                "mouseReleased", at: CGPoint(x: rect.midX, y: rect.midY), button: "left", clicks: 1, modifiers: 0)
        }
    }

    @objc private func chooseOption(_ item: NSMenuItem) {
        guard let id = menuSelectID else { return }
        browser?.chooseOption(select: id, index: item.tag)
    }

    /// The page's CSS cursor as the nearest system cursor.
    static func cursor(css: String) -> NSCursor {
        switch css {
        case "pointer": .pointingHand
        case "text": .iBeam
        case "vertical-text": .iBeamCursorForVerticalLayout
        case "crosshair": .crosshair
        case "not-allowed", "no-drop": .operationNotAllowed
        case "grab": .openHand
        case "grabbing", "move", "all-scroll": .closedHand
        case "col-resize", "ew-resize", "e-resize", "w-resize": .resizeLeftRight
        case "row-resize", "ns-resize", "n-resize", "s-resize": .resizeUpDown
        case "copy": .dragCopy
        case "alias": .dragLink
        case "context-menu": .contextualMenu
        default: .arrow
        }
    }

    override func resetCursorRects() {
        addCursorRect(pageRect, cursor: pageCursor)
    }

    private func ripple(at point: CGPoint) {
        let ripple = AgentClickRipple(frame: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        addSubview(ripple, positioned: .below, relativeTo: cursor)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ripple.animator().frame = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
            ripple.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { ripple.removeFromSuperview() }
        }
    }

    override func layout() {
        super.layout()
        page.frame = pageRect
        positionCursor()
    }
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
        wantsLayer = true
        addSubview(page)
        cursor.isHidden = true
        addSubview(cursor)
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        page.frame = pageRect
        positionCursor()
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
                browser?.editCommand("selectAll", key: "a", code: 65, modifiers: modifiers)
            case "c", "x":
                // Chrome's clipboard is its own in headless mode, so the copy comes back to yours.
                let cut = event.charactersIgnoringModifiers?.lowercased() == "x"
                Task { [weak browser] in
                    guard let browser, case let text = await browser.selectedText(), !text.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    if cut { browser.editCommand("delete", key: "x", code: 88, modifiers: modifiers) }
                }
            case "z":
                let redo = event.modifierFlags.contains(.shift)
                browser?.editCommand(redo ? "redo" : "undo", key: "z", code: 90, modifiers: modifiers)
            default:
                super.keyDown(with: event)
            }
            return
        }
        if !markedText.isEmpty {
            interpretKeyEvents([event])
        } else if let special = Self.specialKeys[event.keyCode] {
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
        } else if event.modifierFlags.contains(.control) {
            if let text = event.characters, !text.isEmpty { type(text, modifiers: modifiers) }
        } else {
            // Through the input method, so dead keys (⌥E E → é) and IMEs compose.
            typingEvent = event
            interpretKeyEvents([event])
            typingEvent = nil
        }
    }

    private func type(_ text: String, modifiers: Int) {
        browser?.key(["type": "keyDown", "text": text, "unmodifiedText": text, "key": text, "modifiers": modifiers])
        browser?.key(["type": "keyUp", "key": text, "modifiers": modifiers])
    }

    /// Keys the input method doesn't turn into text are already handled; don't beep.
    override func doCommand(by selector: Selector) {}
}

extension AgentBrowserCanvas: @preconcurrency NSTextInputClient {
    private static func plain(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? string as? String ?? ""
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plain(string)
        if markedText.isEmpty, let event = typingEvent {
            type(text, modifiers: Self.modifiers(event.modifierFlags))
        } else {
            markedText = ""
            browser?.insertText(text)  // Also commits any composition in the page.
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = Self.plain(string)
        browser?.compose(markedText, selection: selectedRange)
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        let text = markedText
        markedText = ""
        browser?.insertText(text)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange { NSRange(location: markedText.utf16.count, length: 0) }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Under the focused field, so candidate windows don't cover what you're typing.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect =
            fieldRect.map { viewRect(css: $0) } ?? CGRect(x: pageRect.midX, y: pageRect.midY, width: 0, height: 0)
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
}

/// Where Hermes is pointing: an accent arrow with a "Herm" tag, like a collaborator's cursor.
final class AgentCursorView: NSView {
    /// The arrow tip within the view; the canvas places this on the page point.
    static let tip = CGPoint(x: 2, y: 2)
    private static let label = "Herm"

    init() {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let width = (Self.label as NSString).size(withAttributes: [.font: font]).width
        super.init(frame: CGRect(x: 0, y: 0, width: 30 + width, height: 40))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(Color.dockAccent)
        let ink = NSColor(Color.dockOnAccentText)
        let arrow = NSBezierPath()
        arrow.move(to: Self.tip)
        arrow.line(to: CGPoint(x: 2, y: 19))
        arrow.line(to: CGPoint(x: 6.5, y: 14.5))
        arrow.line(to: CGPoint(x: 13.5, y: 14))
        arrow.close()
        arrow.lineJoinStyle = .round
        arrow.lineWidth = 1.5
        accent.setFill()
        arrow.fill()
        ink.setStroke()
        arrow.stroke()

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let size = (Self.label as NSString).size(withAttributes: [.font: font])
        let tag = CGRect(x: 12, y: 18, width: size.width + 12, height: size.height + 4)
        accent.setFill()
        NSBezierPath(roundedRect: tag, xRadius: tag.height / 2, yRadius: tag.height / 2).fill()
        (Self.label as NSString).draw(
            at: CGPoint(x: tag.minX + 6, y: tag.minY + 2), withAttributes: [.font: font, .foregroundColor: ink])
    }
}

/// The ring that spreads from a point Hermes clicked.
private final class AgentClickRipple: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        ring.lineWidth = 2
        NSColor(Color.dockAccent).setStroke()
        ring.stroke()
    }
}

private struct AgentCanvasView: NSViewRepresentable {
    let browser: AgentBrowser
    func makeNSView(context: Context) -> AgentBrowserCanvas {
        let canvas = AgentBrowserCanvas(frame: .zero)
        canvas.browser = browser
        return canvas
    }
    func updateNSView(_ nsView: AgentBrowserCanvas, context: Context) { nsView.browser = browser }
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
        .overlay {
            // Frames the page while it belongs to Hermes, so you can tell before you click.
            if step != nil, !browser.userHasControl {
                Rectangle()
                    .strokeBorder(Color.dockAccent.opacity(0.55), lineWidth: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
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
