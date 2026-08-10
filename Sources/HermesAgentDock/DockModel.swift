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
    case localFallback(String)

    var isNativeConversationActive: Bool {
        switch self {
        case .preparing, .listening, .interrupted, .thinking: true
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
        case .localFallback: "LOCAL VOICE FALLBACK"
        }
    }

    var fallbackDetail: String? {
        if case .localFallback(let detail) = self { return detail }
        return nil
    }
}

struct ActiveToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let input: String
    let startedAt: Date
    var result: String?
    var isComplete: Bool
    var diffPreview: String? = nil
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

struct HermesSubagent: Identifiable, Equatable {
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

struct AgentActivity: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let agentID: String?
    let kind: String
    let text: String
    let toolName: String?
    let handoffTarget: String?
    let diffPreview: String?

    init(id: UUID, timestamp: Date, agentID: String?, kind: String, text: String,
         toolName: String?, handoffTarget: String?, diffPreview: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.agentID = agentID
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.handoffTarget = handoffTarget
        self.diffPreview = diffPreview
    }
}

struct HermesModelOption: Identifiable, Hashable {
    let provider: String
    let model: String
    var id: String { "\(provider)|\(model)" }
    var displayName: String { "\(provider)  /  \(model)" }
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
    @Published private(set) var isHermesConnected = false
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var pendingImage: ImageAttachment?
    @Published var isSending = false
    @Published var approvalTitle: String?
    @Published var approvalText: String?
    @Published private(set) var isRespondingToApproval = false
    @Published var debugLines: [String] = []
    @Published var sessions: [HermesSession] = []
    @Published var isShowingSessions = false
    @Published var isLoadingSessions = false
    @Published var currentSessionTitle: String?
    @Published var reasoningState: ReasoningState?
    @Published var isShowingReasoning = false
    @Published var activeToolCalls: [ActiveToolCall] = []
    @Published var hasUnreadResponse = false
    @Published private(set) var completionNotificationsEnabled: Bool
    @Published var recentEvents: [AgentEvent] = []
    @Published var activeSubagents: [HermesSubagent] = []
    @Published var sessionAgents: [HermesSubagent] = []
    @Published var agentActivities: [AgentActivity] = []
    @Published var runtimeConfiguration: HermesRuntimeConfiguration?
    @Published var isLoadingRuntimeConfiguration = false
    @Published var runtimeConfigurationError: String?
    @Published var runtimeModelOptions: [HermesModelOption] = []
    @Published private(set) var voiceState: HermesVoiceState = .inactive
    @Published private(set) var voiceTelemetry = VoiceTurnTelemetry()
    @Published private(set) var composerFocusRequest = 0
    @Published private(set) var controlInboxRequest = 0
    @Published private(set) var requestedAttentionID: String?

    private let gateway = HermesGateway()
    let eventRouter = HermesEventRouter()
    @Published private(set) var sessionID: String?
    private var streamingMessageID: UUID?
    private var streamingMessageIsVisionNotice = false
    private var didRestoreLatestSession = false
    private var currentModelName: String?
    private var isPopoverVisible = false
    private var isRefreshingDelegationStatus = false
    private var synthesizedSubagentIDs: Set<String> = []
    private var lastAgentDiscovery = Date.distantPast
    private var nativeVoiceCapture = NativeVoiceCaptureLifecycle()
    private let completionNotificationsKey = "hermes.control.notifications.completion.v1"

    init() {
        completionNotificationsEnabled = UserDefaults.standard.bool(forKey: completionNotificationsKey)
        DebugLog.onLine = { [weak self] line in
            guard let self else { return }
            debugLines = Array((debugLines + [line]).suffix(80))
        }
        DebugLog.write("model: initialized")
        gateway.onEvent = { [weak self] type, params in
            self?.eventRouter.route(type: type, params: params)
            self?.handleEvent(type, params: params)
        }
        gateway.onConnectionChange = { [weak self] connected in
            self?.isHermesConnected = connected
            DebugLog.write("model: Hermes connection \(connected ? "online" : "offline")")
        }
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
                discoverDelegatedAgents()
                refreshDelegationStatus()
                DebugLog.write("model: session created (id present: \(sessionID != nil))")
                }
                guard let sessionID else { throw HermesGateway.GatewayError.malformedResponse }

                if let attachedImage {
                    let imageData = try Data(contentsOf: attachedImage.fileURL)
                    let base64 = imageData.base64EncodedString()
                    let attachResult = try await gateway.request(
                        "image.attach",
                        params: ["session_id": sessionID, "data": base64, "file_name": attachedImage.fileName]
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
        // Text fields should keep their normal paste behavior. Some clipboard
        // managers publish image representations alongside textual content.
        guard pasteboard.string(forType: .string) == nil else {
            return false
        }
        let imageType = pasteboard.types?.first { $0 == .png || $0 == .tiff }
        guard let imageType,
              let data = pasteboard.data(forType: imageType),
              let nsImage = NSImage(data: data) else {
            return false
        }
        return stageImage(nsImage)
    }

    func stageImageFile(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
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
        activeToolCalls = []
        reasoningState = nil
        recentEvents = []
        sessionAgents = []
        activeSubagents = []
        agentActivities = []
        synthesizedSubagentIDs = []
        lastAgentDiscovery = .distantPast
        streamingMessageID = nil
        streamingMessageIsVisionNotice = false
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
                rehydrateSubagents(from: result["messages"])
                discoverDelegatedAgents()
                refreshDelegationStatus()
                currentSessionTitle = session.displayTitle
                status = .idle
                DebugLog.write("model: resumed session \(session.id) (\(messages.count) messages, \(activeSubagents.count) rehydrated agents)")
            } catch {
                status = .offline
                messages = [ChatMessage(role: .hermes, text: "I couldn't load that conversation: \(error.localizedDescription)", modelName: currentModelName)]
                DebugLog.write("model: session resume failed: \(error.localizedDescription)")
            }
        }
    }

    func newChat() {
        sessionID = nil
        currentSessionTitle = nil
        currentModelName = nil
        messages = []
        activeToolCalls = []
        reasoningState = nil
        recentEvents = []
        streamingMessageID = nil
        streamingMessageIsVisionNotice = false
        isSending = false
        status = .idle
        isShowingSessions = false
        activeSubagents = []
        sessionAgents = []
        agentActivities = []
        synthesizedSubagentIDs = []
    }

    func markPopoverVisible() {
        isPopoverVisible = true
        hasUnreadResponse = false
    }

    func requestComposerFocus() {
        composerFocusRequest &+= 1
    }

    func setCompletionNotificationsEnabled(_ enabled: Bool) {
        completionNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: completionNotificationsKey)
    }

    func requestControlInbox() {
        requestedAttentionID = nil
        controlInboxRequest &+= 1
    }

    func requestControlAttention(_ id: String) {
        requestedAttentionID = id
        controlInboxRequest &+= 1
    }

    func markPopoverHidden() {
        isPopoverVisible = false
    }

    func stop() {
        if let sessionID { Task { _ = try? await gateway.request("session.interrupt", params: ["session_id": sessionID]) } }
        status = .idle
        isSending = false
    }

    /// Control-center actions share the user-facing Hermes gateway so they do
    /// not create a second backend or bypass the normal approval/event stream.
    var controlRPCClient: HermesRPCClientProtocol { gateway }

    func requestControl(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        try await gateway.request(method, params: params)
    }

    func submitControlPrompt(_ text: String) async throws {
        try await gateway.connect()
        if sessionID == nil {
            let result = try await gateway.request("session.create", params: ["source": "hermes-agent-dock-control"])
            sessionID = result["session_id"] as? String
        }
        guard let sessionID else { throw HermesGateway.GatewayError.malformedResponse }
        _ = try await gateway.request("prompt.submit", params: ["session_id": sessionID, "text": text])
    }

    /// Starts Hermes' native VAD/TTS voice loop. Hermes owns the microphone,
    /// transcription, streaming speech, and spoken barge-in for this mode.
    /// If the locally installed CLI is missing those optional dependencies, the
    /// Dock keeps its existing Apple speech-recognition flow as a clear fallback.
    func startVoiceConversation() {
        guard voiceState == .inactive || {
            if case .localFallback = voiceState { return true }
            return false
        }() else { return }
        guard !voiceState.isNativeConversationActive else { return }
        nativeVoiceCapture.reset()
        voiceState = .preparing

        Task {
            do {
                try await gateway.connect()
                if sessionID == nil {
                    let result = try await gateway.request("session.create", params: ["source": "hermes-agent-dock"])
                    sessionID = result["session_id"] as? String
                    currentModelName = (result["model"] as? String) ?? (result["model_name"] as? String)
                }
                guard sessionID != nil else { throw HermesGateway.GatewayError.malformedResponse }

                let requirements = try await gateway.request("voice.toggle", params: ["action": "status"])
                guard (requirements["available"] as? Bool) != false,
                      (requirements["stt_available"] as? Bool) != false else {
                    let detail = (requirements["details"] as? String) ?? "Hermes voice dependencies are unavailable."
                    voiceState = .localFallback(detail)
                    return
                }

                let enabled = try await gateway.request("voice.toggle", params: ["action": "on"])
                if (enabled["tts"] as? Bool) != true {
                    _ = try await gateway.request("voice.toggle", params: ["action": "tts"])
                }
                voiceTelemetry.beginListening()
                voiceState = .listening
                armNativeVoiceCapture()
            } catch {
                DebugLog.write("voice: Hermes native voice unavailable: \(error.localizedDescription)")
                voiceState = .localFallback(error.localizedDescription)
            }
        }
    }

    func stopVoiceConversation() {
        let wasNative = voiceState.isNativeConversationActive
        nativeVoiceCapture.reset()
        voiceState = .inactive
        guard wasNative else { return }
        Task {
            if let sessionID {
                _ = try? await gateway.request("voice.record", params: ["action": "stop", "session_id": sessionID])
            }
            _ = try? await gateway.request("voice.toggle", params: ["action": "off"])
        }
    }

    func respondToApproval(_ choice: String) {
        guard let sessionID else { return }
        guard !isRespondingToApproval else { return }
        isRespondingToApproval = true
        Task {
            defer { isRespondingToApproval = false }
            do {
                _ = try await gateway.request("approval.respond", params: ["session_id": sessionID, "choice": choice])
                resolveApproval(for: sessionID)
            } catch {
                DebugLog.write("model: approval response failed: \(error.localizedDescription)")
            }
        }
    }

    /// Reconciles an approval answered through another surface, such as Inbox.
    /// The model only presents the current session, so responses for other
    /// sessions must not alter the visible conversation.
    func resolveApproval(for resolvedSessionID: String) {
        guard sessionID == resolvedSessionID else { return }
        approvalTitle = nil
        approvalText = nil
        if status == .needsApproval {
            status = .working
        }
    }

    private func handleEvent(_ type: String, params: [String: Any]) {
        if let eventSessionID = params["session_id"] as? String,
           !eventSessionID.isEmpty,
           let sessionID, sessionID != eventSessionID {
            DebugLog.write("model: ignoring event \(type) for other session \(eventSessionID)")
            return
        }
        DebugLog.write("model: handling event \(type)")
        let payload = params["payload"] as? [String: Any] ?? [:]
        if type.hasPrefix("subagent.") {
            recordAgentActivity(type, params: params, payload: payload)
            mergeAgentEvent(type, payload: payload)
        }
        if type == "message.start" {
            recentEvents.removeAll()
        }
        recordEvent(type, params: params)
        switch type {
        case "voice.transcript":
            guard voiceState.isNativeConversationActive else { return }
            let transcript = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            nativeVoiceCapture.receivedTranscript(hasText: !transcript.isEmpty)
            if (payload["stop_phrase"] as? Bool) == true {
                stopVoiceConversation()
                return
            }
            guard !transcript.isEmpty else {
                voiceState = .listening
                armNativeVoiceCapture()
                return
            }
            voiceTelemetry.receivedTranscript()
            submitNativeVoiceTranscript(transcript)
        case "voice.status":
            guard voiceState.isNativeConversationActive else { return }
            let state = payload["state"] as? String
            switch state {
            case "recording", "listening":
                voiceState = .listening
            case "idle":
                voiceState = .listening
                if nativeVoiceCapture.receivedIdle() {
                    armNativeVoiceCapture()
                }
            default:
                voiceState = .thinking
            }
        case "voice.interrupted":
            guard voiceState.isNativeConversationActive else { return }
            status = .idle
            isSending = false
            voiceTelemetry.markInterrupted()
            let interruptionGeneration = nativeVoiceCapture.beginInterruption()
            voiceState = .interrupted
            recoverNativeVoiceCaptureIfInterruptedTranscriptIsMissing(generation: interruptionGeneration)
        case "message.start":
            let model = (payload["model"] as? String) ?? (payload["model_name"] as? String)
            if let model {
                currentModelName = model
            }
            messages.append(ChatMessage(role: .hermes, text: "", modelName: currentModelName))
            streamingMessageID = messages.last?.id
            streamingMessageIsVisionNotice = false
            reasoningState = nil
            isShowingReasoning = false
            activeToolCalls = []
        case "message.delta":
            guard let delta = (payload["delta"] as? String) ?? (payload["text"] as? String),
                  let id = streamingMessageID,
                  let index = messages.firstIndex(where: { $0.id == id }) else { return }
            if streamingMessageIsVisionNotice { return }
            if voiceState.isNativeConversationActive {
                voiceTelemetry.receivedResponse()
            }
            var newText = messages[index].text + delta
            if Self.isVisionUnsupportedError(newText) {
                streamingMessageIsVisionNotice = true
                newText = Self.visionUnsupportedNotice
                activeToolCalls.removeAll { $0.name.lowercased().contains("vision") }
            }
            messages[index] = ChatMessage(id: id, role: .hermes, text: newText, image: messages[index].image, timestamp: messages[index].timestamp, modelName: messages[index].modelName)
        case "message.complete":
            if let id = streamingMessageID,
               let index = messages.firstIndex(where: { $0.id == id }),
               Self.isVisionUnsupportedError(messages[index].text) {
                messages[index] = ChatMessage(id: id, role: .hermes, text: Self.visionUnsupportedNotice, timestamp: messages[index].timestamp, modelName: messages[index].modelName)
                activeToolCalls.removeAll { $0.name.lowercased().contains("vision") }
            }
            status = .idle
            isSending = false
            streamingMessageID = nil
            hasUnreadResponse = !isPopoverVisible
            if completionNotificationsEnabled {
                let response = messages.last(where: { $0.role == .hermes })?.text ?? "Hermes completed the active request."
                notify(title: "Hermes completed work", body: response, identifier: "completed:\(sessionID ?? "hermes")")
            }
            if voiceState.isNativeConversationActive {
                voiceTelemetry.completedResponse()
                voiceState = .listening
                if nativeVoiceCapture.completedResponse() {
                    armNativeVoiceCapture()
                }
            }
        case "approval.request":
            let approval = ApprovalPresentation.from(payload: payload)
            approvalTitle = approval.title
            approvalText = approval.detail
            status = .needsApproval
            notify(title: approval.title, body: approval.detail, identifier: "approval:\(sessionID ?? "hermes")")
        case "clarification.request", "clarify.request":
            let question = (payload["question"] as? String)
                ?? (payload["message"] as? String)
                ?? (payload["description"] as? String)
                ?? "Hermes needs more information."
            notify(title: "Hermes needs clarification", body: question, identifier: "clarification:\(sessionID ?? "hermes")")
        case "error":
            let raw = (payload["message"] as? String) ?? "Hermes reported an error."
            let text = Self.isVisionUnsupportedError(raw) ? Self.visionUnsupportedNotice : raw
            messages.append(ChatMessage(role: .hermes, text: text, modelName: currentModelName))
            status = .idle
            isSending = false
            if voiceState.isNativeConversationActive {
                nativeVoiceCapture.reset()
                voiceState = .listening
                armNativeVoiceCapture()
            }
            notify(title: "Hermes encountered an error", body: text, identifier: "failure:\(sessionID ?? "hermes")")
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
            let argsDict = (payload["arguments"] as? [String: Any])
                ?? (payload["input"] as? [String: Any])
                ?? (payload["args"] as? [String: Any])
                ?? Self.parseArgsDict(payload["args_text"])
                ?? [:]
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
            let id = (payload["id"] as? String) ?? (payload["tool_id"] as? String) ?? UUID().uuidString
            activeToolCalls.append(ActiveToolCall(id: id, name: name, input: input, startedAt: dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date(), result: nil, isComplete: false))
            if Self.isDelegationTool(name) {
                synthesizeSubagent(toolCallID: id, args: argsDict)
            }
        case "tool.result", "tool_result", "tool.complete", "tool_complete":
            let id = (payload["id"] as? String) ?? (payload["tool_id"] as? String) ?? ""
            let result = Self.eventText(payload["result"] ?? payload["output"])
            let diffPreview = Self.diffPreview(from: payload)
            if Self.isVisionUnsupportedError(result) {
                activeToolCalls.removeAll { $0.name.lowercased().contains("vision") }
            } else if let index = activeToolCalls.firstIndex(where: { $0.id == id }) {
                let wasDelegation = Self.isDelegationTool(activeToolCalls[index].name)
                if wasDelegation, let args = payload["args"] as? [String: Any] {
                    refreshSynthesizedSubagents(toolCallID: id, args: args)
                }
                activeToolCalls[index].result = result.isEmpty ? nil : result
                activeToolCalls[index].isComplete = true
                activeToolCalls[index].diffPreview = diffPreview
                if wasDelegation { completeSynthesizedSubagent(toolCallID: id, result: result, payload: payload) }
            } else if !activeToolCalls.isEmpty, let last = activeToolCalls.lastIndex(where: { !$0.isComplete }) {
                let wasDelegation = Self.isDelegationTool(activeToolCalls[last].name)
                if wasDelegation, let args = payload["args"] as? [String: Any] {
                    refreshSynthesizedSubagents(toolCallID: activeToolCalls[last].id, args: args)
                }
                activeToolCalls[last].result = result.isEmpty ? nil : result
                activeToolCalls[last].isComplete = true
                activeToolCalls[last].diffPreview = diffPreview
                if wasDelegation { completeSynthesizedSubagent(toolCallID: activeToolCalls[last].id, result: result, payload: payload) }
            }

        case "sessions.changed":
            discoverDelegatedAgents()

        default:
            DebugLog.write("model: unknown event type: \(type) params: \(params.keys.sorted().joined(separator: ", "))")
            break
        }
        if type == "sessions.changed" || type.hasPrefix("tool.") || type.hasPrefix("subagent.") || type == "message.complete" {
            refreshDelegationStatus()
        }
    }

    private func armNativeVoiceCapture(generation expectedGeneration: Int? = nil) {
        if let expectedGeneration, !nativeVoiceCapture.isCurrent(generation: expectedGeneration) {
            return
        }
        guard voiceState.isNativeConversationActive,
              !isSending,
              let sessionID,
              nativeVoiceCapture.beginCapture() else { return }
        let captureGeneration = nativeVoiceCapture.generation

        Task {
            do {
                let recording = try await gateway.request("voice.record", params: ["action": "start", "session_id": sessionID])
                guard nativeVoiceCapture.isCurrent(generation: captureGeneration),
                      voiceState.isNativeConversationActive else { return }
                if (recording["status"] as? String) == "busy" {
                    let shouldRetry = nativeVoiceCapture.captureStartFailed()
                    if shouldRetry {
                        try? await Task.sleep(for: .milliseconds(300))
                        armNativeVoiceCapture(generation: captureGeneration)
                    } else {
                        voiceState = .localFallback("Hermes microphone stayed busy. Tap the orb to retry voice.")
                    }
                    return
                }
                nativeVoiceCapture.captureStarted()
                voiceState = .listening
            } catch {
                guard nativeVoiceCapture.isCurrent(generation: captureGeneration),
                      voiceState.isNativeConversationActive else { return }
                let shouldRetry = nativeVoiceCapture.captureStartFailed()
                if shouldRetry {
                    try? await Task.sleep(for: .milliseconds(300))
                    armNativeVoiceCapture(generation: captureGeneration)
                } else {
                    voiceState = .localFallback("Hermes could not start the next voice capture: \(error.localizedDescription)")
                }
            }
        }
    }

    private func recoverNativeVoiceCaptureIfInterruptedTranscriptIsMissing(generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  self.voiceState.isNativeConversationActive,
                  self.nativeVoiceCapture.interruptionTimedOut(generation: generation) else { return }
            self.voiceState = .listening
            self.armNativeVoiceCapture()
        }
    }

    private func submitNativeVoiceTranscript(_ text: String) {
        guard let sessionID, !isSending else { return }
        messages.append(ChatMessage(role: .user, text: text))
        status = .working
        isSending = true
        voiceState = .thinking
        voiceTelemetry.submittedRequest()
        Task {
            do {
                _ = try await gateway.request(
                    "prompt.submit",
                    params: ["session_id": sessionID, "text": text]
                )
            } catch {
                messages.append(ChatMessage(role: .hermes, text: "I couldn’t submit the voice request: \(error.localizedDescription)", modelName: currentModelName))
                status = .offline
                isSending = false
                nativeVoiceCapture.reset()
                voiceState = .listening
                armNativeVoiceCapture()
            }
        }
    }

    private func notify(title: String, body: String, identifier: String) {
        guard !isPopoverVisible else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.userInfo = ["attention_id": identifier]
        let request = UNNotificationRequest(identifier: "\(identifier)-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func refreshDelegationStatus() {
        guard !isRefreshingDelegationStatus else { return }
        isRefreshingDelegationStatus = true
        Task {
            defer { isRefreshingDelegationStatus = false }
            do {
                let result = try await gateway.request("delegation.status", params: [:])
                let rows = result["active"] as? [[String: Any]] ?? []
                let rpcAgents = rows.compactMap { row -> HermesSubagent? in
                    guard row["subagent_id"] is String else { return nil }
                    return self.telemetry(from: row, fallbackStatus: "running")
                }
                let rpcIDs = Set(rpcAgents.map { $0.id })
                let preserved = activeSubagents.filter {
                    !rpcIDs.contains($0.id)
                        && (synthesizedSubagentIDs.contains($0.id) || Self.isTerminalAgentStatus($0.status))
                }
                activeSubagents = rpcAgents + preserved
                for agent in activeSubagents { upsertSessionAgent(agent) }
            } catch {
                DebugLog.write("workspace: delegation status failed: \(error.localizedDescription)")
            }
        }
    }

    func discoverDelegatedAgents() {
        guard Date().timeIntervalSince(lastAgentDiscovery) > 2.0 else { return }
        lastAgentDiscovery = Date()
        Task {
            do {
                let result = try await gateway.request("session.list", params: ["limit": 50])
                let rows = result["sessions"] as? [[String: Any]] ?? []
                let discovered = rows.compactMap { row -> HermesSubagent? in
                    self.parseAgentSession(row)
                }
                guard !discovered.isEmpty else { return }
                let discoveredIDs = Set(discovered.map { $0.id })
                let preserved = activeSubagents.filter { synthesizedSubagentIDs.contains($0.id) && !discoveredIDs.contains($0.id) }
                let rpcIDs = Set(activeSubagents.filter { !synthesizedSubagentIDs.contains($0.id) }.map { $0.id })
                activeSubagents = discovered + preserved + activeSubagents.filter { rpcIDs.contains($0.id) && !discoveredIDs.contains($0.id) }
                for agent in discovered { upsertSessionAgent(agent) }
                DebugLog.write("model: discovered \(discovered.count) delegated agent session(s)")
            } catch {
                DebugLog.write("model: agent discovery failed: \(error.localizedDescription)")
            }
        }
    }

    private func parseAgentSession(_ row: [String: Any]) -> HermesSubagent? {
        guard let id = row["id"] as? String else { return nil }
        if id == sessionID { return nil }
        let source = (row["source"] as? String ?? "").lowercased()
        let parentID = (row["parent_id"] as? String) ?? (row["parent_session_id"] as? String)
        let isChild = parentID != nil && parentID == sessionID
        let isAgentSource = source.contains("delegate") || source.contains("subagent") || source.contains("agent")
        let isOwnApp = source == "hermes-agent-dock" || source.hasPrefix("hermes-workspace-")
        guard isChild || (isAgentSource && !isOwnApp) else { return nil }
        let title = (row["title"] as? String) ?? (row["preview"] as? String) ?? "Delegated agent"
        let rawStatus = (row["status"] as? String) ?? (row["state"] as? String) ?? ""
        let status = Self.mapSessionStatus(rawStatus, messageCount: (row["message_count"] as? NSNumber)?.intValue ?? 0)
        let rawRole = (row["agent_role"] as? String) ?? (row["role"] as? String)
        let role = rawRole.flatMap { value in
            ["leaf", "orchestrator"].contains(value.lowercased()) ? nil : value
        } ?? Self.inferRole(from: title)
        return HermesSubagent(
            id: id,
            name: (row["name"] as? String) ?? (row["agent_name"] as? String) ?? (row["display_name"] as? String) ?? role,
            parentID: parentID ?? sessionID,
            childSessionID: id,
            depth: 1,
            goal: title,
            role: role,
            sourceSkill: row["source_skill"] as? String ?? row["source"] as? String,
            status: status,
            model: row["model"] as? String,
            startedAt: dateValue(row["started_at"]),
            toolCount: 0,
            latestActivity: (row["preview"] as? String)?.isEmpty == false ? row["preview"] as? String : nil,
            summary: nil
        )
    }

    private static func mapSessionStatus(_ raw: String, messageCount: Int) -> String {
        let lower = raw.lowercased()
        if lower.contains("run") || lower.contains("active") || lower.contains("work") { return "running" }
        if lower.contains("complete") || lower.contains("done") || lower.contains("finish") { return "complete" }
        if lower.contains("block") || lower.contains("error") || lower.contains("fail") { return "blocked" }
        if lower.contains("idle") || lower.contains("wait") { return "queued" }
        return messageCount > 0 ? "running" : "queued"
    }

    private static func isTerminalAgentStatus(_ status: String) -> Bool {
        let lower = status.lowercased()
        return lower.contains("complete") || lower.contains("done") || lower.contains("finish")
            || lower.contains("error") || lower.contains("fail") || lower.contains("interrupt")
    }

    static func agentStatus(current: String, eventType: String) -> String {
        let eventStatus: String? = switch eventType {
        case "subagent.spawn_requested": "queued"
        case "subagent.start", "subagent.tool", "subagent.progress", "subagent.thinking": "running"
        case "subagent.complete": "complete"
        case "subagent.error": "error"
        case "subagent.interrupt", "subagent.interrupted": "interrupted"
        default: nil
        }
        guard let eventStatus else { return current }
        if isTerminalAgentStatus(current), !isTerminalAgentStatus(eventStatus) { return current }
        return eventStatus
    }

    private static func inferRole(from title: String) -> String? {
        let lower = title.lowercased()
        let roles: [(needle: String, label: String)] = [
            ("quality assurance", "QA"), ("security reviewer", "Security Reviewer"),
            ("frontend", "Frontend"), ("front-end", "Frontend"),
            ("backend", "Backend"), ("back-end", "Backend"),
            ("security", "Security"), ("qa", "QA"),
            ("planner", "Planner"), ("implementer", "Implementer"),
            ("reviewer", "Reviewer"), ("verifier", "Verifier"),
            ("investigator", "Investigator"), ("researcher", "Researcher"),
            ("tester", "Tester"), ("testing", "QA"), ("architect", "Architect")
        ]
        for role in roles where lower.contains(role.needle) {
            return role.label
        }
        return nil
    }

    /// Converts one Hermes `delegate_task` call into the semantic workers the
    /// call represents. Batch delegation is one tool call but many agents, so
    /// the tool-call ID alone is not a sufficient row identity.
    static func projectedDelegationAgents(toolCallID: String, args: [String: Any], startedAt: Date) -> [HermesSubagent] {
        let taskRows = args["tasks"] as? [[String: Any]]
        let rows = taskRows?.isEmpty == false ? taskRows! : [args]

        return rows.enumerated().map { index, task in
            func value(_ keys: [String]) -> String? {
                for source in [task, args] {
                    for key in keys {
                        guard let raw = source[key] as? String else { continue }
                        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { return clean }
                    }
                }
                return nil
            }

            let goal = value(["goal", "description", "prompt", "task", "instructions", "title"])
                ?? "Delegated agent"
            let orchestrationRole = value(["role"])
            let humanRole = value(["agent_role", "role_label", "specialty", "agent_type"])
                ?? orchestrationRole.flatMap { role in
                    ["leaf", "orchestrator"].contains(role.lowercased()) ? nil : role
                }
                ?? inferRole(from: goal)
            let name = value(["name", "agent_name", "display_name", "label"]) ?? humanRole
            let id = rows.count == 1 ? toolCallID : "\(toolCallID):\(index)"

            return HermesSubagent(
                id: id,
                name: name,
                childSessionID: value(["session_id", "child_session_id"]),
                goal: goal,
                role: humanRole,
                sourceSkill: value(["source_skill", "skill", "workflow"]),
                status: "running",
                model: value(["model"]),
                startedAt: startedAt,
                latestActivity: goal
            )
        }
    }

    static func isBackgroundDelegationDispatch(_ result: String) -> Bool {
        guard let data = result.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let status = (payload["status"] as? String)?.lowercased()
        let mode = (payload["mode"] as? String)?.lowercased()
        return status == "dispatched" || mode == "background"
    }

    static func eventText(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Hermes emits `inline_diff` for edit tool completions. Some adapters use
    /// `diff`, `patch`, or place the patch in a subagent output tail, so accept
    /// those shapes while refusing ordinary tool output.
    static func diffPreview(from payload: [String: Any]) -> String? {
        for key in ["inline_diff", "diff_preview", "diff", "patch"] {
            if let preview = normalizedDiff(payload[key] as? String, requireMarkers: false) {
                return preview
            }
        }
        if let result = payload["result"] as? [String: Any] {
            for key in ["inline_diff", "diff_preview", "diff", "patch"] {
                if let preview = normalizedDiff(result[key] as? String, requireMarkers: false) {
                    return preview
                }
            }
        }
        if let tail = payload["output_tail"] as? [[String: Any]] {
            for entry in tail.reversed() {
                if let preview = normalizedDiff(entry["preview"] as? String, requireMarkers: true) {
                    return preview
                }
            }
        }
        return nil
    }

    private static func normalizedDiff(_ raw: String?, requireMarkers: Bool) -> String? {
        guard let raw else { return nil }
        let clean = HermesRuntimeInspector.stripANSI(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if requireMarkers {
            let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
            let hasMarkers = lines.contains {
                $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix("@@") || $0.hasPrefix("diff --git")
            }
            guard hasMarkers else { return nil }
        }
        return String(clean.prefix(4_000))
    }

    private func telemetry(from row: [String: Any], fallbackStatus: String? = nil) -> HermesSubagent? {
        guard let id = row["subagent_id"] as? String else { return nil }
        let goal = row["goal"] as? String ?? "Hermes subagent"
        let rawRole = (row["agent_role"] as? String)
            ?? (row["role_label"] as? String)
            ?? (row["role"] as? String)
        let role = rawRole.flatMap { value in
            ["leaf", "orchestrator"].contains(value.lowercased()) ? nil : value
        } ?? Self.inferRole(from: goal)
        return HermesSubagent(
            id: id,
            name: (row["name"] as? String) ?? (row["agent_name"] as? String) ?? (row["display_name"] as? String) ?? role,
            parentID: row["parent_id"] as? String,
            childSessionID: row["child_session_id"] as? String,
            depth: (row["depth"] as? NSNumber)?.intValue ?? 0,
            goal: goal,
            role: role,
            sourceSkill: row["source_skill"] as? String,
            status: row["status"] as? String ?? fallbackStatus ?? "unknown",
            model: row["model"] as? String,
            startedAt: dateValue(row["started_at"]),
            completedAt: dateValue(row["completed_at"]),
            durationSeconds: (row["duration_seconds"] as? NSNumber)?.doubleValue,
            toolCount: (row["tool_count"] as? NSNumber)?.intValue ?? 0,
            latestActivity: row["tool_preview"] as? String ?? row["text"] as? String,
            summary: row["summary"] as? String,
            inputTokens: (row["input_tokens"] as? NSNumber)?.intValue,
            outputTokens: (row["output_tokens"] as? NSNumber)?.intValue,
            reasoningTokens: (row["reasoning_tokens"] as? NSNumber)?.intValue,
            apiCalls: (row["api_calls"] as? NSNumber)?.intValue,
            filesRead: row["files_read"] as? [String] ?? [],
            filesWritten: row["files_written"] as? [String] ?? []
        )
    }

    private func mergeAgentEvent(_ type: String, payload: [String: Any]) {
        guard let id = payload["subagent_id"] as? String else { return }
        var agent = sessionAgents.first(where: { $0.id == id })
            ?? activeSubagents.first(where: { $0.id == id })
            ?? HermesSubagent(id: id, goal: payload["goal"] as? String ?? "Hermes subagent", status: "running")
        if let hydrated = telemetry(from: payload.merging(["subagent_id": id]) { current, _ in current }) {
            agent.name = hydrated.name ?? agent.name
            agent.parentID = hydrated.parentID ?? agent.parentID
            agent.childSessionID = hydrated.childSessionID ?? agent.childSessionID
            agent.depth = hydrated.depth
            if !hydrated.goal.isEmpty && hydrated.goal != "Hermes subagent" { agent.goal = hydrated.goal }
            agent.role = hydrated.role ?? agent.role
            agent.sourceSkill = hydrated.sourceSkill ?? agent.sourceSkill
            agent.model = hydrated.model ?? agent.model
            agent.toolCount = max(agent.toolCount, hydrated.toolCount)
            agent.startedAt = hydrated.startedAt ?? agent.startedAt
            agent.durationSeconds = hydrated.durationSeconds ?? agent.durationSeconds
            agent.summary = hydrated.summary ?? agent.summary
            agent.inputTokens = hydrated.inputTokens ?? agent.inputTokens
            agent.outputTokens = hydrated.outputTokens ?? agent.outputTokens
            agent.reasoningTokens = hydrated.reasoningTokens ?? agent.reasoningTokens
            agent.apiCalls = hydrated.apiCalls ?? agent.apiCalls
            agent.filesRead = hydrated.filesRead.isEmpty ? agent.filesRead : hydrated.filesRead
            agent.filesWritten = hydrated.filesWritten.isEmpty ? agent.filesWritten : hydrated.filesWritten
        }
        agent.status = Self.agentStatus(current: agent.status, eventType: type)
        if type == "subagent.complete" || type == "subagent.error" || type.contains("interrupt") {
            agent.completedAt = dateValue(payload["completed_at"]) ?? Date()
            agent.durationSeconds = (payload["duration_seconds"] as? NSNumber)?.doubleValue ?? agent.durationSeconds
        }
        if let preview = payload["tool_preview"] as? String ?? payload["text"] as? String { agent.latestActivity = preview }
        reconcileSyntheticPlaceholder(for: agent)
        upsertSessionAgent(agent)
        upsertActiveAgent(agent)
    }

    private func upsertSessionAgent(_ agent: HermesSubagent) {
        if let index = sessionAgents.firstIndex(where: { $0.id == agent.id }) {
            sessionAgents[index] = agent
        } else {
            sessionAgents.append(agent)
        }
    }

    private func upsertActiveAgent(_ agent: HermesSubagent) {
        if let index = activeSubagents.firstIndex(where: { $0.id == agent.id }) {
            activeSubagents[index] = agent
        } else {
            activeSubagents.append(agent)
        }
    }

    /// Native subagent events have a stable Hermes ID; synthesized rows only
    /// bridge the short gap before that first event. Remove the matching
    /// placeholder so a batch never renders both identities for one worker.
    private func reconcileSyntheticPlaceholder(for nativeAgent: HermesSubagent) {
        guard !synthesizedSubagentIDs.contains(nativeAgent.id) else { return }
        let normalizedGoal = nativeAgent.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedGoal.isEmpty, normalizedGoal != "hermes subagent" else { return }
        guard let placeholder = activeSubagents.first(where: {
            synthesizedSubagentIDs.contains($0.id)
                && $0.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedGoal
        }) else { return }

        synthesizedSubagentIDs.remove(placeholder.id)
        activeSubagents.removeAll { $0.id == placeholder.id }
        sessionAgents.removeAll { $0.id == placeholder.id }
        agentActivities.removeAll { $0.agentID == placeholder.id }
    }

    private static func isDelegationTool(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("delegate") || lower == "spawn" || lower == "spawn_agent"
            || lower == "launch_agent" || lower == "create_subagent" || lower == "dispatch_agent"
    }

    private func synthesizeSubagent(toolCallID: String, args: [String: Any]) {
        let startedAt = Date()
        let agents = Self.projectedDelegationAgents(toolCallID: toolCallID, args: args, startedAt: startedAt)
        guard !agents.isEmpty, agents.contains(where: { !synthesizedSubagentIDs.contains($0.id) }) else { return }

        for agent in agents where !synthesizedSubagentIDs.contains(agent.id) {
            synthesizedSubagentIDs.insert(agent.id)
            upsertSessionAgent(agent)
            upsertActiveAgent(agent)
            agentActivities.append(AgentActivity(
                id: UUID(),
                timestamp: startedAt,
                agentID: agent.id,
                kind: "subagent.start",
                text: agent.goal,
                toolName: nil,
                handoffTarget: nil
            ))
        }
        if agentActivities.count > 250 {
            agentActivities.removeFirst(agentActivities.count - 250)
        }
        DebugLog.write("model: synthesized \(agents.count) subagent row(s) for \(toolCallID)")
    }

    private func refreshSynthesizedSubagents(toolCallID: String, args: [String: Any]) {
        let matchingIDs = synthesizedSubagentIDs.filter { $0 == toolCallID || $0.hasPrefix("\(toolCallID):") }
        guard !matchingIDs.isEmpty else { return }
        synthesizedSubagentIDs.subtract(matchingIDs)
        activeSubagents.removeAll { matchingIDs.contains($0.id) }
        sessionAgents.removeAll { matchingIDs.contains($0.id) }
        agentActivities.removeAll { activity in
            activity.agentID.map(matchingIDs.contains) == true
        }
        synthesizeSubagent(toolCallID: toolCallID, args: args)
    }

    private func completeSynthesizedSubagent(toolCallID: String, result: String, payload: [String: Any]) {
        // Modern Hermes returns immediately after background dispatch. Native
        // subagent.complete events, not this acknowledgement, own completion.
        guard !Self.isBackgroundDelegationDispatch(result) else { return }
        let sessionID = (payload["session_id"] as? String) ?? (payload["child_session_id"] as? String)
        let summary = result.isEmpty ? nil : String(result.prefix(400))
        let matchingIDs = synthesizedSubagentIDs.filter { $0 == toolCallID || $0.hasPrefix("\(toolCallID):") }
        for id in matchingIDs {
            guard let index = activeSubagents.firstIndex(where: { $0.id == id }) else { continue }
            activeSubagents[index].status = "complete"
            activeSubagents[index].completedAt = Date()
            if let sessionID { activeSubagents[index].childSessionID = sessionID }
            if let summary { activeSubagents[index].summary = summary }
            if let sessionIndex = sessionAgents.firstIndex(where: { $0.id == id }) {
                sessionAgents[sessionIndex] = activeSubagents[index]
            }
            agentActivities.append(AgentActivity(
                id: UUID(),
                timestamp: Date(),
                agentID: id,
                kind: "subagent.complete",
                text: summary ?? "Delegated agent finished",
                toolName: nil,
                handoffTarget: nil
            ))
        }
        if agentActivities.count > 250 {
            agentActivities.removeFirst(agentActivities.count - 250)
        }
        DebugLog.write("model: completed synthesized subagent \(toolCallID)")
    }

    private func recordAgentActivity(_ type: String, params: [String: Any], payload: [String: Any]) {
        let agentID = payload["subagent_id"] as? String
        let toolName = payload["tool_name"] as? String
        let text = (payload["tool_preview"] as? String) ?? (payload["text"] as? String) ?? (payload["summary"] as? String) ?? type.replacingOccurrences(of: "subagent.", with: "").uppercased()
        agentActivities.append(AgentActivity(
            id: UUID(),
            timestamp: dateValue(params["timestamp"]) ?? dateValue(payload["timestamp"]) ?? Date(),
            agentID: agentID,
            kind: type,
            text: text,
            toolName: toolName,
            handoffTarget: payload["handoff_target"] as? String,
            diffPreview: Self.diffPreview(from: payload)
        ))
        if agentActivities.count > 250 { agentActivities.removeFirst(agentActivities.count - 250) }
    }

    private func dateValue(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    func refreshRuntimeConfiguration() {
        guard !isLoadingRuntimeConfiguration else { return }
        isLoadingRuntimeConfiguration = true
        runtimeConfigurationError = nil
        Task.detached { [weak self] in
            let configuration = HermesRuntimeInspector.read()
            await MainActor.run {
                guard let self else { return }
                self.runtimeConfiguration = configuration
                self.isLoadingRuntimeConfiguration = false
            }
        }
    }

    func refreshRuntimeModelOptions() {
        Task {
            do {
                let result = try await gateway.request("model.options", params: ["explicit_only": true])
                let providers = result["providers"] as? [[String: Any]] ?? []
                runtimeModelOptions = providers.flatMap { provider -> [HermesModelOption] in
                    guard let name = (provider["slug"] as? String) ?? (provider["name"] as? String) else { return [] }
                    let models = provider["models"] as? [String] ?? []
                    return models.map { HermesModelOption(provider: name, model: $0) }
                }
            } catch {
                runtimeConfigurationError = "Hermes could not load its model catalog."
            }
        }
    }

    func updateRuntimeModel(_ option: HermesModelOption) {
        guard !isLoadingRuntimeConfiguration else { return }
        isLoadingRuntimeConfiguration = true
        runtimeConfigurationError = nil
        Task.detached { [weak self] in
            let updated = HermesRuntimeInspector.setModel(option.model, provider: option.provider)
            let configuration = updated ? HermesRuntimeInspector.read() : nil
            await MainActor.run {
                guard let self else { return }
                self.runtimeConfiguration = configuration ?? self.runtimeConfiguration
                self.runtimeConfigurationError = updated ? nil : "Hermes could not update model.default."
                self.isLoadingRuntimeConfiguration = false
            }
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

    private static let visionUnsupportedNotice = "This model can't read images. Use a vision-capable model in Hermes to analyze images."
    private static func isVisionUnsupportedError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("does not support image")
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

    private func rehydrateSubagents(from value: Any?) {
        guard let rows = value as? [[String: Any]] else { return }
        var delegationCalls: [(id: String, args: [String: Any])] = []
        var resultsByID: [String: String] = [:]
        for row in rows {
            scanForDelegation(in: row["content"], calls: &delegationCalls, results: &resultsByID)
            scanForDelegation(in: row["tool_calls"], calls: &delegationCalls, results: &resultsByID)
            scanForDelegation(in: row["parts"], calls: &delegationCalls, results: &resultsByID)
            if (row["role"] as? String) == "tool",
               let id = (row["tool_call_id"] as? String) ?? (row["tool_use_id"] as? String) {
                resultsByID[id] = (row["content"] as? String) ?? Self.messageText(row["content"])
            }
        }
        for (id, args) in delegationCalls where !synthesizedSubagentIDs.contains(id) {
            synthesizeSubagent(toolCallID: id, args: args)
            if let result = resultsByID[id] {
                completeSynthesizedSubagent(toolCallID: id, result: result, payload: [:])
            }
        }
    }

    private func scanForDelegation(in value: Any?, calls: inout [(id: String, args: [String: Any])], results: inout [String: String]) {
        guard let parts = value as? [[String: Any]] else { return }
        for part in parts {
            let partType = (part["type"] as? String)?.lowercased() ?? ""
            if partType.contains("tool_use") || partType == "function_call" || partType == "tool_call" {
                let name = (part["name"] as? String)
                    ?? ((part["function"] as? [String: Any])?["name"] as? String)
                    ?? ""
                if Self.isDelegationTool(name) {
                    let id = (part["id"] as? String) ?? (part["tool_use_id"] as? String) ?? UUID().uuidString
                    let input = (part["input"] as? [String: Any])
                        ?? Self.parseArgsDict((part["function"] as? [String: Any])?["arguments"])
                        ?? Self.parseArgsDict(part["arguments"])
                        ?? [:]
                    calls.append((id, input))
                }
            }
            if partType.contains("tool_result") {
                if let id = (part["tool_use_id"] as? String) ?? (part["id"] as? String) {
                    let content = (part["content"] as? String) ?? Self.messageText(part["content"])
                    results[id] = content
                }
            }
        }
    }

    private static func parseArgsDict(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        if let str = value as? String,
           let data = str.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
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
