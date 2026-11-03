import Testing

@testable import Herm

@Suite struct HermUpdateParsingTests {
    @Test func labelsNightlyBuildsWithShortCommit() {
        #expect(
            HermUpdateParsing.versionLabel(version: "0.1.1", channel: "nightly", commit: "1a2b3c4d5e6f")
                == "0.1.1 · Nightly (1a2b3c4d)")
        #expect(HermUpdateParsing.versionLabel(version: "0.1.1", channel: nil, commit: "1a2b3c4d") == "0.1.1")
        #expect(HermUpdateParsing.versionLabel(version: nil, channel: "nightly", commit: nil) == "dev build")
    }

    @Test func nightlyTakesTheStableBuildOfItsVersion() {
        #expect(HermUpdateParsing.shouldOffer("0.1.1", over: "0.1.1", isNightly: true))
        #expect(!HermUpdateParsing.shouldOffer("0.1.1", over: "0.1.1", isNightly: false))
        #expect(!HermUpdateParsing.shouldOffer("0.1.0", over: "0.1.1", isNightly: true))
        #expect(HermUpdateParsing.shouldOffer("0.2.0", over: "0.1.1", isNightly: false))
    }
}
