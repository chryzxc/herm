import Foundation
import Testing
@testable import Herm

@MainActor
private final class ModelPickerRefreshRPCClient: HermesRPCClientProtocol {
    enum TestError: Error { case rejected }
    private final class Response: @unchecked Sendable {
        let value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }

    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requests: [(method: String, params: [String: Any])] = []
    private var waiters: [CheckedContinuation<Response, Error>] = []

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
            waiters.append(continuation)
        }
        return response.value
    }

    func releaseNext(with response: [String: Any]) {
        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeFirst()
        waiter.resume(returning: Response(response))
    }

    func releaseLatest(with response: [String: Any]) {
        guard !waiters.isEmpty else { return }
        let waiter = waiters.removeLast()
        waiter.resume(returning: Response(response))
    }

    func close() {}
}

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
    func activeModelIsRemovedFromPersistedDisabledIDsWhenItBecomesActive() {
        let activeID = "openai|gpt-5"

        #expect(ModelPickerCatalog.reconciledDisabledIDs([activeID, "anthropic|claude"], activeID: activeID) == ["anthropic|claude"])
    }

    @Test
    func modelOptionsPayloadPreservesRequestAndProviderModelShape() throws {
        let request = DockModel.runtimeModelOptionsRequest(sessionID: "session-7")
        #expect(request["explicit_only"] as? Bool == true)
        #expect(request["session_id"] as? String == "session-7")

        let options = try DockModel.runtimeModelOptions(from: [
            "providers": [["slug": "openai", "models": ["gpt-5"]]]
        ])
        #expect(options.map(\.id) == ["openai|gpt-5"])
    }

    @Test
    func malformedModelOptionsEnvelopeFailsClosed() {
        #expect(throws: DockModel.RuntimeModelOptionsParseError.self) {
            try DockModel.runtimeModelOptions(from: ["providers": ["not-an-object"]])
        }
    }

    @Test
    @MainActor
    func refreshUsesGatewayBoundaryAndPublishesSessionCatalog() async throws {
        let client = ModelPickerRefreshRPCClient()
        let model = DockModel(initialSessionID: "session-7", rpcClient: client)

        model.refreshRuntimeModelOptions(sessionID: "session-7")
        while client.requests.isEmpty { await Task.yield() }
        client.releaseNext(with: [
            "provider": "openai",
            "model": "gpt-5",
            "providers": [["slug": "openai", "models": ["gpt-5"]]]
        ])
        while model.isLoadingRuntimeModelOptions { await Task.yield() }

        let request = try #require(client.requests.first)
        #expect(request.method == HermesFeatureIDs.ID.modelOptions.rawValue)
        #expect(request.params["explicit_only"] as? Bool == true)
        #expect(request.params["session_id"] as? String == "session-7")
        #expect(model.runtimeModelOptions.map(\.id) == ["openai|gpt-5"])
        #expect(model.sessionModelOptionID == "openai|gpt-5")
        #expect(model.runtimeModelOptionsError == nil)
    }

    @Test
    @MainActor
    func latestRefreshWinsWhenGatewayResponsesCompleteOutOfOrder() async {
        let client = ModelPickerRefreshRPCClient()
        let model = DockModel(initialSessionID: "session-race", rpcClient: client)

        model.refreshRuntimeModelOptions(sessionID: "session-race")
        model.refreshRuntimeModelOptions(sessionID: "session-race")
        while client.requests.count < 2 { await Task.yield() }

        client.releaseLatest(with: [
            "providers": [["slug": "anthropic", "models": ["claude-sonnet"]]]
        ])
        while model.isLoadingRuntimeModelOptions { await Task.yield() }
        client.releaseNext(with: [
            "providers": [["slug": "openai", "models": ["gpt-5"]]]
        ])
        await Task.yield()

        #expect(model.runtimeModelOptions.map(\.id) == ["anthropic|claude-sonnet"])
        #expect(model.runtimeModelOptionsError == nil)
        #expect(!model.isLoadingRuntimeModelOptions)
    }

    @Test
    @MainActor
    func switchingToNewChatInvalidatesPendingModelRefresh() async {
        let client = ModelPickerRefreshRPCClient()
        let model = DockModel(initialSessionID: "session-old", rpcClient: client)

        model.refreshRuntimeModelOptions(sessionID: "session-old")
        while client.requests.isEmpty { await Task.yield() }

        model.newChat()
        #expect(model.isLoadingRuntimeModelOptions == false)
        #expect(model.runtimeModelOptionsError == nil)

        client.releaseNext(with: [
            "providers": [["slug": "openai", "models": ["stale-model"]]]
        ])
        await Task.yield()
        #expect(model.runtimeModelOptions.isEmpty)
    }
}
