import CryptoKit
import Foundation
import Testing

@testable import Herm

@MainActor
struct SharedBrowserLoginsTests {
    private func cookie(_ name: String, value: String = "v", domain: String = "github.com", expires: Double = -1)
        -> BrowserCookie
    {
        BrowserCookie(cdp: [
            "name": name, "value": value, "domain": domain, "path": "/", "expires": expires,
            "httpOnly": true, "secure": true, "session": expires <= 0, "sameSite": "Lax",
        ])!
    }

    @Test func hostOnlyCookiesKeepTheirHostAndPartitionedOnesStayLocal() {
        let host = cookie("__Host-user_session").cdpParam()
        #expect(host["url"] as? String == "https://github.com/")
        #expect(host["domain"] == nil)
        #expect(host["expires"] == nil)
        let domain = cookie("logged_in", domain: ".github.com", expires: 2_000_000_000).cdpParam()
        #expect(domain["domain"] as? String == ".github.com")
        #expect(domain["expires"] as? Double == 2_000_000_000)
        #expect(cookie("x").cdpParam(expired: true)["expires"] as? Int == 1)
        #expect(
            BrowserCookie(cdp: [
                "name": "embed", "value": "v", "domain": "a.com", "path": "/",
                "partitionKey": ["topLevelSite": "https://b.com"],
            ]) == nil)
    }

    @Test func changesCarrySignInsAndSignOutsBetweenBrowsers() {
        let baseline = BrowserCookieJar([cookie("old"), cookie("kept"), cookie("token")])
        let changes = baseline.changes(
            to: BrowserCookieJar([cookie("kept"), cookie("token", value: "rotated"), cookie("new")]))
        #expect(Set(changes.updated.map(\.name)) == ["token", "new"])
        #expect(changes.removed.map(\.name) == ["old"])
        var other = baseline
        other.apply(changes)
        #expect(other == BrowserCookieJar([cookie("kept"), cookie("token", value: "rotated"), cookie("new")]))
        #expect(other.changes(to: other).isEmpty)
    }

    @Test func jarIsSealedAtRestAndDropsExpiredCookies() throws {
        let key = SymmetricKey(size: .bits256)
        let jar = BrowserCookieJar([cookie("session"), cookie("stale", expires: 100), cookie("live", expires: 4e9)])
        let sealed = try jar.sealed(with: key)
        #expect(!String(decoding: sealed, as: UTF8.self).contains("session"))
        let opened = try BrowserCookieJar.open(sealed, with: key)
        #expect(Set(opened.cookies.values.map(\.name)) == ["session", "live"])
        #expect(throws: (any Error).self) { try BrowserCookieJar.open(sealed, with: SymmetricKey(size: .bits256)) }
    }

    @Test func recordedChangesPersistAndReachOtherBrowsers() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("logins.sealed")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let key = SymmetricKey(size: .bits256)
        let logins = SharedBrowserLogins(file: file, key: { key })
        var received: [SharedBrowserLogins.Change] = []
        let subscription = logins.changes.sink { received.append($0.change) }
        defer { subscription.cancel() }
        let sender = ObjectIdentifier(logins)

        logins.record(BrowserCookieJar.Changes(), from: sender)
        #expect(received.isEmpty)
        logins.record(BrowserCookieJar.Changes(updated: [cookie("user_session")]), from: sender)
        #expect(received.count == 1)
        let reloaded = SharedBrowserLogins(file: file, key: { key })
        #expect(reloaded.jar == BrowserCookieJar([cookie("user_session")]))
        let permissions =
            try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[
                .posixPermissions] as? Int
        #expect(permissions == 0o700)
    }
}
