import AppKit
import Foundation
import SwiftUI

/// Hermes-owned profile integration. This adapter accepts only the structured
/// profile fields documented by Hermes; it never reads ~/.hermes directly.
@MainActor
final class BotService {
    /// Hermes identifies a profile's forever-chat by its exact session title;
    /// `session.resume` resolves (and lazily creates) it by that title when a
    /// roster row carries no canonical session pointer yet.
    static let canonicalBotChatTitle = "Bot Chat"

    private let client: HermesRPCClientProtocol

    init(client: HermesRPCClientProtocol) { self.client = client }
    var integrationClient: HermesRPCClientProtocol { client }

    /// Stored session id -> busy, for sessions live in the gateway process.
    func liveBusy() async -> [String: Bool] {
        guard let rows = try? await client.request(HermesFeatureIDs.ID.sessionActiveList.rawValue, params: [:])["sessions"] as? [[String: Any]] else { return [:] }
        return Dictionary(rows.compactMap { row in
            (row["session_key"] as? String).map { ($0, (row["status"] as? String ?? "idle") != "idle") }
        }, uniquingKeysWith: { $0 || $1 })
    }

    func list() async -> BotInventory {
        // Some runtimes expose Bots as a managed plugin; desktop-only toggles
        // are not included in this gateway contract.
        if let result = try? await client.request(HermesFeatureIDs.ID.pluginsManage.rawValue, params: ["action": "list"]),
           let rows = result["plugins"] as? [[String: Any]],
           let botPlugin = rows.first(where: { ($0["key"] as? String) == "hermes-bots" }),
           botPlugin["status"] as? String != "enabled" {
            return BotInventory(availability: .unsupported, bots: [], diagnostic: "The Hermes Bots plugin is not enabled.")
        }
        let roster = await rosterList()
        guard roster.availability == .ready else { return roster }
        let live = await liveBusy()
        guard !live.isEmpty else { return roster }
        return BotInventory(availability: roster.availability, bots: roster.bots.map { bot in
            let states = [bot.chat?.sessionID, bot.recentSession?.sessionID, bot.worker?.sessionID].compactMap { $0 }.compactMap { live[$0] }
            guard !states.isEmpty else { return bot }
            var bot = bot
            bot.liveBusy = states.contains(true)
            return bot
        }, diagnostic: roster.diagnostic)
    }

    private func rosterList() async -> BotInventory {
        do {
            let result = try await client.request(HermesFeatureIDs.ID.profilesList.rawValue, params: [:])
            return try Self.parseInventory(result)
        } catch is ParseError { return BotInventory(availability: .malformed, bots: [], diagnostic: "Hermes returned malformed Bot data.") }
        catch let error {
            // Hermes answers unregistered RPCs with `unknown method:`; that is
            // an old runtime, not a transport failure.
            if Self.isUnsupportedMethod(error) { return BotInventory(availability: .unsupported, bots: [], diagnostic: "This Hermes runtime does not advertise profile support yet.") }
            return BotInventory(availability: .unavailable, bots: [], diagnostic: "Hermes did not return the Bot roster. \(Self.transportDiagnostic(for: error))")
        }
    }

    static func isUnsupportedMethod(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("unknown method") || message.contains("method not found")
    }

    /// Transport error text is Dock- or Hermes-generated status prose, never
    /// roster payload data; keep it bounded for presentation.
    private static func transportDiagnostic(for error: Error) -> String {
        let message = error.localizedDescription
        return message.count <= 160 ? message : String(message.prefix(160))
    }

    func describe(profileID: String) async throws -> BotDetails {
        let result = try await client.request(HermesFeatureIDs.ID.profilesDescribe.rawValue, params: ["name": profileID])
        return try Self.parseDetailsResult(result)
    }

    func create(name: String, title: String?, description: String?, cloneFrom: String? = nil, skipsSkills: Bool = false) async throws -> BotDetails {
        var params: [String: Any] = ["name": name]
        if let description, !description.isEmpty { params["description"] = description }
        if let cloneFrom, !cloneFrom.isEmpty { params["clone_from"] = cloneFrom }
        if skipsSkills { params["no_skills"] = true }
        // Hermes `profiles.create` has no `title` parameter; Bot Mode persists
        // roster titles as profile ui_meta through `profiles.configure`.
        let result = try await client.request(HermesFeatureIDs.ID.profilesCreate.rawValue, params: params)
        let details = try Self.parseCreateResult(result)
        if let title, !title.isEmpty {
            _ = try? await client.request(
                HermesFeatureIDs.ID.profilesConfigure.rawValue,
                params: ["name": name, "ui_meta": ["hermes-bots": ["title": title]]]
            )
        }
        return title.flatMap { details.withTitle($0) } ?? details
    }

    func configure(profileID: String, fields: [String: Any]) async throws -> BotDetails {
        guard !fields.keys.contains(where: { Self.blockedFieldKeys.contains($0.lowercased()) }) else { throw ParseError.invalid }
        // Hermes addresses profiles through the `name` parameter.
        var params = fields; params["name"] = profileID
        _ = try await client.request(HermesFeatureIDs.ID.profilesConfigure.rawValue, params: params)
        return try await describe(profileID: profileID)
    }

    // MARK: Avatars

    /// `profiles.get_asset` answers a data URL; decode it to raw image bytes.
    func avatarImageData(profileID: String) async -> Data? {
        guard let result = try? await client.request(HermesFeatureIDs.ID.profilesGetAsset.rawValue, params: ["name": profileID, "asset": "avatar"]),
              (result["found"] as? Bool) == true,
              let dataURL = result["data"] as? String else { return nil }
        return Self.decodeDataURL(dataURL)
    }

    func setAvatar(profileID: String, dataURL: String) async throws {
        _ = try await client.request(HermesFeatureIDs.ID.profilesSetAsset.rawValue, params: ["name": profileID, "asset": "avatar", "data": dataURL])
    }

    func clearAvatar(profileID: String) async throws {
        _ = try await client.request(HermesFeatureIDs.ID.profilesSetAsset.rawValue, params: ["name": profileID, "asset": "avatar", "clear": true])
    }

    func isImageGenerationAvailable() async -> Bool {
        guard let result = try? await client.request(HermesFeatureIDs.ID.imageGenerate.rawValue, params: ["probe": true]),
              (result["available"] as? Bool) == true else { return false }
        return true
    }

    /// `image.generate` returns `image_data` (a data URL) or a plain `image`
    /// URL/path when the download step failed.
    func generateAvatarImage(prompt: String) async throws -> String {
        let result = try await client.request(HermesFeatureIDs.ID.imageGenerate.rawValue, params: ["prompt": prompt, "aspect_ratio": "square"])
        if let dataURL = result["image_data"] as? String, !dataURL.isEmpty { return dataURL }
        if let image = result["image"] as? String, !image.isEmpty,
           let url = URL(string: image), url.scheme == "https" { return image }
        throw NSError(domain: "HermesBots", code: 1, userInfo: [NSLocalizedDescriptionKey: "Hermes could not generate an avatar image."])
    }

    static func decodeDataURL(_ dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ","),
              dataURL.hasPrefix("data:"),
              let base64 = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return base64
    }

    /// MIME type is derived from the image's magic bytes (WebP: "RIFF" + "WEBP" at offset 8).
    static func encodeDataURL(_ data: Data) -> String? {
        let mime: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            mime = "image/png"
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            mime = "image/jpeg"
        } else if data.count >= 12,
                  data.starts(with: Array("RIFF".utf8)),
                  Data(data[8..<12]) == Data("WEBP".utf8) {
            mime = "image/webp"
        } else {
            return nil
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    // MARK: Roster metadata, editing, duplication

    /// Hermes replaces the whole `hermes-bots` ui_meta key on write, so the
    /// full desired metadata block must always be sent together.
    func setRosterMeta(profileID: String, title: String?, hidden: Bool?) async throws {
        var meta: [String: Any] = [:]
        if let title, !title.isEmpty { meta["title"] = title }
        if let hidden { meta["hidden"] = hidden }
        _ = try await client.request(
            HermesFeatureIDs.ID.profilesConfigure.rawValue,
            params: ["name": profileID, "ui_meta": ["hermes-bots": meta]]
        )
    }

    func profileDetail(profileID: String) async throws -> BotProfileDetail {
        let result = try await client.request(HermesFeatureIDs.ID.profilesDescribe.rawValue, params: ["name": profileID])
        return try Self.parseProfileDetail(result)
    }

    /// The profile's effective config (fallback chain, reasoning, context) via
    /// profile-scoped `config.get full`; `nil` when Hermes can't answer.
    func runtimeConfig(profileID: String) async -> BotRuntimeConfig? {
        guard let result = try? await client.request(HermesFeatureIDs.ID.configGet.rawValue, params: ["key": "full", "profile": profileID]),
              let config = result["config"] as? [String: Any] else { return nil }
        return Self.parseRuntimeConfig(config)
    }

    /// Writes the chain as `fallback_providers` through the profile-scoped
    /// `PUT /api/config` deep-merge. The merge can't delete the legacy
    /// `fallback_model`, so it's blanked; Hermes skips entries without a
    /// provider/model, which leaves `fallback_providers` the whole chain.
    func setFallbacks(profileID: String, _ fallbacks: [BotRuntimeConfig.ModelRef]) async throws {
        let entries: [[String: Any]] = fallbacks.map { ref in
            var entry: [String: Any] = ["provider": ref.provider, "model": ref.model]
            if let baseURL = ref.baseURL { entry["base_url"] = baseURL }
            return entry
        }
        _ = try await client.sendHTTP("PUT", path: "/api/config", body: [
            "profile": profileID,
            "config": [
                "fallback_providers": entries,
                "fallback_model": ["provider": "", "model": "", "base_url": ""],
            ],
        ])
    }

    static func parseRuntimeConfig(_ config: [String: Any]) -> BotRuntimeConfig {
        func refs(_ value: Any?) -> [BotRuntimeConfig.ModelRef] {
            let rows = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
            return rows.compactMap { row in
                guard let provider = row["provider"] as? String, let model = row["model"] as? String,
                      !provider.isEmpty, !model.isEmpty else { return nil }
                let baseURL = (row["base_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return .init(provider: provider, model: model, baseURL: baseURL)
            }
        }
        var fallbacks: [BotRuntimeConfig.ModelRef] = []
        for ref in refs(config["fallback_providers"]) + refs(config["fallback_model"]) where !fallbacks.contains(ref) {
            fallbacks.append(ref)
        }
        let effort = ((config["agent"] as? [String: Any])?["reasoning_effort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return BotRuntimeConfig(
            contextLength: (config["model"] as? [String: Any])?["context_length"] as? Int,
            reasoningEffort: effort,
            fallbacks: fallbacks,
            compressionThreshold: (config["compression"] as? [String: Any])?["threshold_tokens"] as? Int
        )
    }

    /// Applies an edited snapshot. Guarded (expensive) model pins answer
    /// `confirm_required` and write nothing until the caller re-sends with
    /// `confirmExpensiveModel`.
    func applyProfileEdit(profileID: String, title: String, description: String, soul: String, provider: String?, model: String?, disabledSkills: [String], enabledToolsets: [String]?, enabledMCPServers: [String], confirmExpensiveModel: Bool) async throws -> BotProfileEditOutcome {
        var params: [String: Any] = [
            "name": profileID,
            "description": description,
            "soul": soul,
            "disabled_skills": disabledSkills,
            "enabled_mcp_servers": enabledMCPServers,
        ]
        if let provider, !provider.isEmpty, let model, !model.isEmpty {
            params["provider"] = provider
            params["model"] = model
            if confirmExpensiveModel { params["confirm_expensive_model"] = true }
        }
        if let enabledToolsets { params["enabled_toolsets"] = enabledToolsets }
        let result = try await client.request(HermesFeatureIDs.ID.profilesConfigure.rawValue, params: params)
        if (result["confirm_required"] as? Bool) == true, let message = result["confirm_message"] as? String {
            return .needsConfirmation(message)
        }
        try? await setRosterMeta(profileID: profileID, title: title, hidden: nil)
        return .applied
    }

    func duplicate(profileID: String, newName: String, title: String?) async throws {
        _ = try await client.request(HermesFeatureIDs.ID.profilesCreate.rawValue, params: ["name": newName, "clone_from": profileID])
        if let title, !title.isEmpty {
            try? await setRosterMeta(profileID: newName, title: title, hidden: nil)
        }
    }

    func modelOptions() async throws -> [(provider: String, models: [String])] {
        let result = try await client.request(HermesFeatureIDs.ID.modelOptions.rawValue, params: ["explicit_only": true])
        let providers = result["providers"] as? [[String: Any]] ?? []
        return providers.compactMap { provider in
            guard let name = (provider["slug"] as? String) ?? (provider["name"] as? String) else { return nil }
            return (name, provider["models"] as? [String] ?? [])
        }
    }

    // MARK: Routines (namespaced Hermes cron jobs)

    static let routineTagPrefix = "[bot:"

    static func routineJobName(profileID: String, title: String) -> String { "[bot:\(profileID)] \(title)" }

    /// Hermes namespaces Bot routines as `[bot:<name>] <routine>` cron jobs;
    /// jobs without the tag belong to the core scheduler, not Bot Mode.
    func listRoutines() async -> [BotRoutine] {
        guard let result = try? await client.request(HermesFeatureIDs.ID.cronManage.rawValue, params: ["action": "list"]),
              let rows = result["jobs"] as? [[String: Any]] else { return [] }
        return rows.compactMap(Self.parseRoutine)
    }

    func createRoutine(profileID: String, title: String, schedule: String, prompt: String) async throws {
        guard Self.isSafeSchedule(schedule) else { throw ParseError.invalid }
        _ = try await client.request(HermesFeatureIDs.ID.cronManage.rawValue, params: [
            "action": "add", "name": Self.routineJobName(profileID: profileID, title: title),
            "schedule": schedule, "prompt": prompt,
        ])
    }

    func removeRoutine(jobName: String) async throws {
        _ = try await client.request(HermesFeatureIDs.ID.cronManage.rawValue, params: ["action": "remove", "name": jobName])
    }

    static func parseRoutine(_ row: [String: Any]) -> BotRoutine? {
        guard let jobName = row["name"] as? String,
              jobName.hasPrefix(routineTagPrefix),
              let closing = jobName.firstIndex(of: "]") else { return nil }
        let profileID = String(jobName[jobName.index(jobName.startIndex, offsetBy: routineTagPrefix.count)..<closing])
        let displayTitle = jobName[jobName.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard safeID(profileID), !displayTitle.isEmpty,
              let schedule = row["schedule"] as? String, !schedule.isEmpty else { return nil }
        let prompt = (row["prompt"] as? String) ?? (row["request"] as? String) ?? (row["task"] as? String)
        return BotRoutine(
            id: jobName, profileID: profileID, name: displayTitle, jobName: jobName,
            schedule: schedule, prompt: prompt, enabled: (row["enabled"] as? Bool) ?? true,
            sessionID: row["session_id"] as? String
        )
    }

    /// Reject control characters and oversized schedule strings before they
    /// reach Hermes; the upstream scheduler owns real validation.
    static func isSafeSchedule(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 256 && trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Parsing extracts only the stable fields the Dock renders and stores;
    /// unknown keys Hermes adds over time are ignored rather than rejecting
    /// the whole roster. Credential, memory, path, instruction, and tool
    /// payloads are never read into Dock state.
    private static func parseInventory(_ result: [String: Any]) throws -> BotInventory {
        guard let rows = result["profiles"] as? [[String: Any]] else { throw ParseError.invalid }
        let bots = try rows.map(parseSummary).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return BotInventory(availability: .ready, bots: bots, diagnostic: "")
    }

    private static func parseSummary(_ raw: [String: Any]) throws -> BotSummary {
        let id = (raw["id"] as? String) ?? (raw["name"] as? String)
        guard let id, safeID(id) else { throw ParseError.invalid }
        let name = (raw["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (raw["name"] as? String) ?? id
        guard name.count <= 512 else { throw ParseError.invalid }
        let chat = try parseChat(raw["chat"] ?? raw["canonical_session"], profileID: id)
        let fallbackChat = try parseChat(raw["last_session"], profileID: id)
        let title = try optionalString(raw, key: "title") ?? rosterTitle(raw)
        let description = try optionalString(raw, key: "description")
        let modelValue = raw["model"]
        let model = try modelValue.flatMap { value -> String? in
            if let string = value as? String { return string }
            if let dictionary = value as? [String: Any] { return try optionalString(dictionary, key: "default") }
            throw ParseError.invalid
        }
        let provider = (raw["provider"] as? String)
            ?? (raw["model"] as? [String: Any])?["provider"] as? String
        let worker = try parseWorker(raw["worker_session"])
        let isActive: Bool
        if let value = raw["is_active"] { guard let value = value as? Bool else { throw ParseError.invalid }; isActive = value } else { isActive = worker?.isLive == true }
        let preview = chat?.preview ?? fallbackChat?.preview
        let workerLastActive = worker?.lastActive
        let lastActive = [chat?.lastActive, fallbackChat?.lastActive, workerLastActive].compactMap { $0 }.max()
        let botsMeta = rosterMeta(raw)
        return BotSummary(
            id: id, name: name, title: title, description: description, model: model, provider: provider,
            isActive: isActive, chat: chat, recentSession: fallbackChat, worker: worker, avatarURL: avatarURL(raw), preview: preview,
            lastActive: lastActive, isHidden: botsMeta?.hidden == true,
            hasAvatar: (raw["has_avatar"] as? Bool) == true,
            hasCustomAvatar: botsMeta?.custom == true,
            isDefault: (raw["is_default"] as? Bool) == true
        )
    }

    private static func parseWorker(_ value: Any?) throws -> BotWorkerReference? {
        guard let value, !(value is NSNull) else { return nil }
        guard let worker = value as? [String: Any],
              let sessionID = worker["id"] as? String,
              safeID(sessionID) else { throw ParseError.invalid }
        let source = try optionalString(worker, key: "source")
        let title = try optionalString(worker, key: "title")
        return BotWorkerReference(
            sessionID: sessionID,
            source: source,
            title: title,
            lastActive: parseTimestamp(worker["last_active"])
        )
    }

    private struct RosterMeta { var title: String?; var hidden: Bool?; var custom: Bool? }

    /// Bot Mode keeps its roster display metadata (title, hidden) in the
    /// profile's `ui_meta['hermes-bots']` block so every client sees it.
    private static func rosterMeta(_ raw: [String: Any]) -> RosterMeta? {
        guard let uiMeta = raw["ui_meta"] as? [String: Any],
              let bots = uiMeta["hermes-bots"] as? [String: Any] else { return nil }
        let title = (bots["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let hidden = (bots["hidden"] as? Bool)
        let custom = (bots["custom"] as? Bool) ?? false
        return RosterMeta(title: (title?.count ?? 0) <= 512 ? title : nil, hidden: hidden, custom: custom)
    }

    private static func rosterTitle(_ raw: [String: Any]) -> String? { rosterMeta(raw)?.title }

    /// Hermes reports roster avatars as HTTPS URLs or data URLs; a malformed
    /// value degrades to no avatar instead of failing the roster.
    private static func avatarURL(_ raw: [String: Any]) -> URL? {
        guard let string = raw["avatar_url"] as? String, let url = URL(string: string) else { return nil }
        return url.scheme == "https" || url.scheme == "data" ? url : nil
    }

    /// Hermes `profiles.describe` answers a configuration snapshot
    /// (`soul`, skills, toolsets, MCP servers) rather than a roster row.
    /// Only stable identity and the model label enter Dock state.
    private static func parseDetailsResult(_ raw: [String: Any]) throws -> BotDetails {
        guard let name = raw["name"] as? String, safeID(name) else { throw ParseError.invalid }
        let description = try optionalString(raw, key: "description")
        var model: String?
        if let value = raw["model"] {
            if let string = value as? String { model = string }
            else if let dict = value as? [String: Any], let defaultModel = dict["default"] as? String { model = defaultModel }
            else { throw ParseError.invalid }
        }
        return BotDetails(id: name, name: name, title: nil, description: description, model: model, chat: nil)
    }

    private static func parseProfileDetail(_ raw: [String: Any]) throws -> BotProfileDetail {
        guard let name = raw["name"] as? String, safeID(name) else { throw ParseError.invalid }
        let modelDict = raw["model"] as? [String: Any]
        let skills = (raw["skills"] as? [[String: Any]] ?? []).compactMap { row -> BotToggleItem? in
            guard let skillName = row["name"] as? String, safeID(skillName) else { return nil }
            return BotToggleItem(id: skillName, label: skillName, enabled: (row["enabled"] as? Bool) ?? true)
        }
        let toolsets = (raw["toolsets"] as? [[String: Any]] ?? []).compactMap { row -> BotToolsetItem? in
            guard let setName = row["name"] as? String, safeID(setName) else { return nil }
            return BotToolsetItem(
                id: setName,
                label: (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? setName,
                detail: (row["description"] as? String) ?? "",
                toolCount: (row["tool_count"] as? Int) ?? 0,
                enabled: (row["enabled"] as? Bool) ?? false
            )
        }
        let mcpServers = (raw["mcp_servers"] as? [[String: Any]] ?? []).compactMap { row -> BotToggleItem? in
            guard let serverName = row["name"] as? String, safeID(serverName) else { return nil }
            return BotToggleItem(id: serverName, label: serverName, enabled: (row["enabled"] as? Bool) ?? true)
        }
        return BotProfileDetail(
            id: name,
            title: "",
            description: (raw["description"] as? String) ?? "",
            soul: raw["soul"] as? String ?? "",
            provider: modelDict?["provider"] as? String,
            model: modelDict?["default"] as? String,
            skills: skills,
            toolsets: toolsets,
            toolsetsPinned: (raw["toolsets_pinned"] as? Bool) ?? false,
            mcpServers: mcpServers
        )
    }

    /// Hermes `profiles.create` answers `{ok, name, path, mirrored…}`; the
    /// path is deliberately not carried into Dock state.
    private static func parseCreateResult(_ raw: [String: Any]) throws -> BotDetails {
        if let ok = raw["ok"] as? Bool, !ok { throw ParseError.invalid }
        guard let name = raw["name"] as? String, safeID(name) else { throw ParseError.invalid }
        let description = try optionalString(raw, key: "description")
        return BotDetails(id: name, name: name, title: nil, description: description, model: nil, chat: nil)
    }

    private static func parseChat(_ value: Any?, profileID: String) throws -> BotChatReference? {
        guard let value, !(value is NSNull) else { return nil }
        guard let chat = value as? [String: Any],
              let sessionID = (chat["resolved_id"] as? String) ?? (chat["session_id"] as? String) ?? (chat["id"] as? String),
              safeID(sessionID) else { throw ParseError.invalid }
        return BotChatReference(sessionID: sessionID, profileID: profileID, title: try? optionalString(chat, key: "title"), preview: try? optionalString(chat, key: "preview"), lastActive: parseTimestamp(chat["last_active"] ?? chat["started_at"]))
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let seconds = value as? Double, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }

    private static func optionalString(_ raw: [String: Any], key: String) throws -> String? {
        guard let value = raw[key] else { return nil }
        guard let string = value as? String, string.count <= 512 else { throw ParseError.invalid }
        return string
    }
    private static func safeID(_ value: String) -> Bool { !value.isEmpty && value.count <= 128 && value.allSatisfy { $0.isLetter || $0.isNumber || ".:_-".contains($0) } }
    private static let blockedFieldKeys: Set<String> = ["credentials", "memory", "path", "cwd", "token", "secret"]
    private enum ParseError: Error { case invalid }
}

private extension BotDetails {
    func withTitle(_ title: String) -> BotDetails {
        BotDetails(id: id, name: name, title: title, description: description, model: model, chat: chat)
    }
}

@MainActor
final class BotModeModel: ObservableObject {
    var integrationClient: HermesRPCClientProtocol? { service?.integrationClient }
    @Published private(set) var inventory = BotInventory(availability: .unavailable, bots: [], diagnostic: "Bot inventory is unavailable.") {
        didSet { rebuildRosterIndex() }
    }
    /// O(1) roster lookup for per-row transcript rendering; rebuilt whenever
    /// the inventory is replaced.
    private(set) var botsByID: [String: BotSummary] = [:]
    /// Bumped on every roster or avatar change so transcript rows can compare
    /// bot attribution with an O(1) integer instead of dictionary contents.
    private(set) var rosterRevision = 0
    @Published private(set) var isRefreshing = false
    private var isPolling = false
    @Published private(set) var isCreatingBot = false
    @Published var searchText = ""
    @Published var botCreationError: String?
    @Published private(set) var selectedProfileID: String?
    @Published private(set) var avatarImages: [String: Data] = [:] {
        didSet { rosterRevision &+= 1; BotMentions.update(bots: inventory.bots, avatars: avatarImages) }
    }
    private var service: BotService?
    let groupChats = GroupChatStore()
    private var capabilityAvailable = false
    private let selectedProfileKey = "hermes.dock.selected-profile.v1"

    init() {
        if let stored = UserDefaults.standard.string(forKey: selectedProfileKey) {
            let normalized = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedProfileID = normalized.isEmpty ? nil : normalized
        } else {
            selectedProfileID = nil
        }
    }

    private let seenKey = "hermes.dock.bot-seen.v1"
    /// When the user last looked at each Bot. A Bot is unread when its roster
    /// activity is newer. ponytail: roster `last_active` only; per-session
    /// unread state exists for the selected Bot alone.
    private var seenAt: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: "hermes.dock.bot-seen.v1") as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
    }()

    /// Roster refreshes touch this constantly; only persist when asked.
    private func markSeen(_ ids: [String], persist: Bool = true) {
        let now = Date()
        for id in ids { seenAt[id] = now }
        if persist { UserDefaults.standard.set(seenAt.mapValues(\.timeIntervalSince1970), forKey: seenKey) }
    }

    func hasUnread(_ bot: BotSummary) -> Bool {
        guard bot.id != selectedProfileID, let last = bot.lastActive, let seen = seenAt[bot.id] else { return false }
        return last > seen
    }

    private func rebuildRosterIndex() {
        // First sighting is the baseline, so existing history is not "unread".
        let fresh = inventory.bots.filter { seenAt[$0.id] == nil }.map(\.id)
        if !fresh.isEmpty { markSeen(fresh) }
        if let selectedProfileID { markSeen([selectedProfileID], persist: false) }
        botsByID = Dictionary(inventory.bots.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        rosterRevision &+= 1
        BotMentions.update(bots: inventory.bots, avatars: avatarImages)
    }

    var bots: [BotSummary] { inventory.bots }

    /// Short-lived banner for bots that just started or finished work.
    @Published private(set) var activityBanner: [BotActivityEvent] = []
    private var bannerTask: Task<Void, Never>?

    private func announce(_ events: [BotActivityEvent]) {
        activityBanner = events
        NotificationCenter.default.post(name: .hermBotActivity, object: nil, userInfo: ["events": events])
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { activityBanner = [] }
        }
    }

    var filteredBots: [BotSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return inventory.bots }
        return inventory.bots.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var canCreateBots: Bool { capabilityAvailable && inventory.availability == .ready }

    func bind(to client: HermesRPCClientProtocol, capabilityAvailable: Bool) {
        service = BotService(client: client)
        self.capabilityAvailable = capabilityAvailable
        groupChats.bind(to: client)
    }

    /// A starved or stale capability snapshot must not tear down a roster
    /// Hermes just served successfully.
    func setCapabilityAvailable(_ available: Bool) {
        capabilityAvailable = available
        if !available, inventory.availability != .ready {
            inventory = BotInventory(availability: .unsupported, bots: [], diagnostic: "Bot Mode requires a Hermes runtime with profile support.")
        }
    }

    func refresh() {
        Task { @MainActor in await refreshNow() }
    }

    /// Hermes' own Bot Mode feature-detects by calling `profiles.list`
    /// directly instead of trusting a capability batch: the RPC answer is the
    /// capability. `force` follows that model so a user-opened page verifies
    /// the contract even when the batch probe starved.
    func refreshNow(force: Bool = false) async {
        guard let service, !isRefreshing, !isPolling else { return }
        // `.unavailable` is a transport failure, so polling keeps retrying it.
        guard force || capabilityAvailable || inventory.availability == .ready || inventory.availability == .unavailable else { return }
        // Background polls stay unpublished so the sidebar rail does not
        // rebuild twice every 10s; only explicit refreshes show a spinner.
        if force { isRefreshing = true } else { isPolling = true }
        let refreshed = await service.list()
        // A timeout while Hermes is busy or a dropped socket must not wipe a
        // roster Hermes already served: the selector, avatars and working
        // Bots would vanish until restart. Keep it; the next poll retries.
        if refreshed.availability == .unavailable, inventory.availability == .ready {
            if force { isRefreshing = false } else { isPolling = false }
            return
        }
        capabilityAvailable = refreshed.availability == .ready
        if refreshed.availability != .ready {
            avatarImages = [:]
            routines = []
            isImageGenerationAvailable = false
            activityBanner = []
            bannerTask?.cancel()
        } else {
            let avatarIDs = Set(refreshed.bots.filter(\.hasAvatar).map(\.id))
            let retained = avatarImages.filter { avatarIDs.contains($0.key) }
            if retained != avatarImages { avatarImages = retained }
        }
        // Unchanged rosters must not republish: every observer (the rail,
        // activity rows) re-renders on it.
        if inventory != refreshed {
            let events = BotActivityEvent.events(from: inventory.bots, to: refreshed.bots, excluding: selectedProfileID)
            inventory = refreshed
            if !events.isEmpty { announce(events) }
        }
        resolveSelectedProfile()
        if force { isRefreshing = false } else { isPolling = false }
        await loadAvatars()
    }

    /// Chooses a stable Hermes profile ID, never a display name. Hidden Bots
    /// are intentionally excluded from the selector.
    private func resolveSelectedProfile() {
        guard inventory.availability == .ready else { return }
        let visible = inventory.bots.filter { !$0.isHidden }
        let candidate = Self.resolvedProfileID(currentSelection: selectedProfileID, visibleBots: visible)
        guard selectedProfileID != candidate else { return }
        selectedProfileID = candidate
        if let candidate { UserDefaults.standard.set(candidate, forKey: selectedProfileKey) }
        else { UserDefaults.standard.removeObject(forKey: selectedProfileKey) }
    }

    static func resolvedProfileID(currentSelection: String?, visibleBots: [BotSummary]) -> String? {
        if let currentSelection {
            // An explicit selection that disappeared must remain unresolved;
            // silently switching profiles would expose another Bot's scope.
            return visibleBots.first(where: { $0.id == currentSelection })?.id
        }
        return visibleBots.first(where: \.isDefault)?.id ?? visibleBots.first?.id
    }

    func selectProfile(_ profileID: String) {
        guard let bot = inventory.bots.first(where: { $0.id == profileID }), !bot.isHidden else { return }
        guard selectedProfileID != bot.id else { return }
        markSeen([selectedProfileID, bot.id].compactMap { $0 })
        selectedProfileID = bot.id
        UserDefaults.standard.set(bot.id, forKey: selectedProfileKey)
    }

    /// Returns true when Hermes accepted the new profile; the roster is
    /// refreshed from Hermes rather than optimistically patched.
    func createBot(name: String, title: String, description: String, cloneFrom: String? = nil, skipsSkills: Bool = false) async -> Bool {
        guard canCreateBots, let service else {
            botCreationError = "Bot Mode requires a Hermes runtime with profile support."
            return false
        }
        guard isCreatingBot == false else { return false }
        isCreatingBot = true
        defer { isCreatingBot = false }
        do {
            _ = try await service.create(name: name, title: title.isEmpty ? nil : title, description: description.isEmpty ? nil : description, cloneFrom: cloneFrom, skipsSkills: skipsSkills)
            botCreationError = nil
            await refreshNow()
            return true
        } catch {
            botCreationError = Self.mutationDiagnostic(for: error, noun: "create the Bot")
            return false
        }
    }

    // MARK: Parity state: avatars, detail editing, routines

    @Published private(set) var routines: [BotRoutine] = []
    @Published private(set) var isLoadingRoutines = false
    @Published private(set) var removingRoutineID: String?
    @Published var routineRemovalError: String?
    @Published private(set) var isImageGenerationAvailable = false

    var visibleBots: [BotSummary] {
        filteredBots.filter { !$0.isHidden }
    }

    var hiddenBots: [BotSummary] {
        filteredBots.filter(\.isHidden)
    }

    var activeNowBots: [BotSummary] {
        inventory.bots.filter { $0.isRecentlyActive || $0.isWorkingNow }
    }

    func loadAvatars() async {
        guard inventory.availability == .ready, let service else { return }
        for bot in inventory.bots where bot.hasAvatar && avatarImages[bot.id] == nil {
            if let data = await service.avatarImageData(profileID: bot.id),
               inventory.availability == .ready, botsByID[bot.id]?.hasAvatar == true {
                avatarImages[bot.id] = data
            }
        }
    }

    /// Fills missing avatars, or with `all` replaces every avatar that isn't
    /// already a Herm face (uploads included) so the whole roster animates.
    func populateAvatars(all: Bool = false) async -> String {
        guard capabilityAvailable, let service else { return "Bot Mode is unavailable." }
        for bot in inventory.bots where bot.hasAvatar && avatarImages[bot.id] == nil {
            if let data = await service.avatarImageData(profileID: bot.id) { avatarImages[bot.id] = data }
        }
        let targets = inventory.bots.filter { bot in
            guard bot.hasAvatar else { return all || !bot.hasCustomAvatar }
            return all && !(avatarImages[bot.id].map { BotAvatarView.matchesHermFace($0, id: bot.id) } ?? false)
        }
        if targets.isEmpty { return all ? "Every Bot already uses its Herm face." : "Every Bot already has an avatar." }
        var saved = 0
        var failure: String?
        for bot in targets {
            guard let png = BotFaceMark.png(id: bot.id) else {
                failure = "Could not render the avatar for \(bot.name)."
                continue
            }
            do {
                try await service.setAvatar(profileID: bot.id, dataURL: "data:image/png;base64," + png.base64EncodedString())
                avatarImages[bot.id] = png
                saved += 1
            } catch {
                failure = error.localizedDescription
            }
        }
        if saved > 0 { await refreshNow(force: true) }
        return "Created \(saved) of \(targets.count) avatars." + (failure.map { " \($0)" } ?? "")
    }

    func checkImageGeneration() async {
        guard capabilityAvailable, let service else { return }
        isImageGenerationAvailable = await service.isImageGenerationAvailable()
    }

    func generateAvatar(prompt: String) async throws -> String {
        guard capabilityAvailable, let service else {
            throw NSError(domain: "HermesBots", code: 0, userInfo: [NSLocalizedDescriptionKey: "Bot Mode is unavailable."])
        }
        return try await service.generateAvatarImage(prompt: prompt)
    }

    func setAvatar(profileID: String, dataURL: String) async throws {
        guard capabilityAvailable, let service else { return }
        try await service.setAvatar(profileID: profileID, dataURL: dataURL)
        avatarImages[profileID] = nil
        await refreshNow(force: true)
    }

    func clearAvatar(profileID: String) async throws {
        guard capabilityAvailable, let service else { return }
        try await service.clearAvatar(profileID: profileID)
        avatarImages[profileID] = nil
        await refreshNow(force: true)
    }

    func loadRoutines() async {
        guard capabilityAvailable, let service, !isLoadingRoutines else { return }
        isLoadingRoutines = true
        let refreshed = await service.listRoutines()
        if capabilityAvailable { routines = refreshed }
        isLoadingRoutines = false
    }

    func setHidden(_ hidden: Bool, for bot: BotSummary) async {
        guard capabilityAvailable, let service else { return }
        _ = try? await service.setRosterMeta(profileID: bot.id, title: bot.title, hidden: hidden)
        await refreshNow()
    }

    func duplicateBot(_ bot: BotSummary, newName: String) async -> Bool {
        guard capabilityAvailable, let service else { return false }
        do {
            try await service.duplicate(profileID: bot.id, newName: newName, title: bot.title)
            await refreshNow()
            return true
        } catch {
            botCreationError = Self.mutationDiagnostic(for: error, noun: "duplicate the Bot")
            return false
        }
    }

    func createRoutine(for bot: BotSummary, title: String, schedule: String, prompt: String) async -> Bool {
        guard capabilityAvailable, let service else { return false }
        do {
            try await service.createRoutine(profileID: bot.id, title: title, schedule: schedule, prompt: prompt)
            await loadRoutines()
            return true
        } catch {
            botCreationError = Self.mutationDiagnostic(for: error, noun: "create the routine")
            return false
        }
    }

    @discardableResult
    func removeRoutine(_ routine: BotRoutine) async -> Bool {
        guard capabilityAvailable, let service, removingRoutineID == nil else { return false }
        removingRoutineID = routine.id
        routineRemovalError = nil
        defer { removingRoutineID = nil }
        do {
            try await service.removeRoutine(jobName: routine.jobName)
            await loadRoutines()
            return true
        } catch {
            routineRemovalError = Self.mutationDiagnostic(for: error, noun: "remove the routine")
            return false
        }
    }

    func clearRoutineRemovalError() {
        routineRemovalError = nil
    }

    func profileDetail(for bot: BotSummary) async -> BotProfileDetail? {
        guard capabilityAvailable, let service else { return nil }
        var detail = try? await service.profileDetail(profileID: bot.id)
        detail?.title = bot.title ?? ""
        return detail
    }

    func runtimeConfig(for bot: BotSummary) async -> BotRuntimeConfig? {
        await service?.runtimeConfig(profileID: bot.id)
    }

    /// `nil` on success, otherwise the user-facing reason.
    func setFallbacks(_ fallbacks: [BotRuntimeConfig.ModelRef], for bot: BotSummary) async -> String? {
        guard capabilityAvailable, let service else { return "Bot Mode is unavailable." }
        do {
            try await service.setFallbacks(profileID: bot.id, fallbacks)
            return nil
        } catch {
            return Self.mutationDiagnostic(for: error, noun: "save the fallback models")
        }
    }

    func modelOptions() async -> [(provider: String, models: [String])] {
        guard capabilityAvailable, let service else { return [] }
        return (try? await service.modelOptions()) ?? []
    }

    /// `failed` must never be presented to the user as a model confirmation.
    func applyProfileEdit(_ detail: BotProfileDetail, confirmExpensiveModel: Bool) async -> ProfileEditResult {
        guard capabilityAvailable, let service else { return .failed("Bot Mode is unavailable.") }
        do {
            switch try await service.applyProfileEdit(
                profileID: detail.id, title: detail.title, description: detail.description,
                soul: detail.soul, provider: detail.provider, model: detail.model,
                disabledSkills: detail.skills.filter { !$0.enabled }.map(\.id),
                enabledToolsets: detail.toolsetsPinned ? detail.toolsets.filter(\.enabled).map(\.id) : nil,
                enabledMCPServers: detail.mcpServers.filter(\.enabled).map(\.id),
                confirmExpensiveModel: confirmExpensiveModel
            ) {
            case .applied:
                await refreshNow()
                await loadAvatars()
                return .applied
            case .needsConfirmation(let message):
                return .needsConfirmation(message)
            }
        } catch {
            return .failed(Self.mutationDiagnostic(for: error, noun: "profile"))
        }
    }

    enum ProfileEditResult: Equatable {
        case applied
        case needsConfirmation(String)
        case failed(String)
    }

    private static func mutationDiagnostic(for error: Error, noun: String) -> String {
        let message = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? (error as NSError).localizedDescription
        return "Hermes could not \(noun). \(message)"
    }
}
