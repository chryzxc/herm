import Foundation
import Testing

@testable import Herm

@MainActor
struct BrowserCookieTests {
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

}
