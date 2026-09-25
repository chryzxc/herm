import Foundation
import Testing
@testable import HermesAgentDock

struct ProviderQuotaTests {
    @Test func quotaWorkspaceNeedsAttentionFlagsCriticalOnly() {
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

    private func snapshot(_ provider: String, _ windows: [(String, Double?, Date?)] = []) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            displayName: provider,
            model: nil,
            updatedAt: .now,
            windows: windows.map {
                ProviderQuotaWindow(id: $0.0, label: $0.0, remainingPercent: $0.1, remainingDisplay: nil, limitDisplay: nil, resetsAt: $0.2, resetsDisplay: nil)
            },
            safeDetail: nil
        )
    }

    @Test func quotaOrderPrefersSavedOrderThenCatalogGroupingAccounts() {
        let reported = ["codex", "codex-hermes-0", "codex-hermes-1", "claude", "glm"].map { snapshot($0) }
        let catalog = ["codex-hermes", "codex", "opencode", "glm", "claude"]

        let defaultOrder = QuotaWorkspacePresentation.ordered(reported, savedOrder: [], catalogOrder: catalog)
        #expect(defaultOrder.map(\.provider) == ["codex-hermes-0", "codex-hermes-1", "codex", "glm", "claude"])

        let custom = QuotaWorkspacePresentation.ordered(reported, savedOrder: ["claude", "codex-hermes-1", "gone"], catalogOrder: catalog)
        #expect(custom.map(\.provider) == ["claude", "codex-hermes-1", "codex-hermes-0", "codex", "glm"])
    }

    @Test func quotaMoveTakesTheTargetPosition() {
        let ids = ["a", "b", "c", "d"]
        #expect(QuotaWorkspacePresentation.moving("a", to: "c", in: ids) == ["b", "c", "a", "d"])
        #expect(QuotaWorkspacePresentation.moving("d", to: "b", in: ids) == ["a", "d", "b", "c"])
        #expect(QuotaWorkspacePresentation.moving("a", to: "a", in: ids) == ids)
        #expect(QuotaWorkspacePresentation.moving("x", to: "a", in: ids) == ids)
    }

    @Test func quotaOverviewUsesTheTightestWindowAndPrefersRecoveries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let exhausted = snapshot("codex", [("Session", 97, now.addingTimeInterval(120)), ("Weekly", 0, now.addingTimeInterval(21 * 3600))])
        let roomy = snapshot("claude", [("Session", 60, now.addingTimeInterval(600)), ("Weekly", 80, nil)])
        let unreported = snapshot("glm", [("Session", nil, nil)])

        #expect(QuotaWorkspacePresentation.effectiveRemaining(exhausted) == 0)
        #expect(QuotaWorkspacePresentation.bestAvailable([exhausted, roomy, unreported])?.provider == "claude")
        #expect(QuotaWorkspacePresentation.bestAvailable([unreported]) == nil)

        let recovery = QuotaWorkspacePresentation.nextReset([exhausted, roomy], now: now)
        #expect(recovery?.window.label == "Weekly")
        #expect(recovery?.restoresAttention == true)
        #expect(QuotaWorkspacePresentation.nextReset([roomy], now: now)?.restoresAttention == false)

        #expect(QuotaWorkspacePresentation.healthLabel(exhausted) == "Exhausted")
        #expect(QuotaWorkspacePresentation.healthLabel(roomy) == nil)
        #expect(QuotaWorkspacePresentation.healthLabel(snapshot("x", [("Weekly", 15, nil)])) == "Low")
    }

    @Test func quotaCompactDurationFormatsCountdowns() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(QuotaWorkspacePresentation.compactDuration(from: now, to: now.addingTimeInterval(30)) == "<1m")
        #expect(QuotaWorkspacePresentation.compactDuration(from: now, to: now.addingTimeInterval(45 * 60)) == "45m")
        #expect(QuotaWorkspacePresentation.compactDuration(from: now, to: now.addingTimeInterval(3 * 3600 + 20 * 60)) == "3h 20m")
        #expect(QuotaWorkspacePresentation.compactDuration(from: now, to: now.addingTimeInterval(21 * 3600)) == "21h")
        #expect(QuotaWorkspacePresentation.compactDuration(from: now, to: now.addingTimeInterval(52 * 3600)) == "2d 4h")
    }

    @Test func providerNicknamesPersistTrimmedAndClearWhenBlank() throws {
        let suite = "ProviderQuotaTests.nicknames.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        ProviderNicknameStore(defaults: defaults).setNickname("  Work account ", for: "codex-hermes-1")
        #expect(ProviderNicknameStore(defaults: defaults).nickname(for: "codex-hermes-1") == "Work account")

        ProviderNicknameStore(defaults: defaults).setNickname("   ", for: "codex-hermes-1")
        #expect(ProviderNicknameStore(defaults: defaults).nickname(for: "codex-hermes-1") == nil)
    }

    @Test func hermesPoolIsTheSourceOfTruthForCodexAccounts() {
        let token = ["access_token": "a", "refresh_token": "r"]
        let store: [String: Any] = [
            // Hermes mirrors its device-code login into both places; the pool
            // copy must not produce a second card for the same account.
            "providers": ["openai-codex": ["tokens": token]],
            "credential_pool": ["openai-codex": [
                ["id": "5796db", "label": "work", "priority": 1, "access_token": "b"],
                ["id": "f4499e", "label": "device_code", "priority": 0, "access_token": "a"],
                ["id": "broken", "label": "no token", "priority": 2]
            ]]
        ]
        let credentials = CodexQuotaService.hermesCredentials(fromAuthStore: store)
        #expect(credentials.map { $0?.id } == ["f4499e", "5796db"])
        #expect(credentials.map { $0?.position } == [1, 2])
        #expect(credentials.first??.label == "device_code")
    }

    @Test func hermesPrimaryLoginIsUsedOnlyWithoutAPool() {
        let store: [String: Any] = ["providers": ["openai-codex": ["tokens": ["access_token": "a"]]]]
        let credentials = CodexQuotaService.hermesCredentials(fromAuthStore: store)
        #expect(credentials.count == 1)
        #expect(credentials.first! == nil)
    }

    @MainActor @Test func parsesHermesCredentialSoOnlyPooledAccountsAreRemovable() {
        var raw: [String: Any] = [
            "provider": "codex-hermes-f4499e",
            "display_name": "Codex (Account 1)",
            "updated_at": QuotaJSON.iso8601String(from: .now),
            "windows": [[String: Any]](),
            "safe_detail": "Hermes rejected this Codex sign-in."
        ]
        #expect(ControlCenterModel.parseProviderQuota(raw)?.hermesCredential == nil)

        raw["hermes_credential"] = ["provider": "openai-codex", "id": "f4499e", "label": "device_code", "position": 1] as [String: Any]
        let snapshot = ControlCenterModel.parseProviderQuota(raw)
        #expect(snapshot?.hermesCredential == HermesPooledCredential(provider: "openai-codex", id: "f4499e", label: "device_code", position: 1))
        // A failed read still yields a card, so the account can be removed.
        #expect(snapshot?.windows.isEmpty == true)
    }
}
