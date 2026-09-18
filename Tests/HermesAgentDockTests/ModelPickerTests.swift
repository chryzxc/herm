import Foundation
import Testing
@testable import HermesAgentDock

struct ModelPickerTests {
    @Test
    func groupsModelsByProviderAndFiltersWithoutLosingProviderContext() {
        let catalog = ModelPickerCatalog(options: [
            HermesModelOption(provider: "openai", model: "gpt-5"),
            HermesModelOption(provider: "openai", model: "gpt-4.1"),
            HermesModelOption(provider: "anthropic", model: "claude-sonnet")
        ])

        let groups = catalog.groups(matching: "sonnet")

        #expect(groups.map(\.provider) == ["anthropic"])
        #expect(groups.first?.models.map(\.model) == ["claude-sonnet"])
    }

    @Test
    func selectionReconcilesByStableIDAcrossRefreshes() {
        let selected = "openai|gpt-5"
        let refreshed = [
            HermesModelOption(provider: "anthropic", model: "claude-sonnet"),
            HermesModelOption(provider: "openai", model: "gpt-5")
        ]

        #expect(ModelPickerCatalog.reconciledSelection(selectedID: selected, options: refreshed) == selected)
        #expect(ModelPickerCatalog.reconciledSelection(selectedID: selected, options: [refreshed[0]]) == nil)
    }

    @Test
    func editorPreferencesPersistDisabledStableIDs() {
        let suiteName = "ModelPickerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preferences = ModelPickerPreferences(defaults: defaults)
        preferences.setEnabled(false, for: "openai|gpt-4.1")

        let reloaded = ModelPickerPreferences(defaults: defaults)
        #expect(reloaded.isEnabled("openai|gpt-4.1") == false)
        #expect(reloaded.isEnabled("openai|gpt-5"))
    }

    @Test
    func refreshStateDistinguishesPendingSuccessEmptyAndUnavailable() {
        #expect(ModelPickerRefreshState.pending.isPending)
        #expect(ModelPickerRefreshState.success.isAvailable)
        #expect(ModelPickerRefreshState.empty.isEmpty)
        #expect(ModelPickerRefreshState.unavailable.isUnavailable)
    }
}
