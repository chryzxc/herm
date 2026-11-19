import Foundation
import Testing

@testable import Herm

/// Serves each profile its own rows, plus the all-profile sidebar scan.
@MainActor
private final class ProfileSessionsRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var rowsByProfile: [String: [[String: Any]]] = [
        "bot-a": [["id": "a-1", "title": "A one", "last_activity_at": 200]],
        "bot-b": [["id": "b-1", "title": "B one", "last_activity_at": 300]],
    ]
    var scanRows: [[String: Any]]?
    private(set) var listedProfiles: [String] = []

    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "session.list":
            let profile = params["profile"] as? String ?? ""
            listedProfiles.append(profile)
            return ["sessions": rowsByProfile[profile] ?? []]
        case "session.resume":
            return ["session_id": params["session_id"] as? String ?? "", "messages": []]
        case "session.active_list":
            return ["sessions": []]
        default:
            throw HermesGateway.GatewayError.malformedResponse
        }
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        if path.hasPrefix("/api/profiles/sessions/sidebar") {
            guard let scanRows else { throw HermesGateway.GatewayError.malformedResponse }
            return ["recents": ["sessions": scanRows]]
        }
        guard path.hasPrefix("/api/sessions?") else { throw HermesGateway.GatewayError.malformedResponse }
        let profile = URLComponents(string: path)?.queryItems?.first { $0.name == "profile" }?.value ?? ""
        return ["sessions": rowsByProfile[profile] ?? []]
    }
}

@MainActor
struct ProfileSessionRetentionTests {
    private func withModel(
        _ body: (DockModel, ProfileSessionsRPCClient) async throws -> Void
    ) async throws {
        let suite = "ProfileSessionRetentionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ProfileSessionsRPCClient()
        let model = DockModel(defaults: defaults, rpcClient: client)
        defer { model.shutdown() }
        try await body(model, client)
    }

    private func settle(_ model: DockModel) async {
        await model.sessionLoadTask?.value
        await model.allBotSessionsTask?.value
    }

    @Test func returningToAProfileShowsItsListAtOnceThenRefreshesQuietly() async throws {
        try await withModel { model, client in
            model.setProfileScope("bot-a")
            await settle(model)
            model.setProfileScope("bot-b")
            #expect(model.sessions.isEmpty)
            #expect(model.sessionProjectionState == .loading)
            await settle(model)
            #expect(model.sessions.map(\.id) == ["b-1"])

            client.rowsByProfile["bot-a"]?.append(["id": "a-2", "title": "A two", "last_activity_at": 400])
            model.setProfileScope("bot-a")
            // Shown before Hermes answers, and the re-read does not flip to a loading state.
            #expect(model.sessions.map(\.id) == ["a-1"])
            #expect(model.sessionProjectionState == .ready(model.sessions))
            #expect(!model.isLoadingSessions)
            await settle(model)
            #expect(Set(model.sessions.map(\.id)) == ["a-1", "a-2"])
            #expect(model.sessions.allSatisfy { $0.profileID == "bot-a" })
            #expect(client.listedProfiles == ["bot-a", "bot-b", "bot-a"])
        }
    }

    @Test func firstVisitShowsThatProfilesRowsFromTheBackgroundScan() async throws {
        try await withModel { model, client in
            client.scanRows = [
                ["id": "a-1", "title": "A one", "profile": "bot-a", "last_activity_at": 200],
                ["id": "b-old", "title": "B old", "profile": "bot-b", "last_activity_at": 100],
                ["id": "b-pin", "title": "B pin", "profile": "bot-b", "last_activity_at": 150, "pinned": true],
            ]
            model.setProfileScope("bot-a")
            await settle(model)
            #expect(model.allBotSessionsState != .loading)

            model.setProfileScope("bot-b")
            #expect(model.sessions.map(\.id) == ["b-pin", "b-old"])
            #expect(model.pinnedSessions.map(\.id) == ["b-pin"])
            #expect(model.sessions.allSatisfy { $0.profileID == "bot-b" })
            await settle(model)
            // The profile's own read replaces the preview.
            #expect(model.sessions.map(\.id) == ["b-1"])
        }
    }

    @Test func aProfileWithoutLoadedRowsStillLoadsNormally() async throws {
        try await withModel { model, _ in
            model.setProfileScope("bot-a")
            // Left before its list arrived: nothing honest to retain.
            model.setProfileScope("bot-b")
            await settle(model)
            model.setProfileScope("bot-a")
            #expect(model.sessionProjectionState == .loading)
            await settle(model)
            #expect(model.sessions.map(\.id) == ["a-1"])
        }
    }

    @Test func returningReportsTheChatTheProfileWasLeftOn() async throws {
        try await withModel { model, _ in
            model.setProfileScope("bot-a")
            await settle(model)
            let chat = try #require(model.sessions.first)
            #expect(await model.resumeSession(chat, reportFailure: true))

            #expect(model.setProfileScope("bot-b") == nil)
            await settle(model)
            let returning = try #require(model.setProfileScope("bot-a"))
            #expect(returning.id == "a-1")
            #expect(returning.profileID == "bot-a")

            // Leaving on a new chat reopens nothing.
            model.newChat()
            model.setProfileScope("bot-b")
            #expect(model.setProfileScope("bot-a") == nil)
        }
    }

    @Test func deletedAndPinnedSessionsUpdateTheRetainedCopy() {
        let model = DockModel(rpcClient: ProfileSessionsRPCClient())
        defer { model.shutdown() }
        let kept = HermesSession(
            id: "keep", profileID: "bot-a", title: "", preview: "", startedAt: nil, messageCount: 0, source: "")
        let gone = HermesSession(
            id: "gone", profileID: "bot-a", title: "", preview: "", startedAt: nil, messageCount: 0, source: "")
        model.retainedProfileSessions["bot-a"] = RetainedProfileSessions(
            sessions: [kept, gone], pinnedSessions: [gone], historyLoadedAt: Date(), openSession: gone)

        model.forgetRetainedSession("gone", profileID: "bot-a")
        model.applyRetainedPin(true, to: kept, profileID: "bot-a")

        let retained = model.retainedProfileSessions["bot-a"]
        #expect(retained?.sessions.map(\.id) == ["keep"])
        #expect(retained?.pinnedSessions.map(\.id) == ["keep"])
        #expect(retained?.openSession == nil)
        #expect(retained?.historyLoadedAt == nil)
    }
}
