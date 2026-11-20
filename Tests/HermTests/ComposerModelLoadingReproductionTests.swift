import Foundation
import Testing

@testable import Herm

@MainActor
private final class ComposerModelLoadingRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var duringConnect: (() -> Void)?
    var reportedModel = "gpt-5"

    func connect() async throws { duringConnect?() }
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.resume" {
            return ["session_id": "conversation", "model": reportedModel, "messages": []]
        }
        throw HermesGateway.GatewayError.malformedResponse
    }
}

@MainActor
struct ComposerModelLoadingReproductionTests {
    @Test func profileSwitchDoesNotBorrowModelAndPickerHandlesBlank() async throws {
        let suite = "ComposerModelLoadingReproductionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = ComposerModelLoadingRPC()
        let model = DockModel(defaults: defaults, initialSessionID: "conversation", rpcClient: rpc)
        defer { model.shutdown() }
        model.sessionProfileID = "first"
        model.sessionModelOptionID = "openai|gpt-5"
        model.sessionModelValue = "gpt-5"
        var checked = false
        rpc.duringConnect = {
            checked = true
            #expect(model.sessionModelValue == nil)
            #expect(model.sessionModelOptionID == nil)
            let picker = ModelPickerView(
                options: [], selectedID: nil, isRefreshing: true, refreshError: nil,
                onRefresh: {}, onSelect: { _ in }, effortModel: model)
            #expect(picker.currentModelTitle == "Select model")
        }
        let row = try #require(DockModel.parseSession(["id": "conversation", "model": "  "], profileID: "second"))
        _ = await model.resumeSession(row, reportFailure: true, profileID: "second")
        #expect(checked)
    }

    @Test func indexedModelAndCopiesSurviveBeforeConnect() async throws {
        let suite = "ComposerModelLoadingReproductionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = ComposerModelLoadingRPC()
        let model = DockModel(defaults: defaults, initialSessionID: nil, rpcClient: rpc)
        defer { model.shutdown() }
        let row = try #require(DockModel.parseSession(["id": "conversation", "model": "  indexed-model  "]))
        #expect(DockModel.parseSession(["id": "blank", "model": " \n "])?.modelName == nil)
        let pinned = row.withPinned(true, profileID: nil)
        let recent = DockModel.withRecency(pinned, from: [row.id: Date()])
        let merged = DockModel.mergingSessionIndex([recent], with: [recent], working: [row.id])
        #expect(merged.first?.modelName == "indexed-model")
        model.sessions = merged
        model.updateSessionActivity(sessionID: row.id, unread: true)
        #expect(model.sessions.first?.modelName == "indexed-model")
        var checked = false
        rpc.duringConnect = {
            checked = true
            #expect(model.sessionModelValue == "indexed-model")
            #expect(model.sessionModelOptionID == nil)
            let picker = ModelPickerView(
                options: [], selectedID: nil, isRefreshing: true, refreshError: nil,
                onRefresh: {}, onSelect: { _ in }, effortModel: model)
            #expect(picker.currentModelTitle == "indexed-model")
        }
        _ = await model.resumeSession(row, reportFailure: true)
        #expect(checked)
    }

    @Test func resumeKeepsOnlyMatchingRoute() async throws {
        let suite = "ComposerModelLoadingReproductionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = ComposerModelLoadingRPC()
        let model = DockModel(defaults: defaults, initialSessionID: "conversation", rpcClient: rpc)
        defer { model.shutdown() }
        let session = HermesSession(
            id: "conversation", title: "", preview: "", startedAt: nil, messageCount: 0, source: "test")
        model.sessionModelOptionID = "openai|gpt-5"
        model.sessionModelValue = HermesModelOption(provider: "openai", model: "gpt-5").displayName
        _ = await model.resumeSession(session, reportFailure: true)
        #expect(model.sessionModelOptionID == "openai|gpt-5")
        rpc.reportedModel = "other-model"
        _ = await model.resumeSession(session, reportFailure: true)
        #expect(model.sessionModelOptionID == nil)
        #expect(model.sessionModelValue == "other-model")
    }

    @Test func activeIdentitySeedsIndexedModelBeforeConnect() async throws {
        let suite = "ComposerModelLoadingReproductionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = ComposerModelLoadingRPC()
        let model = DockModel(defaults: defaults, initialSessionID: "conversation", rpcClient: rpc)
        defer { model.shutdown() }
        let session = try #require(DockModel.parseSession(["id": "conversation", "model": "indexed-model"]))
        var checked = false
        rpc.duringConnect = {
            checked = true
            #expect(model.sessionModelValue == "indexed-model")
            #expect(model.sessionModelOptionID == nil)
        }
        _ = await model.resumeSession(session, reportFailure: true)
        #expect(checked)
    }

    @Test func openingActiveConversationRetainsKnownModelBeforeNetwork() async throws {
        let suite = "ComposerModelLoadingReproductionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rpc = ComposerModelLoadingRPC()
        let model = DockModel(defaults: defaults, initialSessionID: "conversation", rpcClient: rpc)
        defer { model.shutdown() }
        model.sessionModelOptionID = "openai|gpt-5"
        model.sessionModelValue = "gpt-5"
        var checkedBeforeNetwork = false
        rpc.duringConnect = {
            checkedBeforeNetwork = true
            #expect(model.sessionModelValue == "gpt-5")
            #expect(model.sessionModelOptionID == "openai|gpt-5")
        }
        let session = HermesSession(
            id: "conversation", title: "Conversation", preview: "", startedAt: nil,
            messageCount: 0, source: "test")

        #expect(await model.resumeSession(session, reportFailure: true))
        #expect(checkedBeforeNetwork)
    }
}
