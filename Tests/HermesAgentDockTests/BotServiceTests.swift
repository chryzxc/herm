import Foundation
import Testing
@testable import HermesAgentDock

@MainActor
struct BotServiceTests {
    @Test func parsesAndSortsSafeBotRoster() async {
        let client = BotFixtureClient(result: ["profiles": [
            ["id": "research", "name": "Research", "title": "Researcher", "is_active": true, "chat": ["session_id": "chat-research"]],
            ["id": "default", "name": "Default", "model": "gpt-5", "is_active": false]
        ]])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.map(\.id) == ["default", "research"])
        #expect(inventory.bots[1].chat?.sessionID == "chat-research")
    }

    @Test func parsesHermesProfileListShapeAndCanonicalSession() async {
        let client = BotFixtureClient(result: ["profiles": [[
            "name": "research", "path": "/Users/private/.hermes/profiles/research",
            "display_name": "Research Buddy", "description": "Find papers",
            "model": "gpt-5", "provider": "openai", "is_default": false,
            "skill_count": 3, "canonical_session": ["id": "root", "resolved_id": "tip", "title": "Bot Chat"],
            "last_session": ["id": "last", "title": "Scratch", "preview": "older preview"],
            "worker_session": ["id": "worker", "source": "kanban"],
            "ui_meta": ["hermes-bots": ["title": "Paper Finder"]],
            "ui_meta_revisions": ["hermes-bots": 2], "has_avatar": true
        ]], "bot_mode_protocol": true])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.first?.id == "research")
        #expect(inventory.bots.first?.name == "Research Buddy")
        #expect(inventory.bots.first?.chat?.sessionID == "tip")
        #expect(inventory.bots.first?.recentSession?.sessionID == "last")
        #expect(inventory.bots.first?.title == "Paper Finder")
        #expect(inventory.bots.first?.provider == "openai")
        #expect(inventory.bots.first?.model == "gpt-5")
        // A worker session without a heartbeat is historical metadata, not
        // proof that the Bot is currently working.
        #expect(inventory.bots.first?.isActive == false)
        #expect(inventory.bots.first?.preview == "older preview")
    }

    @Test func acceptsNullCanonicalSessionForNewProfile() async {
        let client = BotFixtureClient(result: ["profiles": [[
            "name": "default",
            "display_name": "",
            "model": "gpt-5.6-luna",
            "canonical_session": NSNull(),
            "last_session": NSNull(),
            "worker_session": NSNull()
        ]]])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.count == 1)
        #expect(inventory.bots.first?.chat == nil)
    }

    @Test func ignoresUnknownRosterKeysWithoutStoringPath() async {
        let client = BotFixtureClient(result: ["profiles": [[
            "name": "research",
            "path": "/Users/private/.hermes/profiles/research",
            "future_field": ["anything": true]
        ]]])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.map(\.id) == ["research"])
    }

    @Test func malformedIdentityOrChatFailsClosed() async {
        let noIdentity = BotFixtureClient(result: ["profiles": [["description": "no identity"]]])
        #expect(await BotService(client: noIdentity).list().availability == .malformed)

        let badChat = BotFixtureClient(result: ["profiles": [["name": "research", "canonical_session": ["session_id": ""]]]])
        #expect(await BotService(client: badChat).list().availability == .malformed)
    }

    @Test func avatarDegradesInsteadOfFailingRoster() async {
        let client = BotFixtureClient(result: ["profiles": [
            ["name": "remote", "avatar_url": "https://example.com/a.png"],
            ["name": "local", "avatar_url": "data:image/png;base64,AAAA"],
            ["name": "broken", "avatar_url": "ftp://example.com/a.png"]
        ]])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.first { $0.id == "remote" }?.avatarURL?.scheme == "https")
        #expect(inventory.bots.first { $0.id == "local" }?.avatarURL?.scheme == "data")
        #expect(inventory.bots.first { $0.id == "broken" }?.avatarURL == nil)
    }

    @Test func rosterRefreshDoesNotGenerateOrPersistMissingAvatars() async {
        let client = BotFixtureClient(result: ["profiles": [[
            "name": "research", "is_default": false, "has_avatar": false
        ]]])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)

        await model.refreshNow()

        #expect(client.methods == ["profiles.list"])
        #expect(!client.methods.contains("image.generate"))
        #expect(!client.methods.contains("profiles.set_asset"))
    }

    @Test func inventoryReplacementsBumpRosterRevision() async {
        let client = BotFixtureClient(result: ["profiles": [["name": "research", "has_avatar": false]]])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)

        let before = model.rosterRevision
        await model.refreshNow()
        let afterFirst = model.rosterRevision
        #expect(afterFirst > before)

        await model.refreshNow()
        #expect(model.rosterRevision > afterFirst)
    }

    @Test func createParsesHermesCreateResultWithoutTitleParam() async throws {
        let client = BotFixtureClient(result: ["ok": true, "name": "writer", "path": "/private", "mirrored": ["env": true]])
        let details = try await BotService(client: client).create(name: "writer", title: nil, description: nil)
        #expect(client.methods == ["profiles.create"])
        #expect(client.paramsList.first?["name"] as? String == "writer")
        #expect(client.paramsList.first?["title"] == nil)
        #expect(details.id == "writer")
        #expect(details.title == nil)
    }

    @Test func createPersistsRosterTitleThroughConfigure() async throws {
        let client = BotFixtureClient(result: ["ok": true, "name": "writer", "mirrored": ["env": true]])
        let details = try await BotService(client: client).create(name: "writer", title: "Writer", description: "Words")
        #expect(client.methods == ["profiles.create", "profiles.configure"])
        #expect(client.paramsList.first?["description"] as? String == "Words")
        let configureParams = client.paramsList.last
        #expect(configureParams?["name"] as? String == "writer")
        let uiMeta = configureParams?["ui_meta"] as? [String: Any]
        let botsMeta = uiMeta?["hermes-bots"] as? [String: Any]
        #expect(botsMeta?["title"] as? String == "Writer")
        #expect(details.title == "Writer")
    }

    @Test func createKeepsResultWhenTitlePersistenceFails() async throws {
        let client = BotFailingConfigureClient(createResult: ["ok": true, "name": "writer"])
        let details = try await BotService(client: client).create(name: "writer", title: "Writer", description: nil)
        #expect(details.id == "writer")
        #expect(details.title == "Writer")
    }

    @Test func createFailsClosedWhenHermesRejects() async {
        let client = BotFixtureClient(result: ["ok": false, "name": "writer"])
        do { _ = try await BotService(client: client).create(name: "writer", title: nil, description: nil); Issue.record("expected rejection") }
        catch { }
    }

    @Test func describeParsesConfigurationSnapshotShape() async throws {
        let client = BotFixtureClient(result: [
            "name": "research", "description": "Find papers",
            "soul": "raw instructions", "model": ["provider": "openai", "default": "gpt-5"],
            "skills": [["name": "search", "enabled": true]], "toolsets": [], "mcp_servers": []
        ])
        let details = try await BotService(client: client).describe(profileID: "research")
        #expect(client.lastParams?["name"] as? String == "research")
        #expect(details.id == "research")
        #expect(details.model == "gpt-5")
        #expect(details.description == "Find papers")
    }

    @Test func configureAddressesProfileByNameAndRejectsSensitiveFields() async {
        let rejected = BotFixtureClient(result: [:])
        do { _ = try await BotService(client: rejected).configure(profileID: "writer", fields: ["token": "secret"]); Issue.record("expected rejection") }
        catch { #expect(rejected.lastMethod == nil) }

        let client = BotFixtureClient(result: [:])
        client.stubNextResult = ["name": "writer", "description": "Words", "model": ["provider": "openai", "default": "gpt-5"], "skills": [], "toolsets": [], "mcp_servers": []]
        _ = try? await BotService(client: client).configure(profileID: "writer", fields: ["description": "Words"])
        #expect(client.methods.first == "profiles.configure")
        #expect(client.paramsList.first?["name"] as? String == "writer")
        #expect(client.paramsList.first?["profile"] == nil)
    }

    @Test func unavailableRosterSurfacesTransportReason() async {
        let client = BotErroringClient(message: "Hermes did not respond in time.")
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .unavailable)
        #expect(inventory.diagnostic.contains("did not respond in time"))
    }

    @Test func unknownMethodErrorClassifiesUnsupported() async {
        let client = BotErroringClient(message: "unknown method: profiles.list")
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .unsupported)
    }

    @Test func rosterReadsBotModeMetaAndPresence() async {
        let now = Date().timeIntervalSince1970
        let client = BotFixtureClient(result: ["profiles": [[
            "name": "research",
            "canonical_session": NSNull(),
            "ui_meta": ["hermes-bots": ["title": "Paper Finder", "hidden": true]],
            "has_avatar": true, "is_default": false,
            "worker_session": ["id": "w1", "last_active": now - 10]
        ]]])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        let bot = inventory.bots.first
        #expect(bot?.title == "Paper Finder")
        #expect(bot?.isHidden == true)
        #expect(bot?.hasAvatar == true)
        #expect(bot?.isRecentlyActive == true)
        #expect(bot?.isWorkingNow == true)
        #expect(bot?.worker?.sessionID == "w1")
    }

    @Test func staleWorkerSessionDoesNotKeepBotWorkingForever() async throws {
        let client = BotFixtureClient(result: ["profiles": [[
            "name": "forge",
            "worker_session": ["id": "worker-old", "source": "kanban", "last_active": Date().timeIntervalSince1970 - 360]
        ]]])
        let inventory = await BotService(client: client).list()
        let bot = try #require(inventory.bots.first)
        #expect(bot.isActive == false)
        #expect(bot.isWorkingNow == false)
    }

    @Test func avatarAssetRoundTripUsesAssetRPCs() async throws {
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let dataURL = "data:image/png;base64,\(imageData.base64EncodedString())"
        let client = BotFixtureClient(result: [:])
        client.stubNextResult = ["found": true, "data": dataURL]
        let service = BotService(client: client)
        let fetched = await service.avatarImageData(profileID: "research")
        #expect(fetched == imageData)
        #expect(client.methods.first == "profiles.get_asset")

        try await service.setAvatar(profileID: "research", dataURL: dataURL)
        #expect(client.methods.last == "profiles.set_asset")
        #expect(client.paramsList.last?["data"] as? String == dataURL)
    }

    @Test func rosterMetaWriteSendsCompleteBotModeBlock() async throws {
        let client = BotFixtureClient(result: [:])
        _ = try await BotService(client: client).setRosterMeta(profileID: "research", title: "Paper Finder", hidden: false)
        let params = client.paramsList.first
        #expect(params?["name"] as? String == "research")
        let meta = (params?["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]
        #expect(meta?["title"] as? String == "Paper Finder")
        #expect(meta?["hidden"] as? Bool == false)
    }

    @Test func profileEditSurfacesGuardedModelConfirmation() async throws {
        let client = BotFixtureClient(result: [:])
        client.stubNextResult = ["ok": false, "applied": ["model": false], "confirm_required": true, "confirm_message": "Expensive model"]
        let outcome = try await BotService(client: client).applyProfileEdit(
            profileID: "research", title: "T", description: "D", soul: "S",
            provider: "openai", model: "gpt-expensive",
            disabledSkills: [], enabledToolsets: nil, enabledMCPServers: [], confirmExpensiveModel: false
        )
        #expect(outcome == .needsConfirmation("Expensive model"))
    }

    @Test func modelProfileEditFailureIsNotAConfirmation() async {
        let model = BotModeModel()
        model.bind(to: BotErroringClient(message: "Hermes did not respond in time."), capabilityAvailable: true)
        let detail = BotProfileDetail(
            id: "research", title: "T", description: "D", soul: "S",
            provider: nil, model: nil, skills: [], toolsets: [],
            toolsetsPinned: false, mcpServers: []
        )

        let result = await model.applyProfileEdit(detail, confirmExpensiveModel: false)

        guard case .failed(let message) = result else {
            Issue.record("expected a failure, not \(result)")
            return
        }
        #expect(message.contains("did not respond in time"))
    }

    @Test func modelProfileEditRelayGuardedModelConfirmation() async {
        let client = BotFixtureClient(result: [:])
        client.stubNextResult = ["confirm_required": true, "confirm_message": "Expensive model"]
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        let detail = BotProfileDetail(
            id: "research", title: "T", description: "D", soul: "S",
            provider: "openai", model: "gpt-expensive", skills: [], toolsets: [],
            toolsetsPinned: false, mcpServers: []
        )

        let result = await model.applyProfileEdit(detail, confirmExpensiveModel: false)

        #expect(result == .needsConfirmation("Expensive model"))
    }

    @Test func encodeDataURLLabelsImageTypesByMagicBytes() {
        #expect(BotService.encodeDataURL(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]))?.hasPrefix("data:image/png;base64,") == true)
        #expect(BotService.encodeDataURL(Data([0xFF, 0xD8, 0xFF, 0xE0]))?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(BotService.encodeDataURL(Data("RIFF1234WEBPVP8 ".utf8))?.hasPrefix("data:image/webp;base64,") == true)
        #expect(BotService.encodeDataURL(Data("not an image".utf8)) == nil)
    }

    @Test func duplicateSendsCloneFrom() async throws {
        let client = BotFixtureClient(result: ["ok": true, "name": "research-2"])
        _ = try await BotService(client: client).duplicate(profileID: "research", newName: "research-2", title: nil)
        #expect(client.methods.first == "profiles.create")
        #expect(client.paramsList.first?["clone_from"] as? String == "research")
    }

    @Test func createPassesCloneAndNoSkillsOptions() async throws {
        let client = BotFixtureClient(result: ["ok": true, "name": "writer"])
        _ = try await BotService(client: client).create(name: "writer", title: nil, description: nil, cloneFrom: "research", skipsSkills: true)
        #expect(client.paramsList.first?["clone_from"] as? String == "research")
        #expect(client.paramsList.first?["no_skills"] as? Bool == true)
    }

    @Test func routineParsingAndNamespacing() {
        let jobName = "[bot:research] Summarize inbox"
        let routine = BotService.parseRoutine(["name": jobName, "schedule": "every day 9am", "prompt": "Summarize."])
        #expect(routine?.profileID == "research")
        #expect(routine?.name == "Summarize inbox")
        #expect(routine?.jobName == jobName)
        #expect(routine?.schedule == "every day 9am")

        #expect(BotService.parseRoutine(["name": "plain cron job", "schedule": "every day 9am"]) == nil)
        #expect(BotService.routineJobName(profileID: "research", title: "Digest") == "[bot:research] Digest")
        #expect(BotService.isSafeSchedule("every monday 9am"))
        #expect(!BotService.isSafeSchedule("  "))
    }

    @Test func routinesListFiltersThroughCronManage() async {
        let client = BotFixtureClient(result: ["jobs": [
            ["name": "[bot:research] Digest", "schedule": "every day 9am", "prompt": "Digest."],
            ["name": "system backup", "schedule": "every day 5am"]
        ]])
        let routines = await BotService(client: client).listRoutines()
        #expect(routines.count == 1)
        #expect(routines.first?.profileID == "research")
    }

    @Test func forceRefreshVerifiesContractDespiteCapabilityFlag() async {
        let model = BotModeModel()
        model.setCapabilityAvailable(false)
        model.bind(to: BotFixtureClient(result: ["profiles": [["name": "research"]]]), capabilityAvailable: false)
        #expect(!model.canCreateBots)
        await model.refreshNow(force: true)
        #expect(model.inventory.availability == .ready)
        #expect(model.canCreateBots)
    }

    @Test func gatedRefreshSkipsWhenCapabilityFlagIsFalse() async {
        let model = BotModeModel()
        let client = BotFixtureClient(result: ["profiles": [["name": "research"]]])
        model.bind(to: client, capabilityAvailable: false)
        await model.refreshNow()
        #expect(model.inventory.availability == .unavailable)
    }

    @Test func staleCapabilitySnapshotDoesNotClobberReadyRoster() async {
        let model = BotModeModel()
        model.bind(to: BotFixtureClient(result: ["profiles": [["name": "research"]]]), capabilityAvailable: true)
        await model.refreshNow()
        #expect(model.inventory.availability == .ready)
        model.setCapabilityAvailable(false)
        #expect(model.inventory.availability == .ready)
        #expect(model.inventory.bots.map(\.id) == ["research"])
    }

    @Test func canonicalBotChatTitleMatchesHermesContract() {
        #expect(BotService.canonicalBotChatTitle == "Bot Chat")
    }

    @Test func rosterPresentationPrioritizesRoleAndHonestActivity() {
        let bot = BotSummary(
            id: "cypher",
            name: "Cypher",
            title: "Security Reviewer",
            description: "Security review specialist",
            model: "gpt-5.6-terra",
            isActive: true,
            chat: nil,
            avatarURL: nil,
            preview: "Reviewed authentication boundary",
            lastActive: nil,
            isHidden: false,
            hasAvatar: false,
            isDefault: false
        )

        #expect(BotRosterPresentation.role(for: bot) == "Security Reviewer")
        #expect(BotRosterPresentation.activity(for: bot) == "Reviewed authentication boundary")
        #expect(BotRosterPresentation.activity(for: BotSummary(
            id: "new", name: "New", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil,
            lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false
        )) == "No recent activity")
        #expect(BotRosterPresentation.activity(for: BotSummary(
            id: "worker-active", name: "Forge", title: nil, description: nil, model: nil,
            isActive: true, chat: nil, avatarURL: nil, preview: nil,
            lastActive: .now, isHidden: false, hasAvatar: false, isDefault: false
        )) == "Active in Bot work.")
    }

    @Test func futureLastActiveTimestampIsNotRecentlyActive() {
        let futureBot = BotSummary(
            id: "clock-skew",
            name: "Clock skew",
            title: nil,
            description: nil,
            model: nil,
            isActive: false,
            chat: nil,
            avatarURL: nil,
            preview: nil,
            lastActive: Date().addingTimeInterval(60),
            isHidden: false,
            hasAvatar: false,
            isDefault: false
        )

        #expect(!futureBot.isRecentlyActive)
    }

    @Test func emptySearchUsesMatchingBotsState() {
        #expect(BotRosterPresentation.emptyStateTitle(isSearching: true) == "No matching Bots")
        #expect(BotRosterPresentation.emptyStateTitle(isSearching: false) == "No Bots yet")
    }

    @Test func botRosterPrimaryActionIsEditProfile() {
        #expect(BotRosterPresentation.primaryActionLabel == "Edit Profile")
    }

    @Test func botRosterSectionsAndResponsiveLayoutAreStable() {
        #expect(BotRosterSection.allCases == [.bots, .routines])
        #expect(BotRosterActivityFilter.allCases == [.all, .active, .working])
        #expect(BotRosterRowLayout.columnCount(contentWidth: 500) == 1)
        #expect(BotRosterRowLayout.columnCount(contentWidth: 700) == 2)
        #expect(BotRosterRowLayout.columnCount(contentWidth: 900) == 3)
    }

    @Test func botRosterMetadataOmitsUnavailableValues() {
        #expect(BotRosterMetadata(model: nil, lastActive: nil).values.isEmpty)
        #expect(BotRosterMetadata(model: "  ", lastActive: "today").values == ["today"])
        #expect(BotRosterMetadata(model: "openai / gpt-5", lastActive: "2 min ago").values.count == 2)
    }

    @Test func knownBotsHaveDistinctRoleAvatarSymbols() {
        #expect(BotAvatarPresentation.symbol(for: "nexus") == "compass.drawing")
        #expect(BotAvatarPresentation.symbol(for: "cypher") == "shield.fill")
        #expect(BotAvatarPresentation.symbol(for: "atlas") == "globe")
        #expect(BotAvatarPresentation.symbol(for: "scout") == "binoculars.fill")
        #expect(BotAvatarPresentation.symbol(for: "unknown") == "person.crop.circle")
    }
}

@MainActor
private final class BotFixtureClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    let result: [String: Any]
    var stubNextResult: [String: Any]?
    private(set) var lastMethod: String?
    private(set) var lastParams: [String: Any]?
    private(set) var methods: [String] = []
    private(set) var paramsList: [[String: Any]] = []
    init(result: [String: Any]) { self.result = result }
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        methods.append(method)
        paramsList.append(params)
        lastMethod = method
        lastParams = params
        defer { stubNextResult = nil }
        return stubNextResult ?? result
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func close() {}
}

@MainActor
private final class BotErroringClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    let message: String
    init(message: String) { self.message = message }
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        throw NSError(domain: "Hermes", code: 408, userInfo: [NSLocalizedDescriptionKey: message])
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func close() {}
}

@MainActor
private final class BotFailingConfigureClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    let createResult: [String: Any]
    private(set) var methods: [String] = []
    init(createResult: [String: Any]) { self.createResult = createResult }
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        methods.append(method)
        if method == "profiles.configure" { throw NSError(domain: "HermesControl", code: 5064) }
        return createResult
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func close() {}
}
