import AppKit
import SwiftUI
import WebKit

@MainActor
final class GeneratedHTMLCoordinator: ObservableObject {
  static let shared = GeneratedHTMLCoordinator()
  @Published private(set) var activeKey: String?
  func open(_ key: String) { activeKey = key }
  func close() { activeKey = nil }
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
  @State private var revision = 0
  var expanded = false
  @State private var showingExpanded = false
  @StateObject private var state = GeneratedHTMLLoadState()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Interactive view").font(.system(size: 12, weight: .medium))
        Spacer()
        if !expanded { Button("Expand") { showingExpanded = true }.buttonStyle(.dockCompact) }
        Button("Reload") {
          state.error = nil
          revision += 1
        }.buttonStyle(.dockCompact)
        Button("Close") { GeneratedHTMLCoordinator.shared.close() }.buttonStyle(.dockCompact)
      }
      if let error = state.error {
        Text(error).font(DockTypography.body).foregroundStyle(Color.dockWarning)
          .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
      } else {
        Group { if !showingExpanded { GeneratedHTMLWebView(html: html, state: state) } }.id(
          "\(identity):\(revision):\(DockThemeRuntime.revision)"
        )
        .frame(minHeight: expanded ? 500 : 420, maxHeight: expanded ? .infinity : 420)
        .overlay {
          if state.loading { ProgressView().controlSize(.small).allowsHitTesting(false) }
        }
      }
    }
    .sheet(isPresented: $showingExpanded) {
      GeneratedHTMLPreview(html: html, identity: identity, expanded: true)
        .padding(16).frame(minWidth: 800, idealWidth: 1100, minHeight: 600, idealHeight: 780)
        .background(Color.dockCanvas)
    }
  }
}

@MainActor
final class GeneratedHTMLLoadState: ObservableObject {
  @Published var error: String?
  @Published var loading = true
}

struct GeneratedHTMLWebView: NSViewRepresentable {
  let html: String
  let state: GeneratedHTMLLoadState
  func makeCoordinator() -> Coordinator { Coordinator(html: html, state: state) }

  func makeNSView(context: Context) -> WKWebView {
    let web = context.coordinator.makeWebView()
    context.coordinator.load()
    return web
  }
  func updateNSView(_ web: WKWebView, context: Context) {}
  static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
    coordinator.cancelled = true
    coordinator.timeout?.cancel()
    web.stopLoading()
    web.navigationDelegate = nil
    web.uiDelegate = nil
    web.loadHTMLString("", baseURL: nil)
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {
    let initialURL = URL(string: "herm-generated://preview/\(UUID().uuidString)")!
    let html: String
    let state: GeneratedHTMLLoadState
    weak var web: WKWebView?
    var cancelled = false
    var timeout: Task<Void, Never>?
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
      let view = WKWebView(frame: .zero, configuration: configuration)
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
      let theme =
        ":root{color-scheme:\(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light");--herm-background:\(css(.dockCanvas));--herm-text:\(css(.dockPrimaryText));--herm-secondary:\(css(.dockSecondaryText));--herm-accent:\(css(.dockAccent));--herm-surface:\(css(.dockSurface));--herm-border:\(css(.dockBorder));}html,body{background:var(--herm-background);color:var(--herm-text);font:12px -apple-system,BlinkMacSystemFont,sans-serif;}button,input,select,textarea{font:inherit;}@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important;}}"
      let data = Data(GeneratedHTMLPolicy.wrapper(html, theme: theme).utf8)
      urlSchemeTask.didReceive(
        URLResponse(
          url: initialURL, mimeType: "text/html", expectedContentLength: data.count,
          textEncodingName: "utf-8"))
      urlSchemeTask.didReceive(data)
      urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      decisionHandler(
        GeneratedHTMLPolicy.allowsNavigation(navigationAction.request.url, initialURL: initialURL)
          ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      timeout?.cancel()
      state.loading = false
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
      state.loading = false
      state.error = message
    }
  }
}
