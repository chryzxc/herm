import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A Hermes Desktop plugin's page inside Herm. Hermes owns the plugin; this hosts its
/// `plugin.js` in a web view with Hermes Desktop's own SDK, built into `Resources/DesktopPluginHost`.
struct DesktopPluginPage: View {
    let pluginID: String
    @ObservedObject var store: DesktopPluginStore
    let host: DesktopPluginBridge.Host
    @StateObject private var state = DesktopPluginPageState()

    private var plugin: HermesDesktopPlugin? { store.plugin(pluginID) }

    var body: some View {
        DockExpandedPage(
            title: plugin?.name ?? pluginID, subtitle: state.subtitle,
            onRefresh: plugin == nil ? nil : { state.reload() }, isRefreshing: state.phase == .loading,
            titleAccessory: AnyView(DesktopPluginBadge()), showsClose: false, close: {}, trailing: { EmptyView() }
        ) {
            ZStack {
                if let plugin, plugin.compatibility == .runsInHerm {
                    DesktopPluginWebView(plugin: plugin, host: host, state: state)
                        .id("\(plugin.id)-\(state.generation)")
                        .opacity(state.phase == .failed ? 0 : 1)
                }
                if let message = unavailableMessage {
                    VStack(spacing: 6) {
                        Text(message.title).dockFont(size: 12, weight: .semibold)
                            .foregroundStyle(Color.dockPrimaryText)
                        Text(message.detail).dockFont(size: 12)
                            .foregroundStyle(Color.dockSecondaryText)
                            .multilineTextAlignment(.center)
                        if state.phase == .failed {
                            Button("Reload") { state.reload() }.buttonStyle(.dockSecondary)
                        }
                    }
                    .dockButtonSize(.compact)
                    .frame(maxWidth: 360)
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await store.refresh() }
    }

    private var unavailableMessage: (title: String, detail: String)? {
        guard let plugin else {
            return ("Plugin not found", "This Desktop plugin is no longer installed for Hermes Agent.")
        }
        switch plugin.compatibility {
        case .runsInHerm:
            return state.phase == .failed ? ("This page stopped", state.failure ?? "The plugin did not load.") : nil
        case .needs(let names):
            return (
                "Needs a newer Herm",
                "This plugin uses \(names.joined(separator: ", ")), which this version of Herm does not include."
            )
        case .desktopOnly:
            return ("Desktop only", "This plugin adds no page, so there is nothing to open in Herm.")
        case .unknown:
            return ("Cannot check this plugin", "Herm could not read which Desktop features it uses.")
        case .hostMissing:
            return ("Plugin pages unavailable", "This build of Herm does not include the Desktop plugin host.")
        }
    }
}

@MainActor
final class DesktopPluginPageState: ObservableObject {
    enum Phase { case loading, ready, failed }
    @Published private(set) var phase = Phase.loading
    @Published private(set) var failure: String?
    @Published private(set) var notice: String?
    /// Bumped to rebuild the web view from scratch.
    @Published private(set) var generation = 0
    private var noticeTask: Task<Void, Never>?

    /// Short status lives in the header's subtitle slot so the page never jumps.
    var subtitle: String {
        if let notice { return notice }
        return phase == .loading ? "Loading plugin…" : ""
    }

    private var watchdog: Task<Void, Never>?

    func reload() {
        watchdog?.cancel()
        phase = .loading
        failure = nil
        generation += 1
    }

    /// A page that never reports ready or failed (a module that cannot even link) still ends
    /// in an honest failure instead of loading forever.
    func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.phase == .loading else { return }
            self.fail("The plugin did not start.")
        }
    }

    func ready() {
        watchdog?.cancel()
        phase = .ready
    }

    func fail(_ message: String) {
        watchdog?.cancel()
        failure = message
        phase = .failed
    }

    func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// Which file a `herm-plugin://` request may read: host runtime files from the app bundle, or
/// the plugin's own files under `/plugin/`, never anything outside either folder.
enum DesktopPluginFiles {
    static let scheme = "herm-plugin"

    /// The page's host name, one origin (and so one localStorage) per plugin. A plain lowercase id is
    /// used as is, which keeps existing pages' storage; any other id is spelled in hex so two ids
    /// that differ only in case or punctuation never share an origin. The dot cannot occur in a plain
    /// id, so the two spellings cannot collide either.
    static func origin(for id: String) -> String {
        let plain = !id.isEmpty && id.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
        return plain ? id : "x." + id.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(_ url: URL, hostRoot: URL, pluginRoot: URL) -> URL? {
        let path = url.path
        let (root, relative): (URL, String) =
            path.hasPrefix("/plugin/")
            ? (pluginRoot, String(path.dropFirst("/plugin/".count)))
            : (hostRoot, path == "/" || path.isEmpty ? "host.html" : String(path.dropFirst()))
        // realpath fails for missing files, so only existing files inside the root resolve.
        guard !relative.isEmpty, let base = realPath(root.path),
            let file = realPath(root.appendingPathComponent(relative).path), file.hasPrefix(base + "/")
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: file)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func mimeType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "html": "text/html"
        case "json": "application/json"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        default: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

/// Herm's skin in the same CSS variables a Hermes Desktop theme paints (`applyTheme` in Desktop's
/// `themes/context.tsx`): the color seeds Desktop derives its surfaces from, the shadcn tokens it
/// does not derive, the sans font, and the radius scale. Only variables, never selectors, so
/// Desktop's components restyle themselves and an unknown variable is simply ignored.
enum DesktopPluginTheme {
    static func variables() -> [String: String] {
        let accent = Color.dockAccent.cssValue
        let onAccent = Color.dockOnAccentText.cssValue
        let border = Color.dockBorder.cssValue
        var vars = [
            // Seeds
            "--theme-foreground": Color.dockPrimaryText.cssValue,
            "--theme-primary": accent,
            "--theme-warm": accent,
            "--theme-midground": accent,
            "--theme-secondary": Color.dockControlSurface.cssValue,
            "--theme-accent-soft": Color.dockAccentMuted.cssValue,
            "--theme-background-seed": Color.dockCanvas.cssValue,
            "--theme-sidebar-seed": Color.dockCanvas.cssValue,
            "--theme-card-seed": Color.dockSurface.cssValue,
            "--theme-elevated-seed": Color.dockSurface.cssValue,
            "--theme-bubble-seed": Color.dockUserMessageBubble.cssValue,
            // Tokens Desktop does not derive from the seeds
            "--dt-primary-foreground": onAccent,
            "--dt-primary-solid": accent,
            "--dt-primary-solid-foreground": onAccent,
            "--dt-midground-foreground": onAccent,
            "--dt-secondary-foreground": Color.dockPrimaryText.cssValue,
            "--dt-accent-foreground": Color.dockPrimaryText.cssValue,
            "--dt-muted": Color.dockControlSurface.cssValue,
            "--dt-border": border,
            "--dt-input": border,
            "--dt-sidebar-border": border,
            "--dt-user-bubble-border": border,
            "--dt-ring": accent,
            "--dt-composer-ring": accent,
            "--dt-destructive": Color.dockDestructive.cssValue,
            "--ui-success": Color.dockSuccess.cssValue,
            "--radius-scalar": radiusScalar(DockControlMetrics.cornerRadius),
        ]
        vars["--dt-font-sans"] = fontFamily(DockThemeStyle.current.fontDesign)
        return vars
    }

    /// Desktop's `rounded-md` is `--radius-scalar × 0.625rem` on a 16px root, so this makes it
    /// Herm's control radius.
    static func radiusScalar(_ controlRadius: CGFloat) -> String {
        String(format: "%.3f", max(0, controlRadius) / 10)
    }

    /// The skin's typeface as a WebKit system family; `nil` keeps Desktop's own sans stack.
    static func fontFamily(_ design: Font.Design) -> String? {
        switch design {
        case .rounded: "ui-rounded, system-ui, sans-serif"
        case .serif: "ui-serif, Georgia, serif"
        case .monospaced: "ui-monospace, Menlo, monospace"
        default: nil
        }
    }

    static var isDark: Bool {
        switch DockThemeRuntime.current.appearance {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}

struct DesktopPluginWebView: NSViewRepresentable {
    let plugin: HermesDesktopPlugin
    let host: DesktopPluginBridge.Host
    let state: DesktopPluginPageState

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: DesktopPluginBridge(pluginID: plugin.id, host: host), plugin: plugin, state: state)
    }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeWebView() }

    func updateNSView(_ web: WKWebView, context: Context) {
        // Reading the revision here re-runs this on every skin switch.
        context.coordinator.applyTheme(revision: DockThemeRuntime.revision, theme: DockThemeRuntime.current)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { coordinator.tearDown() }

    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate,
        WKUIDelegate
    {
        private let bridge: DesktopPluginBridge
        private let plugin: HermesDesktopPlugin
        private let state: DesktopPluginPageState
        private weak var web: WKWebView?
        private var themeKey: String?
        private var loaded = false
        /// A skin that follows the system has no revision bump when macOS switches light and dark.
        private var appearanceObservation: NSKeyValueObservation?
        private let hostRoot = Bundle.herm.resourceURL!.appendingPathComponent("DesktopPluginHost")
        private var pageURL: URL {
            URL(string: "\(DesktopPluginFiles.scheme)://\(DesktopPluginFiles.origin(for: plugin.id))/host.html")!
        }

        init(bridge: DesktopPluginBridge, plugin: HermesDesktopPlugin, state: DesktopPluginPageState) {
            self.bridge = bridge
            self.plugin = plugin
            self.state = state
        }

        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.setURLSchemeHandler(self, forURLScheme: DesktopPluginFiles.scheme)
            configuration.userContentController.add(self, name: "herm")
            let id =
                (try? JSONSerialization.data(withJSONObject: [plugin.id])).flatMap { String(data: $0, encoding: .utf8) }
                ?? "[]"
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: "window.__hermPluginID = \(id)[0]", injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
            let view = DesktopPluginWebKitView(frame: .zero, configuration: configuration)
            view.setValue(false, forKey: "drawsBackground")
            view.appearance = NSAppearance(named: DesktopPluginTheme.isDark ? .darkAqua : .aqua)
            // The page sits under the full-size title bar; WebKit would otherwise inset the content by the
            // overlap and show a band of body background above the plugin.
            // KVC finds the private `_set…:` setter from the bare key; an underscored key throws.
            if view.responds(to: NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")) {
                view.setValue(false, forKey: "automaticallyAdjustsContentInsets")
            }
            view.navigationDelegate = self
            view.uiDelegate = self
            web = view
            bridge.reply = { [weak self] id, ok, value in
                self?.call("window.__herm.reply(id, ok, value)", ["id": id, "ok": ok, "value": value])
            }
            bridge.push = { [weak self] event in self?.call("window.__herm.event(event)", ["event": event]) }
            bridge.onReady = { [weak self] in self?.state.ready() }
            bridge.onFailed = { [weak self] message in self?.state.fail(message) }
            bridge.onNotice = { [weak self] message, _ in self?.state.show(message) }
            bridge.start()
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in
                    self?.applyTheme(revision: DockThemeRuntime.revision, theme: DockThemeRuntime.current)
                }
            }
            view.load(URLRequest(url: pageURL))
            return view
        }

        func tearDown() {
            appearanceObservation?.invalidate()
            appearanceObservation = nil
            bridge.stop()
            web?.configuration.userContentController.removeScriptMessageHandler(forName: "herm")
            web?.stopLoading()
        }

        func applyTheme(revision: Int, theme: DockThemeID) {
            let key = "\(revision)-\(theme)-\(DesktopPluginTheme.isDark)"
            guard loaded, key != themeKey else { return }
            themeKey = key
            // Desktop resolves light/dark from the system appearance it is shown in.
            web?.appearance = NSAppearance(named: DesktopPluginTheme.isDark ? .darkAqua : .aqua)
            call("window.__herm.theme(vars)", ["vars": DesktopPluginTheme.variables()])
        }

        private func call(_ script: String, _ arguments: [String: Any]) {
            web?.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page, completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
            Task { await bridge.receive(text) }
        }

        /// Tasks WebKit has not stopped; replying to a stopped task raises an exception.
        private var activeTasks = Set<ObjectIdentifier>()

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
            let id = ObjectIdentifier(task)
            activeTasks.insert(id)
            let hostRoot = hostRoot
            let pluginRoot = plugin.entryURL.deletingLastPathComponent()
            Task {
                // Resolving and reading the runtime and plugin bundles stays off the main thread.
                let file = await Task.detached(priority: .userInitiated) { () -> (URL, Data)? in
                    guard let file = DesktopPluginFiles.resolve(url, hostRoot: hostRoot, pluginRoot: pluginRoot),
                        let data = try? Data(contentsOf: file)
                    else { return nil }
                    return (file, data)
                }.value
                guard activeTasks.remove(id) != nil else { return }
                guard let (path, data) = file else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": DesktopPluginFiles.mimeType(path), "Cache-Control": "no-store"])!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
            activeTasks.remove(ObjectIdentifier(task))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            state.armWatchdog()
            applyTheme(revision: DockThemeRuntime.revision, theme: DockThemeRuntime.current)
        }

        /// The page stays on its own origin; links leave for the browser.
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == DesktopPluginFiles.scheme { return decisionHandler(.allow) }
            if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme) {
                ExternalOpen.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme) { ExternalOpen.open(url) }
            return nil
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
        ) {
            state.fail("Herm could not start this plugin page.")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.fail("The plugin page stopped.")
        }
    }
}

extension Color {
    /// The colour as a CSS `rgba()` value in sRGB.
    var cssValue: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "inherit" }
        return
            "rgba(\(Int(rgb.redComponent * 255)),\(Int(rgb.greenComponent * 255)),\(Int(rgb.blueComponent * 255)),\(rgb.alphaComponent))"
    }
}

/// Herm's header already clears the title bar, so the web content starts at the view's top edge.
final class DesktopPluginWebKitView: WKWebView {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
}
