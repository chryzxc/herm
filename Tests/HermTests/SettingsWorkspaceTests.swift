import Foundation
import Testing

@testable import Herm

@Suite("Settings workspace")
struct SettingsWorkspaceTests {
    @Test("categories keep the documented order")
    func categoryOrder() {
        #expect(
            SettingsCategory.allCases == [
                .general, .gateway, .appearance, .notifications, .runtime, .providers, .chat, .workspace, .safety,
                .browser, .memory, .voice, .advanced, .integrations, .session, .diagnostics, .updates,
            ])
        let grouped = SettingsCategoryGroup.allCases.flatMap(\.categories)
        #expect(grouped.count == Set(grouped).count)
        #expect(Set(grouped) == Set(SettingsCategory.allCases))
        #expect(SettingsCategoryGroup.app.categories == [.general, .gateway, .appearance, .notifications])
        #expect(SettingsCategory.general.title == "General")
        #expect(SettingsCategory.diagnostics.icon == .stethoscope)
    }

    @Test("layout switches at the native compact breakpoint")
    func layoutBreakpoint() {
        #expect(SettingsLayoutMode.forWidth(759) == .menu)
        #expect(SettingsLayoutMode.forWidth(760) == .rail)
        #expect(SettingsLayoutMode.forWidth(920) == .rail)
    }

    @Test("badges expose only actionable states")
    func badgeKinds() {
        #expect(
            SettingsCategoryBadge(kind: .dot, isWarning: true) != SettingsCategoryBadge(kind: .dot, isWarning: false))
        #expect(SettingsCategoryBadge(kind: .count(2), isWarning: true).kind == .count(2))
    }

    @Test("provider and file limits live with the controls they configure")
    func configCategories() {
        let providerKeys = HermesConfigCatalog.pages[.providers, default: []].flatMap(\.fields).map(\.key)
        #expect(providerKeys.contains("credential_pool_strategies.openai-codex"))
        let workspaceKeys = HermesConfigCatalog.pages[.workspace, default: []].flatMap(\.fields).map(\.key)
        #expect(workspaceKeys.contains("tool_output.max_bytes"))
        #expect(workspaceKeys.contains("tool_output.max_lines"))
        #expect(workspaceKeys.contains("tool_output.max_line_length"))
    }

    @Test("config editor writes nested partial updates over a unique catalog")
    @MainActor
    func configEditorPaths() {
        let root: [String: Any] = ["tts": ["provider": "openai", "openai": ["voice": "alloy"]]]
        let updated = HermesConfigEditor.setting(root, "tts.openai.model", "tts-1")
        #expect(HermesConfigEditor.nested(updated, "tts.openai.model") as? String == "tts-1")
        #expect(HermesConfigEditor.nested(updated, "tts.openai.voice") as? String == "alloy")
        #expect(HermesConfigEditor.nested(updated, "tts.provider") as? String == "openai")
        #expect(HermesConfigEditor.nested(["a": NSNull()], "a") == nil)

        let catalogKeys = HermesConfigCatalog.pages.values.flatMap { $0.flatMap(\.fields).map(\.key) }
        #expect(Set(catalogKeys).count == catalogKeys.count)
        #expect(!catalogKeys.contains("fallback_providers"))
    }
}
