import Foundation
import Testing
@testable import HermesAgentDock

struct HermesUpdateServiceTests {
    @Test func updateCommandIsExactlyTheAllowListedCommand() {
        #expect(HermesUpdateService.updateCommandArguments == ["hermes", "update"])
        #expect(HermesUpdateService.updateCommandDisplay == "hermes update")
        #expect(HermesUpdateService.updateCommandArguments.contains(where: { $0.hasPrefix("-") }) == false)
    }

    @Test func parsesInstalledVersionAndInstallMethod() {
        let output = """
        Hermes Agent v0.19.1 (2026.7.30) · upstream e3b5512b
        Install directory: /Users/example/.hermes/hermes-agent
        Install method: git
        """

        let version = HermesUpdateParsing.installedVersion(from: output)

        #expect(version?.marketing == "0.19.1")
        #expect(version?.calendar == "2026.7.30")
        #expect(HermesUpdateParsing.installMethod(from: output) == "git")
    }

    @Test func parsesLatestReleasePayload() {
        let payload: [String: Any] = [
            "tag_name": "v2026.8.19",
            "name": "Hermes Agent v0.20.5 (v2026.8.19)",
            "published_at": "2026-08-21T12:16:39Z",
            "html_url": "https://github.com/NousResearch/hermes-agent/releases/tag/v2026.8.19"
        ]

        let release = HermesUpdateParsing.latestRelease(from: payload)

        #expect(release?.tag == "v2026.8.19")
        #expect(release?.marketing == "0.20.5")
        #expect(release?.calendar == "2026.8.19")
        #expect(release?.publishedAt != nil)
    }

    @Test func fallsBackToCalendarReleaseVersion() {
        let release = HermesUpdateParsing.latestRelease(from: ["tag_name": "v2026.8.19"])

        #expect(release?.marketing == nil)
        #expect(release?.calendar == "2026.8.19")
    }

    @Test func detectsOutdatedMarketingVersion() {
        let installed = HermesInstalledVersion(marketing: "0.19.1", calendar: "2026.7.30")
        let latest = HermesLatestRelease(tag: "v2026.8.19", marketing: "0.20.5", name: nil, publishedAt: nil, pageURL: nil)

        #expect(HermesUpdateParsing.isOutdated(installed: installed, latest: latest) == true)
    }

    @Test func reportsMatchingVersionsAsCurrent() {
        let installed = HermesInstalledVersion(marketing: "0.20.5", calendar: "2026.8.19")
        let latest = HermesLatestRelease(tag: "v2026.8.19", marketing: "0.20.5", name: nil, publishedAt: nil, pageURL: nil)

        #expect(HermesUpdateParsing.isOutdated(installed: installed, latest: latest) == false)
    }

    @Test func comparesCalendarVersionsWhenMarketingIsUnavailable() {
        let installed = HermesInstalledVersion(marketing: nil, calendar: "2026.7.30")
        let latest = HermesLatestRelease(tag: "v2026.8.19", marketing: nil, name: nil, publishedAt: nil, pageURL: nil)

        #expect(HermesUpdateParsing.isOutdated(installed: installed, latest: latest) == true)
    }

    @Test func returnsUnknownWhenVersionsCannotBeCompared() {
        let installed = HermesInstalledVersion(marketing: "0.19.1", calendar: nil)
        let latest = HermesLatestRelease(tag: "main", marketing: nil, name: nil, publishedAt: nil, pageURL: nil)

        #expect(HermesUpdateParsing.isOutdated(installed: installed, latest: latest) == nil)
    }

    @Test func sanitizesAnsiAndBoundsProgressLines() {
        #expect(HermesUpdateLogPresentation.sanitize("\u{001B}[32mSuccess\u{001B}[0m") == "Success")
        #expect(HermesUpdateLogPresentation.sanitize("   ") == nil)
        #expect(HermesUpdateLogPresentation.sanitize(String(repeating: "a", count: 300))?.count == 241)
    }
}
