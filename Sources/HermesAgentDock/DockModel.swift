import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

struct ActiveToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let input: String
    var result: String?
    var isComplete: Bool
}

struct ReasoningState: Equatable {
    var text: String
    var isComplete: Bool
}

struct AgentEvent: Identifiable, Equatable {
    let id: UUID
    let type: String
    let detail: String
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let text: String
    let image: NSImage?
    let timestamp: Date
    let modelName: String?

    init(id: UUID = UUID(), role: Role, text: String, image: NSImage? = nil, timestamp: Date = Date(), modelName: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.image = image
        self.timestamp = timestamp
        self.modelName = modelName
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

struct ImageAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
    let fileURL: URL

    var fileName: String { fileURL.lastPathComponent }
}

@MainActor
final class DockModel: ObservableObject {
    @Published var status: HermesStatus = .idle
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var pendingImage: ImageAttachment?
    @Published var isSending = false
    @Published var approvalText: String?
    @Published var debugLines: [String] = []
    @Published var sessions: [HermesSession] = []
    @Published var isShowingSessions = false
    @Published var isLoadingSessions = false
    @Published var currentSessionTitle: String?
    @Published var reasoningState: ReasoningState?
    @Published var isShowingReasoning = false
    @Published var activeToolCalls: [ActiveToolCall] = []
    @Published var hasUnreadResponse = false
    @Published var recentEvents: [AgentEvent] = []

    private let gateway = HermesGateway()
    private var sessionID: String?
    private var streamingMessageID: UUID?
    private var didRestoreLatestSession = false
    private var currentModelName: String?
    private var isPopoverVisible = false

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
        let attachedImage = pendingImage
        guard (!prompt.isEmpty || attachedImage != nil), !isSending else { return }

        let text = (prompt.isEmpty && attachedImage != nil) ? "What do you see in this image?" : prompt
        draft = ""
        pendingImage = nil
        messages.append(ChatMessage(role: .user, text: text, image: attachedImage?.image))
        status = .working
        isSending = true
        DebugLog.write("model: send started (\(prompt.count) characters, image: \(attachedImage != nil))")

        Task {
            do {
                try await gateway.connect()
                if sessionID == nil {
                    let result = try await gateway.request("session.create", params: ["source": "hermes-agent-dock"])
                    sessionID = result["session_id"] as? String
                    let model = (result["model"] as? String) ?? (result["model_name"] as? String)
                    if let model {
                        currentModelName = model
                    }
                    DebugLog.write("model: session created (id present: \(sessionID != nil))")
                }
                guard let sessionID else { throw HermesGateway.GatewayError.malformedResponse }

                if let attachedImage {
                    let attachResult = try await gateway.request(
                        "image.attach",
                        params: ["session_id": sessionID, "path": attachedImage.fileURL.path]
                    )
                    let attached = (attachResult["attached"] as? Bool) ?? false
                    guard attached else {
                        throw HermesGateway.GatewayError.imageAttachFailed(
                            (attachResult["message"] as? String) ?? "Hermes could not attach the image."
                        )
                    }
                    DebugLog.write("model: image attached to session (\(attachResult))")
                    cleanupImageAttachment(attachedImage)
                }

                _ = try await gateway.request("prompt.submit", params: ["session_id": sessionID, "text": text])
                DebugLog.write("model: prompt submitted")
            } catch {
                DebugLog.write("model: send failed: \(error.localizedDescription)")
                cleanupImageAttachment(attachedImage)
                messages.append(ChatMessage(role: .hermes, text: "I couldn’t connect to Hermes: \(error.localizedDescription)", modelName: currentModelName))
                status = .offline
                isSending = false
            }
        }
    }

    @discardableResult
    func pasteImageFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        let imageType = pasteboard.types?.first { $0 == .png || $0 == .tiff }
        guard let imageType,
              let data = pasteboard.data(forType: imageType),
              let nsImage = NSImage(data: data) else {
            return false
        }
        return stageImage(nsImage)
    }

    func pickImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let nsImage = NSImage(contentsOf: url) else {
            DebugLog.write("model: could not load image at \(url.path)")
            return
        }
        pendingImage = ImageAttachment(image: nsImage, fileURL: url)
        DebugLog.write("model: picked image \(url.lastPathComponent)")
    }

    func clearPendingImage() {
        cleanupImageAttachment(pendingImage)
        pendingImage = nil
    }

    @discardableResult
    private func stageImage(_ nsImage: NSImage) -> Bool {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            DebugLog.write("model: failed to encode pasted image as PNG")
            return false
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-paste-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: tempURL)
        } catch {
            DebugLog.write("model: failed to write image temp file: \(error.localizedDescription)")
            return false
        }
        pendingImage = ImageAttachment(image: nsImage, fileURL: tempURL)
        DebugLog.write("model: staged pasted image at \(tempURL.lastPathComponent)")
        return true
    }

    private func cleanupImageAttachment(_ attachment: ImageAttachment?) {
        guard let attachment else { return }
        if attachment.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: attachment.fileURL)
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
                let model = (result["model"] as? String) ?? (result["model_name"] as? String)
                if let model { currentModelName = model }
                messages = Self.parseMessages(result["messages"])
                currentSessionTitle = session.displayTitle
                status = .idle
                DebugLog.write("model: resumed session \(session.id) (\(messages.count) messages)")
            } catch {
                status = .offline
                messages = [ChatMessage(role: .hermes, text: "I couldn’t load that conversation: \(error.localizedDescription)", modelName: currentModelName)]
                DebugLog.write("model: session resume failed: \(error.localizedDescription)")
            }
        }
    }

    func newChat() {
        sessionID = nil
        currentSessionTitle = nil
        currentModelName = nil
        messages = []
        status = .idle
        isShowingSessions = false
    }

    func markPopoverVisible() {
        isPopoverVisible = true
        hasUnreadResponse = false
    }

    func markPopoverHidden() {
        isPopoverVisible = false
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
        if type == "message.start" {
            recentEvents.removeAll()
        }
        recordEvent(type, params: params)
        switch type {
        case "message.start":
            let model = (payload["model"] as? String) ?? (payload["model_name"] as? String)
            if let model {
                currentModelName = model
            }
            messages.append(ChatMessage(role: .hermes, text: "", modelName: currentModelName))
            streamingMessageID = messages.last?.id
            reasoningState = nil
            isShowingReasoning = false
            activeToolCalls = []
        case "message.delta":
            guard let delta = (payload["delta"] as? String) ?? (payload["text"] as? String),
                  let id = streamingMessageID,
                  let index = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[index] = ChatMessage(id: id, role: .hermes, text: messages[index].text + delta, timestamp: messages[index].timestamp, modelName: messages[index].modelName)
        case "message.complete":
            status = .idle
            isSending = false
            streamingMessageID = nil
            hasUnreadResponse = !isPopoverVisible
        case "approval.request":
            approvalText = (payload["command"] as? String) ?? (payload["description"] as? String) ?? "Hermes wants to perform an action."
            status = .needsApproval
        case "error":
            messages.append(ChatMessage(role: .hermes, text: (payload["message"] as? String) ?? "Hermes reported an error.", modelName: currentModelName))
            status = .idle
            isSending = false
            hasUnreadResponse = !isPopoverVisible

        case "reasoning.start", "thinking":
            reasoningState = ReasoningState(text: "", isComplete: false)
            isShowingReasoning = false
        case "reasoning.delta", "thinking.delta":
            guard var state = reasoningState else { return }
            let delta = (payload["delta"] as? String) ?? (payload["text"] as? String) ?? ""
            state.text += delta
            reasoningState = state
        case "reasoning.complete", "thinking.stop", "thinking.complete":
            guard var state = reasoningState else { return }
            state.isComplete = true
            reasoningState = state

        case "tool.call", "tool.start", "tool.use", "tool_use":
            let name = (payload["name"] as? String) ?? (payload["tool"] as? String) ?? (payload["tool_name"] as? String) ?? "unknown"
            let input: String
            if let args = payload["arguments"] as? [String: Any] {
                input = args.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", ")
            } else if let args = payload["arguments"] as? String {
                input = args
            } else if let inputStr = payload["input"] as? [String: Any] {
                input = inputStr.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", ")
            } else {
                input = ""
            }
            let id = (payload["id"] as? String) ?? UUID().uuidString
            activeToolCalls.append(ActiveToolCall(id: id, name: name, input: input, result: nil, isComplete: false))
        case "tool.result", "tool_result", "tool.complete", "tool_complete":
            let id = (payload["id"] as? String) ?? (payload["tool_id"] as? String) ?? ""
            let result = (payload["result"] as? String) ?? (payload["output"] as? String) ?? ""
            if let index = activeToolCalls.firstIndex(where: { $0.id == id }) {
                activeToolCalls[index].result = result.isEmpty ? nil : result
                activeToolCalls[index].isComplete = true
            } else if !activeToolCalls.isEmpty, let last = activeToolCalls.lastIndex(where: { !$0.isComplete }) {
                activeToolCalls[last].result = result.isEmpty ? nil : result
                activeToolCalls[last].isComplete = true
            }

        default:
            DebugLog.write("model: unknown event type: \(type) params: \(params.keys.sorted().joined(separator: ", "))")
            break
        }
    }

    private func recordEvent(_ type: String, params: [String: Any]) {
        let detail: String
        if let data = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            detail = json
        } else {
            detail = String(describing: params)
        }
        DebugLog.write("event \(type): \(detail)")
        recentEvents.append(AgentEvent(id: UUID(), type: type, detail: detail))
        if recentEvents.count > 40 {
            recentEvents.removeFirst(recentEvents.count - 40)
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
            let timestamp: Date
            if let ts = row["timestamp"] as? Double {
                timestamp = Date(timeIntervalSince1970: ts)
            } else if let ts = row["timestamp"] as? NSNumber {
                timestamp = Date(timeIntervalSince1970: ts.doubleValue)
            } else {
                timestamp = Date()
            }
            return ChatMessage(role: role == "user" ? .user : .hermes, text: text, timestamp: timestamp)
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
