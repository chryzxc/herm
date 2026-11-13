import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
struct BotServiceTests {
    @Test func orbFacesRequireExplicitlyEnabledPlugin() async {
        let client = BotFixtureClient(result: ["profiles": [["name": "research"], ["name": "writer"]]])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        #expect(model.orbHermFaceID(profileID: "research") == nil)
        await model.refreshNow(force: true)
        // A working roster alone is not confirmation that the plugin is on.
        #expect(model.inventory.availability == .ready)
        #expect(model.orbHermFaceID(profileID: "research") == nil)
        for status in ["enabled", "disabled", "enabled", "error"] {
            client.stubNextResult = ["plugins": [["key": "hermes-bots", "status": status]]]
            await model.refreshNow(force: true)
            #expect(model.orbHermFaceID(profileID: "research") == (status == "enabled" ? "research" : nil))
            #expect(model.orbHermFaceID(profileID: "writer") == (status == "enabled" ? "writer" : nil))
            if status == "enabled" {
                #expect(model.orbHermFaceID(profileID: nil) == model.selectedProfileID)
            }
        }
        // Unknown plugin state must hide the face again, even after enabling.
        client.stubNextResult = ["plugins": [["key": "hermes-bots", "status": "enabled"]]]
        await model.refreshNow(force: true)
        await model.refreshNow(force: true)
        #expect(model.orbHermFaceID(profileID: "research") == nil)
    }

    @Test func builtInBotModeShowsOrbFaceWithoutPluginRow() async {
        let client = BotFixtureClient(result: ["profiles": [["name": "research"]]])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        client.stubNextResult = ["plugins": [["key": "platforms/qqbot", "status": "enabled"]]]
        await model.refreshNow(force: true)
        #expect(model.orbHermFaceID(profileID: "research") == "research")
    }

    @Test func unavailableRosterRetainsBotsButClearsUnconfirmedOrbFace() async {
        let client = BotFixtureClient(result: ["profiles": [["name": "research"]]])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        client.stubNextResult = ["plugins": [["key": "hermes-bots", "status": "enabled"]]]
        await model.refreshNow(force: true)
        #expect(model.orbHermFaceID(profileID: "research") == "research")
        client.failingMethod = "profiles.list"
        await model.refreshNow(force: true)
        #expect(model.bots.count == 1)
        #expect(model.orbHermFaceID(profileID: "research") == nil)
    }

    @Test func disabledPluginClearsRosterAndBlocksCreation() async {
        let client = BotFixtureClient(result: ["profiles": [["name": "research"]]])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        #expect(model.bots.count == 1)
        client.stubNextResult = ["plugins": [["key": "hermes-bots", "status": "disabled"]]]
        await model.refreshNow(force: true)
        #expect(model.inventory.availability == .unsupported)
        #expect(model.botsByID.isEmpty)
        #expect(model.avatarImages.isEmpty)
        #expect(!model.canCreateBots)
        #expect(client.methods.last == "plugins.manage")
        #expect(await model.createBot(name: "blocked", title: "", description: "") == false)
        await model.refreshNow(force: true)
        #expect(model.inventory.availability == .ready)
    }

    @Test func missingRosterDoesNotFetchLiveSessions() async {
        let client = BotFixtureClient(result: [:])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .malformed)
        #expect(client.methods == ["plugins.manage", "profiles.list"])
    }

    @Test func populatePreservesExistingAndCustomAvatarsEvenWhenAssetsCannotLoad() async {
        let client = BotFixtureClient(result: [
            "profiles": [
                ["name": "uploaded", "has_avatar": true],
                ["name": "custom", "has_avatar": false, "ui_meta": ["hermes-bots": ["custom": true]]],
            ]
        ])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        _ = await model.populateAvatars()
        #expect(!client.methods.contains("profiles.set_asset"))
    }

    @Test func regenerateAllRerendersEveryAvatarIncludingUploads() async {
        let client = BotFixtureClient(result: [
            "profiles": [
                ["name": "uploaded", "has_avatar": true],
                ["name": "custom", "has_avatar": true, "ui_meta": ["hermes-bots": ["custom": true]]],
            ]
        ])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        _ = await model.populateAvatars(all: true)
        #expect(client.methods.filter { $0 == "profiles.set_asset" }.count == 2)
    }

    @Test func parsesRuntimeConfigFallbackChain() {
        let runtime = BotService.parseRuntimeConfig([
            "model": ["default": "gpt-6.1-sol", "provider": "openai-codex", "context_length": 200000],
            "fallback_providers": [
                ["provider": "anthropic", "model": "claude-opus-5-5"], ["provider": "", "model": "x"],
            ],
            "fallback_model": ["provider": "anthropic", "model": "claude-opus-5-5"],
            "agent": ["reasoning_effort": "high"],
            "compression": ["threshold_tokens": 150000],
        ])
        #expect(runtime.fallbacks == [.init(provider: "anthropic", model: "claude-opus-5-5")])
        #expect(runtime.contextLength == 200000)
        #expect(runtime.reasoningEffort == "high")
        #expect(runtime.compressionThreshold == 150000)
        #expect(BotService.parseRuntimeConfig([:]) == BotRuntimeConfig())
    }

    @Test func fallbackEditWritesProfileScopedChainAndBlanksLegacyKey() async throws {
        let client = BotFixtureClient(result: [:])
        try await BotService(client: client).setFallbacks(
            profileID: "aegis",
            [
                .init(provider: "anthropic", model: "claude-opus-5-5", baseURL: "process://x"),
                .init(provider: "openrouter", model: "gpt-6"),
            ])
        #expect(client.methods == ["PUT /api/config"])
        #expect(client.lastHTTPBody?["profile"] as? String == "aegis")
        let config = try #require(client.lastHTTPBody?["config"] as? [String: Any])
        let chain = try #require(config["fallback_providers"] as? [[String: Any]])
        #expect(chain.map { $0["model"] as? String } == ["claude-opus-5-5", "gpt-6"])
        #expect(chain[0]["base_url"] as? String == "process://x")
        #expect((config["fallback_model"] as? [String: String])?["provider"] == "")
    }

    @Test func parsesAndSortsSafeBotRoster() async {
        let client = BotFixtureClient(result: [
            "profiles": [
                [
                    "id": "research", "name": "Research", "title": "Researcher", "is_active": true,
                    "chat": ["session_id": "chat-research"],
                ],
                ["id": "default", "name": "Default", "model": "gpt-5", "is_active": false],
            ]
        ])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.map(\.id) == ["default", "research"])
        #expect(inventory.bots[1].chat?.sessionID == "chat-research")
    }

    @Test func parsesHermesProfileListShapeAndCanonicalSession() async {
        let client = BotFixtureClient(result: [
            "profiles": [
                [
                    "name": "research", "path": "/Users/private/.hermes/profiles/research",
                    "display_name": "Research Buddy", "description": "Find papers",
                    "model": "gpt-5", "provider": "openai", "is_default": false,
                    "skill_count": 3, "canonical_session": ["id": "root", "resolved_id": "tip", "title": "Bot Chat"],
                    "last_session": ["id": "last", "title": "Scratch", "preview": "older preview"],
                    "worker_session": ["id": "worker", "source": "kanban"],
                    "ui_meta": ["hermes-bots": ["title": "Paper Finder"]],
                    "ui_meta_revisions": ["hermes-bots": 2], "has_avatar": true,
                ]
            ], "bot_mode_protocol": true,
        ])
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
        let client = BotFixtureClient(result: [
            "profiles": [
                [
                    "name": "default",
                    "display_name": "",
                    "model": "gpt-5.6-luna",
                    "canonical_session": NSNull(),
                    "last_session": NSNull(),
                    "worker_session": NSNull(),
                ]
            ]
        ])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.count == 1)
        #expect(inventory.bots.first?.chat == nil)
    }

    @Test func ignoresUnknownRosterKeysWithoutStoringPath() async {
        let client = BotFixtureClient(result: [
            "profiles": [
                [
                    "name": "research",
                    "path": "/Users/private/.hermes/profiles/research",
                    "future_field": ["anything": true],
                ]
            ]
        ])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.map(\.id) == ["research"])
    }

    @Test func malformedIdentityOrChatFailsClosed() async {
        let noIdentity = BotFixtureClient(result: ["profiles": [["description": "no identity"]]])
        #expect(await BotService(client: noIdentity).list().availability == .malformed)

        let badChat = BotFixtureClient(result: [
            "profiles": [["name": "research", "canonical_session": ["session_id": ""]]]
        ])
        #expect(await BotService(client: badChat).list().availability == .malformed)
    }

    @Test func avatarDegradesInsteadOfFailingRoster() async {
        let client = BotFixtureClient(result: [
            "profiles": [
                ["name": "remote", "avatar_url": "https://example.com/a.png"],
                ["name": "local", "avatar_url": "data:image/png;base64,AAAA"],
                ["name": "broken", "avatar_url": "ftp://example.com/a.png"],
            ]
        ])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        #expect(inventory.bots.first { $0.id == "remote" }?.avatarURL?.scheme == "https")
        #expect(inventory.bots.first { $0.id == "local" }?.avatarURL?.scheme == "data")
        #expect(inventory.bots.first { $0.id == "broken" }?.avatarURL == nil)
    }

    @Test func rosterRefreshDoesNotGenerateOrPersistMissingAvatars() async {
        let client = BotFixtureClient(result: [
            "profiles": [
                [
                    "name": "research", "is_default": false, "has_avatar": false,
                ]
            ]
        ])
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)

        await model.refreshNow()

        #expect(client.methods == ["plugins.manage", "profiles.list", "session.active_list"])
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
        #expect(model.rosterRevision == afterFirst, "An unchanged roster should not invalidate transcript rows")
        let changedClient = BotFixtureClient(result: [
            "profiles": [["name": "research", "has_avatar": false], ["name": "coding", "has_avatar": false]]
        ])
        model.bind(to: changedClient, capabilityAvailable: true)
        await model.refreshNow()
        #expect(model.rosterRevision > afterFirst)
    }

    @Test func createParsesHermesCreateResultWithoutTitleParam() async throws {
        let client = BotFixtureClient(result: [
            "ok": true, "name": "writer", "path": "/private", "mirrored": ["env": true],
        ])
        let details = try await BotService(client: client).create(name: "writer", title: nil, description: nil)
        #expect(client.methods == ["profiles.create"])
        #expect(client.paramsList.first?["name"] as? String == "writer")
        #expect(client.paramsList.first?["title"] == nil)
        #expect(details.id == "writer")
        #expect(details.title == nil)
    }

    @Test func createPersistsRosterTitleThroughConfigure() async throws {
        let client = CreationMetadataClient()
        let details = try await BotService(client: client).create(name: "writer", title: "Writer", description: "Words")
        #expect(client.methods == ["profiles.create", "profiles.list", "profiles.configure", "profiles.list"])
        #expect(client.createParams?["description"] as? String == "Words")
        let configureParams = client.configureParams
        #expect(configureParams?["name"] as? String == "writer")
        let uiMeta = configureParams?["ui_meta"] as? [String: Any]
        let botsMeta = uiMeta?["hermes-bots"] as? [String: Any]
        #expect(botsMeta?["title"] as? String == "Writer")
        #expect(details.title == "Writer")
    }

    @Test func createPreservesExistingMetadata() async throws {
        let client = CreationMetadataClient()
        _ = try await BotService(client: client).create(name: "writer", title: "Writer", description: nil)
        #expect(client.meta["title"] as? String == "Writer")
        #expect(client.meta["sectionId"] as? String == "team")
    }

    @Test func createReportsPartialWhenTitlePersistenceFails() async throws {
        let client = BotFailingConfigureClient(createResult: ["ok": true, "name": "writer"])
        do {
            _ = try await BotService(client: client).create(name: "writer", title: "Writer", description: nil)
            Issue.record("Expected a partial creation outcome")
        } catch let partial as BotCreationPartialError {
            #expect(partial.profileID == "writer")
        }
    }

    @Test func creationDoesNotClaimRoleWhenReadbackDisagrees() async {
        let client = CreationMetadataClient()
        client.ignoreMetadataWrite = true
        do {
            _ = try await BotService(client: client).create(name: "writer", title: "Writer", description: nil)
            Issue.record("Expected an unconfirmed role")
        } catch let partial as BotCreationPartialError {
            #expect(partial.profileID == "writer")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func draftRetriesRoleWithoutCreatingAnotherProfile() async {
        let client = CreationMetadataClient()
        client.failConfigureOnce = true
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        let draft = BotCreationDraft()
        draft.name = "writer"
        draft.role = "Writer"
        await draft.create(model)
        #expect(model.partialCreatedBotID == "writer")
        await draft.create(model)
        #expect(client.methods.filter { $0 == "profiles.create" }.count == 1)
        #expect(draft.finished?.id == "writer")
    }

    @Test func draftDoesNotRecreateWhenRosterReadbackIsMissing() async {
        let client = CreationMetadataClient()
        client.hideCreatedRoster = true
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        let draft = BotCreationDraft()
        draft.name = "writer"
        await draft.create(model)
        await draft.create(model)
        #expect(client.methods.filter { $0 == "profiles.create" }.count == 1)
        #expect(draft.finished == nil)
    }

    @Test func draftDoesNotRecreateAfterUnknownAdmission() async {
        let client = CreationMetadataClient()
        client.failCreateAfterAdmission = true
        let model = BotModeModel()
        model.bind(to: client, capabilityAvailable: true)
        await model.refreshNow(force: true)
        let draft = BotCreationDraft()
        draft.name = "writer"
        await draft.create(model)
        await draft.create(model)
        #expect(client.methods.filter { $0 == "profiles.create" }.count == 1)
        #expect(model.botCreationError?.contains("could not be confirmed") == true)
    }

    @Test func createFailsClosedWhenHermesRejects() async {
        let client = BotFixtureClient(result: ["ok": false, "name": "writer"])
        do {
            _ = try await BotService(client: client).create(name: "writer", title: nil, description: nil)
            Issue.record("expected rejection")
        } catch {}
    }

    @Test func describeParsesConfigurationSnapshotShape() async throws {
        let client = BotFixtureClient(result: [
            "name": "research", "description": "Find papers",
            "soul": "raw instructions", "model": ["provider": "openai", "default": "gpt-5"],
            "skills": [["name": "search", "enabled": true]], "toolsets": [], "mcp_servers": [],
        ])
        let details = try await BotService(client: client).describe(profileID: "research")
        #expect(client.lastParams?["name"] as? String == "research")
        #expect(details.id == "research")
        #expect(details.model == "gpt-5")
        #expect(details.description == "Find papers")
    }

    @Test func configureAddressesProfileByNameAndRejectsSensitiveFields() async {
        let rejected = BotFixtureClient(result: [:])
        do {
            _ = try await BotService(client: rejected).configure(profileID: "writer", fields: ["token": "secret"])
            Issue.record("expected rejection")
        } catch { #expect(rejected.lastMethod == nil) }

        let client = BotFixtureClient(result: [:])
        client.stubNextResult = [
            "name": "writer", "description": "Words", "model": ["provider": "openai", "default": "gpt-5"], "skills": [],
            "toolsets": [], "mcp_servers": [],
        ]
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
        let client = BotFixtureClient(result: [
            "profiles": [
                [
                    "name": "research",
                    "canonical_session": NSNull(),
                    "ui_meta": [
                        "hermes-bots": [
                            "title": "Paper Finder", "hidden": true, "sectionId": "sec-1", "sectionName": " Clients ",
                        ]
                    ],
                    "has_avatar": true, "is_default": false,
                    "worker_session": ["id": "w1", "last_active": now - 10],
                ]
            ]
        ])
        let inventory = await BotService(client: client).list()
        #expect(inventory.availability == .ready)
        let bot = inventory.bots.first
        #expect(bot?.title == "Paper Finder")
        #expect(bot?.isHidden == true)
        #expect(bot?.hasAvatar == true)
        #expect(bot?.isRecentlyActive == true)
        #expect(bot?.isWorkingNow == true)
        #expect(bot?.worker?.sessionID == "w1")
        #expect(bot?.sectionID == "sec-1")
        #expect(bot?.sectionName == "Clients")
    }

    @Test func staleWorkerSessionDoesNotKeepBotWorkingForever() async throws {
        let client = BotFixtureClient(result: [
            "profiles": [
                [
                    "name": "forge",
                    "worker_session": [
                        "id": "worker-old", "source": "kanban", "last_active": Date().timeIntervalSince1970 - 360,
                    ],
                ]
            ]
        ])
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
        let client = BotFixtureClient(result: ["profiles": [["name": "research"]]])
        _ = try await BotService(client: client).setRosterMeta(
            profileID: "research", title: "Paper Finder", hidden: false)
        let params = client.paramsList.last
        #expect(params?["name"] as? String == "research")
        let meta = (params?["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]
        #expect(meta?["title"] as? String == "Paper Finder")
        #expect(meta?["hidden"] as? Bool == false)
    }

    @Test func rosterMetadataPreservesOtherClientsFieldsAndUsesRevision() async throws {
        let client = MetadataFixtureClient()
        try await BotService(client: client).setRosterMeta(profileID: "research", title: nil, hidden: true)
        let params = try #require(client.configured)
        let meta = try #require((params["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any])
        #expect(meta["title"] as? String == "Research")
        #expect(meta["sectionId"] as? String == "team")
        #expect(meta["sectionName"] as? String == "Team")
        #expect(meta["hidden"] as? Bool == true)
        #expect((params["ui_meta_expected_revisions"] as? [String: Int])?["hermes-bots"] == 4)
    }

    @Test func rosterSectionWriteKeepsOtherFieldsAndClears() async throws {
        let client = MetadataFixtureClient()
        try await BotService(client: client).setRosterSection(profileID: "research", id: "sec-2", name: "Clients")
        var meta = try #require(
            ((client.configured?["ui_meta"] as? [String: Any])?["hermes-bots"]) as? [String: Any])
        #expect(meta["sectionId"] as? String == "sec-2")
        #expect(meta["sectionName"] as? String == "Clients")
        #expect(meta["title"] as? String == "Research")

        try await BotService(client: client).setRosterSection(profileID: "research", id: nil, name: nil)
        meta = try #require(((client.configured?["ui_meta"] as? [String: Any])?["hermes-bots"]) as? [String: Any])
        #expect(meta["sectionId"] == nil && meta["sectionName"] == nil)
        #expect(meta["title"] as? String == "Research")
    }

    @Test func concurrentMetadataWritesPreserveBothChanges() async throws {
        let client = ConcurrentMetadataClient()
        let service = BotService(client: client)
        let first = Task { try await service.setRosterMeta(profileID: "research", title: "New", hidden: nil) }
        for await _ in client.firstWriteStarted { break }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let second = Task {
            signal.yield(())
            try await service.setRosterMeta(profileID: "research", title: nil, hidden: true)
        }
        for await _ in started { break }
        client.releaseFirst.yield(())
        client.releaseFirst.finish()
        try await first.value
        try await second.value
        #expect(client.meta["title"] as? String == "New")
        #expect(client.meta["hidden"] as? Bool == true)
    }

    @Test func profileEditReportsFailureWhenRoleCannotBeSaved() async {
        let client = BotFixtureClient(result: ["ok": true])
        do {
            _ = try await BotService(client: client).applyProfileEdit(
                profileID: "research", title: "New", description: "D", soul: "S", provider: nil, model: nil,
                disabledSkills: [], enabledToolsets: nil, enabledMCPServers: [], confirmExpensiveModel: false)
            Issue.record("Expected a role persistence failure")
        } catch {}
    }

    @Test func profileEditSurfacesGuardedModelConfirmation() async throws {
        let client = BotFixtureClient(result: [:])
        client.stubNextResult = [
            "ok": false, "applied": ["model": false], "confirm_required": true, "confirm_message": "Expensive model",
        ]
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
        #expect(
            BotService.encodeDataURL(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]))?.hasPrefix("data:image/png;base64,")
                == true)
        #expect(BotService.encodeDataURL(Data([0xFF, 0xD8, 0xFF, 0xE0]))?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(BotService.encodeDataURL(Data("RIFF1234WEBPVP8 ".utf8))?.hasPrefix("data:image/webp;base64,") == true)
        #expect(BotService.encodeDataURL(Data("not an image".utf8)) == nil)
    }

    @Test func duplicateReportsPartialWhenRoleCannotBeSaved() async {
        let client = CreationMetadataClient()
        client.failConfigureOnce = true
        do {
            try await BotService(client: client).duplicate(profileID: "original", newName: "writer", title: "Writer")
            Issue.record("Expected partial duplication")
        } catch let partial as BotCreationPartialError {
            #expect(partial.profileID == "writer")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func duplicateSendsCloneFrom() async throws {
        let client = BotFixtureClient(result: ["ok": true, "name": "research-2"])
        _ = try await BotService(client: client).duplicate(profileID: "research", newName: "research-2", title: nil)
        #expect(client.methods.first == "profiles.create")
        #expect(client.paramsList.first?["clone_from"] as? String == "research")
    }

    @Test func createPassesCloneAndNoSkillsOptions() async throws {
        let client = BotFixtureClient(result: ["ok": true, "name": "writer"])
        _ = try await BotService(client: client).create(
            name: "writer", title: nil, description: nil, cloneFrom: "research", skipsSkills: true)
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
        let client = BotFixtureClient(result: [
            "jobs": [
                ["name": "[bot:research] Digest", "schedule": "every day 9am", "prompt": "Digest."],
                ["name": "system backup", "schedule": "every day 5am"],
            ]
        ])
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
        model.setCapabilityAvailable(false)
        await model.refreshNow()
        #expect(model.inventory.availability == .unsupported)
        #expect(client.methods.isEmpty)
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
        #expect(
            BotRosterPresentation.activity(
                for: BotSummary(
                    id: "new", name: "New", title: nil, description: nil, model: nil,
                    isActive: false, chat: nil, avatarURL: nil, preview: nil,
                    lastActive: nil, isHidden: false, hasAvatar: false, isDefault: false
                )) == "No recent activity")
        #expect(
            BotRosterPresentation.activity(
                for: BotSummary(
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

    @Test func savedGlossyHermFacesAreRecognized() throws {
        let renderer = ImageRenderer(
            content: Canvas { context, _ in
                BotFaceMark.draw(in: &context, id: "nexus", size: 160, mood: .idle, pose: .rest, theme: .glass)
            }.frame(width: 160, height: 160))
        renderer.scale = 1
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        #expect(BotAvatarView.showsHermFace(png, id: "nexus"))
        #expect(!BotAvatarView.showsHermFace(png, id: "cypher"))
    }

    /// Saved Herm faces are drawn live; another Bot's face or other art stays an image.
    @MainActor @Test func previousGlossyPaletteStillRecognizesSavedFaces() throws {
        let image = try #require(BotFaceMark.still(id: "nexus", theme: .glass, originalColors: true).nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(BotAvatarView.matchesHermFace(png, id: "nexus"))
        #expect(!BotAvatarView.matchesHermFace(png, id: "cypher"))
    }

    @MainActor @Test func savedHermFaceIsRecognizedOnlyForItsOwnBot() throws {
        let png = try #require(BotFaceMark.png(id: "nexus"))
        #expect(BotAvatarView.matchesHermFace(png, id: "nexus"))
        #expect(!BotAvatarView.matchesHermFace(png, id: "cypher"))
        // Blob faces saved before Herm Faces still count as Herm faces.
        let tiff = try #require(BotFaceMark.still(id: "nexus", legacy: true).nsImage?.tiffRepresentation)
        let legacy = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        #expect(BotAvatarView.matchesHermFace(legacy, id: "nexus"))
        #expect(!BotAvatarView.matchesHermFace(legacy, id: "cypher"))
        #expect(!BotAvatarView.matchesHermFace(Data("not an image".utf8), id: "nexus"))
    }
}

@MainActor
private final class CreationMetadataClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var meta: [String: Any] = ["sectionId": "team"]
    var failConfigureOnce = false
    var hideCreatedRoster = false
    var failCreateAfterAdmission = false
    var ignoreMetadataWrite = false
    private var created = false
    private(set) var methods: [String] = []
    private(set) var createParams: [String: Any]?
    private(set) var configureParams: [String: Any]?
    func connect() async throws {}
    func close() {}
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        methods.append(method)
        switch method {
        case "profiles.create":
            createParams = params
            created = true
            if failCreateAfterAdmission { throw URLError(.timedOut) }
            return ["ok": true, "name": "writer"]
        case "profiles.list":
            return [
                "profiles": created && !hideCreatedRoster ? [["name": "writer", "ui_meta": ["hermes-bots": meta]]] : []
            ]
        case "profiles.configure":
            configureParams = params
            if failConfigureOnce {
                failConfigureOnce = false
                throw URLError(.timedOut)
            }
            if !ignoreMetadataWrite {
                meta = (params["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any] ?? [:]
            }
            return ["ok": true]
        default: return [:]
        }
    }
}

@MainActor
private final class ConcurrentMetadataClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private let firstWrite = AsyncStream<Void>.makeStream()
    private let firstStarted = AsyncStream<Void>.makeStream()
    var firstWriteStarted: AsyncStream<Void> { firstStarted.stream }
    var releaseFirst: AsyncStream<Void>.Continuation { firstWrite.continuation }
    var meta: [String: Any] = ["title": "Old", "hidden": false]
    private var writes = 0
    func connect() async throws {}
    func close() {}
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "profiles.list" {
            return ["profiles": [["name": "research", "ui_meta": ["hermes-bots": meta]]]]
        }
        if method == "profiles.configure" {
            writes += 1
            let update = (params["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any] ?? [:]
            if writes == 1 {
                firstStarted.continuation.yield(())
                for await _ in firstWrite.stream { break }
            }
            meta = update
            return ["ok": true]
        }
        return [:]
    }
}

@MainActor
private final class MetadataFixtureClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var configured: [String: Any]?
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "profiles.list" {
            return [
                "profiles": [
                    [
                        "name": "research",
                        "ui_meta": [
                            "hermes-bots": [
                                "title": "Research", "sectionId": "team", "sectionName": "Team", "hidden": false,
                            ]
                        ], "ui_meta_revisions": ["hermes-bots": 4],
                    ]
                ]
            ]
        }
        if method == "profiles.configure" {
            configured = params
            return ["ok": true]
        }
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    func close() {}
}

@MainActor
private final class BotFixtureClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    let result: [String: Any]
    var stubNextResult: [String: Any]?
    var failingMethod: String?
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
        if method == failingMethod { throw URLError(.timedOut) }
        return stubNextResult ?? result
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { [:] }
    private(set) var lastHTTPBody: [String: Any]?
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        methods.append("\(method) \(path)")
        lastHTTPBody = body
        return ["ok": true]
    }
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
