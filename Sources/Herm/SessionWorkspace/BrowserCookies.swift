import Foundation

/// One Chrome cookie as CDP reports it. Partitioned (CHIPS) cookies belong to embeds, not
/// sign-ins, so they stay with the session that made them.
struct BrowserCookie: Hashable {
    let name, value, domain, path: String
    /// Unix seconds; nil for a session cookie.
    let expires: Double?
    let httpOnly, secure: Bool
    let sameSite: String?

    var id: String { [name, domain, path].joined(separator: "\u{1}") }

    init?(cdp: [String: Any]) {
        guard cdp["partitionKey"] == nil, let name = cdp["name"] as? String, let value = cdp["value"] as? String,
            let domain = cdp["domain"] as? String, !domain.isEmpty, let path = cdp["path"] as? String
        else { return nil }
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        let expires = cdp["expires"] as? Double ?? -1
        self.expires = cdp["session"] as? Bool == true || expires <= 0 ? nil : expires
        httpOnly = cdp["httpOnly"] as? Bool ?? false
        secure = cdp["secure"] as? Bool ?? false
        sameSite = cdp["sameSite"] as? String
    }

    init?(http cookie: HTTPCookie) {
        var cdp: [String: Any] = [
            "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
            "expires": cookie.expiresDate?.timeIntervalSince1970 ?? -1, "session": cookie.isSessionOnly,
            "httpOnly": cookie.isHTTPOnly, "secure": cookie.isSecure,
        ]
        // CDP spells these "Lax"/"Strict"; WebKit reports "lax"/"strict".
        if let policy = cookie.sameSitePolicy?.rawValue {
            cdp["sameSite"] = policy.prefix(1).uppercased() + policy.dropFirst()
        }
        self.init(cdp: cdp)
    }

    /// Sent to `host`: a domain cookie reaches its subdomains, a host-only one just its host.
    func matches(host: String) -> Bool {
        let domain = domain.lowercased()
        guard domain.hasPrefix(".") else { return host == domain }
        return host == domain.dropFirst() || host.hasSuffix(domain)
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
        if let sameSite { properties[.sameSitePolicy] = sameSite.lowercased() }
        return HTTPCookie(properties: properties)
    }

    /// `Storage.setCookies` form. Host-only cookies (no leading dot) are set by URL, since a
    /// Domain attribute would widen them to subdomains and `__Host-` cookies reject one.
    /// An expired copy deletes the cookie.
    func cdpParam(expired: Bool = false) -> [String: Any] {
        var param: [String: Any] = ["name": name, "value": value, "path": path, "httpOnly": httpOnly, "secure": secure]
        if domain.hasPrefix(".") {
            param["domain"] = domain
        } else {
            param["url"] = "\(secure ? "https" : "http")://\(domain)\(path)"
        }
        if let sameSite { param["sameSite"] = sameSite }
        if expired { param["expires"] = 1 } else if let expires { param["expires"] = expires }
        return param
    }
}

struct BrowserCookieJar: Equatable {
    struct Changes: Equatable {
        var updated: [BrowserCookie] = []
        var removed: [BrowserCookie] = []
        var isEmpty: Bool { updated.isEmpty && removed.isEmpty }
    }

    private(set) var cookies: [String: BrowserCookie] = [:]
    init(_ cookies: [BrowserCookie] = []) {
        for cookie in cookies { self.cookies[cookie.id] = cookie }
    }

    func changes(to current: BrowserCookieJar) -> Changes {
        Changes(
            updated: current.cookies.values.filter { cookies[$0.id] != $0 },
            removed: cookies.values.filter { current.cookies[$0.id] == nil })
    }

    mutating func apply(_ changes: Changes) {
        for cookie in changes.removed { cookies[cookie.id] = nil }
        for cookie in changes.updated { cookies[cookie.id] = cookie }
    }

}
