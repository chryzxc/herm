import Testing

@testable import Herm

@Suite struct HermBuildInfoTests {
    @Test func labelsNightlyBuildsWithOptionalShortCommit() {
        let build = HermBuildInfo(channel: "nightly", commit: "1a2b3c4d5e6f", isDebug: false)
        #expect(build.channel == .nightly)
        #expect(build.badge() == "Nightly")
        #expect(build.badge(includesCommit: true) == "Nightly 1a2b3c4d")
        #expect(HermBuildInfo(channel: "nightly", commit: "", isDebug: false).badge(includesCommit: true) == "Nightly")
        #expect(HermBuildInfo(channel: "nightly", commit: nil, isDebug: true).badge() == "Nightly")
    }

    @Test func labelsDevelopmentBuilds() {
        #expect(HermBuildInfo(channel: nil, commit: nil, isDebug: true).badge() == "Dev")
        #expect(HermBuildInfo(channel: "dev", commit: nil, isDebug: false).badge() == "Dev")
    }

    @Test func stableBuildsHaveNoBadge() {
        #expect(HermBuildInfo(channel: nil, commit: "1a2b3c4d", isDebug: false).badge(includesCommit: true) == nil)
        #expect(HermBuildInfo(channel: "stable", commit: "1a2b3c4d", isDebug: true).badge(includesCommit: true) == nil)
    }
}
