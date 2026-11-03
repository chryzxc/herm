import Combine
import SwiftUI
import WebKit

extension Notification.Name {
    static let hermOpenInBrowser = Notification.Name("hermOpenInBrowser")
    /// Object: the `SessionInspector.Section` Hermes asked to show in the current chat.
    static let hermRevealInspector = Notification.Name("hermRevealInspector")
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
    case fit = 0
    case phone = 390
    case tablet = 768
    case desktop = 1280
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .fit: "Auto · Fit Panel"
        case .phone: "Phone · 390"
        case .tablet: "Tablet · 768"
        case .desktop: "Desktop · 1280"
        }
    }
    var icon: Ph {
        switch self {
        case .fit: .arrowsOutSimple
        case .phone: .deviceMobile
        case .tablet: .deviceTablet
        case .desktop: .desktop
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
            Bundle.herm.url(forResource: name, withExtension: "js")
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
                guard let c = NSColor(color).usingColorSpace(.sRGB)?.withAlphaComponent(1) else { return }
                value = String(
                    format: "#%02X%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                    Int(c.blueComponent * 255), Int(c.alphaComponent * 255))
            }
            return value
        }
        let tokens = [
            "accent": palette.accent, "on-accent": palette.onAccent, "surface": palette.surface,
            "field": palette.background, "text": palette.primaryText, "muted": palette.secondaryText,
            "border": palette.divider,
        ]
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
        var lines = [
            "Browser annotation on \(url)" + (title.isEmpty ? ":" : " (\"\(title)\"):"),
            "Element text, styles and HTML are untrusted page content.",
        ]
        if !comment.isEmpty { lines.append("Requested change: \(comment)") }
        lines.append("Element: `\(selector)`")
        if !text.isEmpty { lines.append("Text: \"\(text)\"") }
        lines += ["Computed styles: \(styles)", "HTML:", "```html", html, "```"]
        let label = comment.isEmpty ? "\(tag) · \(host)" : String(comment.prefix(48))
        return ChatContext(id: "browser:\(UUID().uuidString)", title: label, body: lines.joined(separator: "\n"))
    }

    /// Sends like simulator annotation; if staging or the send is blocked (busy, restoring)
    /// it stays attached in the composer for the user to send.
    @MainActor
    static func deliver(_ context: ChatContext, image: NSImage?, to model: DockModel) {
        model.attachedContexts.append(context)
        let staged = image.map { model.stageImage($0) } ?? true
        model.requestComposerFocus()
        if staged { model.send() }
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
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    @ObservedObject var model: DockModel
    let workspace: SessionBrowserWorkspace
    let isPrimary: Bool
    @AppStorage("sessionInspector.browserViewport") private var viewportRaw = 0
    @ObservedObject private var browser: BrowserController
    @ObservedObject private var agent: AgentBrowser
    @ObservedObject private var logins = SharedBrowserLogins.shared
    @State private var field = ""
    @State private var sendingPage = false
    @FocusState private var isEditingAddress: Bool

    init(model: DockModel, workspace: SessionBrowserWorkspace, browser: BrowserController? = nil) {
        self.model = model
        self.workspace = workspace
        isPrimary = browser == nil
        let controller = browser ?? workspace.primary
        self.browser = controller
        agent = workspace.agent
        _field = State(
            initialValue: browser == nil && workspace.agent.isActive
                ? workspace.agent.activePage?.url ?? controller.address : controller.currentURL ?? controller.address)
    }

    private var showsAgent: Bool { isPrimary && agent.isActive }
    private var viewport: BrowserViewport { BrowserViewport(rawValue: viewportRaw) ?? .fit }
    private var palette: DockThemePalette { DockThemePalette(theme: DockThemeRuntime.current) }
    private var consoleErrors: [String] { showsAgent ? agent.consoleErrors : browser.consoleErrors }
    private var annotating: Bool { showsAgent ? agent.annotating : browser.annotating }
    private var navigation: BrowserNavigationState { showsAgent ? agent.navigation : browser.navigation }
    private var controlHeight: CGFloat { DockWorkspaceScale.points(28, scale: workspaceScale) }

    /// The Browser tab fell back to WebKit: say so, since Hermes' browser tools are off too.
    private func offlineNotice(_ message: String) -> some View {
        HStack(spacing: 8) {
            DockStatusDot(tone: .attention, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent browser offline")
                    .dockFont(.body, weight: .semibold)
                    .foregroundStyle(Color.dockPrimaryText)
                Text("Herm can't browse. \(message)")
                    .dockFont(.metadata)
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
        .dockPadding(.horizontal, 10)
        .dockPadding(.vertical, 6)
        .background(Color.dockWarning.opacity(0.08))
        .background(Color.dockOpaqueCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .dockPadding(.horizontal, DockSpacing.inspectorInset)
                .dockPadding(.vertical, 8)
                .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
                .overlay(alignment: .bottom) {
                    if navigation.isLoading { DockShimmerTrack(tone: .working, muted: true) }
                }

            if let error = navigation.error {
                navigationFailure(error)
            } else if isPrimary, case .failed(let message) = agent.state {
                offlineNotice(message)
            }

            pageContent
                .overlay(alignment: .top) {
                    if isPrimary, agent.handoffFailed {
                        HStack(spacing: 8) {
                            DockStatusDot(tone: .attention, size: 7)
                            Text("Hermes couldn't connect to this browser. Check the Hermes connection, then retry.")
                                .dockFont(.metadata)
                                .foregroundStyle(Color.dockSecondaryText)
                            Spacer(minLength: 4)
                            Button("Retry") { agent.reconnectHermes() }
                                .buttonStyle(DockSecondaryButtonStyle())
                        }
                        .dockPadding(.horizontal, 10)
                        .dockPadding(.vertical, 6)
                        .background(Color.dockOpaqueCanvas)
                    }
                }
        }
        .task { await logins.prepare() }
        .background {
            Button("Focus browser address") { isEditingAddress = true }
                .keyboardShortcut("l", modifiers: .command).hidden().accessibilityHidden(true)
            Button("Reload page") { reload() }
                .keyboardShortcut("r", modifiers: .command).hidden().accessibilityHidden(true)
        }
        .onAppear {
            browser.model = model
            if browser.currentURL == nil, browser.address.isEmpty || browser.address == "about:blank",
                let restored = WorkspacePresentationStore.shared.load(WorkspaceIdentity.session(model))?.browserURL
            {
                browser.address = restored
            }
            field = displayAddress(pageURL.isEmpty ? browser.address : pageURL)
            guard isPrimary else { return }
            agent.model = model
            agent.presetWidth = viewportRaw
            if !agent.isActive { agent.start() }  // opening the tab retries a failed browser
            if !showsAgent { browser.loadAddressIfNeeded() }
        }
        .onReceive(browser.$currentURL) { url in
            guard let url, !showsAgent else { return }
            if !isEditingAddress { field = displayAddress(url) }
            browser.address = url
            let key = WorkspaceIdentity.session(model)
            var presentation = WorkspacePresentationStore.shared.load(key) ?? InspectorPresentation()
            presentation.browserURL = WorkspacePresentationStore.restorableBrowserURL(url)
            WorkspacePresentationStore.shared.save(presentation, identity: key)
        }
        .onChange(of: agent.activePage, initial: true) { _, page in
            guard showsAgent, let url = page?.url else { return }
            if !isEditingAddress { field = displayAddress(url) }  // never clobber what you're typing
            if url != "about:blank" { browser.address = url }
        }
        .onChange(of: viewportRaw) { _, raw in if isPrimary { agent.presetWidth = raw } }
        .onChange(of: showsAgent) { _, agentMode in
            field = displayAddress(agentMode ? agent.activePage?.url ?? "" : browser.currentURL ?? browser.address)
            // Agent browser failed to start: carry on in WebKit.
            if !agentMode { browser.loadAddressIfNeeded() }
        }
    }

    var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                navigationButtons
                addressField.frame(minWidth: 180)
                annotationButton
                attachPageButton(compact: false)
                viewportMenu(compact: false)
                moreMenu
            }
            HStack(spacing: 6) {
                navigationButtons
                addressField.frame(minWidth: 220)
                annotationButton
                attachPageButton(compact: false)
                viewportMenu(compact: true)
                moreMenu
            }
            VStack(spacing: 8) {
                addressField
                HStack(spacing: 6) {
                    navigationButtons
                    Spacer(minLength: 8)
                    annotationButton
                    attachPageButton(compact: true)
                    viewportMenu(compact: true)
                    moreMenu
                }
            }
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 4) {
            DockIconButton(icon: .arrowLeft, label: "Back", style: palette) {
                if showsAgent { agent.goBack() } else { browser.web.goBack() }
            }.disabled(!navigation.canGoBack)
            DockIconButton(icon: .arrowRight, label: "Forward", style: palette) {
                if showsAgent { agent.goForward() } else { browser.web.goForward() }
            }.disabled(!navigation.canGoForward)
            DockIconButton(
                icon: navigation.isLoading ? .x : .arrowClockwise,
                label: navigation.isLoading ? "Stop loading" : "Reload page (⌘R)", style: palette
            ) {
                if navigation.isLoading {
                    if showsAgent { agent.stopLoading() } else { browser.stopLoading() }
                } else {
                    reload()
                }
            }
        }
    }

    private var addressField: some View {
        TextField("Search or enter address", text: $field)
            .textFieldStyle(DockGlassTextFieldStyle(compact: true, trailingInset: 20))
            .focused($isEditingAddress)
            .onSubmit {
                go(field)
                isEditingAddress = false
            }
            .onExitCommand {
                field = displayAddress(pageURL)
                isEditingAddress = false
            }
            .accessibilityLabel("Browser address")
            .help(navigation.isLoading ? "Loading page…" : "Search or enter address (⌘L)")
            .overlay(alignment: .trailing) {
                if navigation.isLoading, !isEditingAddress {
                    ProgressView().controlSize(.mini).dockPadding(.trailing, 8)
                        .accessibilityLabel("Loading page")
                        .allowsHitTesting(false)
                }
            }
    }

    private func attachPageButton(compact: Bool) -> some View {
        Button {
            Task { await sendPage() }
        } label: {
            HStack(spacing: 4) {
                if sendingPage { ProgressView().controlSize(.mini) }
                Text(compact ? "Attach" : "Attach Page").fixedSize()
            }
        }
        .buttonStyle(.dockCompact)
        .disabled(sendingPage || pageURL.isEmpty || pageURL == "about:blank")
        .help("Attach this page and selected text to the session composer without sending")
        .accessibilityLabel("Attach page to chat")
    }

    private var annotationButton: some View {
        DockIconButton(
            icon: .cursorClick,
            label: annotating ? "Stop Annotating (Esc)" : "Annotate: click an element to comment on it",
            isProminent: annotating, style: palette
        ) {
            toggleAnnotation()
        }
        .disabled(pageURL.isEmpty || pageURL == "about:blank")
    }

    private func viewportMenu(compact: Bool) -> some View {
        DockMenu {
            DockMenuSection("Responsive viewport") {
                ForEach(BrowserViewport.allCases) { option in
                    DockMenuCheckRow(title: option.title, isSelected: option == viewport) {
                        viewportRaw = option.rawValue
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                DockIcon(viewport.icon, size: 14)
                if !compact {
                    Text(viewport == .fit ? "Auto" : "\(viewport.rawValue)").dockFont(.control)
                    DockIcon(.caretDown, size: 10)
                }
            }
            .foregroundStyle(Color.dockPrimaryText)
            .dockPadding(.horizontal, compact ? 0 : 8)
            .frame(minWidth: controlHeight, minHeight: controlHeight)
            .background(DockThemeShape(cornerRadius: 7).fill(Color.dockControlSurface))
        }
        .fixedSize()
        .help(viewport == .fit ? "Auto: page follows the panel width" : "\(viewport.title): fixed preview width")
        .accessibilityLabel("Viewport: \(viewport.title)")
    }

    private func toggleAnnotation() {
        if showsAgent { agent.annotating.toggle() } else { browser.annotating.toggle() }
    }

    private var moreMenu: some View {
        DockMenu {
            Button("Copy Address", icon: .copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pageURL, forType: .string)
            }.disabled(pageURL.isEmpty || pageURL == "about:blank")
            Button("Open in Default Browser", icon: .arrowSquareOut) {
                if let url = URL(string: pageURL) { ExternalOpen.open(url) }
            }.disabled(!["http", "https"].contains(URL(string: pageURL)?.scheme?.lowercased() ?? ""))
            Button(
                consoleErrors.isEmpty ? "No Console Errors" : "Send \(consoleErrors.count) Console Errors",
                icon: .bugBeetle
            ) {
                sendConsole()
            }
            .disabled(consoleErrors.isEmpty)
            if showsAgent, let site = BrowserCookieJar.site(of: pageURL) {
                DockMenuCheckRow(title: "Share Sign-In for \(site)", isSelected: logins.jar.sites.contains(site)) {
                    agent.toggleSharing(site)
                }
                .help("Let every session's agent browser use this site's sign-in")
                .disabled(!logins.isPrepared)
            }
            if !logins.jar.sites.isEmpty {
                DockMenu("Shared Sign-Ins", icon: .users) {
                    ForEach(logins.jar.sites.sorted(), id: \.self) { site in
                        Button("Stop Sharing \(site)", icon: .x) { logins.stopSharing(site) }
                    }
                }
            }
            if !logins.isPrepared {
                Button("Retry Shared Sign-Ins", icon: .arrowClockwise) { Task { await logins.prepare() } }
            }
            Button("Sign Out of All Sites", icon: .signOut) { SharedBrowserLogins.shared.clear() }
                .disabled(!logins.isPrepared)
                .help("Clear the cookies every session's browser shares")
            if showsAgent {
                DockMenuSection("Agent Tabs") {
                    ForEach(agent.pages) { page in
                        Button {
                            agent.select(page)
                        } label: {
                            let title = page.title.isEmpty ? page.url : page.title
                            if page.id == agent.activeTargetID { Label(title, icon: .check) } else { Text(title) }
                        }
                    }
                }
            }
        } label: {
            DockIcon(.dotsThree)
                .opacity(sendingPage ? 0 : 1)
                .overlay {
                    if sendingPage { ProgressView().controlSize(.mini).accessibilityLabel("Adding page to chat") }
                }
                .dockFont(.conversation, weight: .medium)
                .foregroundStyle(consoleErrors.isEmpty ? Color.dockSecondaryText : Color.dockWarning)
                .frame(width: controlHeight, height: controlHeight)
                .background(DockThemeShape(cornerRadius: 7).fill(Color.dockControlSurface))
                .contentShape(Rectangle())
        }
        .help(consoleErrors.isEmpty ? "More browser actions" : "\(consoleErrors.count) console errors")
        .accessibilityLabel(
            consoleErrors.isEmpty
                ? "More browser actions" : "More browser actions, \(consoleErrors.count) console errors")
    }

    @ViewBuilder private var pageContent: some View {
        ZStack {
            if showsAgent {
                AgentBrowserPane(browser: agent, model: model)
            } else {
                BrowserWebView(web: browser.web, viewport: viewport)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if pageURL.isEmpty || pageURL == "about:blank", !navigation.isLoading,
                !showsAgent || agent.state == .running
            {
                VStack(spacing: 8) {
                    DockIcon(.globe, size: 24, color: Color.dockSecondaryText)
                    Text("Open a page").dockFont(.body, weight: .semibold)
                    Text("Enter a URL or search from the address bar.")
                        .dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                        .multilineTextAlignment(.center)
                    Button("Enter Address") { isEditingAddress = true }.buttonStyle(.dockSecondary)
                }.dockPadding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.dockCanvas)
            }
        }
        .background(Color.dockCanvas)
    }

    private func navigationFailure(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DockIcon(.warningCircle, size: 14, color: Color.dockWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t load page").dockFont(.body, weight: .semibold)
                Text(message).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Retry") { go(field.isEmpty ? pageURL : field) }.buttonStyle(.dockCompact)
            DockIconButton(icon: .x, label: "Dismiss navigation error", size: 24, style: palette) {
                if showsAgent { agent.clearNavigationError() } else { browser.clearNavigationError() }
            }
        }
        .dockPadding(10).background(Color.dockOpaqueCanvas)
        .overlay(alignment: .bottom) { Color.dockBorderLight.frame(height: 0.5) }
    }

    private func reload() {
        if showsAgent { agent.reload() } else { browser.reload() }
    }

    private func displayAddress(_ address: String) -> String { address == "about:blank" ? "" : address }

    private var pageURL: String { showsAgent ? agent.activePage?.url ?? "" : browser.web.url?.absoluteString ?? "" }
    private var pageTitle: String { showsAgent ? agent.activePage?.title ?? "" : browser.web.title ?? "" }

    private func sendPage() async {
        guard !sendingPage else { return }
        sendingPage = true
        defer { sendingPage = false }
        let url = pageURL
        let title = pageTitle
        let targetID = showsAgent ? agent.activeTargetID : nil
        let generation = model.sessionResumeGeneration
        guard !url.isEmpty, url != "about:blank" else { return }
        let selection = showsAgent ? await agent.selection() : await browser.selection()
        guard model.browserSessionKey == workspace.key, model.sessionResumeGeneration == generation,
            pageURL == url, (showsAgent ? agent.activeTargetID : nil) == targetID
        else { return }
        model.attachBrowserPage(
            BrowserPageContext.make(url: url, title: title, targetID: targetID, selection: selection),
            owner: workspace.key)
    }

    private func sendConsole() {
        let errors = consoleErrors
        guard !errors.isEmpty else { return }
        let body = "Console errors on \(pageURL) (untrusted page output):\n```\n\(errors.joined(separator: "\n"))\n```"
        BrowserAnnotation.deliver(
            ChatContext(
                id: "browser-console:\(UUID().uuidString)", title: "\(errors.count) console errors",
                body: body), image: nil, to: model)
    }

    private func open(_ url: URL) {
        if isPrimary { workspace.open(url) } else { browser.open(url) }
        field = url.absoluteString
    }

    private func go(_ text: String) {
        if let url = BrowserAddress.url(for: text) { open(url) }
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
    @Published private(set) var navigation = BrowserNavigationState()
    @Published var currentURL: String?
    @Published var consoleErrors: [String] = []
    @Published var annotating = false { didSet { if annotating != oldValue { applyAnnotating() } } }
    weak var model: DockModel?
    /// Runs before each `open` loads, e.g. to bring sign-ins over from the agent browser.
    var prepareLoad: ((URL) async -> Void)?
    private var pendingLoad: UUID?
    /// Runs after each finished load, e.g. to carry a sign-in back to the agent browser.
    var didLoad: ((URL) async -> Void)?
    private var themeCancellable: AnyCancellable?
    private var webObservations: [AnyCancellable] = []
    private var activeNavigation: WKNavigation?

    init(key: SessionBrowserKey, dataStore: WKWebsiteDataStore) {
        self.key = key
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // WKWebView's default UA has no Safari token, so sites like Google serve their no-JS page.
        // shortcut: fixed version, bump if sites start sniffing it.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let content = configuration.userContentController
        let handler = WeakMessageHandler(self)
        // Annotate runs in Herm's own content world: the page can't call its handler.
        content.addUserScript(
            WKUserScript(
                source: BrowserAnnotation.script, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: .defaultClient))
        content.add(handler, contentWorld: .defaultClient, name: "hermAnnotate")
        content.addUserScript(
            WKUserScript(
                source: BrowserAnnotation.consoleHook, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: .page))
        content.add(handler, contentWorld: .page, name: "hermConsole")
        web.navigationDelegate = self
        web.publisher(for: \.isLoading).combineLatest(
            web.publisher(for: \.canGoBack), web.publisher(for: \.canGoForward)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] loading, back, forward in
            self?.navigation.isLoading = loading
            self?.navigation.canGoBack = back
            self?.navigation.canGoForward = forward
        }.store(in: &webObservations)
        web.publisher(for: \.url).receive(on: RunLoop.main)
            .sink { [weak self] url in
                guard let self, let url else { return }
                address = url.absoluteString
                currentURL = url.absoluteString
            }.store(in: &webObservations)
        themeCancellable = DockThemeStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyAnnotating() }
    }

    func open(_ url: URL) {
        address = url.absoluteString
        navigation.start()
        guard let prepareLoad else { return load(url) }
        let token = UUID()
        pendingLoad = token
        Task { [weak self] in
            await prepareLoad(url)
            self?.finishLoad(url, token: token)
        }
        // A stalled agent browser must not hold the tab: load without its sign-ins.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.finishLoad(url, token: token)
        }
    }

    private func finishLoad(_ url: URL, token: UUID) {
        guard pendingLoad == token else { return }
        pendingLoad = nil
        load(url)
    }

    private func load(_ url: URL) {
        guard SSHPortForwards.remotePort(for: url, backend: GatewayConnectionStore.backendSettings) != nil else {
            activeNavigation = web.load(URLRequest(url: url))
            return
        }
        Task { [weak self] in
            let failure = await SSHPortForwards.shared.prepare(url)
            guard let self, self.address == url.absoluteString else { return }
            if let failure { return self.navigation.fail(failure) }
            self.activeNavigation = self.web.load(URLRequest(url: url))
        }
    }

    func reload() {
        if navigation.error != nil, let url = URL(string: address), !address.isEmpty { return open(url) }
        activeNavigation = web.reload()
        if activeNavigation != nil { navigation.start() }
    }

    func stopLoading() {
        web.stopLoading()
        activeNavigation = nil
        navigation.finish()
    }

    func clearNavigationError() { navigation.error = nil }

    func loadAddressIfNeeded() {
        guard !address.isEmpty, let url = URL(string: address), web.url == nil || currentURL != address else { return }
        open(url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        consoleErrors = []
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activeNavigation = navigation
        self.navigation.start()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard activeNavigation == nil || activeNavigation === navigation else { return }
        self.navigation.finish()
        self.navigation.canGoBack = webView.canGoBack
        self.navigation.canGoForward = webView.canGoForward
        if let url = webView.url { address = url.absoluteString }
        currentURL = webView.url?.absoluteString
        applyAnnotating()
        if let didLoad, let url = webView.url { Task { await didLoad(url) } }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error: error)
    }

    private func failed(_ navigation: WKNavigation?, error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
            activeNavigation == nil || activeNavigation === navigation
        else { return }
        self.navigation.fail(HermesDiagnosticsService.safeSummary(error.localizedDescription))
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
                if let model, model.browserSessionKey == key {
                    BrowserAnnotation.deliver(annotation.context, image: image, to: model)
                }
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

struct BrowserWebView: NSViewRepresentable {
    let web: WKWebView
    var viewport = BrowserViewport.fit
    func makeNSView(context: Context) -> BrowserPageContainer { BrowserPageContainer(web: web, viewport: viewport) }
    func updateNSView(_ nsView: BrowserPageContainer, context: Context) { nsView.viewport = viewport }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BrowserPageContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Native bounds own the live page size; resizing never reloads its document.
final class BrowserPageContainer: NSView {
    let web: WKWebView
    var viewport: BrowserViewport { didSet { layoutPage() } }

    init(web: WKWebView, viewport: BrowserViewport) {
        self.web = web
        self.viewport = viewport
        super.init(frame: .zero)
        web.removeFromSuperview()
        addSubview(web)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPage()
    }

    override func layout() {
        super.layout()
        layoutPage()
    }

    private func layoutPage() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let width = viewport == .fit ? bounds.width : min(bounds.width, CGFloat(viewport.rawValue))
        let zoom = viewport == .fit ? 1 : min(1, width / CGFloat(viewport.rawValue))
        if web.pageZoom != zoom { web.pageZoom = zoom }
        web.frame = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
    }
}
