import AppKit
import WebKit

/// Shares one browser session between the portal and per-agent sign-in, as Desktop does.
@MainActor
final class GatewayWebAuthentication {
    static let shared = GatewayWebAuthentication()
    let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "3F8FB5D9-46ED-4CB8-95AE-3B0E38EB30F5")!)
    private var signingIn = false

    static var portalURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let text = environment["HERMES_PORTAL_BASE_URL"] ?? environment["NOUS_PORTAL_BASE_URL"] ?? "https://portal.nousresearch.com"
        return (try? GatewayConnectionSettings.normalizedURL(text)) ?? URL(string: "https://portal.nousresearch.com")!
    }

    static let portalAccessNames: Set<String> = ["nas-session", "__Host-privy-token", "__Secure-privy-token", "privy-token"]
    static let portalRefreshNames: Set<String> = ["nas-refresh", "privy-session", "privy-refresh-token"]
    static let gatewayAccessNames: Set<String> = ["hermes_session_at", "__Host-hermes_session_at", "__Secure-hermes_session_at"]
    static let gatewayRefreshNames: Set<String> = ["hermes_session_rt", "__Host-hermes_session_rt", "__Secure-hermes_session_rt"]

    nonisolated static func matches(_ cookie: HTTPCookie, url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased(), cookie.expiresDate.map({ $0 > now }) ?? true,
              !cookie.isSecure || ["https", "wss"].contains(url.scheme) else { return false }
        let domain = cookie.domain.lowercased()
        let plain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == plain || (domain.hasPrefix(".") && host.hasSuffix("." + plain)) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
    }

    func cookies(for url: URL) async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies().filter { Self.matches($0, url: url) }
    }

    func hasSession(_ base: URL, portal: Bool = false) async -> Bool {
        let names = portal ? Self.portalAccessNames.union(Self.portalRefreshNames) : Self.gatewayAccessNames.union(Self.gatewayRefreshNames)
        return await cookies(for: base).contains { names.contains($0.name) && !$0.value.isEmpty }
    }

    func headers(for url: URL) async -> [String: String] {
        HTTPCookie.requestHeaderFields(with: await cookies(for: url))
    }

    func capture(_ response: HTTPURLResponse) async {
        guard let url = response.url else { return }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard let host = url.host?.lowercased(), host == domain || host.hasSuffix("." + domain) else { continue }
            await dataStore.httpCookieStore.setCookie(cookie)
        }
    }

    func signOut(_ base: URL) async {
        for cookie in await dataStore.httpCookieStore.allCookies() {
            var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            url.path = cookie.path
            if let url = url.url, Self.matches(cookie, url: url, now: .distantPast) { await dataStore.httpCookieStore.deleteCookie(cookie) }
        }
    }

    func signIn(_ base: URL, portal: Bool = false, silent: Bool = false) async throws {
        guard !signingIn else { throw GatewayConnectionError.unavailable("Another gateway sign-in is already open.") }
        signingIn = true
        defer { signingIn = false }
        let names = portal ? Self.portalAccessNames : Self.gatewayAccessNames
        let before = await cookies(for: base).filter { names.contains($0.name) }.map { $0.name + "=" + $0.value }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let browser = WKWebView(frame: .zero, configuration: configuration)
        let controller = GatewaySignInWindow(browser: browser, title: portal ? "Sign in to Hermes Cloud" : "Sign in to Hermes gateway")
        let start = portal ? base : try GatewayConnectionSettings.endpoint(base, "/login")
        browser.load(URLRequest(url: start))
        if !silent { controller.window.center(); controller.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        defer { controller.window.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(silent ? 12 : 300))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if controller.closed { throw CancellationError() }
            if let error = controller.error { throw error }
            let current = await cookies(for: base).filter { names.contains($0.name) && !$0.value.isEmpty }
            if current.contains(where: { !before.contains($0.name + "=" + $0.value) }) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw GatewayConnectionError.unavailable(silent ? "Session renewal did not complete. Sign in again." : "Sign-in timed out. Try again.")
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } }
    }
}

@MainActor
private final class GatewaySignInWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let window: NSWindow
    var closed = false
    var error: Error?

    init(browser: WKWebView, title: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = browser
        window.delegate = self
        browser.navigationDelegate = self
        browser.uiDelegate = self
    }
    func windowWillClose(_ notification: Notification) { closed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["https", "http", "about"].contains(url.scheme) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme) { webView.load(navigationAction.request) }
        return nil
    }
}

final class GatewaySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // A pasted endpoint must not redirect bearer credentials or WS tokens elsewhere.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
enum GatewayHTTP {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: GatewaySessionDelegate(), delegateQueue: nil)
    }()
    static func request(_ url: URL, method: String = "GET", token: String? = nil, signIn: Bool = false, authBase: URL? = nil, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        if signIn, let authBase, let access = try await GatewayNativeAuthentication.shared.accessToken(authBase) {
            let response = try await request(url, method: method, token: access, body: body)
            if response.0 != 401 { return response }
            if let refreshed = try await GatewayNativeAuthentication.shared.accessToken(authBase, force: true), refreshed != access {
                let retried = try await request(url, method: method, token: refreshed, body: body)
                if retried.0 != 401 { return retried }
            }
            // The remaining path uses the independently held browser session.
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if signIn { for (key, value) in await GatewayWebAuthentication.shared.headers(for: url) { request.setValue(value, forHTTPHeaderField: key) } }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HermesGateway.GatewayError.malformedResponse }
        if signIn { await GatewayWebAuthentication.shared.capture(response) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if !(200..<300).contains(response.statusCode) { throw HermesGateway.GatewayError.httpError(response.statusCode) }
            throw HermesGateway.GatewayError.malformedResponse
        }
        return (response.statusCode, json)
    }
}
