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

    @Test
    func refreshFailureRetainsCatalogAsStaleWhenOptionsExist() {
        #expect(ModelPickerView.refreshState(isRefreshing: false, error: "offline", optionCount: 1) == .stale)
        #expect(ModelPickerView.refreshState(isRefreshing: false, error: "offline", optionCount: 0) == .unavailable)
    }

    @Test
    func activeModelRemainsVisibleAndEnabledAfterItWasDisabled() {
        let options = [HermesModelOption(provider: "openai", model: "gpt-5")]
        let groups = ModelPickerCatalog(options: options).groups(
            matching: "",
            disabledIDs: [options[0].id],
            activeID: options[0].id
        )

        #expect(groups.flatMap(\.models).map(\.id) == [options[0].id])
        #expect(ModelPickerCatalog.isEnabled(options[0].id, disabledIDs: [options[0].id], activeID: options[0].id))
    }

    @Test
    func modelOptionsPayloadPreservesRequestAndProviderModelShape() {
        let request = DockModel.runtimeModelOptionsRequest(sessionID: "session-7")
        #expect(request["explicit_only"] as? Bool == true)
        #expect(request["session_id"] as? String == "session-7")

        let options = DockModel.runtimeModelOptions(from: [
            "providers": [["slug": "openai", "models": ["gpt-5"]]]
        ])
        #expect(options.map(\.id) == ["openai|gpt-5"])
    }
}
