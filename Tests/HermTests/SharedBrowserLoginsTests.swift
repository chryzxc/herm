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
        let jar = BrowserCookieJar(
            [
                cookie("session"), cookie("stale", expires: 100), cookie("live", expires: 4e9),
                cookie("x", domain: "a.com"),
            ],
            sites: ["github.com"], signOuts: 2)
        let sealed = try jar.sealed(with: key)
        #expect(!String(decoding: sealed, as: UTF8.self).contains("session"))
        let opened = try BrowserCookieJar.open(sealed, with: key)
        #expect(Set(opened.cookies.values.map(\.name)) == ["session", "live"])
        #expect(opened.sites == ["github.com"])
        #expect(opened.signOuts == 2)
        #expect(throws: (any Error).self) { try BrowserCookieJar.open(sealed, with: SymmetricKey(size: .bits256)) }
    }

    @Test func recordedChangesPersistAndReachOtherBrowsers() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("logins.sealed")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let key = SymmetricKey(size: .bits256)
        let logins = SharedBrowserLogins(file: file, key: { key })
        #expect(await logins.prepare())
        var received: [SharedBrowserLogins.Change] = []
        let subscription = logins.changes.sink { received.append($0.change) }
        defer { subscription.cancel() }
        let sender = ObjectIdentifier(logins)

        logins.record(BrowserCookieJar.Changes(), from: sender)
        #expect(received.isEmpty)
        logins.record(BrowserCookieJar.Changes(updated: [cookie("user_session")]), from: sender)
        #expect(received.isEmpty)  // Not shared yet: this session's sign-in stays its own.
        logins.share("github.com", cookies: [cookie("user_session"), cookie("x", domain: "a.com")], from: sender)
        #expect(received.count == 1)
        let reloaded = SharedBrowserLogins(file: file, key: { key })
        #expect(await reloaded.prepare())
        #expect(reloaded.jar == BrowserCookieJar([cookie("user_session")], sites: ["github.com"]))
        reloaded.stopSharing("github.com")
        let stopped = SharedBrowserLogins(file: file, key: { key })
        #expect(await stopped.prepare())
        #expect(stopped.jar == BrowserCookieJar())
        let permissions =
            try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[
                .posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test func sharingFollowsTheSiteAcrossItsSubdomainsAndParentDomain() {
        #expect(BrowserCookieJar.site(of: "https://www.GitHub.com/login") == "github.com")
        #expect(BrowserCookieJar.site(of: "file:///etc/hosts") == nil)
        #expect(BrowserCookieJar.site(of: "about:blank") == nil)
        let jar = BrowserCookieJar(sites: ["accounts.google.com"])
        #expect(jar.shares(cookie("SID", domain: ".google.com")))
        #expect(jar.shares(cookie("x", domain: "accounts.google.com")))
        #expect(jar.shares(cookie("x", domain: "eu.accounts.google.com")))
        #expect(!jar.shares(cookie("x", domain: "mail.google.com")))
        #expect(!jar.shares(cookie("x", domain: "notgoogle.com")))
    }

    @Test func failedSignOutDoesNotPublishSuccessOrReplacePersistedCookies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = directory.appendingPathExtension("preserved")
        let file = directory.appendingPathComponent("logins.sealed")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: moved)
        }
        let key = SymmetricKey(size: .bits256)
        let logins = SharedBrowserLogins(file: file, key: { key })
        #expect(await logins.prepare())
        logins.share("github.com", cookies: [cookie("session")], from: ObjectIdentifier(logins))
        let original = logins.jar
        let saved = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: directory, to: moved)
        try Data().write(to: directory)
        var clearEvents = 0
        let subscription = logins.changes.sink { if case .cleared = $0.change { clearEvents += 1 } }
        defer { subscription.cancel() }
        logins.clear()
        #expect(clearEvents == 0)
        #expect(logins.jar == original)
        #expect(try Data(contentsOf: moved.appendingPathComponent("logins.sealed")) == saved)
    }

    @Test func corruptStoredLoginsArePreservedAndCannotBeOverwritten() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data("corrupt jar".utf8)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let logins = SharedBrowserLogins(file: file, key: { SymmetricKey(size: .bits256) })
        #expect(await logins.prepare() == false)
        logins.clear()
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func retryPublishesReadinessAndSignOutToExistingConsumers() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("logins.sealed")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var denied = true
        let logins = SharedBrowserLogins(
            file: file,
            key: {
                if denied { throw CocoaError(.fileReadNoPermission) }
                return SymmetricKey(size: .bits256)
            })
        var prepared = 0
        var cleared = 0
        let consumer = logins.changes.sink {
            switch $0.change {
            case .prepared: prepared += 1
            case .cleared: cleared += 1
            case .updated: break
            }
        }
        defer { consumer.cancel() }
        #expect(await logins.prepare() == false)
        #expect(prepared == 0)
        denied = false
        #expect(await logins.prepare())
        #expect(prepared == 1)
        logins.clear()
        #expect(cleared == 1)
        #expect(await logins.prepare())
        #expect(prepared == 1)
    }
}
