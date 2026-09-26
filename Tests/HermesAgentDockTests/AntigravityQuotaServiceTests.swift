import Foundation
import Testing
@testable import HermesAgentDock

struct AntigravityQuotaServiceTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private static let futureReset = Date(timeIntervalSince1970: 1_700_003_600)

    @Test func extractsFlagValuesFromCommandLines() {
        #expect(AntigravityQuotaService.flagValue(command: "server --csrf_token abc --port 1", flag: "--csrf_token") == "abc")
        #expect(AntigravityQuotaService.flagValue(command: "server --csrf_token=abc", flag: "--csrf_token") == "abc")
        #expect(AntigravityQuotaService.flagValue(command: "server", flag: "--csrf_token") == nil)
        #expect(AntigravityQuotaService.flagValue(command: "server --csrf_token", flag: "--csrf_token") == nil)
    }

    @Test func ranksLanguageServerCandidatesByMarkerMatch() {
        let psOutput = """
        100 /Applications/Antigravity.app/Contents/language_server --ide_name antigravity --csrf_token tok --extension_server_port 4311
        200 /opt/other/language_server --ide_name windsurf --csrf_token tok2
        300 /usr/local/bin/agy language-server --serve
        700 /opt/antigravity/bin/language_server
        """
        let app = AntigravityQuotaService.languageServerCandidates(psOutput: psOutput, processName: "language_server", markers: ["antigravity", "antigravity-ide"])
        #expect(app.map { $0.pid } == [100, 700])

        let exact = AntigravityQuotaService.languageServerCandidates(
            psOutput: """
            500 /usr/local/bin/language_server --ide_name antigravity
            600 /usr/local/bin/language_server --ide_name antigravity-next
            """,
            processName: "language_server",
            markers: ["antigravity", "antigravity-ide"]
        )
        #expect(exact.map { $0.pid } == [500])

        let cli = AntigravityQuotaService.languageServerCandidates(psOutput: psOutput, processName: "agy", markers: [])
        #expect(cli.map { $0.pid } == [300])
    }

    @Test func parsesListeningPortsFromLsofOutput() {
        let lsofOutput = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        languag~ 100 x 8u IPv4 ... TCP 127.0.0.1:52168 (LISTEN)
        languag~ 100 x 9u IPv6 ... TCP *:4311 (LISTEN)
        """
        #expect(AntigravityQuotaService.listeningPorts(lsofOutput) == [4311, 52168])
        #expect(AntigravityQuotaService.listeningPorts("languag~ 100 x 8u IPv4 ... TCP 127.0.0.1:52168 (ESTABLISHED)") == [])
    }

    @Test func poolsLegacyModelQuotasIntoSharedPools() {
        let configs = [
            AntigravityQuotaService.ModelQuota(label: "Gemini 3 Pro (High)", modelID: "M7", remainingFraction: 0.5, resetTime: Self.futureReset),
            AntigravityQuotaService.ModelQuota(label: "Gemini 3 Pro (Low)", modelID: "M8", remainingFraction: 0.9, resetTime: nil),
            AntigravityQuotaService.ModelQuota(label: "Claude Sonnet 4.5", modelID: "M26", remainingFraction: 0.25, resetTime: Self.futureReset),
            AntigravityQuotaService.ModelQuota(label: "GPT-OSS 120B", modelID: "M30", remainingFraction: 0.75, resetTime: nil)
        ]
        let windows = AntigravityQuotaService.legacyWindows(configs, now: Self.fixedNow)
        #expect(windows.map { $0["id"] as? String } == ["gemini-5h", "3p-5h"])
        #expect(windows.map { $0["label"] as? String } == ["Gemini Session", "Claude & GPT Session"])
        #expect(windows.map { $0["remaining_percent"] as? Double } == [50, 25])
        #expect(windows.allSatisfy { ($0["resets_at"] as? String) != nil })
    }

    @Test func depletedModelsDrainTheirPoolWithoutResetTime() {
        let configs = [
            AntigravityQuotaService.ModelQuota(label: "Gemini 3 Pro (High)", modelID: "M7", remainingFraction: 0.5, resetTime: Self.futureReset),
            AntigravityQuotaService.ModelQuota(label: "Claude Opus 4.6 (Thinking)", modelID: "M26", remainingFraction: 0, resetTime: nil),
            AntigravityQuotaService.ModelQuota(label: "Claude Sonnet 4.5", modelID: "M27", remainingFraction: 0.7, resetTime: Self.futureReset)
        ]
        let windows = AntigravityQuotaService.legacyWindows(configs, now: Self.fixedNow)
        let claude = windows.first { $0["id"] as? String == "3p-5h" }
        #expect(claude?["remaining_percent"] as? Double == 0)
        #expect(claude?["resets_at"] == nil)
    }

    @Test func skipsInternalAndEmptyModels() {
        let configs = [
            AntigravityQuotaService.ModelQuota(label: "Gemini 3 Pro", modelID: "MODEL_CHAT_20706", remainingFraction: 0, resetTime: nil),
            AntigravityQuotaService.ModelQuota(label: "Gemini 3 Flash", modelID: "M9", remainingFraction: 0.6, resetTime: nil),
            AntigravityQuotaService.ModelQuota(label: "  ", modelID: "M10", remainingFraction: 0.1, resetTime: nil)
        ]
        let windows = AntigravityQuotaService.legacyWindows(configs, now: Self.fixedNow)
        #expect(windows.map { $0["id"] as? String } == ["gemini-5h"])
        #expect(windows.first?["remaining_percent"] as? Double == 60)
    }

    @Test func parsesUserStatusPlanAndConfigs() {
        let json: [String: Any] = [
            "userStatus": [
                "userTier": ["name": "Google AI Pro"],
                "cascadeModelConfigData": ["clientModelConfigs": [
                    ["label": "Gemini 3 Pro (High)", "modelOrAlias": ["model": "M7"], "quotaInfo": ["remainingFraction": 0.8, "resetTime": "2026-08-22T12:00:00Z"]],
                    ["label": "Claude Opus 4.6 (Thinking)", "modelOrAlias": ["model": "M26"]]
                ]]
            ]
        ]
        let parsed = AntigravityQuotaService.parseUserStatus(json)
        #expect(parsed?.plan == "Pro")
        #expect(parsed?.configs.count == 2)
        #expect(parsed?.configs[0].remainingFraction == 0.8)
        #expect(parsed?.configs[1].remainingFraction == 0)

        #expect(AntigravityQuotaService.parseCommandModelConfigs(["clientModelConfigs": [["label": "Gemini 3 Flash"]]])?.count == 1)
        #expect(AntigravityQuotaService.parseCommandModelConfigs(["unexpected": 1]) == nil)
    }

    @Test func formatsTierLabels() {
        #expect(AntigravityQuotaService.formatPlan("Google AI Ultra") == "Ultra")
        #expect(AntigravityQuotaService.formatPlan("Pro") == "Pro")
        #expect(AntigravityQuotaService.formatPlan("  Free tier ") == "Free")
        #expect(AntigravityQuotaService.formatPlan(nil) == nil)
        #expect(AntigravityQuotaService.formatPlan("") == nil)
    }

    @Test func recognizesOnlySummaryPayloadsWithGroups() {
        #expect(AntigravityQuotaService.hasQuotaSummaryGroups(["response": ["groups": []]]))
        #expect(AntigravityQuotaService.hasQuotaSummaryGroups(["groups": [["buckets": []]]]))
        #expect(!AntigravityQuotaService.hasQuotaSummaryGroups(["error": ["code": 1]]))
        #expect(!AntigravityQuotaService.hasQuotaSummaryGroups(["response": ["groups": "broken"]]))
    }

    @Test func largeProcessOutputDoesNotDeadlock() async {
        let output = await AntigravityQuotaService.processOutput(executable: "/usr/bin/head", arguments: ["-c", "262144", "/dev/zero"])
        #expect(output?.utf8.count == 262_144)
        #expect(await AntigravityQuotaService.processOutput(executable: "/usr/bin/false", arguments: []) == nil)
        #expect(await AntigravityQuotaService.processOutput(executable: "/nonexistent/binary", arguments: []) == nil)
    }

    @Test func normalizedLabelsStripTrailingVariants() {
        #expect(AntigravityQuotaService.normalizedModelLabel("Gemini 3 Pro (High)") == "Gemini 3 Pro")
        #expect(AntigravityQuotaService.normalizedModelLabel("Claude Opus 4.6 ") == "Claude Opus 4.6")
    }
}
