import Foundation
import Testing
@testable import HermesAgentDock

struct ProviderQuotaTests {
    @Test func quotaWorkspaceSortsWorstHealthFirstWithCatalogTieBreakers() {
        let healthy = ProviderQuotaSnapshot(
            provider: "codex",
            displayName: "Codex",
            model: nil,
            updatedAt: .now,
            windows: [ProviderQuotaWindow(id: "weekly", label: "Weekly", remainingPercent: 80, remainingDisplay: nil, limitDisplay: nil, resetsAt: nil, resetsDisplay: nil)],
            safeDetail: nil
        )
        let warning = ProviderQuotaSnapshot(
            provider: "claude",
            displayName: "Claude",
            model: nil,
            updatedAt: .now,
            windows: [ProviderQuotaWindow(id: "weekly", label: "Weekly", remainingPercent: 20, remainingDisplay: nil, limitDisplay: nil, resetsAt: nil, resetsDisplay: nil)],
            safeDetail: nil
        )
        let critical = ProviderQuotaSnapshot(
            provider: "glm",
            displayName: "GLM",
            model: nil,
            updatedAt: .now,
            windows: [ProviderQuotaWindow(id: "session", label: "Session", remainingPercent: 5, remainingDisplay: nil, limitDisplay: nil, resetsAt: nil, resetsDisplay: nil)],
            safeDetail: nil
        )
        let unknown = ProviderQuotaSnapshot(
            provider: "opencode",
            displayName: "OpenCode",
            model: nil,
            updatedAt: .now,
            windows: [],
            safeDetail: nil
        )

        #expect(QuotaWorkspacePresentation.sortedConnected([healthy, unknown, warning, critical]).map(\.provider) == ["glm", "claude", "opencode", "codex"])
        #expect(QuotaWorkspacePresentation.needsAttention(critical))
        #expect(!QuotaWorkspacePresentation.needsAttention(unknown))
    }

    @Test func quotaWorkspaceOverviewSentenceHandlesCountsAndAvailableProviders() {
        #expect(QuotaWorkspacePresentation.overviewSentence(providerCount: 6, connectedCount: 3, attentionCount: 0) == "3 connected · 0 need attention · 3 available to connect")
        #expect(QuotaWorkspacePresentation.overviewSentence(providerCount: 2, connectedCount: 1, attentionCount: 1) == "1 connected · 1 needs attention · 1 available to connect")
    }

    @MainActor
    @Test func parsesBoundedQuotaWindowsAndDropsInvalidValues() {
        let snapshot = ControlCenterModel.parseProviderQuota([
            "provider": "codex",
            "display_name": "Codex",
            "model": "gpt-5.3-codex",
            "updated_at": "2026-08-21T00:00:00Z",
            "windows": [
                ["id": "weekly", "label": "Weekly", "remaining_percent": 81.0, "resets_at": "2026-08-27T00:00:00Z"],
                ["id": "bad", "label": "Bad", "remaining_percent": 101],
                ["id": "weekly", "label": "Duplicate", "remaining_percent": 20]
            ]
        ])

        #expect(snapshot?.provider == "codex")
        #expect(snapshot?.windows.count == 1)
        #expect(snapshot?.windows.first?.threshold == .healthy)
        #expect(snapshot?.windows.first?.resetsAt != nil)
    }

    @MainActor
    @Test func malformedSnapshotIsUnavailableRatherThanFabricated() {
        #expect(ControlCenterModel.parseProviderQuota(["provider": "codex"]) == nil)
        #expect(ControlCenterModel.parseProviderQuota([
            "provider": "codex",
            "updated_at": "2026-08-21T00:00:00Z",
            "windows": [["id": "w", "label": "Weekly", "remaining_percent": -1]]
        ])?.windows.isEmpty == true)
    }

    @MainActor
    @Test func parsesFractionalResetTimestampsFromOpenCode() {
        let snapshot = ControlCenterModel.parseProviderQuota([
            "provider": "opencode",
            "display_name": "OpenCode Go",
            "updated_at": "2026-08-21T00:00:00.123Z",
            "windows": [[
                "id": "rolling",
                "label": "Session",
                "remaining_percent": 82,
                "resets_at": "2026-08-21T05:47:14.366Z"
            ]]
        ])

        #expect(snapshot?.windows.first?.resetsAt != nil)
    }

    @MainActor
    @Test func normalizesGLMCreditLimitWindows() {
        let raw = GLMQuotaService.normalize([
            "data": ["level": "pro", "limits": [
                ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 21, "nextResetTime": 1786073946574],
                ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "percentage": 37, "nextResetTime": 1786660486998]
            ]]
        ], now: Date(timeIntervalSince1970: 1_700_000_000))
        let snapshot = ControlCenterModel.parseProviderQuota(raw)
        #expect(snapshot?.provider == "glm")
        #expect(snapshot?.displayName == "GLM Coding Plan")
        #expect(snapshot?.windows.map(\.id) == ["session", "weekly"])
        #expect(snapshot?.windows.first?.remainingPercent == 79)
    }

    @MainActor
    @Test func normalizesClaudeUsageWindows() {
        let raw = ClaudeQuotaService.normalize([
            "five_hour": ["utilization": 25, "resets_at": "2026-08-22T12:00:00Z"],
            "seven_day": ["utilization": 40, "resets_at": "2026-08-27T12:00:00Z"],
            "seven_day_opus": ["utilization": 10]
        ], now: Date(timeIntervalSince1970: 1_700_000_000))
        let snapshot = ControlCenterModel.parseProviderQuota(raw)
        #expect(snapshot?.provider == "claude")
        #expect(snapshot?.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(snapshot?.windows.first?.remainingPercent == 75)
    }

    @MainActor
    @Test func normalizesAntigravitySharedQuotaPools() {
        let raw: [String: Any] = [
            "response": ["groups": [["buckets": [
                ["bucketId": "gemini-5h", "remainingFraction": 0.82, "resetTime": "2026-08-22T12:00:00Z"],
                ["bucketId": "gemini-weekly", "remainingFraction": 0.61],
                ["bucketId": "3p-5h", "remainingFraction": 0.44],
                ["bucketId": "3p-weekly", "remainingFraction": 0.33],
                ["bucketId": "future-pool", "remainingFraction": 0.99]
            ]]]]
        ]
        let snapshot = ControlCenterModel.parseProviderQuota(AntigravityQuotaService.normalize(raw, now: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(snapshot?.provider == "antigravity")
        #expect(snapshot?.windows.map(\.id) == ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        #expect(snapshot?.windows.first?.remainingPercent == 82)
    }
}
