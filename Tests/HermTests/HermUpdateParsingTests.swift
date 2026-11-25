import Foundation
import Testing

@testable import Herm

@Suite struct HermUpdateParsingTests {
    private enum LookupFailure: Error { case missing }

    private func release(_ version: String, commit: String? = nil) -> HermRelease {
        HermRelease(
            version: version, pageURL: nil,
            assetURL: URL(string: "https://api.github.com/repos/chryzxc/herm/releases/assets/1")!, digest: nil,
            commit: commit)
    }

    @Test func nightlyLookupSurvivesAMissingStableRelease() async throws {
        let nightly = release("nightly bbbbbbbb", commit: String(repeating: "b", count: 40))
        let result = try await HermAppUpdater.findUpdate(
            currentVersion: "1.0.0", isNightly: true, currentCommit: "aaaaaaaa"
        ) { path in
            if path == "latest" { throw LookupFailure.missing }
            #expect(path == "tags/nightly")
            return nightly
        }
        #expect(result.hasUpdate && result.latest == nightly)
    }

    @Test func stableBuildNeverChecksTheNightlyChannel() async throws {
        let stable = release("1.0.0")
        let result = try await HermAppUpdater.findUpdate(
            currentVersion: "1.0.0", isNightly: false, currentCommit: nil
        ) { path in
            #expect(path == "latest")
            return stable
        }
        #expect(!result.hasUpdate)
    }

    @Test func failedNightlyLookupDoesNotClaimUpToDate() async {
        let stable = release("0.9.0")
        await #expect(throws: (any Error).self) {
            try await HermAppUpdater.findUpdate(
                currentVersion: "1.0.0", isNightly: true, currentCommit: "aaaaaaaa"
            ) { path in
                if path == "latest" { return stable }
                throw LookupFailure.missing
            }
        }
    }

    @Test func releaseSignatureAssetIsOptionalAndRequiresHTTPS() throws {
        var value = payload(tag: "v1.0.0", prerelease: false)
        var assets = try #require(value["assets"] as? [[String: Any]])
        assets.append(["name": "Herm.dmg.sig", "url": "https://api.github.com/repos/chryzxc/herm/releases/assets/2"])
        value["assets"] = assets
        #expect(HermUpdateParsing.release(from: value)?.signatureURL?.lastPathComponent == "2")
        assets[1]["url"] = "http://api.github.com/repos/chryzxc/herm/releases/assets/2"
        value["assets"] = assets
        #expect(HermUpdateParsing.release(from: value)?.signatureURL == nil)
    }

    @Test func updateChecksDoNotRequireAWriteableInstallLocation() {
        let app = URL(fileURLWithPath: "/System/Applications/Herm.app")
        #expect(HermAppUpdater.checkUnavailableReason(version: "1.0.0", bundleURL: app) == nil)
        #expect(HermAppUpdater.checkUnavailableReason(version: nil, bundleURL: app) != nil)
        #expect(HermAppUpdater.checkUnavailableReason(version: "1.0.0", bundleURL: app.deletingPathExtension()) != nil)
    }

    @Test func nightlyTakesTheStableBuildOfItsVersion() {
        #expect(HermUpdateParsing.shouldOffer("0.1.1", over: "0.1.1", isNightly: true))
        #expect(!HermUpdateParsing.shouldOffer("0.1.1", over: "0.1.1", isNightly: false))
        #expect(!HermUpdateParsing.shouldOffer("0.1.0", over: "0.1.1", isNightly: true))
        #expect(HermUpdateParsing.shouldOffer("0.2.0", over: "0.1.1", isNightly: false))
    }

    private func payload(tag: String, prerelease: Bool, commit: String = String(repeating: "b", count: 40)) -> [String:
        Any]
    {
        [
            "tag_name": tag, "prerelease": prerelease, "target_commitish": commit,
            "assets": [["name": "Herm.dmg", "url": "https://api.github.com/repos/chryzxc/herm/releases/assets/1"]],
        ]
    }

    @Test func nightlyReleaseIsIdentifiedByCommit() throws {
        var value = payload(tag: "nightly", prerelease: true)
        value["name"] = "Nightly 1.2.3-dev (bbbbbbbb)"
        let nightly = try #require(HermUpdateParsing.release(from: value))
        #expect(nightly.commit == String(repeating: "b", count: 40))
        #expect(nightly.downloadVersionLabel == "1.2.3-dev · bbbbbbbb")
        #expect(HermUpdateParsing.isNewerNightly(nightly, currentCommit: String(repeating: "a", count: 40)))
        #expect(!HermUpdateParsing.isNewerNightly(nightly, currentCommit: "bbbbbbbb"))
        #expect(!HermUpdateParsing.isNewerNightly(nightly, currentCommit: nil))
        value["name"] = "Nightly 1.2.3-dev (aaaaaaaa)"
        #expect(HermUpdateParsing.release(from: value)?.downloadVersionLabel == "Build bbbbbbbb")
    }

    @Test func otherPrereleasesAreIgnored() {
        #expect(HermUpdateParsing.release(from: payload(tag: "v0.3.0-rc.1", prerelease: true)) == nil)
        #expect(HermUpdateParsing.release(from: payload(tag: "v0.3.0", prerelease: false))?.commit == nil)
    }

    @Test func alternateOffersNightlyToDevAndStableAndStableToNightly() {
        for current in [HermBuildInfo.Channel.dev, .stable] {
            let channel = HermAlternateReleaseChannel(current: current)
            #expect(channel == .nightly)
            #expect(channel.releasePath == "tags/nightly")
        }
        let channel = HermAlternateReleaseChannel(current: .nightly)
        #expect(channel == .stable)
        #expect(channel.releasePath == "latest")
    }

    @Test func releaseDatePrefersTheDmgUpdateAndFallsBackToPublication() throws {
        var value = payload(tag: "nightly", prerelease: true)
        value["published_at"] = "2026-11-21T03:00:00Z"
        #expect(HermUpdateParsing.release(from: value)?.updatedAt == ISO8601Parsing.date("2026-11-21T03:00:00Z"))
        var assets = try #require(value["assets"] as? [[String: String]])
        assets[0]["updated_at"] = "2026-11-22T03:00:00Z"
        value["assets"] = assets
        #expect(HermUpdateParsing.release(from: value)?.updatedAt == ISO8601Parsing.date("2026-11-22T03:00:00Z"))
    }

    @Test func archiveNameCannotContainPathComponents() {
        #expect(release("nightly abcdef12").archiveFilename == "Herm-nightly-abcdef12.dmg")
        #expect(!release("../weird/build").archiveFilename.contains("/"))
    }

    @MainActor @Test func alternateDownloadDoesNotStageAnInAppUpdate() async throws {
        let latest = release("nightly bbbbbbbb", commit: String(repeating: "b", count: 40))
        let saved = URL(fileURLWithPath: "/tmp/Herm-nightly-bbbbbbbb.dmg")
        let app = HermAppUpdater(
            build: HermBuildInfo(channel: "dev", commit: nil, isDebug: true),
            fetchAlternate: { channel in
                #expect(channel == .nightly)
                return latest
            },
            saveAlternate: { requested, progress in
                #expect(requested == latest)
                progress(0.5, "Downloading")
                return saved
            })
        app.checkAlternateIfStale()
        for _ in 0..<100 where app.alternateReleaseState == .checking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(app.alternateReleaseState == .available(latest))
        app.downloadAlternateRelease()
        #expect(app.alternateReleaseState == .downloading(latest, fraction: nil, stage: "Downloading"))
        for _ in 0..<100 where app.alternateReleaseState != .downloaded(latest, saved) {
            try await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        #expect(app.alternateReleaseState == .downloaded(latest, saved))
        #expect(app.phase == .idle)
        #expect(!app.hasUpdate)
    }

    @MainActor @Test func alternateLookupRejectsAReleaseFromTheWrongChannel() async throws {
        let stable = release("1.0.0")
        let app = HermAppUpdater(
            build: HermBuildInfo(channel: "stable", commit: nil, isDebug: false),
            fetchAlternate: { _ in stable })
        app.checkAlternateRelease()
        for _ in 0..<100 where app.alternateReleaseState == .checking {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = app.alternateReleaseState else {
            Issue.record("A stable release must not be shown as the alternate Nightly build.")
            return
        }
    }

    @Test func staleCheckThrottlesRepeatChecks() {
        let now = Date()
        #expect(HermAppUpdater.isStale(nil, now: now, maxAge: 900))
        #expect(!HermAppUpdater.isStale(now.addingTimeInterval(-60), now: now, maxAge: 900))
        #expect(HermAppUpdater.isStale(now.addingTimeInterval(-900), now: now, maxAge: 900))
    }
}
