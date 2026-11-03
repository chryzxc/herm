import Testing

@testable import Herm

@Suite struct HermUpdateParsingTests {
    @Test func labelsNightlyBuildsWithShortCommit() {
        #expect(HermUpdateParsing.nightlyBadge(channel: "nightly", commit: "1a2b3c4d5e6f") == "Nightly 1a2b3c4d")
        #expect(HermUpdateParsing.nightlyBadge(channel: "nightly", commit: "") == "Nightly")
        #expect(HermUpdateParsing.nightlyBadge(channel: nil, commit: "1a2b3c4d") == nil)
    }

    @Test func nightlyTakesTheStableBuildOfItsVersion() {
        #expect(HermUpdateParsing.shouldOffer("0.1.1", over: "0.1.1", isNightly: true))
        #expect(!HermUpdateParsing.shouldOffer("0.1.1", over: "0.1.1", isNightly: false))
        #expect(!HermUpdateParsing.shouldOffer("0.1.0", over: "0.1.1", isNightly: true))
        #expect(HermUpdateParsing.shouldOffer("0.2.0", over: "0.1.1", isNightly: false))
    }
}
