import Foundation

enum BotAvailability: Equatable, Sendable { case ready, unavailable, unsupported, malformed, stale }

struct BotChatReference: Equatable, Sendable {
    let sessionID: String
    let profileID: String
    var title: String?
    var preview: String?
    var lastActive: Date?

    init(sessionID: String, profileID: String, title: String? = nil, preview: String? = nil, lastActive: Date? = nil) {
        self.sessionID = sessionID
        self.profileID = profileID
        self.title = title
        self.preview = preview
        self.lastActive = lastActive
    }
}

/// The profile-owned worker session Hermes includes in `profiles.list`.
/// This is deliberately separate from a Bot's canonical chat: Kanban and
/// delegated-tool workers are hidden from normal conversation lists but
/// heartbeat while they are running.
struct BotWorkerReference: Equatable, Sendable {
    let sessionID: String
    let source: String?
    let title: String?
    let lastActive: Date?

    /// Hermes workers heartbeat at least once a minute. Allow one missed
    /// heartbeat without presenting a finished worker as perpetually active.
    var isLive: Bool {
        guard let lastActive else { return false }
        let age = Date().timeIntervalSince(lastActive)
        return (0...150).contains(age)
    }
}

struct BotSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let title: String?
    let description: String?
    let model: String?
    let provider: String?
    let isActive: Bool
    let chat: BotChatReference?
    let recentSession: BotChatReference?
    let worker: BotWorkerReference?
    let avatarURL: URL?
    let preview: String?
    let lastActive: Date?
    let isHidden: Bool
    let hasAvatar: Bool
    let hasCustomAvatar: Bool
    let isDefault: Bool
    /// Exact busy flag from the gateway's live session list (`working`/`waiting`
    /// vs `idle`). nil when none of the bot's sessions is live in that process
    /// (kanban or cron workers), where the heartbeat heuristic still applies.
    var liveBusy: Bool?

    init(id: String, name: String, title: String?, description: String?, model: String?, provider: String? = nil, isActive: Bool, chat: BotChatReference?, recentSession: BotChatReference? = nil, worker: BotWorkerReference? = nil, avatarURL: URL?, preview: String?, lastActive: Date?, isHidden: Bool, hasAvatar: Bool, hasCustomAvatar: Bool = false, isDefault: Bool) {
        self.id = id
        self.name = name
        self.title = title
        self.description = description
        self.model = model
        self.provider = provider
        self.isActive = isActive
        self.chat = chat
        self.recentSession = recentSession
        self.worker = worker
        self.avatarURL = avatarURL
        self.preview = preview
        self.lastActive = lastActive
        self.isHidden = isHidden
        self.hasAvatar = hasAvatar
        self.hasCustomAvatar = hasCustomAvatar
        self.isDefault = isDefault
    }
    /// Newest of the canonical-chat and worker watermarks; Hermes reports
    /// both in epoch seconds and Bot Mode treats ~90s as "working now".
    var isRecentlyActive: Bool {
        guard liveBusy == nil, let lastActive else { return false }
        return (0...90).contains(Date().timeIntervalSince(lastActive))
    }

    var isWorkingNow: Bool { liveBusy ?? (worker?.isLive == true) }

    /// The kanban/cron worker session while it is live. Worker sessions are
    /// kept out of Recents, so this is the only way to open one.
    var liveWorkerChat: BotChatReference? {
        guard let worker, worker.isLive else { return nil }
        return BotChatReference(sessionID: worker.sessionID, profileID: id, title: worker.title, lastActive: worker.lastActive)
    }
}

struct BotDetails: Equatable, Sendable {
    let id: String
    let name: String
    let title: String?
    let description: String?
    let model: String?
    let chat: BotChatReference?
}

struct BotRoutine: Identifiable, Equatable, Sendable {
    let id: String
    let profileID: String
    /// Display title without the `[bot:<name>]` namespace Hermes stores.
    let name: String
    /// Full Hermes cron job name including the `[bot:<name>]` namespace.
    let jobName: String
    let schedule: String
    let prompt: String?
    let enabled: Bool
    let sessionID: String?
}

struct BotInventory: Equatable, Sendable {
    let availability: BotAvailability
    let bots: [BotSummary]
    let diagnostic: String
}

/// Compact, truthful strings for the Bot roster. The page may show canonical
/// Bot Chat preview text as a preview, but it must never label it as a task or
/// infer a work duration from it.
enum BotRosterPresentation {
    static func role(for bot: BotSummary) -> String {
        bot.title?.nonEmpty ?? bot.description?.nonEmpty ?? "Hermes profile"
    }

    static func activity(for bot: BotSummary) -> String {
        if let preview = bot.preview?.nonEmpty { return preview }
        if bot.isWorkingNow { return "Working in \(bot.worker?.source ?? "Hermes") work." }
        return bot.isRecentlyActive ? "Active in Bot work." : "No recent activity"
    }

    static func emptyStateTitle(isSearching: Bool) -> String {
        isSearching ? "No matching Bots" : "No Bots yet"
    }

    static let primaryActionLabel = "Edit Profile"
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One switchable capability row (skill or MCP server) from
/// `profiles.describe`.
struct BotToggleItem: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    var enabled: Bool
}

/// One toolset row from `profiles.describe`, including Hermes' own
/// human-facing label and description.
struct BotToolsetItem: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let detail: String
    let toolCount: Int
    var enabled: Bool
}

/// Full editable snapshot of one profile from `profiles.describe`. Hermes
/// owns the profile; this is the Dock's projection for the editor sheet.
struct BotProfileDetail: Equatable, Sendable {
    let id: String
    var title: String
    var description: String
    var soul: String
    var provider: String?
    var model: String?
    var skills: [BotToggleItem]
    var toolsets: [BotToolsetItem]
    var toolsetsPinned: Bool
    var mcpServers: [BotToggleItem]
}

/// Enabled skill, toolset and MCP totals shown on a roster card.
struct BotCapabilityCounts: Equatable, Sendable {
    let skills: Int
    let toolsets: Int
    let mcpServers: Int

    init(_ detail: BotProfileDetail) {
        skills = detail.skills.filter(\.enabled).count
        toolsets = detail.toolsets.filter(\.enabled).count
        mcpServers = detail.mcpServers.filter(\.enabled).count
    }

    var label: String {
        ["\(skills) skills", "\(toolsets) toolsets", mcpServers > 0 ? "\(mcpServers) MCP" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// `profiles.configure` answers `confirm_required` when a guarded model pin
/// needs explicit user confirmation before Hermes writes anything.
enum BotProfileEditOutcome: Equatable, Sendable {
    case applied
    case needsConfirmation(String)
}

/// Read-only runtime facts from the profile's own `config.get full`:
/// what the editor shows beside the editable model pin.
struct BotRuntimeConfig: Equatable, Sendable {
    struct ModelRef: Equatable, Sendable {
        let provider: String
        let model: String
        /// Kept so re-saving an existing entry doesn't drop its endpoint.
        var baseURL: String? = nil
    }
    var contextLength: Int?
    var reasoningEffort: String?
    /// Hermes' order: `fallback_providers` first, legacy `fallback_model` after.
    var fallbacks: [ModelRef] = []
    var compressionThreshold: Int?
}

/// A bot starting or finishing work, detected by diffing two roster reads.
struct BotActivityEvent: Identifiable, Equatable, Sendable {
    let botID: String
    let name: String
    let finished: Bool
    /// The bot's `lastActive` epoch, so every observer derives the same notice id.
    let stamp: String
    var id: String { "\(botID)/\(finished)" }
    var text: String { finished ? "\(name) finished" : "\(name) is running" }

    /// ponytail: "working" is the roster's own 90s/live heuristic, so a finish
    /// surfaces up to ~90s after the last write; Hermes has no bot push event.
    static func events(from old: [BotSummary], to new: [BotSummary], excluding profileID: String?) -> [BotActivityEvent] {
        guard !old.isEmpty else { return [] }
        let before = Dictionary(old.map { ($0.id, $0.isWorkingNow || $0.isRecentlyActive) }, uniquingKeysWith: { _, n in n })
        return new.compactMap { bot in
            guard bot.id != profileID, let was = before[bot.id] else { return nil }
            let now = bot.isWorkingNow || bot.isRecentlyActive
            guard now != was else { return nil }
            return BotActivityEvent(botID: bot.id, name: bot.name, finished: !now,
                                    stamp: String(Int(bot.lastActive?.timeIntervalSince1970 ?? 0)))
        }
    }
}

extension Notification.Name {
    static let hermBotActivity = Notification.Name("hermBotActivity")
}
