import Testing

@testable import Herm

@Suite struct HermUpdateParsingTests {
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
