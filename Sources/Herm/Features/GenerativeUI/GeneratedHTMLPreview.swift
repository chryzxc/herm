import AppKit
import SwiftUI
import WebKit

@MainActor
final class GeneratedHTMLCoordinator: ObservableObject {
    static let shared = GeneratedHTMLCoordinator()
    @Published private(set) var activeKey: String?
    private var host: GeneratedHTMLWebView.Coordinator?
    private var hostIdentity: String?
    private var stateIdentity: String?
    private var loadState: GeneratedHTMLLoadState?
    func open(_ key: String) {
        if activeKey != key { close() }
        activeKey = key
    }
    func state(for identity: String) -> GeneratedHTMLLoadState {
        if let loadState, stateIdentity == identity { return loadState }
        let state = GeneratedHTMLLoadState()
        stateIdentity = identity
        loadState = state
        return state
    }
    func coordinator(html: String, identity: String, state: GeneratedHTMLLoadState) -> GeneratedHTMLWebView.Coordinator
    {
        if let host, hostIdentity == identity { return host }
        if let host, let web = host.web { GeneratedHTMLWebView.destroy(web, coordinator: host) }
        let coordinator = GeneratedHTMLWebView.Coordinator(html: html, state: state)
        host = coordinator
        hostIdentity = identity
        return coordinator
    }
    func rekey(from old: String, to new: String) {
        guard activeKey == old else { return }
        if let identity = hostIdentity, identity.hasPrefix(old) { hostIdentity = new + identity.dropFirst(old.count) }
        if stateIdentity == old { stateIdentity = new }
        activeKey = new
    }
    func close() {
        if let host, let web = host.web { GeneratedHTMLWebView.destroy(web, coordinator: host) }
        host = nil
        hostIdentity = nil
        loadState = nil
        stateIdentity = nil
        activeKey = nil
    }
}

/// CSS defaults follow the selected skin; authored content can still style its own artwork.
enum GeneratedHTMLTheme {
    static func defaults(for theme: DockThemeID, systemDark: Bool, textScale: CGFloat = 1) -> String {
        let style = theme.style
        let dark: Bool
        switch theme.appearance {
        case .dark: dark = true
        case .light: dark = false
        case .system: dark = systemDark
        }
        let family: String
        switch style.fontDesign {
        case .monospaced: family = "ui-monospace,Menlo,monospace"
        case .serif: family = "ui-serif,Georgia,serif"
        case .rounded: family = "ui-rounded,-apple-system,BlinkMacSystemFont,sans-serif"
        default: family = "-apple-system,BlinkMacSystemFont,sans-serif"
        }
        let stopMotion =
            "*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important;}"
        return """
            :root{color-scheme:\(dark ? "dark" : "light");--herm-font:\(family);--herm-control-radius:\(style.controlRadius)px;--herm-pane-radius:\(style.paneRadius)px;--herm-base-font-size:\(DockTypography.size(.body, scale: textScale))px;}
            html,body{font:var(--herm-base-font-size) var(--herm-font);}
            button,input,select,textarea{font:inherit;accent-color:var(--herm-accent);}
            @media(prefers-reduced-motion:reduce){\(stopMotion)}
            \(style.animates ? "" : stopMotion)
            """
    }
}

enum GeneratedHTMLPolicy {
    static let contentPolicy =
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
    static let resourceRules =
        #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^herm-generated://preview/"},"action":{"type":"ignore-previous-rules"}}]"#

    static func allowsNavigation(_ url: URL?, initialURL: URL) -> Bool {
        guard let url else { return false }
        return url == initialURL || ["about:blank", "about:srcdoc"].contains(url.absoluteString)
    }

    static func wrapper(_ html: String, theme: String) -> String {
        func attribute(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
                of: "\"", with: "&quot;"
            )
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let document =
            "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentPolicy)\"><meta http-equiv=\"x-dns-prefetch-control\" content=\"off\"><style>\(theme)</style>"
            + html
        return """
            <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; frame-src 'self' about:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><meta http-equiv="x-dns-prefetch-control" content="off"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden}iframe{border:0;width:100%;height:100%}</style></head><body><iframe sandbox="allow-scripts" allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'; display-capture 'none'; usb 'none'" referrerpolicy="no-referrer" title="Generated interactive view" srcdoc="\(attribute(document))"></iframe></body></html>
            """
    }

    /// The sandboxed document accepts only a numeric font-size update from its parent.
    static let textSizeListener = """
        if (window !== window.top) {
          addEventListener('message', event => {
            const size = event.data?.hermTextSize;
            if (event.source === parent && typeof size === 'number' && Number.isFinite(size) && size >= 12 && size <= 16) {
              document.documentElement.style.setProperty('--herm-base-font-size', size + 'px');
            }
          });
        }
        """

    /// Relays postMessage objects between the sandboxed frame and a host bridge. Runs in its own content world,
    /// so the frame can reach neither this script nor the native handler.
    static let bridgeRelay = """
        (() => {
          const frame = () => document.querySelector('iframe');
          addEventListener('message', event => {
            const view = frame();
            if (!view || event.source !== view.contentWindow || typeof event.data !== 'object' || !event.data) return;
            try { webkit.messageHandlers.hermBridge.postMessage(JSON.stringify(event.data)); } catch {}
          });
          window.hermBridgeSend = message => frame()?.contentWindow?.postMessage(message, '*');
        })();
        """

    /// CSP does not cover WebRTC data channels. Disable realm-creating/network APIs before any authored script.
    static let restrictedAPIs = """
        (() => {
          for (const name of ['RTCPeerConnection','webkitRTCPeerConnection','Worker','SharedWorker','WebSocket','EventSource']) {
            try { Object.defineProperty(window, name, {value:undefined,writable:false,configurable:false}); } catch {}
          }
        })();
        """
}

struct GeneratedHTMLPreview: View {
    let html: String
    let identity: String
    var expanded = false
    @ObservedObject private var state: GeneratedHTMLLoadState
    init(html: String, identity: String, expanded: Bool = false) {
        self.html = html
        self.identity = identity
        self.expanded = expanded
        self.state = GeneratedHTMLCoordinator.shared.state(for: identity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Interactive view").dockFont(.body, weight: .medium)
                Spacer()
                Button("Reload") {
                    state.error = nil
                    state.revision += 1
                }.buttonStyle(.dockCompact).help("Reload restarts the original document and resets its inputs.")
                Button("Close") { GeneratedHTMLCoordinator.shared.close() }.buttonStyle(.dockCompact)
            }
            if let error = state.error {
                Text(error).dockFont(.body).foregroundStyle(Color.dockWarning)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                Group {
                    GeneratedHTMLWebView(
                        html: html, state: state,
                        identity: identity + ":" + String(state.revision) + ":" + String(DockThemeRuntime.revision),
                        presentationPriority: expanded ? 1 : 0)
                }.id(
                    "\(identity):\(state.revision):\(DockThemeRuntime.revision)"
                )
                .frame(minHeight: expanded ? 500 : 420, maxHeight: expanded ? .infinity : 420)
                .overlay {
                    if state.loading { ProgressView().controlSize(.small).allowsHitTesting(false) }
                }
            }
        }

    }
}

/// Host side of a sandboxed view's postMessage channel; `send` posts back into the frame.
@MainActor
protocol GeneratedHTMLBridge: AnyObject {
    var send: (([String: Any]) -> Void)? { get set }
    var authorize: ((GeneratedHTMLActionApproval.Action) async -> Bool)? { get set }
    func receive(_ message: [String: Any])
    func invalidate()
}

@MainActor
final class GeneratedHTMLLoadState: ObservableObject {
    @Published var revision = 0
    @Published var error: String?
    @Published var loading = true
}

struct GeneratedHTMLWebView: NSViewRepresentable {
    @Environment(\.dockWorkspaceScale) private var workspaceScale
    let html: String
    let state: GeneratedHTMLLoadState
    var identity: String? = nil
    var presentationPriority = 0
    /// MCP Apps and Hermes inline widgets; generated HTML has no host bridge.
    var bridge: (any GeneratedHTMLBridge)? = nil
    /// The frame already fits its content, so wheel events scroll the transcript.
    var passesScroll = false
    func makeCoordinator() -> Coordinator {
        if let identity {
            return GeneratedHTMLCoordinator.shared.coordinator(html: html, identity: identity, state: state)
        }
        let coordinator = Coordinator(html: html, state: state)
        coordinator.bridge = bridge
        return coordinator
    }

    func makeNSView(context: Context) -> GeneratedHTMLContainer {
        let coordinator = context.coordinator
        coordinator.setTextScale(workspaceScale)
        if coordinator.web == nil {
            coordinator.retainedWeb = coordinator.makeWebView()
            coordinator.retainsHost = identity != nil
            coordinator.load()
        }
        let container = GeneratedHTMLContainer()
        container.presentationPriority = presentationPriority
        coordinator.mount(container)
        (coordinator.web as? GeneratedHTMLWebKitView)?.passesScroll = passesScroll
        return container
    }
    func updateNSView(_ view: GeneratedHTMLContainer, context: Context) {
        context.coordinator.setTextScale(workspaceScale)
        (context.coordinator.web as? GeneratedHTMLWebKitView)?.passesScroll = passesScroll
        if view.presentationPriority != presentationPriority {
            view.presentationPriority = presentationPriority
            context.coordinator.mount(view)
        }
    }
    static func dismantleNSView(_ view: GeneratedHTMLContainer, coordinator: Coordinator) {
        coordinator.unmount(view)
        if !coordinator.retainsHost, let web = coordinator.web { destroy(web, coordinator: coordinator) }
    }
    // Direct WebKit fixtures use the same teardown without a SwiftUI container.
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        destroy(web, coordinator: coordinator)
    }
    static func destroy(_ web: WKWebView, coordinator: Coordinator) {
        web.removeFromSuperview()
        coordinator.retainedWeb = nil
        coordinator.cancelled = true
        coordinator.approval.invalidate()
        coordinator.bridge?.invalidate()
        coordinator.timeout?.cancel()
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        coordinator.bridge = nil
        web.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler, WKScriptMessageHandler {
        let initialURL = URL(string: "herm-generated://preview/\(UUID().uuidString)")!
        let html: String
        let state: GeneratedHTMLLoadState
        weak var web: WKWebView?
        var retainedWeb: WKWebView?
        var retainsHost = false
        private struct Host { weak var view: GeneratedHTMLContainer? }
        private var containers: [Host] = []
        func mount(_ container: GeneratedHTMLContainer) {
            containers.removeAll { $0.view == nil || $0.view === container }
            containers.append(Host(view: container))
            attachToLastContainer()
        }
        func unmount(_ container: GeneratedHTMLContainer) {
            containers.removeAll { $0.view == nil || $0.view === container }
            attachToLastContainer()
        }
        private func attachToLastContainer() {
            let active = containers.compactMap(\.view).enumerated().max { left, right in
                if left.element.presentationPriority == right.element.presentationPriority {
                    return left.offset < right.offset
                }
                return left.element.presentationPriority < right.element.presentationPriority
            }
            guard let container = active?.element, let web else { return }
            web.removeFromSuperview()
            container.addSubview(web)
            web.frame = container.bounds
            web.autoresizingMask = [.width, .height]
        }
        private var textScale: CGFloat = 1
        func setTextScale(_ scale: CGFloat) {
            guard textScale != scale else { return }
            textScale = scale
            applyTextSize()
        }

        private func applyTextSize() {
            let size = DockTypography.size(.body, scale: textScale)
            web?.evaluateJavaScript(
                "document.querySelector('iframe')?.contentWindow?.postMessage({hermTextSize: \(size)}, '*')",
                completionHandler: nil)
        }

        var cancelled = false
        var timeout: Task<Void, Never>?
        var bridge: (any GeneratedHTMLBridge)?
        let approval = GeneratedHTMLActionApproval()
        init(html: String, state: GeneratedHTMLLoadState) {
            self.html = html
            self.state = state
        }

        func makeWebView() -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(self, forURLScheme: "herm-generated")
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: GeneratedHTMLPolicy.restrictedAPIs,
                    injectionTime: .atDocumentStart, forMainFrameOnly: false))
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: GeneratedHTMLPolicy.textSizeListener,
                    injectionTime: .atDocumentStart, forMainFrameOnly: false))
            if let bridge {
                bridge.authorize = { [weak self] action in
                    guard let self, !self.cancelled else { return false }
                    return await self.approval.approve(action, window: self.web?.window)
                }
                // The relay and handler live in their own world: the sandboxed iframe reaches Herm only via postMessage.
                let world = WKContentWorld.world(name: "HermHTMLBridge")
                configuration.userContentController.add(self, contentWorld: world, name: "hermBridge")
                configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: GeneratedHTMLPolicy.bridgeRelay, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                        in: world))
                bridge.send = { [weak self] message in
                    self?.web?.callAsyncJavaScript(
                        "hermBridgeSend(message)", arguments: ["message": message], in: nil, in: world,
                        completionHandler: nil)
                }
            }
            let view = GeneratedHTMLWebKitView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.uiDelegate = self
            web = view
            return view
        }

        func load() {
            state.loading = true
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "HermGeneratedOfflineV1",
                encodedContentRuleList: GeneratedHTMLPolicy.resourceRules
            ) { [weak self] rules, error in
                Task { @MainActor [weak self] in
                    guard let self, !self.cancelled, let web = self.web else { return }
                    guard let rules, error == nil else {
                        self.fail("The isolated preview could not start.")
                        return
                    }
                    web.configuration.userContentController.add(rules)
                    web.load(URLRequest(url: self.initialURL))
                    self.timeout = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard !Task.isCancelled, let self, self.state.loading else { return }
                        self.web?.stopLoading()
                        self.fail("This preview did not finish loading. Reload or close it.")
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard urlSchemeTask.request.url == initialURL, !cancelled else {
                urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
                return
            }
            func css(_ color: Color) -> String {
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return "inherit" }
                return
                    "rgba(\(Int(rgb.redComponent * 255)),\(Int(rgb.greenComponent * 255)),\(Int(rgb.blueComponent * 255)),\(rgb.alphaComponent))"
            }
            let accents = DockAccentColor.allCases.map { family in
                "--herm-\(family):\(css(family.fill));--herm-\(family)-ink:\(css(family.color));"
            }.joined()
            let theme =
                ":root{--herm-background:\(css(.dockCanvas));--herm-text:\(css(.dockPrimaryText));--herm-secondary:\(css(.dockSecondaryText));--herm-accent:\(css(.dockAccent));--herm-surface:\(css(.dockSurface));--herm-border:\(css(.dockBorder));--foreground:\(css(.dockPrimaryText));--muted-foreground:\(css(.dockSecondaryText));--accent:\(css(.dockAccent));--border:\(css(.dockBorder));--card:\(css(.dockSurface));\(accents)}html,body{background:var(--herm-background);color:var(--herm-text);}"
            let defaults = GeneratedHTMLTheme.defaults(
                for: DockThemeRuntime.current,
                systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                textScale: textScale)
            let data = Data(GeneratedHTMLPolicy.wrapper(html, theme: theme + defaults).utf8)
            urlSchemeTask.didReceive(
                URLResponse(
                    url: initialURL, mimeType: "text/html", expectedContentLength: data.count,
                    textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !cancelled, message.frameInfo.isMainFrame, let text = message.body as? String,
                text.utf8.count <= 1_048_576,
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { return }
            bridge?.receive(object)
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let allowed = GeneratedHTMLPolicy.allowsNavigation(navigationAction.request.url, initialURL: initialURL)
            if allowed && (!navigationAction.sourceFrame.isMainFrame || !state.loading) {
                approval.invalidate()
                bridge?.invalidate()
            }
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            timeout?.cancel()
            state.loading = false
            applyTextSize()
        }
        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
        ) {
            fail("The interactive view could not load. Reload or inspect its source.")
        }
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            fail("The interactive view could not load. Reload or inspect its source.")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("The interactive view stopped. Reload to start it again.")
        }
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? { nil }
        func webView(
            _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) { decisionHandler(.deny) }
        func webView(
            _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
        ) { completionHandler(nil) }
        private func fail(_ message: String) {
            timeout?.cancel()
            guard !cancelled else { return }
            approval.invalidate()
            bridge?.invalidate()
            state.loading = false
            state.error = message
        }
    }
}

@MainActor
/// WebKit consumes every wheel event, even with nothing to scroll. A content-sized frame hands them to
/// the transcript instead.
final class GeneratedHTMLWebKitView: WKWebView {
    var passesScroll = false
    override func scrollWheel(with event: NSEvent) {
        if passesScroll, let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class GeneratedHTMLContainer: NSView {
    var presentationPriority = 0
    override var isFlipped: Bool { true }
}
