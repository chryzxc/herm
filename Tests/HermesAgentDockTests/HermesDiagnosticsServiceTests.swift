import Testing
@testable import HermesAgentDock

struct HermesDiagnosticsServiceTests {
    @Test func safeSummaryRemovesSensitivePathsAndKeepsUsefulStatus() {
        let summary = HermesDiagnosticsService.safeSummary("""
        Gateway Service
        Status: running
        Auth file: /Users/example/.hermes/auth.json
        Project: /Users/example/hermes-agent
        """)

        #expect(summary == "Gateway Service  ·  Status: running")
    }
}
