import Combine
import CryptoKit
import Foundation
import WebKit

/// One Chrome cookie as CDP reports it. Partitioned (CHIPS) cookies belong to embeds, not
/// sign-ins, so they stay with the session that made them.
struct BrowserCookie: Codable, Hashable {
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
    /// Sites you chose to share (hosts without "www."); only their cookies leave a session.
    var sites: Set<String> = []
    /// Bumped by Sign Out of All Sites, so a profile that was closed at the time signs out on reopen.
    var signOuts = 0

    init(_ cookies: [BrowserCookie] = [], sites: Set<String> = [], signOuts: Int = 0) {
        for cookie in cookies { self.cookies[cookie.id] = cookie }
        self.sites = sites
        self.signOuts = signOuts
    }

    /// The site a page URL shares under: its host, minus "www.".
    static func site(of url: String) -> String? {
        guard let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            var host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// A site's sign-in spans its subdomains and the parent domains it sets cookies on
    /// (accounts.google.com signs in on .google.com).
    func shares(_ cookie: BrowserCookie) -> Bool {
        let domain = cookie.domain.lowercased().drop { $0 == "." }
        return sites.contains { domain == $0 || domain.hasSuffix("." + $0) || $0.hasSuffix("." + domain) }
    }

    func changes(to current: BrowserCookieJar) -> Changes {
        Changes(
            updated: current.cookies.values.filter { cookies[$0.id] != $0 },
            removed: cookies.values.filter { current.cookies[$0.id] == nil })
    }

    /// Only the shared sites' part of a diff.
    func shared(_ changes: Changes) -> Changes {
        Changes(updated: changes.updated.filter(shares), removed: changes.removed.filter(shares))
    }

    mutating func apply(_ changes: Changes) {
        for cookie in changes.removed { cookies[cookie.id] = nil }
        for cookie in changes.updated { cookies[cookie.id] = cookie }
    }

    private struct Sealed: Codable {
        let sites: [String]
        let signOuts: Int
        let cookies: [BrowserCookie]
    }

    func sealed(with key: SymmetricKey) throws -> Data {
        let payload = Sealed(sites: sites.sorted(), signOuts: signOuts, cookies: Array(cookies.values))
        guard let data = try AES.GCM.seal(JSONEncoder().encode(payload), using: key).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return data
    }

    /// Drops cookies that expired while no browser was running, and any outside the shared sites.
    static func open(_ data: Data, with key: SymmetricKey, now: Date = Date()) throws -> BrowserCookieJar {
        let payload = try JSONDecoder().decode(
            Sealed.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key))
        var jar = BrowserCookieJar(sites: Set(payload.sites), signOuts: payload.signOuts)
        for cookie in payload.cookies where (cookie.expires ?? .infinity) > now.timeIntervalSince1970 {
            if jar.shares(cookie) { jar.cookies[cookie.id] = cookie }
        }
        return jar
    }
}

/// Sign-ins shared by every profile's agent browser, for the sites you choose. Each Hermes
/// profile runs one Chrome its sessions share; this jar seeds a starting Chrome and relays
/// those sites' cookie changes between running ones. Sealed at
/// rest with a Keychain-held key.
@MainActor
final class SharedBrowserLogins: ObservableObject {
    static let shared = SharedBrowserLogins(
        file: AgentBrowser.profileRoot.appendingPathComponent("SharedLogins.sealed"), key: keychainKey)

    enum Change {
        case prepared
        case updated(BrowserCookieJar.Changes)
        case cleared
    }

    /// Another browser's sign-in changes, for each running browser to apply; `origin` skips the sender.
    let changes = PassthroughSubject<(origin: ObjectIdentifier?, change: Change), Never>()
    private let file: URL
    private let key: () async throws -> SymmetricKey
    private var loaded: BrowserCookieJar?
    private var cachedKey: SymmetricKey?

    init(file: URL, key: @escaping () async throws -> SymmetricKey) {
        self.file = file
        self.key = key
    }

    @Published private(set) var isPrepared = false
    private var preparation: Task<SymmetricKey, Error>?
    private var loadFailed = false

    @discardableResult
    func prepare() async -> Bool {
        if isPrepared { return true }
        if preparation == nil { preparation = Task { try await key() } }
        do {
            let fetched = try await preparation?.value
            if isPrepared { return true }
            cachedKey = fetched
            preparation = nil
            loadFailed = false
            _ = jar
            isPrepared = loaded != nil
            if isPrepared { changes.send((nil, .prepared)) }
        } catch {
            preparation = nil
            reportFailure("Shared sign-ins are unavailable. Unlock Keychain and retry.")
        }
        return isPrepared
    }

    var jar: BrowserCookieJar {
        if let loaded { return loaded }
        guard let cachedKey, !loadFailed else { return BrowserCookieJar() }
        do {
            let data = try Data(contentsOf: file)
            let opened = try BrowserCookieJar.open(data, with: cachedKey)
            loaded = opened
            return opened
        } catch CocoaError.fileReadNoSuchFile {
            let empty = BrowserCookieJar()
            loaded = empty
            return empty
        } catch {
            loadFailed = true
            reportFailure("Stored shared sign-ins could not be read. The existing file was preserved.")
            return BrowserCookieJar()
        }
    }

    private func reportFailure(_ message: String) {
        DockActionErrorCenter.shared.report("Shared sign-ins unavailable", message: message)
    }

    func record(_ changes: BrowserCookieJar.Changes, from origin: ObjectIdentifier) {
        let changes = jar.shared(changes)
        guard !changes.isEmpty else { return }
        var next = jar
        next.apply(changes)
        guard save(next) else { return }
        self.changes.send((origin, .updated(changes)))
    }

    /// Starts sharing `site`, seeded with the sender's current cookies for it.
    func share(_ site: String, cookies: [BrowserCookie], from origin: ObjectIdentifier) {
        var next = jar
        next.sites.insert(site)
        let changes = next.shared(BrowserCookieJar.Changes(updated: cookies))
        next.apply(changes)
        guard save(next) else { return }
        if !changes.isEmpty { self.changes.send((origin, .updated(changes))) }
    }

    /// New browsers stop receiving `site`; running ones stay signed in until they sign out.
    func stopSharing(_ site: String) {
        var next = jar
        next.sites.remove(site)
        save(BrowserCookieJar(next.cookies.values.filter(next.shares), sites: next.sites, signOuts: next.signOuts))
    }

    /// Signs every Herm browser out of every site: running Chromes now, closed ones when they
    /// reopen, and the WebKit tabs. The shared-site list stays.
    func clear() {
        guard save(BrowserCookieJar(sites: jar.sites, signOuts: jar.signOuts + 1)) else { return }
        changes.send((nil, .cleared))
        Task {
            for id in await WKWebsiteDataStore.allDataStoreIdentifiers where SessionBrowserWorkspace.isDataStoreID(id) {
                await WKWebsiteDataStore(forIdentifier: id).removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
        }
    }

    @discardableResult
    private func save(_ jar: BrowserCookieJar) -> Bool {
        guard isPrepared, let cachedKey else {
            reportFailure("Shared sign-ins are unavailable. Retry before changing them.")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try jar.sealed(with: cachedKey).write(to: file, options: .atomic)
            objectWillChange.send()
            loaded = jar
            return true
        } catch {
            reportFailure(
                "Shared sign-in changes could not be saved. Sign-out was not completed. Check available disk space and permissions, then retry."
            )
            return false
        }
    }

    nonisolated private static func keychainKey() async throws -> SymmetricKey {
        let service = "io.github.chryzxc.Herm.browser"
        let account = "shared-logins-key"
        if let value = try await HermKeychain.read(service: service, account: account) {
            guard let data = Data(base64Encoded: value), data.count == 32 else {
                throw CocoaError(.coderReadCorrupt)
            }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let value = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        try await HermKeychain.write(service: service, account: account, value: value)
        return key
    }
}
