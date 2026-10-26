import Testing

@testable import Herm

struct MessagingPlatformsTests {
    @Test func decodesDashboardPlatformRow() throws {
        let platform = try #require(
            MessagingPlatformsModel.platform([
                "id": "telegram", "name": "Telegram", "enabled": false, "configured": false, "state": "disabled",
                "docs_url": "https://example.com/telegram",
                "env_vars": [
                    [
                        "key": "TELEGRAM_BOT_TOKEN", "required": true, "is_set": true, "redacted_value": "12…ab",
                        "is_password": true, "prompt": "Bot token",
                    ],
                    ["key": "TELEGRAM_ALLOWED_USERS", "is_list": true, "value": "42"],
                ],
            ]))
        #expect(platform.envVars.map(\.key) == ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS"])
        #expect(
            platform.envVars[0].required && platform.envVars[0].isPassword && platform.envVars[0].prompt == "Bot token")
        #expect(platform.envVars[1].value == "42")
        #expect(platform.statusLabels.map(\.1) == ["Disabled", "Needs setup"])
        #expect(MessagingPlatformsModel.platform(["name": "no id"]) == nil)
    }
}

@MainActor
private final class MessagingPageClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var response: [String: Any] = ["platforms": []]
    var failure = false
    var blockedPath: String?
    var pending: CheckedContinuation<Void, Never>?
    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        let captured = response
        if path == blockedPath { await withCheckedContinuation { pending = $0 } }
        if failure { throw HermesGateway.GatewayError.malformedResponse }
        return captured
    }
}

@MainActor
struct MessagingPageStateTests {
    @Test func emptyFailureAndProfileChangeRemainDistinct() async {
        let client = MessagingPageClient()
        let model = MessagingPlatformsModel(client: client)
        await model.load(profileID: "one")
        #expect(model.hasLoaded && model.platforms.isEmpty && !model.loading)
        client.response = ["platforms": [["id": "telegram"]]]
        await model.load(profileID: "one")
        client.failure = true
        await model.load(profileID: "one")
        #expect(model.platforms.count == 1 && model.error != nil)
        await model.load(profileID: "two")
        #expect(model.platforms.isEmpty && !model.hasLoaded && model.error != nil)
    }

    @Test func oldProfileResponseCannotReplaceNewProfile() async {
        let client = MessagingPageClient()
        let model = MessagingPlatformsModel(client: client)
        client.response = ["platforms": [["id": "old"]]]
        client.blockedPath = "/api/messaging/platforms?profile=one"
        let old = Task { await model.load(profileID: "one") }
        while client.pending == nil { await Task.yield() }
        client.response = ["platforms": [["id": "new"]]]
        await model.load(profileID: "two")
        client.pending?.resume()
        await old.value
        #expect(model.platforms.map(\.id) == ["new"])
        #expect(!model.loading)
    }

    @Test func searchAndDraftsReflectEffectiveChanges() throws {
        let platform = try #require(
            MessagingPlatformsModel.platform([
                "id": "telegram", "name": "Telegram", "description": "Bot messages", "enabled": true,
                "env_vars": [
                    ["key": "TOKEN", "is_password": true, "is_set": true],
                    ["key": "USERS", "is_list": true, "is_set": true, "value": "42"],
                ],
            ]))
        #expect(MessagingPlatform.matching([platform], query: "  BOT  ").count == 1)
        #expect(MessagingPlatform.matching([platform], query: "discord").isEmpty)
        #expect(!platform.hasChanges(enabled: true, drafts: ["TOKEN": "", "USERS": "42"]))
        #expect(platform.hasChanges(enabled: true, drafts: ["USERS": ""]))
        #expect(platform.hasChanges(enabled: false, drafts: [:]))
    }
}
