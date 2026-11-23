import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum HermesStatus: Equatable, Sendable {
    case idle, working, needsApproval, needsClarification, offline

    var title: String {
        switch self {
        case .idle: "Ready"
        case .working: "Working"
        case .needsApproval: "Needs your approval"
        case .needsClarification: "Needs your clarification"
        case .offline: "Hermes is offline"
        }
    }

    var icon: Ph {
        switch self {
        case .idle: .checkCircle
        case .working: .lightning
        case .needsApproval: .warningCircle
        case .needsClarification: .question
        case .offline: .wifiSlash
        }
    }
}

enum HermesVoiceState: Equatable {
    case inactive
    case preparing
    case listening
    /// Hermes stopped capturing and is running speech-to-text on the utterance.
    case transcribing
    case interrupted
    case thinking
    case speaking
    /// Hermes heard nothing for several captures. Voice mode stays on, but the
    /// microphone is released until the user resumes.
    case paused
    case localFallback(String)

    var isNativeConversationActive: Bool {
        switch self {
        case .preparing, .listening, .transcribing, .interrupted, .thinking, .speaking, .paused: true
        case .inactive, .localFallback: false
        }
    }

    var label: String { label(agentName: "Herm") }

    func label(agentName: String) -> String {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmed.isEmpty ? "Herm" : trimmed).uppercased()
        return switch self {
        case .inactive: "VOICE OFF"
        case .preparing: "CONNECTING " + name + " VOICE"
        case .listening: name + " IS LISTENING"
        case .transcribing: "TRANSCRIBING"
        case .interrupted: "HEARD YOU — TRANSCRIBING"
        case .thinking: name + " IS THINKING"
        case .speaking: name + " IS SPEAKING"
        case .paused: "PAUSED — TAP TO RESUME"
        case .localFallback: "LOCAL VOICE FALLBACK"
        }
    }

    var fallbackDetail: String? {
        if case .localFallback(let detail) = self { return detail }
        return nil
    }
}

struct ActiveToolCall: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let input: String
    let context: String
    let startedAt: Date
    var result: String?
    var isComplete: Bool
    var completedAt: Date? = nil
    var diffPreview: String? = nil
    var agentID: String? = nil
    var parentAgentID: String? = nil
    var childSessionID: String? = nil
    /// The call's arguments as text, for describing what it does.
    var args: [String: String]? = nil

    var traceDuration: TimeInterval? = nil
    var traceTiming: SessionTraceTiming? = nil
    var traceOutcome: String? = nil
    /// MCP Apps receipt: the cached view this call renders (`MCPApp.receiptID`).
    var app: String? = nil

    /// Marks a thinking segment in a response's activity log.
    static let thinkingName = "__thinking"
    /// Marks a context compaction in a response's activity log.
    static let compactionName = "__compaction"
}

/// Hermes' working plan for a session, from `todo.updated`.
struct TodoPlan: Equatable {
    struct Item: Equatable {
        let content: String
        let status: String
    }
    let sessionID: String
    let items: [Item]
    /// Hermes' snapshot revision; a lower one is an older write.
    var revision = 0
    /// When Hermes wrote this snapshot.
    var updatedAt = Date.distantPast

    var done: Int { items.filter { $0.status == "completed" || $0.status == "cancelled" }.count }
    var inProgress: Item? { items.first { $0.status == "in_progress" } }
    var current: Item? { inProgress ?? items.first { $0.status == "pending" } }

    /// Hermes keeps an abandoned plan forever, so only one written since the latest prompt is live work.
    func isCurrent(latestPromptAt: Date?) -> Bool {
        latestPromptAt.map { updatedAt >= $0 } ?? true
    }

    /// Presentation order only; original slots remain stable identities as statuses change.
    var orderedItemIndices: [Int] {
        func rank(_ item: Item) -> Int {
            switch item.status {
            case "in_progress": 0
            case "completed", "cancelled": 2
            default: 1
            }
        }
        return items.indices.sorted {
            let left = rank(items[$0])
            let right = rank(items[$1])
            return left == right ? $0 < $1 : left < right
        }
    }
}

struct ReasoningState: Equatable {
    var text: String
    var isComplete: Bool
}

enum ConversationActivityPhase: Equatable {
    case idle
    case thinking
    case responding
}

enum InterruptState: Equatable {
    case idle
    case requesting
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct AgentEvent: Identifiable, Equatable, Codable {
    let id: UUID
    let type: String
    let detail: String
    let timestamp: Date
}

struct HermesSubagent: Identifiable, Equatable, Codable {
    let id: String
    var name: String?
    var parentID: String?
    var childSessionID: String?
    var depth: Int
    var goal: String
    var role: String?
    var sourceSkill: String?
    var status: String
    var model: String?
    var startedAt: Date?
    var completedAt: Date?
    var durationSeconds: Double?
    var toolCount: Int
    var latestActivity: String?
    var summary: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var apiCalls: Int?
    var filesRead: [String]
    var filesWritten: [String]

    init(
        id: String, name: String? = nil, parentID: String? = nil, childSessionID: String? = nil, depth: Int = 0,
        goal: String, role: String? = nil, sourceSkill: String? = nil, status: String,
        model: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil,
        durationSeconds: Double? = nil, toolCount: Int = 0, latestActivity: String? = nil,
        summary: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
        reasoningTokens: Int? = nil, apiCalls: Int? = nil, filesRead: [String] = [], filesWritten: [String] = []
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.childSessionID = childSessionID
        self.depth = depth
        self.goal = goal
        self.role = role
        self.sourceSkill = sourceSkill
        self.status = status
        self.model = model
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationSeconds = durationSeconds
        self.toolCount = toolCount
        self.latestActivity = latestActivity
        self.summary = summary
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.apiCalls = apiCalls
        self.filesRead = filesRead
        self.filesWritten = filesWritten
    }
}

enum HermesBackgroundTaskStatus: String, Equatable {
    case running
    case completed
}

enum HermesBackgroundTaskKind: String, Equatable {
    case general, verification, handoff, review
}

struct HermesBackgroundTask: Identifiable, Equatable {
    let id: String
    let parentSessionID: String
    let prompt: String
    let kind: HermesBackgroundTaskKind
    var status: HermesBackgroundTaskStatus
    var output: String?
    let startedAt: Date
    var completedAt: Date?
}

struct AgentActivity: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: Date
    let agentID: String?
    let kind: String
    let text: String
    let toolName: String?
    let handoffTarget: String?
    let diffPreview: String?
    let parentAgentID: String?
    let childSessionID: String?
    var traceCallID: String? = nil
    var traceTiming: SessionTraceTiming? = nil
    var traceDuration: Double? = nil
    var traceOutcome: String? = nil

    init(
        id: UUID, timestamp: Date, agentID: String?, kind: String, text: String,
        toolName: String?, handoffTarget: String?, diffPreview: String? = nil,
        parentAgentID: String? = nil, childSessionID: String? = nil,
        traceCallID: String? = nil, traceTiming: SessionTraceTiming? = nil,
        traceDuration: Double? = nil, traceOutcome: String? = nil
    ) {
        self.traceCallID = traceCallID
        self.traceTiming = traceTiming
        self.traceDuration = traceDuration
        self.traceOutcome = traceOutcome
        self.id = id
        self.timestamp = timestamp
        self.agentID = agentID
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.handoffTarget = handoffTarget
        self.diffPreview = diffPreview
        self.parentAgentID = parentAgentID
        self.childSessionID = childSessionID
    }
}

struct AgentActivityEnvelopeProjection {
    let kind: String
    let payload: [String: Any]
    let consumesParentEvent: Bool
}

struct AgentPresentationSnapshot: Equatable {
    let displayedSubagents: [HermesSubagent]
    let pipeline: [AgentActivityPresentation.PipelineActivity]
    let activityCountsByAgentID: [String: Int]
    let activeAgentIDs: Set<String>
    let revision: UInt
}

struct SessionAgentState: Equatable, Codable {
    let activeToolCalls: [ActiveToolCall]
    let recentEvents: [AgentEvent]
    let sessionAgents: [HermesSubagent]
    let activeSubagents: [HermesSubagent]
    let agentActivities: [AgentActivity]
    let synthesizedSubagentIDs: Set<String>
}

/// Keep the archive bounded by most recent agent activity.
enum SessionAgentStateRetention {
    static let maximumSessionCount = 300

    nonisolated static func lastActivity(_ state: SessionAgentState) -> Date {
        var latest = Date.distantPast
        for call in state.activeToolCalls { latest = max(latest, call.completedAt ?? call.startedAt) }
        for event in state.recentEvents { latest = max(latest, event.timestamp) }
        for activity in state.agentActivities { latest = max(latest, activity.timestamp) }
        return latest
    }

    nonisolated static func pruned(
        _ states: [String: SessionAgentState], limit: Int = maximumSessionCount
    ) -> [String: SessionAgentState] {
        guard states.count > limit else { return states }
        let kept = Set(
            states.map { (id: $0.key, date: lastActivity($0.value)) }
                .sorted { $0.date != $1.date ? $0.date > $1.date : $0.id < $1.id }
                .prefix(limit).map(\.id))
        return states.filter { kept.contains($0.key) }
    }
}

private struct SessionAgentStateArchive: Codable {
    let schemaVersion: Int
    let states: [String: SessionAgentState]

    init(states: [String: SessionAgentState]) {
        self.schemaVersion = 1
        self.states = states
    }
}

struct SessionAgentStateStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        let supportRoot =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support", isDirectory: true)
        self.fileURL =
            fileURL
            ?? supportRoot
            .appendingPathComponent("Herm", isDirectory: true)
            .appendingPathComponent("session-agent-state-v1.json")
    }

    func load() -> [String: SessionAgentState] {
        guard let data = try? Data(contentsOf: fileURL),
            let archive = try? JSONDecoder.sessionAgentState.decode(SessionAgentStateArchive.self, from: data),
            archive.schemaVersion == 1
        else { return [:] }
        return SessionAgentStateRetention.pruned(archive.states)
    }

    /// Atomic writes stage through `<name>.sb-*` siblings, and a process killed
    /// mid-write leaves them behind. Only files untouched for an hour are
    /// removed, so an in-flight write is never disturbed.
    func removeStaleTemporaryFiles(now: Date = .now) {
        let prefix = fileURL.lastPathComponent + ".sb-"
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: fileURL.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > 3600 else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func save(_ states: [String: SessionAgentState]) {
        guard let data = try? JSONEncoder.sessionAgentState.encode(SessionAgentStateArchive(states: states)) else {
            return
        }
        _ = saveEncoded(data)
    }

    func saveEncoded(_ data: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            print("[Herm] session agent state persistence failed")
            return false
        }
    }
}

actor SessionAgentStateWriter {
    private struct Row {
        let state: SessionAgentState
        let json: Data
    }

    private let store: SessionAgentStateStore
    private var pending: [String: SessionAgentState]?
    private var isCommitScheduled = false
    private var encodedRows: [String: Row] = [:]
    private var lastCommittedStates: [String: SessionAgentState]?
    private var hasSweptTemporaryFiles = false

    init(store: SessionAgentStateStore) { self.store = store }

    /// Enqueues and commits at once, off the main actor. Session switches and
    /// turn ends use this instead of a synchronous store save.
    func commitNow(_ states: [String: SessionAgentState]) {
        enqueue(states)
        commit()
    }

    /// Coalesce activity while keeping an upper bound on the time between saves.
    func enqueue(_ states: [String: SessionAgentState]) {
        if states == pending || (pending == nil && states == lastCommittedStates) { return }
        pending = states
        guard !isCommitScheduled else { return }
        isCommitScheduled = true
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.commitScheduled()
        }
    }

    func flush() {
        commit()
    }

    private func commitScheduled() {
        isCommitScheduled = false
        commit()
    }

    private func commit() {
        guard let pending else { return }
        if pending == lastCommittedStates {
            self.pending = nil
            return
        }
        let retained = SessionAgentStateRetention.pruned(pending)
        guard let rows = encodeChangedRows(retained) else { return }
        let needsWrite =
            lastCommittedStates == nil || rows.count != encodedRows.count
            || rows.contains { encodedRows[$0.key]?.json != $0.value.json }
        if needsWrite {
            var archive = Data(#"{"schemaVersion":1,"states":{"#.utf8)
            archive.reserveCapacity(archive.count + rows.values.reduce(2) { $0 + $1.json.count + 1 })
            for (index, row) in rows.sorted(by: { $0.key < $1.key }).enumerated() {
                if index != 0 { archive.append(0x2C) }
                archive.append(row.value.json)
            }
            archive.append(contentsOf: "}}".utf8)
            guard store.saveEncoded(archive) else { return }
        }
        encodedRows = rows
        lastCommittedStates = pending
        self.pending = nil
        // Swept after the first real save, not at launch, so a model that never
        // persists (such as a test's) never touches the folder.
        if !hasSweptTemporaryFiles {
            hasSweptTemporaryFiles = true
            store.removeStaleTemporaryFiles()
        }
    }

    /// Keep the v1 archive readable by existing builds and reuse unchanged JSON members.
    private func encodeChangedRows(_ states: [String: SessionAgentState]) -> [String: Row]? {
        let encoder = JSONEncoder.sessionAgentState
        var rows: [String: Row] = [:]
        rows.reserveCapacity(states.count)
        for (id, state) in states {
            if let previous = encodedRows[id], previous.state == state {
                rows[id] = previous
            } else {
                guard var member = try? encoder.encode(id), let value = try? encoder.encode(state) else { return nil }
                member.append(0x3A)
                member.append(value)
                rows[id] = Row(state: state, json: member)
            }
        }
        return rows
    }
}

extension JSONEncoder {
    fileprivate static var sessionAgentState: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var sessionAgentState: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct HermesModelOption: Identifiable, Hashable {
    let provider: String
    let model: String
    var id: String { "\(provider)|\(model)" }
    var displayName: String { "\(provider)  /  \(model)" }
}

enum HermesReasoningVariant: String, CaseIterable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max, ultra

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

struct HermesRuntimeModelSwitchRequest: Equatable {
    let sessionID: String?
    let value: String

    var parameters: [String: Any] {
        var result: [String: Any] = [
            "key": "model",
            "value": value,
            // Selecting a catalog entry is the user's explicit confirmation.
            "confirm_expensive_model": true,
        ]
        if let sessionID { result["session_id"] = sessionID }
        return result
    }
}

struct ChatMessage: Identifiable, Equatable {
    /// Mutable only so a re-read transcript can keep its rows' IDs.
    var id: UUID
    let role: Role
    let text: String
    let images: [NSImage]
    let attachmentURLs: [URL]
    let timestamp: Date
    let modelName: String?
    /// The route returned by the completed prompt's receipt.
    var responseRoute: HermesModelOption?
    let responseDuration: TimeInterval?
    /// Tokens this turn consumed: the delta between consecutive `session.usage`
    /// totals carried by `message.complete`. Nil for restored history.
    let tokenCount: Int?
    let isSteering: Bool
    let steeringStatus: String?
    let isError: Bool
    /// Hermes Bot Mode prefixes teammate deliveries with a documented sender
    /// attribution. Keep it separate from ordinary assistant messages so the
    /// UI never guesses a Bot from message prose.
    let botProfileID: String?
    let botDisplayName: String?
    /// Picker selections are presentation metadata, never inferred from prose.
    let botMentions: [ComposerBotMention]
    /// Stable content revision computed once when a message enters the model.
    /// Transcript descriptors can then compare revisions without re-hashing
    /// the full Markdown body during unrelated view updates.
    let contentRevision: Int
    /// Presentation emptiness, computed once at init. Row guards and the
    /// unread-badge policy consult this flag instead of re-trimming the full
    /// body on every SwiftUI evaluation.
    let hasBodyText: Bool
    /// Metadata labels, formatted once at init: the timestamp and duration are
    /// immutable per message, so row rendering must not re-run DateFormatter.
    let timeLabel: String
    let durationLabel: String?
    /// Tool calls Hermes ran while producing this response, oldest first.
    let activity: [ActiveToolCall]
    /// Set only for Hermes kanban wake notices, which render as a status card.
    let kanbanNotice: KanbanNotice?
    /// Set for rows Hermes wrote itself (system rows, gateway notes, live
    /// status lines), which render as a compact system card.
    let systemEvent: SystemEvent?
    /// A Bot's answer to a DM another Bot sent from this session.
    let isBotHandoffReply: Bool
    /// Emoji reactions Hermes stored on this message; set after init from history or `message.reaction`.
    var reactions: [MessageReaction] = []

    init(
        id: UUID = UUID(), role: Role, text: String, image: NSImage? = nil, images: [NSImage] = [],
        timestamp: Date = Date(), modelName: String? = nil, responseDuration: TimeInterval? = nil,
        tokenCount: Int? = nil, isSteering: Bool = false, steeringStatus: String? = nil, isError: Bool = false,
        botProfileID: String? = nil, botDisplayName: String? = nil, contentRevision: Int? = nil,
        activity: [ActiveToolCall] = [], kanbanNotice: KanbanNotice? = nil, systemEvent: SystemEvent? = nil,
        isBotHandoffReply: Bool = false, botMentions: [ComposerBotMention] = [], attachmentURLs: [URL] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images.isEmpty ? image.map { [$0] } ?? [] : images
        self.attachmentURLs = attachmentURLs
        self.timestamp = timestamp
        self.modelName = modelName
        self.responseDuration = responseDuration
        self.tokenCount = tokenCount
        self.isSteering = isSteering
        self.steeringStatus = steeringStatus
        self.isError = isError
        self.botProfileID = botProfileID
        self.botDisplayName = botDisplayName
        self.botMentions = botMentions
        self.contentRevision = contentRevision ?? Self.revision(for: text)
        self.hasBodyText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.timeLabel = timestamp.formatted(date: .abbreviated, time: .shortened)
        self.durationLabel = responseDuration.map { ResponseDurationFormatting.string(seconds: $0) }
        self.activity = activity
        self.kanbanNotice = kanbanNotice
        self.systemEvent = systemEvent
        self.isBotHandoffReply = isBotHandoffReply
    }

    var image: NSImage? { images.first }

    private static func revision(for text: String) -> Int {
        var value: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: value)
    }

    func attachingImages(_ added: [NSImage]) -> ChatMessage {
        var copy = ChatMessage(
            id: id,
            role: role,
            text: text,
            images: images + added,
            timestamp: timestamp,
            modelName: modelName,
            responseDuration: responseDuration,
            tokenCount: tokenCount,
            isSteering: isSteering,
            steeringStatus: steeringStatus,
            isError: isError,
            botProfileID: botProfileID,
            botDisplayName: botDisplayName,
            contentRevision: contentRevision,
            activity: activity,
            kanbanNotice: kanbanNotice,
            systemEvent: systemEvent,
            isBotHandoffReply: isBotHandoffReply,
            botMentions: botMentions,
            attachmentURLs: attachmentURLs
        )
        copy.reactions = reactions
        copy.responseRoute = responseRoute
        return copy
    }

    enum Role { case user, hermes }
}

/// A feed status line split for display: `▶ **Fix 2** started · @forge \`t_1\``
/// becomes headline "**Fix 2** started", bots ["forge"], id "t_1". Segments
/// after the first ` · ` lose their mentions and ids and become tags.
struct FeedLine: Equatable {
    var headline: String
    var bots: [String] = []
    var tags: [String] = []
    var id: String?
    var detail: String?

    init(_ text: String) {
        // Any plugin's text works: the first line with words is the headline
        // (leading glyphs and heading marks dropped), the rest is detail.
        let strip = { (line: String) in String(line.drop { !$0.isLetter && !$0.isNumber && $0 != "*" && $0 != "`" }) }
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.count > 1, strip(lines[0]).isEmpty { lines.removeFirst() }
        let segments = (lines.first ?? "").components(separatedBy: " · ")
        headline = strip(segments[0])
        for segment in segments.dropFirst() {
            var leftover: [Substring] = []
            for word in segment.split(separator: " ") {
                if word.hasPrefix("@"), word.count > 1 {
                    bots.append(String(word.dropFirst().trimmingCharacters(in: .punctuationCharacters)))
                } else if word.count > 2, word.hasPrefix("`"), word.hasSuffix("`") {
                    id = String(word.dropFirst().dropLast())
                } else {
                    leftover.append(word)
                }
            }
            if !leftover.isEmpty { tags.append(leftover.joined(separator: " ")) }
        }
        let body = lines.dropFirst()
            .map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        detail = body.isEmpty ? nil : body
    }
}

/// A transcript row or live status Hermes produced itself rather than the
/// user or the model's reply: kept visible, labelled, and set apart.
struct SystemEvent: Equatable {
    var label: String
    var tone: DockStatusTone = .inactive
    /// A plugin feed row: rendered as a one-line activity entry.
    var isFeed = false
    var isModelSwitch = false

    static func modelSwitchSummary(_ text: String) -> String {
        let prefix = "[System: The active model for this chat has changed to "
        let suffix =
            ". From this point forward, use this runtime metadata when answering questions about what model/provider is active.]"
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return text }
        return "Switched to " + text.dropFirst(prefix.count).dropLast(suffix.count)
    }

    static func modelSwitchProvider(_ text: String) -> (summary: String, provider: String)? {
        let summary = modelSwitchSummary(text)
        guard summary != text, let delimiter = summary.range(of: " via provider ", options: .backwards) else {
            return nil
        }
        let provider = String(summary[delimiter.upperBound...])
        guard !provider.isEmpty else { return nil }
        return (String(summary[..<delimiter.upperBound]), provider)
    }

    private static let prefixLabels: [(prefix: String, label: String)] = [
        ("[ASYNC DELEGATION BATCH COMPLETE", "Delegation complete"),
        ("[CONTEXT COMPACTION", "Context compaction"),
        ("[System: The active model", "Model switch"),
        ("[System note: Your previous turn was interrupted", "Auto-continue"),
        ("[System", "System note"),
        ("[IMPORTANT: Background process", "Background process"),
        ("[IMPORTANT: You are running as a schedul", "Scheduled job"),
        ("[Cronjob", "Cron job"),
        ("[OUT-OF-BAND USER MESSAGE", "Out-of-band message"),
        ("[Your active task list was preserved", "Task list"),
        ("[STILL IN PROGRESS", "Still in progress"),
        ("[INTERNAL NOTIFICATION", "Notification"),
    ]

    /// Classifies a stored transcript row; nil keeps it an ordinary bubble.
    /// Steers and slash-skill turns are typed but are the user's own words.
    static func classify(role: String, text: String, displayKind: String?) -> SystemEvent? {
        if displayKind == "model_switch"
            || (role == "user"
                && text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("[System: The active model"))
        {
            return SystemEvent(label: "Model switch", isModelSwitch: true)
        }
        if role == "system" { return SystemEvent(label: "System") }
        if let kind = displayKind, !kind.isEmpty, kind != "steer", kind != "skill_invocation" {
            return SystemEvent(label: humanized(kind), tone: kind == "failed_turn" ? .attention : .inactive)
        }
        guard role == "user" else { return nil }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.hasPrefix("[IMPORTANT: The user has invoked the ") else { return nil }
        if let match = prefixLabels.first(where: { head.hasPrefix($0.prefix) }) {
            return SystemEvent(label: match.label)
        }
        // Other gateway notes open with an ALL-CAPS bracket header.
        guard head.hasPrefix("["),
            let end = head.dropFirst().firstIndex(where: { ":]—".contains($0) })
        else { return nil }
        let header = head[head.index(after: head.startIndex)..<end].trimmingCharacters(in: .whitespaces)
        guard header.count >= 4, header == header.uppercased(), header.contains(where: \.isLetter) else { return nil }
        return SystemEvent(label: humanized(header.lowercased()))
    }

    /// Live `status.update` kinds Herm has no dedicated UI for.
    static func liveStatus(kind: String) -> SystemEvent {
        switch kind {
        case "warn": SystemEvent(label: "Warning", tone: .attention)
        case "goal": SystemEvent(label: "Goal", tone: .review)
        case "loop": SystemEvent(label: "Loop", tone: .working)
        case "process": SystemEvent(label: "Background process", tone: .complete)
        default: SystemEvent(label: humanized(kind))
        }
    }

    /// A plugin feed row (e.g. a pipeline status line), toned by its glyph.
    static func feed(source: String, text: String) -> SystemEvent {
        let tone: DockStatusTone =
            switch text.trimmingCharacters(in: .whitespaces).first {
            case "✅", "✔": .complete
            case "▶": .working
            case "🔍", "👀": .review
            case "🔁", "🔄", "→": .queued
            case "↩", "⏸", "⛔", "🛑", "✖", "✘", "❌", "⚠": .attention
            default: keywordTone(text)
            }
        return SystemEvent(label: source, tone: tone, isFeed: true)
    }

    /// Fallback for plugins that post plain words instead of status glyphs.
    private static func keywordTone(_ text: String) -> DockStatusTone {
        let head = (text.split(separator: "\n").first.map(String.init) ?? text).lowercased()
        let has = { (words: [String]) in words.contains { head.contains($0) } }
        if has(["fail", "error", "blocked", "rejected", "changes requested", "crash", "timed out"]) {
            return .attention
        }
        if has(["review"]) { return .review }
        if has(["done", "complete", "approved", "passed", "success", "merged", "finished"]) { return .complete }
        if has(["start", "running", "in progress", "working"]) { return .working }
        return .inactive
    }

    static func humanized(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// One kanban wake notice (`✔ Kanban t_c891be93 done — Title` plus summary
/// lines), split for the status card. Only the glyph and card id are stable
/// Hermes output, so the label falls back to the glyph when wording changes.
struct KanbanNotice: Equatable {
    let taskID: String
    let label: String
    let tone: DockStatusTone
    let title: String?
    let detail: String?
    /// Set on notices rebuilt from the card's history, for de-duplication.
    var eventKey: String?

    init?(text: String) {
        var lines = text.components(separatedBy: .newlines)
        let head = lines.removeFirst()
        guard let id = head.firstMatch(of: /\bt_[0-9a-f]{8}\b/) else { return nil }
        taskID = String(id.0)
        let glyph = head.prefix { $0 != " " }
        var event = head[id.range.upperBound...].trimmingCharacters(in: .whitespaces)
        var title: String?
        var reason: String?
        // Whichever separator comes first: `done — <title>` or `blocked: <reason>`.
        let dash = event.range(of: " — ")
        let colon = event.range(of: ": ")
        if let dash, colon.map({ dash.lowerBound < $0.lowerBound }) ?? true {
            title = String(event[dash.upperBound...])
            event = String(event[..<dash.lowerBound])
        } else if let colon {
            reason = String(event[colon.upperBound...])
            event = String(event[..<colon.lowerBound])
        }
        let lower = event.lowercased()
        (label, tone) =
            switch true {
            case lower.contains("changes"): ("Changes requested", .attention)
            case lower.hasPrefix("created"): ("Created", .queued)
            case lower.hasPrefix("picked up"): ("Picked up", .working)
            case lower.hasPrefix("assigned"):
                (event.prefix(1).uppercased() + event.dropFirst().replacing("@", with: ""), .queued)
            case lower.hasPrefix("unblocked"): ("Unblocked", .queued)
            case lower.contains("triage"): ("Triage", .attention)
            case lower.contains("blocked"): ("Blocked", .attention)
            case lower.contains("gave up"): ("Gave up", .attention)
            case lower.contains("crash"), lower.contains("stopped unexpectedly"): ("Crashed", .attention)
            case lower.contains("timed out"), lower.contains("ran past"): ("Timed out", .attention)
            case lower.contains("review"): ("Ready for review", .review)
            case lower.hasPrefix("done"), lower.contains("complete"): ("Done", .complete)
            case lower.hasPrefix("→"): ("Moved to \(event.dropFirst().trimmingCharacters(in: .whitespaces))", .queued)
            default:
                switch glyph {
                case "✔", "✅": ("Done", .complete)
                case "👀": ("Ready for review", .review)
                case "🔄": ("Updated", .queued)
                case "⏸", "⛔", "🛑", "✖", "✘", "⏱": ("Needs attention", .attention)
                default: ("Update", .inactive)
                }
            }
        self.title = title
        let detail = ([reason] + lines.map(Optional.some)).compactMap { $0 }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail.isEmpty ? nil : detail
    }

    /// Card events Hermes never posts to chat (it notifies terminal ones
    /// only), written as wake-notice text so they parse into the same cards.
    /// Heartbeats and other worker bookkeeping stay out.
    static func boardEventNotices(for card: KanbanTaskDetail) -> [(
        key: String, profileID: String?, text: String, date: Date
    )] {
        let runs = Dictionary(card.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return card.events.compactMap { event in
            guard let date = event.createdAt else { return nil }
            let who = event.runID.flatMap { runs[$0]?.profile } ?? event.assignee
            let head: String
            switch event.kind {
            case "created": head = "🆕 Kanban \(card.id) created" + (event.assignee.map { " for @\($0)" } ?? "")
            case "claimed": head = "▶ Kanban \(card.id) picked up" + (who.map { " by @\($0)" } ?? "")
            case "review_requested": head = "👀 Kanban \(card.id) review requested"
            case "changes_requested": head = "↩ Kanban \(card.id) changes requested"
            case "assigned": head = "👤 Kanban \(card.id) assigned" + (event.assignee.map { " to @\($0)" } ?? "")
            case "promoted": head = "🔄 Kanban \(card.id) → ready"
            case "unblocked": head = "🔄 Kanban \(card.id) unblocked"
            default: return nil
            }
            var note = event.note.flatMap { $0.components(separatedBy: .newlines).first }.map { "\n\($0)" } ?? ""
            // A pickup by a new bot is the handoff: name both ends.
            if event.kind == "claimed", note.isEmpty, let who,
                let index = card.runs.firstIndex(where: { $0.id == event.runID }), index > 0,
                let from = card.runs[index - 1].profile, from != who
            {
                note = "\n\(from) → \(who)"
            }
            let key = "\(card.id)|\(event.kind)|\(Int(date.timeIntervalSince1970))|\(event.runID ?? "")"
            return (key, who ?? card.assignee, "\(head) — \(card.title)\(note)", date)
        }
    }

    var taskSummary: KanbanTaskSummary {
        KanbanTaskSummary(id: taskID, title: title ?? taskID, status: "", detail: nil, priority: nil, assignee: nil)
    }

    /// Full handoff behind the notice: the run summary Hermes clipped to its
    /// first line, else the card's latest summary.
    func fullSummary(in card: KanbanTaskDetail) -> String? {
        let clipped = detail.map { String($0.prefix(80)) } ?? ""
        let matched = clipped.isEmpty ? nil : card.runs.compactMap(\.summary).last { $0.hasPrefix(clipped) }
        return matched ?? card.latestSummary
    }
}

struct HermesSession: Identifiable, Equatable, Sendable {
    let id: String
    /// Hermes profile that owns this session. Older launch-profile payloads
    /// omit it, so the value remains optional for compatibility.
    let profileID: String?
    let title: String
    let preview: String
    let startedAt: Date?
    /// The most recent activity time. Older Hermes responses may omit it, so
    /// callers should use `lastUpdatedAt` when rendering or sorting activity.
    let updatedAt: Date?
    let messageCount: Int
    let source: String
    let isHidden: Bool
    /// True while a turn or background task is actively running for this
    /// session, even when it is not the one currently open.
    let isWorking: Bool
    /// True once this session has completed activity the user has not yet
    /// seen (i.e. it was not the open session when the activity finished).
    let hasUnreadUpdate: Bool
    /// Hermes' `pinned` flag as the row reported it. The selected profile's
    /// pins come from `DockModel.pinnedSessions`; this carries other
    /// profiles' pins from the all-profile scan.
    let isPinned: Bool
    /// Last model reported by Hermes, for display only, not provider routing.
    let modelName: String?

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled chat" : title
    }

    var displayPreview: String? {
        SessionPreviewPresentation.summary(preview)
    }

    var lastUpdatedAt: Date? { updatedAt ?? startedAt }

    /// Origin comes only from Hermes metadata, never from a title or preview.
    var sourceBadgeTitle: String? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "", "herm", "hermes", "local", "cli", "tui", "desktop", "web", "api", "conversation",
            "project", "projects", "branch", "unknown", "subagent", "bot_room":
            return nil
        case "cron": return "Cron"
        case "cron_output": return "Cron output"
        case "whatsapp", "whatsapp_cloud": return "WhatsApp"
        case "bluebubbles": return "BlueBubbles"
        case "google_chat": return "Google Chat"
        case "teams", "msteams": return "Microsoft Teams"
        case "sms": return "SMS"
        default:
            return value.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    var scopedID: ProfileScopedID { ProfileScopedID(profileID: profileID, resourceID: id) }

    func withPinned(_ pinned: Bool, profileID: String?) -> HermesSession {
        HermesSession(
            id: id, profileID: profileID, title: title, preview: preview, startedAt: startedAt, updatedAt: updatedAt,
            messageCount: messageCount, source: source, isHidden: isHidden, isWorking: isWorking,
            hasUnreadUpdate: hasUnreadUpdate, isPinned: pinned, modelName: modelName)
    }

    func withModelName(_ name: String?) -> HermesSession {
        HermesSession(
            id: id, profileID: profileID, title: title, preview: preview, startedAt: startedAt, updatedAt: updatedAt,
            messageCount: messageCount, source: source, isHidden: isHidden, isWorking: isWorking,
            hasUnreadUpdate: hasUnreadUpdate, isPinned: isPinned, modelName: name)
    }

    init(
        id: String,
        profileID: String? = nil,
        title: String,
        preview: String,
        startedAt: Date?,
        updatedAt: Date? = nil,
        messageCount: Int,
        source: String,
        isHidden: Bool = false,
        isWorking: Bool = false,
        hasUnreadUpdate: Bool = false,
        isPinned: Bool = false,
        modelName: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.preview = preview
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.source = source
        self.isHidden = isHidden
        self.isWorking = isWorking
        self.hasUnreadUpdate = hasUnreadUpdate
        self.isPinned = isPinned
        let trimmed = modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Stable identity for a profile-owned Hermes resource. Display names are
/// presentation only and must never be used as routing keys.
struct ProfileScopedID: Hashable, Equatable, Sendable {
    let profileID: String?
    let resourceID: String

    init(profileID: String?, resourceID: String) {
        self.profileID =
            profileID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? profileID?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        self.resourceID = resourceID
    }
}

struct QueuedPrompt: Identifiable {
    let id = UUID()
    let sessionID: String
    var text: String
    let images: [ImageAttachment]
    var pdfURLs: [URL] = []
    var contexts: [ChatContext] = []
    var replyQuote: ReplyQuote? = nil
    var botMentions: [ComposerBotMention] = []
    var botRecipient: BotSummary? = nil
    var profileID: String? = nil
    var mentionProfiles: [String] = []
}

struct ImageAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
    let fileURL: URL
    var ownsTemporaryFile = false

    var fileName: String { fileURL.lastPathComponent }
}
