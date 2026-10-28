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
        case updated(BrowserCookieJar.Changes)
        case cleared
    }

    /// Another browser's sign-in changes, for each running browser to apply; `origin` skips the sender.
    let changes = PassthroughSubject<(origin: ObjectIdentifier?, change: Change), Never>()
    private let file: URL
    private let key: () throws -> SymmetricKey
    private var loaded: BrowserCookieJar?
    private var cachedKey: SymmetricKey?

    init(file: URL, key: @escaping () throws -> SymmetricKey) {
        self.file = file
        self.key = key
    }

    /// Fetched once: each Keychain read launches `security`, and every save needs the key.
    private func sealingKey() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let fetched = try key()
        cachedKey = fetched
        return fetched
    }

    var jar: BrowserCookieJar {
        if let loaded { return loaded }
        var jar = BrowserCookieJar()
        if let data = try? Data(contentsOf: file) {
            do { jar = try BrowserCookieJar.open(data, with: sealingKey()) } catch {
                DebugLog.write(
                    "agent browser: shared logins unreadable: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
                )
            }
        }
        loaded = jar
        return jar
    }

    func record(_ changes: BrowserCookieJar.Changes, from origin: ObjectIdentifier) {
        let changes = jar.shared(changes)
        guard !changes.isEmpty else { return }
        var next = jar
        next.apply(changes)
        save(next)
        self.changes.send((origin, .updated(changes)))
    }

    /// Starts sharing `site`, seeded with the sender's current cookies for it.
    func share(_ site: String, cookies: [BrowserCookie], from origin: ObjectIdentifier) {
        var next = jar
        next.sites.insert(site)
        save(next)
        record(BrowserCookieJar.Changes(updated: cookies), from: origin)
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
        save(BrowserCookieJar(sites: jar.sites, signOuts: jar.signOuts + 1))
        changes.send((nil, .cleared))
        SessionBrowserWorkspace.dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        ) {}
    }

    private func save(_ jar: BrowserCookieJar) {
        objectWillChange.send()
        loaded = jar
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try jar.sealed(with: sealingKey()).write(to: file, options: .atomic)
        } catch {
            DebugLog.write(
                "agent browser: shared logins not saved: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
            )
        }
    }

    /// A new account name: the earlier `shared-logins` item was added in-process and so trusts
    /// only the build that made it.
    nonisolated private static func keychainKey() throws -> SymmetricKey {
        let item = ["-s", "io.github.chryzxc.Herm.browser", "-a", "shared-logins-key"]
        var result = try KeychainCLI.run(["find-generic-password", "-w"] + item)
        if result.status == KeychainCLI.notFound {
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
            result = try KeychainCLI.run(["add-generic-password", "-w", key] + item)
            if result.status == 0 { result.output = key }
        }
        guard result.status == 0, let data = Data(base64Encoded: result.output), data.count == 32 else {
            throw NSError(
                domain: NSOSStatusErrorDomain, code: Int(result.status),
                userInfo: [
                    NSLocalizedDescriptionKey: "Keychain access for shared browser logins failed (\(result.status))."
                ])
        }
        return SymmetricKey(data: data)
    }
}
