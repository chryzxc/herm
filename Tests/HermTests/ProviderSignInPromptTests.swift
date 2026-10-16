import Foundation
import Testing
@testable import Herm

struct ProviderSignInPromptTests {
    @Test func readsCodexDeviceCode() {
        let prompt = ProviderSignInPrompt.parse([
            "To sign in, open https://auth.openai.com/codex/device",
            "Enter this code: ABCD-1234",
        ])
        #expect(prompt.url?.absoluteString == "https://auth.openai.com/codex/device")
        #expect(prompt.code == "ABCD-1234")
        #expect(!prompt.needsInput)
    }

    @Test func readsDeviceFlowSteps() {
        let prompt = ProviderSignInPrompt.parse(["1. Open: https://portal.nousresearch.com/device", "2. If prompted, enter code: WXYZ-9876"])
        #expect(prompt.url?.host == "portal.nousresearch.com")
        #expect(prompt.code == "WXYZ-9876")
    }

    @Test func detectsStdinPromptsOnlyOnPartialLine() {
        let anthropic = ProviderSignInPrompt.parse(["Open https://claude.ai/oauth/authorize?x=1"], partial: "Authorization code: ")
        #expect(anthropic.needsInput && anthropic.asksForCode)
        let nous = ProviderSignInPrompt.parse([], partial: "Import these credentials? [Y/n]: ")
        #expect(nous.needsInput && !nous.asksForCode)
        #expect(!ProviderSignInPrompt.parse(["Authorization code: "]).needsInput)
    }

    @Test func readsSuccessLabel() {
        let prompt = ProviderSignInPrompt.parse(["Added anthropic OAuth credential #2: \"work\""])
        #expect(prompt.accountLabel == "work")
        #expect(prompt.successLine?.hasPrefix("Added anthropic") == true)
    }

    @Test func linksAreUnderlined() {
        let linked = ProviderSignInPrompt.linked("Open https://example.com/x now")
        let runs = linked.runs.filter { $0.link != nil }
        #expect(runs.count == 1)
        #expect(runs.first?.link?.absoluteString == "https://example.com/x")
        #expect(runs.first?.underlineStyle == .single)
        #expect(String(linked.characters) == "Open https://example.com/x now")
    }
}

struct HermesProviderCatalogTests {
    @Test func poolSnapshotsCoverEveryProviderButCodex() {
        let store: [String: Any] = ["credential_pool": [
            "openai-codex": [["id": "c1", "label": "me"]],
            "anthropic": [["id": "b", "label": "second", "priority": 1], ["id": "a", "label": "first", "priority": 0]],
            "deepseek": [["id": "k", "auth_type": "api_key"]],
        ]]
        let snapshots = HermesPoolQuotaService.snapshots(fromAuthStore: store, now: .now)
        #expect(snapshots.compactMap { $0["provider"] as? String } == ["hermes-pool-anthropic-a", "hermes-pool-anthropic-b", "hermes-pool-deepseek-k"])
        #expect(snapshots.last?["safe_detail"] as? String == "API key · usage not tracked")
    }

    @Test func parsesModelOptionsRows() {
        let rows = HermesProviderRow.rows(from: ["providers": [
            ["slug": "anthropic", "name": "Anthropic", "is_current": true, "models": ["a", "b"], "total_models": 2],
            ["slug": "deepseek", "name": "DeepSeek", "authenticated": false, "auth_type": "api_key", "key_env": "DEEPSEEK_API_KEY", "models": []],
            ["slug": "bedrock", "name": "AWS Bedrock", "authenticated": false, "auth_type": "aws_sdk", "warning": "run `hermes model` to configure (aws_sdk)"],
            ["slug": "mine", "is_user_defined": true],
            ["name": "no slug"],
        ]])
        #expect(rows.map(\.slug) == ["anthropic", "deepseek", "bedrock", "mine"])
        #expect(rows[0].authenticated && rows[0].isCurrent && rows[0].totalModels == 2 && rows[0].access == .browser)
        #expect(!rows[1].authenticated && rows[1].keyEnv == "DEEPSEEK_API_KEY" && rows[1].access == .apiKey)
        #expect(rows[2].access == .external)
        #expect(rows[3].name == "mine" && rows[3].access == .external)
    }
}
