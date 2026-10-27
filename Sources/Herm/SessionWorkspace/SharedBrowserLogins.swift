import Combine
import CryptoKit
import Foundation
import Security
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

    func sealed(with key: SymmetricKey) throws -> Data {
        guard let data = try AES.GCM.seal(JSONEncoder().encode(Array(cookies.values)), using: key).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return data
    }

    /// Drops cookies that expired while no browser was running.
    static func open(_ data: Data, with key: SymmetricKey, now: Date = Date()) throws -> BrowserCookieJar {
        let list = try JSONDecoder().decode(
            [BrowserCookie].self, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key))
        return BrowserCookieJar(list.filter { ($0.expires ?? .infinity) > now.timeIntervalSince1970 })
    }
}

/// Sign-ins shared by every session's agent browser. Each session still runs its own Chrome
/// (opened and closed with its Browser tab); this jar seeds a starting Chrome and relays
/// cookie changes between running ones. Sealed at rest with a Keychain-held key.
@MainActor
final class SharedBrowserLogins {
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

    init(file: URL, key: @escaping () throws -> SymmetricKey) {
        self.file = file
        self.key = key
    }

    var jar: BrowserCookieJar {
        if let loaded { return loaded }
        var jar = BrowserCookieJar()
        if let data = try? Data(contentsOf: file) {
            do { jar = try BrowserCookieJar.open(data, with: key()) } catch {
                DebugLog.write(
                    "agent browser: shared logins unreadable: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
                )
            }
        }
        loaded = jar
        return jar
    }

    func record(_ changes: BrowserCookieJar.Changes, from origin: ObjectIdentifier) {
        guard !changes.isEmpty else { return }
        var next = jar
        next.apply(changes)
        save(next)
        self.changes.send((origin, .updated(changes)))
    }

    /// Signs every Herm browser out: running Chromes, future ones, and the WebKit tabs.
    func clear() {
        save(BrowserCookieJar())
        changes.send((nil, .cleared))
        SessionBrowserWorkspace.dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
        ) {}
    }

    private func save(_ jar: BrowserCookieJar) {
        loaded = jar
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try jar.sealed(with: key()).write(to: file, options: .atomic)
        } catch {
            DebugLog.write(
                "agent browser: shared logins not saved: \(HermesDiagnosticsService.safeSummary(error.localizedDescription))"
            )
        }
    }

    nonisolated private static func keychainKey() throws -> SymmetricKey {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "io.github.chryzxc.Herm.browser",
            kSecAttrAccount: "shared-logins",
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(
            query.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { $1 } as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return SymmetricKey(data: data) }
        if status == errSecItemNotFound {
            let key = SymmetricKey(size: .bits256)
            status = SecItemAdd(
                query.merging([
                    kSecValueData: key.withUnsafeBytes { Data($0) },
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]) { $1 } as CFDictionary, nil)
            if status == errSecSuccess { return key }
        }
        throw NSError(
            domain: NSOSStatusErrorDomain, code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Keychain access for shared browser logins failed (\(status))."])
    }
}
