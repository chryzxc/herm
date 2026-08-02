import Foundation
import SwiftUI

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

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

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
}

@MainActor
final class DockModel: ObservableObject {
    @Published var status: HermesStatus = .idle
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isSending = false
    @Published var approvalText: String?
    @Published var debugLines: [String] = []
    @Published var sessions: [HermesSession] = []
    @Published var isShowingSessions = false
    @Published var isLoadingSessions = false
    @Published var currentSessionTitle: String?

    private let gateway = HermesGateway()
    private var sessionID: String?
    private var streamingMessageID: UUID?
    private var didRestoreLatestSession = false

    init() {
        DebugLog.onLine = { [weak self] line in
            guard let self else { return }
            debugLines = Array((debugLines + [line]).suffix(80))
        }
        DebugLog.write("model: initialized")
        gateway.onEvent = { [weak self] type, params in self?.handleEvent(type, params: params) }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSending else { return }
        draft = ""
        messages.append(ChatMessage(role: .user, text: prompt))
        status = .working
        isSending = true
        DebugLog.write("model: send started (\(prompt.count) characters)")

        Task {
            do {
                try await gateway.connect()
                if sessionID == nil {
                    let result = try await gateway.request("session.create", params: ["source": "hermes-agent-dock"])
                    sessionID = result["session_id"] as? String
                    DebugLog.write("model: session created (id present: \(sessionID != nil))")
                }
                guard let sessionID else { throw HermesGateway.GatewayError.malformedResponse }
                _ = try await gateway.request("prompt.submit", params: ["session_id": sessionID, "text": prompt])
                DebugLog.write("model: prompt submitted")
            } catch {
                DebugLog.write("model: send failed: \(error.localizedDescription)")
                messages.append(ChatMessage(role: .hermes, text: "I couldn’t connect to Hermes: \(error.localizedDescription)"))
                status = .offline
                isSending = false
            }
        }
    }

    func toggleSessions() {
        isShowingSessions.toggle()
        if isShowingSessions { loadSessions() }
    }

    func loadSessions() {
        guard !isLoadingSessions else { return }
        isLoadingSessions = true
        Task {
            defer { isLoadingSessions = false }
            do {
                try await gateway.connect()
                let result = try await gateway.request("session.list", params: ["limit": 50])
                let rows = result["sessions"] as? [[String: Any]] ?? []
                sessions = rows.compactMap(Self.parseSession)
                DebugLog.write("model: loaded \(sessions.count) saved sessions")
            } catch {
                DebugLog.write("model: session list failed: \(error.localizedDescription)")
            }
        }
    }

    func restoreLatestSessionIfNeeded() {
        guard !didRestoreLatestSession else { return }
        didRestoreLatestSession = true
        Task {
            do {
                try await gateway.connect()
                let result = try await gateway.request("session.list", params: ["limit": 1])
                let latest = (result["sessions"] as? [[String: Any]] ?? []).compactMap(Self.parseSession).first
                guard let latest else {
                    DebugLog.write("model: no saved session to restore")
                    return
                }
                sessions = [latest]
                resumeSession(latest)
            } catch {
                DebugLog.write("model: latest session restore failed: \(error.localizedDescription)")
            }
        }
    }

    func resumeSession(_ session: HermesSession) {
        isShowingSessions = false
        isSending = false
        status = .working
        Task {
            do {
                try await gateway.connect()
                let result = try await gateway.request("session.resume", params: [
                    "session_id": session.id,
                    "source": "hermes-agent-dock"
                ])
                sessionID = result["session_id"] as? String
                messages = Self.parseMessages(result["messages"])
                currentSessionTitle = session.displayTitle
                status = .idle
                DebugLog.write("model: resumed session \(session.id) (\(messages.count) messages)")
            } catch {
                status = .offline
                messages = [ChatMessage(role: .hermes, text: "I couldn’t load that conversation: (error.localizedDescription)")]
                DebugLog.write("model: session resume failed: \(error.localizedDescription)")
            }
        }
    }

    func newChat() {
        sessionID = nil
        currentSessionTitle = nil
        messages = []
        status = .idle
        isShowingSessions = false
    }

    func stop() {
        if let sessionID { Task { _ = try? await gateway.request("session.interrupt", params: ["session_id": sessionID]) } }
        status = .idle
        isSending = false
    }

    func respondToApproval(_ choice: String) {
        guard let sessionID else { return }
        Task {
            _ = try? await gateway.request("approval.respond", params: ["session_id": sessionID, "choice": choice])
            approvalText = nil
            status = .working
        }
    }

    private func handleEvent(_ type: String, params: [String: Any]) {
        DebugLog.write("model: handling event \(type)")
        let payload = params["payload"] as? [String: Any] ?? [:]
        switch type {
        case "message.start":
            messages.append(ChatMessage(role: .hermes, text: ""))
            streamingMessageID = messages.last?.id
        case "message.delta":
            guard let delta = (payload["delta"] as? String) ?? (payload["text"] as? String),
                  let id = streamingMessageID,
                  let index = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[index] = ChatMessage(id: id, role: .hermes, text: messages[index].text + delta)
        case "message.complete":
            status = .idle
            isSending = false
            streamingMessageID = nil
        case "approval.request":
            approvalText = (payload["command"] as? String) ?? (payload["description"] as? String) ?? "Hermes wants to perform an action."
            status = .needsApproval
        case "error":
            messages.append(ChatMessage(role: .hermes, text: (payload["message"] as? String) ?? "Hermes reported an error."))
            status = .idle
            isSending = false
        default: break
        }
    }

    private static func parseSession(_ row: [String: Any]) -> HermesSession? {
        guard let id = row["id"] as? String else { return nil }
        let timestamp = (row["started_at"] as? NSNumber)?.doubleValue ?? (row["started_at"] as? Double)
        return HermesSession(
            id: id,
            title: row["title"] as? String ?? "",
            preview: row["preview"] as? String ?? "",
            startedAt: timestamp.map { Date(timeIntervalSince1970: $0) },
            messageCount: (row["message_count"] as? NSNumber)?.intValue ?? 0,
            source: row["source"] as? String ?? ""
        )
    }

    private static func parseMessages(_ value: Any?) -> [ChatMessage] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let role = row["role"] as? String else { return nil }
            let text = messageText(row["text"] ?? row["content"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ChatMessage(role: role == "user" ? .user : .hermes, text: text)
        }
    }

    private static func messageText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }.joined()
        }
        return ""
    }

}
