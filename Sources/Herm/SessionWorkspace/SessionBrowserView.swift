import SwiftUI
import WebKit

extension Notification.Name {
    static let hermOpenInBrowser = Notification.Name("hermOpenInBrowser")
}

/// Routes chat link clicks to the session inspector's Browser tab. Falls back
/// to the system browser when no window hosts an inspector.
@MainActor
enum InAppBrowser {
    /// Set synchronously by a host that received the open request.
    static var handled = false

    static func open(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return ExternalOpen.open(url) }
        handled = false
        NotificationCenter.default.post(name: .hermOpenInBrowser, object: url)
        if !handled { ExternalOpen.open(url) }
    }
}

/// Responsive-mode widths for the page.
enum BrowserViewport: Int, CaseIterable, Identifiable {
    case fit = 0, phone = 390, tablet = 768, desktop = 1280
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fit: "Fit Panel"
        case .phone: "Phone · 390"
        case .tablet: "Tablet · 768"
        case .desktop: "Desktop · 1280"
        }
    }
}

/// Annotate mode's payload (Resources/BrowserAnnotate.js) and how it lands in the composer.
struct BrowserAnnotation: Decodable {
    struct Rect: Decodable { let x, y, width, height: Double }
    let comment, url, title, selector, tag, text, html, styles: String
    let rect: Rect
    let scrollX, scrollY: Double

    /// @medv/finder (MIT, Resources/BrowserFinder.js) + the annotate script, one closure so
    /// finder's functions stay private to Herm's isolated world.
    static let script: String = {
        func load(_ name: String) -> String {
            Bundle.module.url(forResource: name, withExtension: "js")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        }
        let finder = load("BrowserFinder").replacingOccurrences(of: "export function", with: "function")
        return "(() => {\n\(finder)\n\(load("BrowserAnnotate"))\n})();"
    }()

    /// Herm's current palette as the annotate UI's CSS custom properties (a JSON object literal).
    @MainActor static var themeJSON: String {
        let palette = DockThemePalette(theme: DockThemeRuntime.current)
        func hex(_ color: Color) -> String {
            var value = "#888888"
            NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                value = String(format: "#%02X%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                               Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
            }
            return value
        }
        let tokens = ["accent": palette.accent, "on-accent": palette.onAccent, "surface": palette.surface,
                      "field": palette.background, "text": palette.primaryText, "muted": palette.secondaryText,
                      "border": palette.divider]
        return "{" + tokens.map { "\"\($0.key)\":\"\(hex($0.value))\"" }.joined(separator: ",") + "}"
    }

    /// Page-world hook for the WebKit tab; agent mode reads the console over CDP instead.
    static let consoleHook = """
    (() => {
      const h = window.webkit?.messageHandlers?.hermConsole; if (!h) return;
      const str = (a) => a instanceof Error ? (a.stack || String(a)) : typeof a === 'object' ? (() => { try { return JSON.stringify(a) } catch { return String(a) } })() : String(a);
      const send = (args) => { try { h.postMessage(args.map(str).join(' ').slice(0, 2000)) } catch {} };
      const error = console.error; console.error = function (...a) { send(a); return error.apply(this, a) };
      addEventListener('error', (e) => send([e.error || e.message]));
      addEventListener('unhandledrejection', (e) => send(['Unhandled rejection:', e.reason]));
    })();
    """

    var context: ChatContext {
        let host = URL(string: url)?.host() ?? url
        var lines = ["Browser annotation on \(url)" + (title.isEmpty ? ":" : " (\"\(title)\"):")]
        if !comment.isEmpty { lines.append("Requested change: \(comment)") }
        lines.append("Element: `\(selector)`")
        if !text.isEmpty { lines.append("Text: \"\(text)\"") }
        lines += ["Computed styles: \(styles)", "HTML:", "```html", html, "```"]
        let label = comment.isEmpty ? "\(tag) · \(host)" : String(comment.prefix(48))
        return ChatContext(id: "browser:\(UUID().uuidString)", title: label, body: lines.joined(separator: "\n"))
    }

    @MainActor
    static func deliver(_ context: ChatContext, image: NSImage?, to model: DockModel) {
        model.attachedContexts.append(context)
        if let image { model.stageImage(image) }
        model.requestComposerFocus()
    }
}

enum BrowserPageMessage {
    case annotation(BrowserAnnotation)
    case modeOff

    init?(json: String) {
        let data = Data(json.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "annotation":
            guard let annotation = try? JSONDecoder().decode(BrowserAnnotation.self, from: data) else { return nil }
            self = .annotation(annotation)
        case "mode": self = .modeOff
        default: return nil
        }
    }
}

/// In-panel browser. The primary tab is the shared agent browser Hermes drives (started
/// automatically); other tabs, or a failed agent start, use WebKit. Both support annotate,
/// send-page and console errors.
struct SessionBrowserView: View {
    @ObservedObject var model: DockModel
    let workspace: SessionBrowserWorkspace
    let isPrimary: Bool
    var discoveryActive = true
    @AppStorage("sessionInspector.browserViewport") private var viewportRaw = 0
    @ObservedObject private var browser: BrowserController
    @ObservedObject private var agent: AgentBrowser
    @State private var field = ""
    @FocusState private var isEditingAddress: Bool

    init(model: DockModel, workspace: SessionBrowserWorkspace, browser: BrowserController? = nil, discoveryActive: Bool = true) {
        self.discoveryActive = discoveryActive
        self.model = model
        self.workspace = workspace
        isPrimary = browser == nil
        let controller = browser ?? workspace.primary
        self.browser = controller
        agent = workspace.agent
        _field = State(initialValue: browser == nil && workspace.agent.isActive
            ? workspace.agent.activePage?.url ?? controller.address : controller.currentURL ?? controller.address)
    }

    private var showsAgent: Bool { isPrimary && agent.isActive }
    private var viewport: BrowserViewport { BrowserViewport(rawValue: viewportRaw) ?? .fit }
    private var palette: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    private var consoleErrors: [String] { showsAgent ? agent.consoleErrors : browser.consoleErrors }
    private var annotating: Bool { showsAgent ? agent.annotating : browser.annotating }

    /// The Browser tab fell back to WebKit: say so, since Hermes' browser tools are off too.
    private func offlineNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            DockStatusDot(tone: .attention, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent browser offline")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dockPrimaryText)
                Text("Hermes can't browse. \(message)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dockSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
            Spacer(minLength: 4)
            Button("Retry") { agent.start() }
                .buttonStyle(DockSecondaryButtonStyle())
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.dockWarning.opacity(0.08))
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(8)
                .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }

            if isPrimary, case .failed(let message) = agent.state { offlineNotice(message) }

            if showsAgent {
                AgentBrowserPane(browser: agent, model: model)
            } else {
                GeometryReader { geo in
                    BrowserWebView(web: browser.web)
                        .frame(width: viewport == .fit ? geo.size.width : min(geo.size.width, CGFloat(viewport.rawValue)))
                        .frame(maxWidth: .infinity)
                        .onAppear { browser.zoom(toFit: viewport.rawValue, in: geo.size.width) }
                        .onChange(of: geo.size.width) { _, width in browser.zoom(toFit: viewport.rawValue, in: width) }
                        .onChange(of: viewportRaw) { _, raw in browser.zoom(toFit: raw, in: geo.size.width) }
                }
            }
        }
        .onAppear {
            browser.model = model
            if browser.currentURL == nil, browser.address.isEmpty || browser.address == "about:blank",
               let restored = WorkspacePresentationStore.shared.load(WorkspaceIdentity.session(model))?.browserURL {
                browser.address = restored
            }
            field = pageURL.isEmpty ? browser.address : pageURL
            guard isPrimary else { return }
            agent.model = model
            agent.presetWidth = viewportRaw
            if !agent.isActive { agent.start() }  // opening the tab retries a failed browser
            if !showsAgent { browser.loadAddressIfNeeded() }
        }
        .onReceive(browser.$currentURL) { url in
            guard let url, !showsAgent else { return }
            if !isEditingAddress { field = url }
            browser.address = url
            let key = WorkspaceIdentity.session(model)
            var presentation = WorkspacePresentationStore.shared.load(key) ?? InspectorPresentation()
            presentation.browserURL = WorkspacePresentationStore.restorableBrowserURL(url)
            WorkspacePresentationStore.shared.save(presentation, identity: key)
        }
        .onChange(of: agent.activePage, initial: true) { _, page in
            guard showsAgent, let url = page?.url else { return }
            if !isEditingAddress { field = url }  // never clobber what you're typing
            if url != "about:blank" { browser.address = url }
        }
        .onChange(of: viewportRaw) { _, raw in if isPrimary { agent.presetWidth = raw } }
        .onChange(of: showsAgent) { _, agentMode in
            field = agentMode ? agent.activePage?.url ?? "" : browser.currentURL ?? ""
            // Agent browser failed to start: carry on in WebKit.
            if !agentMode { browser.loadAddressIfNeeded() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            DockIconButton(icon: .arrowLeft, label: "Back", style: palette) {
                if showsAgent { agent.goBack() } else { browser.web.goBack() }
            }
            .disabled(!showsAgent && !browser.canGoBack)
            DockIconButton(icon: .arrowRight, label: "Forward", style: palette) {
                if showsAgent { agent.goForward() } else { browser.web.goForward() }
            }
            .disabled(!showsAgent && !browser.canGoForward)
            DockIconButton(icon: .arrowClockwise, label: "Reload", style: palette) {
                if showsAgent { agent.reload() } else { browser.web.reload() }
            }
            TextField(showsAgent ? "Agent browser address" : "Search or enter address", text: $field)
                .textFieldStyle(.dockGlass)
                .frame(minWidth: 80)
                .focused($isEditingAddress)
                .onSubmit { go(field); isEditingAddress = false }
            DockIconButton(icon: .cursorClick, label: annotating ? "Stop Annotating (Esc)" : "Annotate: click an element to comment on it",
                           isProminent: annotating, style: palette) {
                if showsAgent { agent.annotating.toggle() } else { browser.annotating.toggle() }
            }
            LocalServersMenu(processIDs: TerminalWorkspaceStore.shared.processIDs(matching:
                WorkspaceIdentity.session(model)), active: discoveryActive)
            moreMenu
        }
    }

    private var moreMenu: some View {
        DockMenu {
            Button("Send Page to Chat", icon: .paperPlaneTilt) { Task { await sendPage() } }
            Button(consoleErrors.isEmpty ? "No Console Errors" : "Send \(consoleErrors.count) Console Errors", icon: .bugBeetle) {
                sendConsole()
            }
            .disabled(consoleErrors.isEmpty)
            DockMenuSection("Viewport") {
                ForEach(BrowserViewport.allCases) { option in
                    Button { viewportRaw = option.rawValue } label: {
                        if option == viewport { Label(option.title, icon: .check) } else { Text(option.title) }
                    }
                }
            }
            if showsAgent, agent.pages.count > 1 {
                DockMenuSection("Agent Tabs") {
                    ForEach(agent.pages) { page in
                        Button { agent.select(page) } label: {
                            let title = page.title.isEmpty ? page.url : page.title
                            if page.id == agent.activeTargetID { Label(title, icon: .check) } else { Text(title) }
                        }
                    }
                }
            }
        } label: {
            DockIcon(.dotsThree)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(consoleErrors.isEmpty ? Color.dockSecondaryText : Color.dockWarning)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .help(consoleErrors.isEmpty ? "More browser actions" : "\(consoleErrors.count) console errors")
    }

    private var pageURL: String { showsAgent ? agent.activePage?.url ?? "" : browser.web.url?.absoluteString ?? "" }
    private var pageTitle: String { showsAgent ? agent.activePage?.title ?? "" : browser.web.title ?? "" }

    private func sendPage() async {
        let url = pageURL
        guard !url.isEmpty else { return }
        let selection = showsAgent ? await agent.selection() : await browser.selection()
        guard model.browserSessionKey == workspace.key else { return }
        var body = "Regarding the page \(url)" + (pageTitle.isEmpty ? "" : " (\"\(pageTitle)\")")
        if !selection.isEmpty { body += "\nSelected text:\n> " + selection.replacingOccurrences(of: "\n", with: "\n> ") }
        let title = pageTitle.isEmpty ? (URL(string: url)?.host() ?? url) : pageTitle
        BrowserAnnotation.deliver(ChatContext(id: "browser-page:\(url)", title: title, body: body), image: nil, to: model)
    }

    private func sendConsole() {
        let errors = consoleErrors
        guard !errors.isEmpty else { return }
        let body = "Console errors on \(pageURL):\n```\n\(errors.joined(separator: "\n"))\n```"
        BrowserAnnotation.deliver(ChatContext(id: "browser-console:\(UUID().uuidString)", title: "\(errors.count) console errors",
                                              body: body), image: nil, to: model)
    }

    private func open(_ url: URL) {
        if isPrimary { workspace.open(url) } else { browser.open(url) }
        field = url.absoluteString
    }

    private func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hasHost = trimmed.contains(".") && !trimmed.contains(" ")
        let raw = trimmed.contains("://") ? trimmed
            : hasHost ? "https://\(trimmed)"
            : "https://www.google.com/search?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)"
        if let url = URL(string: raw) { open(url) }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle back to the controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserController?
    init(_ target: BrowserController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.received(message) }
    }
}

@MainActor
final class BrowserController: NSObject, ObservableObject, Identifiable, WKNavigationDelegate {
    let id = UUID()
    let key: SessionBrowserKey
    let web: WKWebView
    var address = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: String?
    @Published var consoleErrors: [String] = []
    @Published var annotating = false { didSet { if annotating != oldValue { applyAnnotating() } } }
    weak var model: DockModel?

    init(key: SessionBrowserKey, dataStore: WKWebsiteDataStore) {
        self.key = key
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // WKWebView's default UA has no Safari token, so sites like Google serve their no-JS page.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"  // ponytail: fixed version, bump if sites start sniffing it
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let content = configuration.userContentController
        let handler = WeakMessageHandler(self)
        // Annotate runs in Herm's own content world: the page can't call its handler.
        content.addUserScript(WKUserScript(source: BrowserAnnotation.script, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: .defaultClient))
        content.add(handler, contentWorld: .defaultClient, name: "hermAnnotate")
        content.addUserScript(WKUserScript(source: BrowserAnnotation.consoleHook, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: .page))
        content.add(handler, contentWorld: .page, name: "hermConsole")
        web.navigationDelegate = self
    }

    func open(_ url: URL) {
        address = url.absoluteString
        web.load(URLRequest(url: url))
    }

    func loadAddressIfNeeded() {
        guard !address.isEmpty, let url = URL(string: address), web.url == nil || currentURL != address else { return }
        open(url)
    }

    /// Responsive presets wider than the panel zoom out so the page lays out at that width.
    func zoom(toFit width: Int, in available: CGFloat) {
        web.pageZoom = width > 0 && available > 0 ? min(1, available / CGFloat(width)) : 1
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        consoleErrors = []
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url { address = url.absoluteString }
        currentURL = webView.url?.absoluteString
        applyAnnotating()
    }

    func received(_ message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        if message.name == "hermConsole" {
            consoleErrors = Array((consoleErrors + [String(body.prefix(2000))]).suffix(50))
            return
        }
        guard message.name == "hermAnnotate", message.frameInfo.isMainFrame else { return }
        switch BrowserPageMessage(json: body) {
        case .modeOff:
            annotating = false
        case .annotation(let annotation):
            Task {
                let image = await snapshot(annotation.rect)
                evaluate("window.__hermAnnotate?.done()")
                if let model, model.browserSessionKey == key { BrowserAnnotation.deliver(annotation.context, image: image, to: model) }
            }
        case nil:
            break
        }
    }

    func selection() async -> String {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript("window.__hermAnnotate?.selection() ?? ''", in: nil, in: .defaultClient) { result in
                continuation.resume(returning: (try? result.get()) as? String ?? "")
            }
        }
    }

    private func snapshot(_ rect: BrowserAnnotation.Rect) async -> NSImage? {
        let zoom = web.pageZoom
        let area = CGRect(x: rect.x * zoom, y: rect.y * zoom, width: rect.width * zoom, height: rect.height * zoom)
            .intersection(web.bounds)
        guard !area.isNull, area.width >= 2, area.height >= 2 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = area
        return try? await web.takeSnapshot(configuration: configuration)
    }

    private func applyAnnotating() {
        evaluate("window.__hermAnnotate?.setEnabled(\(annotating), \(BrowserAnnotation.themeJSON))")
    }

    private func evaluate(_ script: String) {
        web.evaluateJavaScript(script, in: nil, in: .defaultClient, completionHandler: nil)
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
