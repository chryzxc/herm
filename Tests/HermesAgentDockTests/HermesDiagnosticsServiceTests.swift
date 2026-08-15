import Testing
@testable import HermesAgentDock

struct HermesDiagnosticsServiceTests {
    @Test func safeSummaryMasksHomePathsAndDropsCredentialFiles() {
        let summary = HermesDiagnosticsService.safeSummary("""
        Gateway Service
        Status: running
        Auth file: /Users/example/.hermes/auth.json
        Project: /Users/example/hermes-agent
        """)

        #expect(summary == "Gateway Service  ·  Status: running  ·  Project: ••••/hermes-agent")
        #expect(!summary.contains("/Users/"))
        #expect(!summary.contains("example"))
        #expect(!summary.contains("auth.json"))
    }

    @Test func safeSummaryMasksInlineCredentialAssignments() {
        let summary = HermesDiagnosticsService.safeSummary("""
        Gateway: ok
        Status: running token=abc123
        Loaded api_key=sk_live_supersecret
        """)

        #expect(!summary.contains("abc123"))
        #expect(!summary.contains("sk_live_supersecret"))
        #expect(summary.contains("token: ••••"))
        #expect(summary.contains("api_key: ••••"))
    }

    @Test func safeSummaryMasksKnownProviderTokenPrefixes() {
        let summary = HermesDiagnosticsService.safeSummary("""
        Health: good
        Token: ghp_aBcDeFgHiJkLmN0pQrS
        Webhook: xoxb-123456789-abcdef
        """)

        #expect(!summary.contains("ghp_aBcDeFgHiJkLmN0pQrS"))
        #expect(!summary.contains("xoxb-123456789-abcdef"))
        #expect(summary.contains("••••"))
    }

    @Test func safeSummaryMasksTildeHomePaths() {
        let summary = HermesDiagnosticsService.safeSummary("""
        Ready
        Cache: ~/.hermes/cache
        """)

        #expect(!summary.contains("~/"))
        #expect(summary.contains("••••"))
    }
}
