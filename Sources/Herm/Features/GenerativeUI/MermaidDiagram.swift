import AppKit
import SwiftUI
import WebKit

/// Renders ```mermaid fences to images with the bundled Mermaid (MIT, Resources/Mermaid.js).
/// One offscreen, offline WebKit page runs Mermaid in strict mode; transcripts show plain images.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
    static let shared = MermaidRenderer()
    static let maximumSource = 50_000

    struct Failure: Error { let message: String }

    private let page = URL(string: "herm-mermaid://render/")!
    private var web: WKWebView?
    private var ready: Task<Void, any Error>?
    private var queue: Task<Void, Never>?
    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        return cache
    }()
    private var loaded: CheckedContinuation<Void, any Error>?

    func cached(_ source: String, dark: Bool) -> NSImage? {
        cache.object(forKey: Self.key(source, dark: dark))
    }

    func render(_ source: String, dark: Bool) async throws -> NSImage {
        if let image = cached(source, dark: dark) { return image }
        guard source.utf8.count <= Self.maximumSource else {
            throw Failure(message: "The diagram is larger than Herm renders.")
        }
        // One render at a time: Mermaid keeps global configuration.
        let previous = queue
        let job = Task { @MainActor () throws -> NSImage in
            await previous?.value
            if let image = cached(source, dark: dark) { return image }
            let image = try await draw(source, dark: dark)
            cache.setObject(image, forKey: Self.key(source, dark: dark))
            return image
        }
        queue = Task { _ = try? await job.value }
        return try await job.value
    }

    private static func key(_ source: String, dark: Bool) -> NSString { ((dark ? "d:" : "l:") + source) as NSString }

    private func draw(_ source: String, dark: Bool) async throws -> NSImage {
        try await start()
        guard let web else { throw Failure(message: "The diagram renderer is unavailable.") }
        // ponytail: the timeout is in-page; a synchronous Mermaid hang would still block this renderer.
        let result = try await web.callAsyncJavaScript(
            "return await hermRender(source, dark)", arguments: ["source": source, "dark": dark], contentWorld: .page)
        guard let values = result as? [String: Any] else { throw Failure(message: "The diagram did not render.") }
        if let error = values["error"] as? String {
            throw Failure(message: String(error.prefix(300)))
        }
        guard let url = values["png"] as? String, let comma = url.firstIndex(of: ","),
            let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
            let image = NSImage(data: data),
            let width = (values["width"] as? NSNumber)?.doubleValue,
            let height = (values["height"] as? NSNumber)?.doubleValue
        else { throw Failure(message: "The diagram did not render.") }
        image.size = NSSize(width: width, height: height)
        return image
    }

    private func start() async throws {
        if ready == nil {
            ready = Task { @MainActor in
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.setURLSchemeHandler(self, forURLScheme: "herm-mermaid")
                configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: GeneratedHTMLPolicy.restrictedAPIs, injectionTime: .atDocumentStart,
                        forMainFrameOnly: false))
                let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "HermMermaidOfflineV1", encodedContentRuleList: Self.resourceRules)
                if let rules { configuration.userContentController.add(rules) }
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
                view.navigationDelegate = self
                web = view
                try await withCheckedThrowingContinuation { continuation in
                    loaded = continuation
                    view.load(URLRequest(url: page))
                }
            }
        }
        do {
            try await ready?.value
        } catch {
            // A failed start (for example a WebContent crash) retries on the next diagram.
            ready = nil
            web = nil
            throw Failure(message: "The diagram renderer could not start.")
        }
    }

    static let resourceRules =
        #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^herm-mermaid://render/"},"action":{"type":"ignore-previous-rules"}}]"#

    /// htmlLabels off keeps text in plain SVG, so the canvas stays untainted and exports a PNG.
    static let document = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src herm-mermaid: 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
        <script src="herm-mermaid://render/mermaid.js"></script>
        <script>
        let count = 0;
        function hermRender(source, dark) {
          const late = new Promise(done => setTimeout(() => done({error: 'The diagram took too long to render.'}), 10000));
          return Promise.race([draw(source, dark), late]);
        }
        async function draw(source, dark) {
          try {
            mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default',
              htmlLabels: false, flowchart: {htmlLabels: false}, maxTextSize: 50000,
              fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'});
            const {svg} = await mermaid.render('herm-mermaid-' + (++count), source);
            const doc = new DOMParser().parseFromString(svg, 'image/svg+xml');
            const root = doc.documentElement;
            const box = (root.getAttribute('viewBox') || '').split(/[\\s,]+/).map(Number);
            let width = box[2] || 600, height = box[3] || 400;
            const fit = Math.min(1, 2400 / width, 2400 / height);
            width *= fit; height *= fit;
            root.setAttribute('width', width); root.setAttribute('height', height);
            root.style.maxWidth = 'none';
            const image = new Image();
            image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(root));
            await image.decode();
            const canvas = document.createElement('canvas');
            canvas.width = Math.ceil(width * 2); canvas.height = Math.ceil(height * 2);
            const context = canvas.getContext('2d');
            context.scale(2, 2);
            context.drawImage(image, 0, 0, width, height);
            return {png: canvas.toDataURL('image/png'), width, height};
          } catch (error) {
            document.querySelectorAll('[id^="dherm-mermaid-"]').forEach(node => node.remove());
            return {error: String(error?.message || error)};
          }
        }
        </script></head><body></body></html>
        """

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let body: Data?
        let mime: String
        switch url.absoluteString {
        case page.absoluteString:
            body = Data(Self.document.utf8)
            mime = "text/html"
        case page.absoluteString + "mermaid.js":
            body = Bundle.herm.url(forResource: "Mermaid", withExtension: "js").flatMap { try? Data(contentsOf: $0) }
            mime = "text/javascript"
        default:
            body = nil
            mime = ""
        }
        guard let body else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        urlSchemeTask.didReceive(
            URLResponse(url: url, mimeType: mime, expectedContentLength: body.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url == page ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = nil
        web = nil
    }
}

/// A Mermaid fence in a reply: Preview shows the rendered diagram, Code the source.
struct MermaidDiagramView: View {
    let source: String
    var expanded = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsCode = false
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var copied = false
    @State private var showingExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("mermaid").dockFont(.metadata).foregroundStyle(Color.dockMetadataText)
                Spacer(minLength: 8)
                DockSegmentedPicker(selection: $showsCode, options: [(false, "Preview"), (true, "Code")])
                    .fixedSize()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                    copied = true
                } label: {
                    DockIconLabel(copied ? "Copied" : "Copy", icon: .copy)
                }.buttonStyle(.dockSecondary)
                if !expanded {
                    Button {
                        showingExpanded = true
                    } label: {
                        DockIconLabel("Expand", icon: .arrowsOut)
                    }.buttonStyle(.dockSecondary)
                }
            }
            .dockButtonSize(.compact)
            .dockPadding(.horizontal, 12)
            .dockPadding(.vertical, 8)
            Divider().overlay(Color.dockBorderLight)
            Group {
                if showsCode {
                    ScrollView(.horizontal) {
                        Text(source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .fixedSize()
                    }
                } else if let image, expanded {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width, height: image.size.height)
                    }
                    .accessibilityLabel("Mermaid diagram")
                } else if let image {
                    // Inline fits the column; Expand shows full size.
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .frame(maxWidth: image.size.width, maxHeight: 640)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Mermaid diagram")
                } else if let failure {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diagram unavailable").dockFont(.body, weight: .semibold)
                        Text(failure).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Show code") { showsCode = true }.buttonStyle(.dockLink)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dockPadding(12)
        }
        .foregroundStyle(Color.dockPrimaryText)
        .dockCard(padding: 0)
        .task(id: "\(colorScheme == .dark):\(source)") { await render() }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
        .dockSheet(isPresented: $showingExpanded) {
            DockExpandedPage(title: "Diagram", subtitle: "Mermaid", close: { showingExpanded = false }) {
                MermaidDiagramView(source: source, expanded: true).dockPadding(16)
            }.frame(minWidth: 640, minHeight: 500).modifier(ReviewSheetContext())
        }
    }

    private func render() async {
        let dark = colorScheme == .dark
        if let cached = MermaidRenderer.shared.cached(source, dark: dark) {
            image = cached
            return
        }
        image = nil
        failure = nil
        do {
            image = try await MermaidRenderer.shared.render(source, dark: dark)
        } catch let error as MermaidRenderer.Failure {
            failure = error.message
        } catch {
            failure = HermesDiagnosticsService.safeSummary(error.localizedDescription)
        }
    }
}
