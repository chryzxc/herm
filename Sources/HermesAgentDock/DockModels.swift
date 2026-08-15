import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum HermesStatus: Equatable {
    case idle, working, needsApproval, offline

    var title: String {
        switch self {
        case .idle: "Ready"
        case .working: "Working"
        case .needsApproval: "Needs your approval"
        case .offline: "Hermes is offline"
        }
    }

    var icon: String {
        switch self {
        case .idle: "sparkles"
        case .working: "bolt.horizontal.circle"
        case .needsApproval: "exclamationmark.circle"
        case .offline: "wifi.slash"
        }
    }
}

enum HermesVoiceState: Equatable {
    case inactive
    case preparing
    case listening
    case interrupted
    case thinking
    case speaking
    case localFallback(String)

    var isNativeConversationActive: Bool {
        switch self {
        case .preparing, .listening, .interrupted, .thinking, .speaking: true
        case .inactive, .localFallback: false
        }
    }

    var label: String {
        switch self {
        case .inactive: "VOICE OFF"
        case .preparing: "CONNECTING VOICE"
        case .listening: "HERMES IS LISTENING"
        case .interrupted: "HEARD YOU — TRANSCRIBING"
        case .thinking: "HERMES IS THINKING"
        case .speaking: "HERMES IS SPEAKING"
        case .localFallback: "LOCAL VOICE FALLBACK"
        }
    }

    var fallbackDetail: String? {
        if case .localFallback(let detail) = self { return detail }
        return nil
    }
}

struct ActiveToolCall: Identifiable, Equatable, Codable {
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

    init(id: String, name: String? = nil, parentID: String? = nil, childSessionID: String? = nil, depth: Int = 0,
         goal: String, role: String? = nil, sourceSkill: String? = nil, status: String,
         model: String? = nil, startedAt: Date? = nil, completedAt: Date? = nil,
         durationSeconds: Double? = nil, toolCount: Int = 0, latestActivity: String? = nil,
         summary: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
         reasoningTokens: Int? = nil, apiCalls: Int? = nil, filesRead: [String] = [], filesWritten: [String] = []) {
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

    init(id: UUID, timestamp: Date, agentID: String?, kind: String, text: String,
         toolName: String?, handoffTarget: String?, diffPreview: String? = nil,
         parentAgentID: String? = nil, childSessionID: String? = nil) {
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
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.fileURL = fileURL ?? supportRoot
            .appendingPathComponent("HermesAgentDock", isDirectory: true)
            .appendingPathComponent("session-agent-state-v1.json")
    }

    func load() -> [String: SessionAgentState] {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder.sessionAgentState.decode(SessionAgentStateArchive.self, from: data),
              archive.schemaVersion == 1 else { return [:] }
        return archive.states
    }

    func save(_ states: [String: SessionAgentState]) {
        guard let data = try? JSONEncoder.sessionAgentState.encode(SessionAgentStateArchive(states: states)) else { return }
        saveEncoded(data)
    }

    func saveEncoded(_ data: Data) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("[HermesAgentDock] session agent state persistence failed")
        }
    }
}

actor SessionAgentStateWriter {
    private let store: SessionAgentStateStore
    private var pending: [String: SessionAgentState]?
    private var generation = 0
    private var lastEncoded: Data?

    init(store: SessionAgentStateStore) { self.store = store }

    func enqueue(_ states: [String: SessionAgentState]) {
        pending = states
        generation &+= 1
        let expected = generation
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.commitIfCurrent(expected)
        }
    }

    func flush() {
        generation &+= 1
        commit()
    }

    private func commitIfCurrent(_ expected: Int) {
        guard expected == generation else { return }
        commit()
    }

    private func commit() {
        guard let pending,
              let data = try? JSONEncoder.sessionAgentState.encode(SessionAgentStateArchive(states: pending)),
              data != lastEncoded else { return }
        lastEncoded = data
        store.saveEncoded(data)
        self.pending = nil
    }
}

private extension JSONEncoder {
    static var sessionAgentState: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var sessionAgentState: JSONDecoder {
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
            "confirm_expensive_model": true
        ]
        if let sessionID { result["session_id"] = sessionID }
        return result
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let text: String
    let images: [NSImage]
    let timestamp: Date
    let modelName: String?
    let isSteering: Bool
    let steeringStatus: String?

    init(id: UUID = UUID(), role: Role, text: String, image: NSImage? = nil, images: [NSImage] = [], timestamp: Date = Date(), modelName: String? = nil, isSteering: Bool = false, steeringStatus: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images.isEmpty ? image.map { [$0] } ?? [] : images
        self.timestamp = timestamp
        self.modelName = modelName
        self.isSteering = isSteering
        self.steeringStatus = steeringStatus
    }

    var image: NSImage? { images.first }

    enum Role { case user, hermes }
}

struct HermesSession: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let startedAt: Date?
    let messageCount: Int
    let source: String

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled chat" : title
    }

    var displayPreview: String? {
        SessionPreviewPresentation.summary(preview)
    }
}

struct ImageAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
    let fileURL: URL

    var fileName: String { fileURL.lastPathComponent }
}
