import Foundation
import Testing
@testable import Herm

@MainActor
struct HermesDiagnosticsServiceTests {
    @Test func summaryStopsAfterThreeVisibleLinesWithoutChangingRedaction() {
        let output = "\u{001B}[32mReady\u{001B}[0m\nAuth file: /Users/test/auth.json\n\n"
            + "Loaded .env\nStatus: token=secret\nProject: ~/work\n"
            + String(repeating: "Ignored token=secret /Users/test/private\n", count: 10_000)
        #expect(HermesDiagnosticsService.safeSummary(output) == "Ready  ·  Status: token: ••••  ·  Project: ••••/work")
    }

    @Test func thrownDiagnosticErrorsAreRedactedBeforeBecomingDetails() async {
        let service = HermesDiagnosticsService()
        let diagnostics = await service.read(client: ThrowingDiagnosticsRPCClient())
        let detail = diagnostics.first?.detail ?? ""

        #expect(!detail.contains("super-secret-token"))
        #expect(!detail.contains("/Users/example/private"))
        #expect(detail.isEmpty)
    }

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
        Token: ghp_aB...pQrS
        Webhook: xoxb-1...cdef
        """)

        #expect(!summary.contains("ghp_aB...pQrS"))
        #expect(!summary.contains("xoxb-1...cdef"))
        #expect(summary.contains("••••"))
    }

    @Test func safeSummaryMasksEndpointURLs() {
        let summary = HermesDiagnosticsService.safeSummary("Endpoint: https://gateway.example.test/rpc")

        #expect(!summary.contains("https://gateway.example.test/rpc"))
        #expect(summary == "Endpoint: ••••")
    }

    @Test func safeSummaryMasksEmbeddedCredentialEndpointURLs() {
        let summary = HermesDiagnosticsService.safeSummary("Endpoint: https://admin:super-secret@gateway.example.test/rpc")

        #expect(!summary.contains("https://admin:super-secret@gateway.example.test/rpc"))
        #expect(!summary.contains("super-secret"))
        #expect(summary == "Endpoint: ••••")
    }

    @Test func safeSummaryMasksTildeHomePaths() {
        let summary = HermesDiagnosticsService.safeSummary("""
        Ready
        Cache: ~/.hermes/cache
        """)

        #expect(!summary.contains("~/"))
        #expect(summary.contains("••••"))
    }

    @Test func safeSummaryCapsVeryLongDiagnosticLines() {
        let summary = HermesDiagnosticsService.safeSummary(String(repeating: "x", count: 2_000))
        #expect(summary.count == 1_000)
    }
}

@MainActor
private final class ThrowingDiagnosticsRPCClient: HermesRPCClientProtocol {
    enum Failure: LocalizedError {
        case rejected
        var errorDescription: String? {
            "super-secret-token at /Users/example/private/.env"
        }
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        throw Failure.rejected
    }
}
