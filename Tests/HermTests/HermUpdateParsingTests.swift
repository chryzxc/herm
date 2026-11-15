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
        let nightly = try #require(HermUpdateParsing.release(from: payload(tag: "nightly", prerelease: true)))
        #expect(nightly.commit == String(repeating: "b", count: 40))
        #expect(HermUpdateParsing.isNewerNightly(nightly, currentCommit: String(repeating: "a", count: 40)))
        #expect(!HermUpdateParsing.isNewerNightly(nightly, currentCommit: "bbbbbbbb"))
        #expect(!HermUpdateParsing.isNewerNightly(nightly, currentCommit: nil))
    }

    @Test func otherPrereleasesAreIgnored() {
        #expect(HermUpdateParsing.release(from: payload(tag: "v0.3.0-rc.1", prerelease: true)) == nil)
        #expect(HermUpdateParsing.release(from: payload(tag: "v0.3.0", prerelease: false))?.commit == nil)
    }
}
