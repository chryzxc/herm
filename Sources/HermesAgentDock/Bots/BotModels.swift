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
    let isActive: Bool
    let chat: BotChatReference?
    let worker: BotWorkerReference?
    let avatarURL: URL?
    let preview: String?
    let lastActive: Date?
    let isHidden: Bool
    let hasAvatar: Bool
    let hasCustomAvatar: Bool
    let isDefault: Bool

    init(id: String, name: String, title: String?, description: String?, model: String?, isActive: Bool, chat: BotChatReference?, worker: BotWorkerReference? = nil, avatarURL: URL?, preview: String?, lastActive: Date?, isHidden: Bool, hasAvatar: Bool, hasCustomAvatar: Bool = false, isDefault: Bool) {
        self.id = id
        self.name = name
        self.title = title
        self.description = description
        self.model = model
        self.isActive = isActive
        self.chat = chat
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
        guard let lastActive else { return false }
        return (0...90).contains(Date().timeIntervalSince(lastActive))
    }

    var isWorkingNow: Bool { worker?.isLive == true }
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

/// `profiles.configure` answers `confirm_required` when a guarded model pin
/// needs explicit user confirmation before Hermes writes anything.
enum BotProfileEditOutcome: Equatable, Sendable {
    case applied
    case needsConfirmation(String)
}
