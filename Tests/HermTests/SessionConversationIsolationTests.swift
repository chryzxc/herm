import AppKit
import Foundation
import Testing
@testable import Herm

/// Records every RPC request and returns scripted responses. `onEvent` fires
/// while `request` is still in flight so tests can interleave gateway events
/// with an open session switch, exactly like a second session streaming while
/// the user opens another conversation.
@MainActor
private final class SessionIsolationRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    private(set) var requests: [(method: String, params: [String: Any])] = []
    var resumeResponses: [[String: Any]] = []
    /// Closure invoked during the `session.resume` await, before its response resolves.
    var duringResume: (() -> Void)?

    func connect() async throws {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append((method, params))
        switch method {
        case "session.resume":
            duringResume?()
            let index = requests.filter { $0.method == "session.resume" }.count - 1
            return index < resumeResponses.count ? resumeResponses[index] : ["session_id": params["session_id"] as? String ?? "", "messages": []]
        default:
            return [:]
        }
    }

    func close() {}
}

@MainActor
private struct Fixtures {
    static let sessionA = "session-a"
    static let sessionB = "session-b"

    static var sessionAResponse: [String: Any] {
        [
            "session_id": sessionA,
            "messages": [
                ["role": "user", "content": "question in session A"],
                ["role": "assistant", "content": "answer in session A"]
            ]
        ]
    }

    static func messageEvent(_ type: String, sessionID: String?, delta: String? = nil, text: String? = nil) -> (String, [String: Any]) {
        var params: [String: Any] = [:]
        if let sessionID { params["session_id"] = sessionID }
        var payload: [String: Any] = [:]
        if let delta { payload["delta"] = delta }
        if let text { payload["text"] = text }
        params["payload"] = payload
        return (type, params)
    }
}

@MainActor
struct SessionConversationIsolationTests {
    @Test func queuedMessagesSurviveSessionSwitchAndNewRuntimeHandle() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            ["session_id": "runtime-a-1", "session_key": Fixtures.sessionA, "messages": []],
            ["session_id": "runtime-b", "session_key": Fixtures.sessionB, "messages": []],
            ["session_id": "runtime-a-2", "session_key": Fixtures.sessionA, "messages": [], "running": true]
        ]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let sessionB = HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test")
        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == "runtime-a-1" && model.status == .idle }
        model.draft = "Follow up in A"
        model.queueDraft()
        let queuedID = try #require(model.queuedPrompts.first?.id)
        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Follow up in A"])

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == "runtime-b" && model.status == .idle }
        #expect(model.currentSessionQueuedPrompts.isEmpty)
        model.draft = "Follow up in B"
        model.queueDraft()
        #expect(model.currentSessionQueuedPrompts.map(\.text) == ["Follow up in B"])
        #expect(model.queuedPrompts.count == 2)

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == "runtime-a-2" && model.isSending }
        #expect(model.currentSessionQueuedPrompts.map(\.id) == [queuedID])
        model.receiveGatewayEvent("message.complete", params: [
            "session_id": "runtime-a-2", "payload": ["text": "Done"]
        ])
        try await waitUntil { rpc.requests.contains { $0.method == "prompt.submit" } }
        let submission = try #require(rpc.requests.first { $0.method == "prompt.submit" })
        #expect(submission.params["session_id"] as? String == "runtime-a-2")
        #expect(submission.params["text"] as? String == "Follow up in A")
        #expect(model.queuedPrompts.map(\.text) == ["Follow up in B"])
    }

    @Test func queuedAttachmentsAndEditsSurviveNewChatAndReopening() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            ["session_id": "runtime-a-1", "session_key": Fixtures.sessionA, "messages": []],
            ["session_id": "runtime-a-2", "session_key": Fixtures.sessionA, "messages": []]
        ]
        let model = DockModel(rpcClient: rpc)
        let session = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        model.resumeSession(session)
        try await waitUntil { model.sessionID == "runtime-a-1" && model.status == .idle }
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("queued-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        model.pendingImages = [ImageAttachment(image: NSImage(size: NSSize(width: 2, height: 2)), fileURL: imageURL)]
        model.draft = "Use the image"
        model.queueDraft()
        let id = try #require(model.currentSessionQueuedPrompts.first?.id)
        model.editingQueuedPromptID = id
        model.updateQueuedPrompt(id, text: "Use the edited image")
        model.newChat()
        #expect(model.currentSessionQueuedPrompts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        model.resumeSession(session)
        try await waitUntil { model.sessionID == "runtime-a-2" && model.status == .idle }
        #expect(model.currentSessionQueuedPrompts.first?.id == id)
        #expect(model.currentSessionQueuedPrompts.first?.text == "Use the edited image")
        #expect(model.currentSessionQueuedPrompts.first?.images.first?.fileURL == imageURL)
        #expect(model.editingQueuedPromptID == id)
        model.removeQueuedPrompt(id)
        #expect(model.currentSessionQueuedPrompts.isEmpty)
    }

    @Test func clearingSelectedProfileDisablesUnscopedSessionLoading() async throws {
        let defaults = UserDefaults(suiteName: "profile-scope-(UUID().uuidString)")!
        let rpc = SessionIsolationRPCClient()
        let model = DockModel(defaults: defaults, rpcClient: rpc)

        model.setProfileScope("bot-a")
        model.setProfileScope(nil)

        #expect(model.profileScopeID == nil)
        #expect(model.profileScopeUnavailable)
        #expect(model.sessions.isEmpty)
        #expect(model.loadSessions() == nil)
        #expect(!rpc.requests.contains(where: { $0.method == "session.list" }))
    }

    @Test func pendingApprovalReturnsWhenItsSessionIsReopened() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            Fixtures.sessionAResponse,
            ["session_id": Fixtures.sessionB, "messages": []],
            Fixtures.sessionAResponse
        ]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let sessionB = HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test")

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.receiveGatewayEvent("approval.request", params: [
            "session_id": Fixtures.sessionA,
            "payload": ["title": "Approve push", "command": "git push"]
        ])

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == Fixtures.sessionB && model.status == .idle }
        #expect(model.approvalText == nil)

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .needsApproval }
        #expect(model.approvalTitle == "Approve push")
        #expect(model.approvalText == "git push")
    }

    @Test func approvalArrivingForAnotherSessionAppearsWhenThatSessionOpens() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            Fixtures.sessionAResponse,
            ["session_id": Fixtures.sessionB, "messages": []]
        ]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let sessionB = HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test")

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.receiveGatewayEvent("approval.request", params: [
            "session_id": Fixtures.sessionB,
            "payload": ["title": "Approve install", "command": "npm install"]
        ])
        #expect(model.approvalText == nil)

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == Fixtures.sessionB && model.status == .needsApproval }
        #expect(model.approvalTitle == "Approve install")
        #expect(model.approvalText == "npm install")
    }

    @Test func resolvingHiddenApprovalClearsItsRuntimeAndDurableSessionAliases() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            ["session_id": "runtime-b", "session_key": Fixtures.sessionB, "messages": []],
            Fixtures.sessionAResponse,
            ["session_id": "runtime-b", "session_key": Fixtures.sessionB, "messages": []]
        ]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let sessionB = HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test")

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == "runtime-b" && model.status == .idle }
        model.receiveGatewayEvent("approval.request", params: [
            "session_id": "runtime-b",
            "payload": ["command": "git push"]
        ])

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.resolveApproval(for: "runtime-b")

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == "runtime-b" && model.status == .idle }
        #expect(model.approvalText == nil)
    }

    @Test func pendingClarificationReturnsWhenItsSessionIsReopened() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            Fixtures.sessionAResponse,
            ["session_id": Fixtures.sessionB, "messages": []],
            Fixtures.sessionAResponse
        ]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let sessionB = HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test")

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.receiveGatewayEvent("clarification.request", params: [
            "session_id": Fixtures.sessionA,
            "payload": [
                "request_id": "clarify-a",
                "question": "Which environment?",
                "choices": ["Staging", "Production"]
            ]
        ])

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == Fixtures.sessionB && model.status == .idle }
        #expect(model.clarificationQuestion == nil)

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .needsClarification }
        #expect(model.clarificationQuestion == "Which environment?")
        #expect(model.clarificationChoices == ["Staging", "Production"])
        #expect(model.clarificationRequestID == "clarify-a")
        #expect(model.messages.last?.text.contains("Which environment?") == true)
    }

    @Test func clarificationArrivingForAnotherSessionAppearsWhenThatSessionOpens() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            Fixtures.sessionAResponse,
            ["session_id": Fixtures.sessionB, "messages": []]
        ]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let sessionB = HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test")

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.receiveGatewayEvent("clarification.request", params: [
            "session_id": Fixtures.sessionB,
            "payload": ["request_id": "clarify-b", "question": "Continue deployment?"]
        ])
        #expect(model.clarificationQuestion == nil)

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == Fixtures.sessionB && model.status == .needsClarification }
        #expect(model.clarificationQuestion == "Continue deployment?")
        #expect(model.clarificationRequestID == "clarify-b")
    }

    @Test func hiddenClarificationExpiryPreventsItFromReturning() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            Fixtures.sessionAResponse,
            ["session_id": Fixtures.sessionB, "messages": []]
        ]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let sessionB = HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test")

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.receiveGatewayEvent("clarification.request", params: [
            "session_id": Fixtures.sessionB,
            "payload": ["request_id": "expired-b", "question": "Choose a target"]
        ])
        model.receiveGatewayEvent("clarification.expire", params: [
            "session_id": Fixtures.sessionB,
            "payload": ["request_id": "expired-b"]
        ])

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == Fixtures.sessionB && model.status == .idle }
        #expect(model.clarificationQuestion == nil)
        #expect(model.clarificationRequestID == nil)
    }

    @Test func answeredClarificationReplayDoesNotReturnAfterSessionSwitch() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            Fixtures.sessionAResponse,
            ["session_id": Fixtures.sessionB, "messages": []],
            Fixtures.sessionAResponse
        ]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let sessionB = HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test")
        let request: [String: Any] = [
            "session_id": Fixtures.sessionA,
            "payload": ["request_id": "answered-a", "question": "Which environment?"]
        ]

        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.receiveGatewayEvent("clarification.request", params: request)
        model.respondToClarification("Staging")
        try await waitUntil { model.clarificationQuestion == nil }

        model.resumeSession(sessionB)
        try await waitUntil { model.sessionID == Fixtures.sessionB && model.status == .idle }
        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.receiveGatewayEvent("clarification.request", params: request)

        #expect(model.clarificationQuestion == nil)
        #expect(model.clarificationRequestID == nil)
        #expect(model.status == .idle)
    }

    @Test func reopeningTheActiveSessionRetainsItsUnsentDraft() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse, Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        let session = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")

        model.resumeSession(session)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        model.draft = "Keep this unsent message"

        model.resumeSession(session)
        try await waitUntil { rpc.requests.filter { $0.method == "session.resume" }.count == 2 && model.status == .idle }

        #expect(model.draft == "Keep this unsent message")
    }

    @Test func reopeningAnAliasedActiveSessionRetainsItsUnsentDraft() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            ["session_id": "runtime-a", "session_key": Fixtures.sessionA, "messages": []],
            ["session_id": "runtime-a", "session_key": Fixtures.sessionA, "messages": []]
        ]
        let model = DockModel(rpcClient: rpc)
        let session = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")

        model.resumeSession(session)
        try await waitUntil { model.sessionID == "runtime-a" && model.status == .idle }
        model.draft = "Keep this aliased session draft"

        model.resumeSession(session)
        try await waitUntil { rpc.requests.filter { $0.method == "session.resume" }.count == 2 && model.status == .idle }

        #expect(model.draft == "Keep this aliased session draft")
    }

    @Test func runtimeAliasEventsDoNotAddADuplicateRailRow() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [["session_id": "runtime-a", "session_key": Fixtures.sessionA, "messages": []]]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { model.sessionID == "runtime-a" && model.status == .idle }

        model.receiveGatewayEvent("message.start", params: ["session_id": "runtime-a", "payload": [:]])

        #expect(model.navigationSessionID == Fixtures.sessionA)
        #expect(!model.sessions.contains { $0.id == "runtime-a" })
    }

    @Test func taggedStreamFromRespondingSessionDoesNotEnterOpenSession() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.sessionID == Fixtures.sessionA }

        model.receiveGatewayEvent("message.start", params: ["session_id": Fixtures.sessionB, "payload": [:]])
        model.receiveGatewayEvent("message.delta", params: ["session_id": Fixtures.sessionB, "payload": ["delta": "secret from session B"]])
        model.receiveGatewayEvent("message.complete", params: ["session_id": Fixtures.sessionB, "payload": [:]])

        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
        #expect(model.streamingText.text.isEmpty)
    }

    @Test func untaggedStreamFromRespondingSessionDoesNotEnterOpenSession() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.sessionID == Fixtures.sessionA }

        model.receiveGatewayEvent("message.start", params: ["payload": [:]])
        model.receiveGatewayEvent("message.delta", params: ["payload": ["delta": "secret from session B"]])
        model.receiveGatewayEvent("message.complete", params: ["payload": [:]])

        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
        #expect(model.streamingText.text.isEmpty)
    }

    @Test func respondingSessionEventsDuringResumeWindowDoNotEnterOpeningSession() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        rpc.duringResume = {
            model.receiveGatewayEvent("message.start", params: ["session_id": Fixtures.sessionB, "payload": [:]])
            model.receiveGatewayEvent("message.delta", params: ["session_id": Fixtures.sessionB, "payload": ["delta": "secret from session B"]])
        }
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(model.sessionID == Fixtures.sessionA)
        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
        #expect(model.streamingText.text.isEmpty)
    }

    @Test func resumeResponseForAnotherSessionDoesNotAdoptThatConversation() async throws {
        let rpc = SessionIsolationRPCClient()
        // Hermes returns the currently active (responding) session's identity
        // and messages instead of the requested session's.
        rpc.resumeResponses = [
            [
                "session_id": Fixtures.sessionB,
                "messages": [
                    ["role": "user", "content": "question in session B"],
                    ["role": "assistant", "content": "answer in session B"]
                ]
            ]
        ]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(model.sessionID == Fixtures.sessionA)
        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
    }

    @Test func resumeResponseForkingTheRequestedSessionIsAdopted() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            [
                "session_id": "runtime-fork",
                "session_key": Fixtures.sessionA,
                "messages": [
                    ["role": "user", "content": "question in session A"],
                    ["role": "assistant", "content": "answer in session A"]
                ]
            ]
        ]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(model.sessionID == "runtime-fork")
        #expect(model.messages.contains { $0.text == "question in session A" })
    }

    @Test func resumeOfCanonicalBotChatMayResolveToAFreshSessionID() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            [
                "session_id": "sentry-session",
                "session_key": BotService.canonicalBotChatTitle,
                "messages": []
            ]
        ]
        let model = DockModel(rpcClient: rpc)
        let sentry = BotSummary(
            id: "sentry",
            name: "Sentry",
            title: nil,
            description: nil,
            model: nil,
            isActive: false,
            chat: nil,
            avatarURL: nil,
            preview: nil,
            lastActive: nil,
            isHidden: false,
            hasAvatar: false,
            isDefault: false
        )
        model.resumeBotChat(sentry)
        try await waitUntil { model.sessionID == "sentry-session" }

        #expect(model.messages.isEmpty)
    }

    @Test func duplicateTerminalErrorEventsProduceOneAssistantMessage() {
        let model = DockModel(initialSessionID: Fixtures.sessionA)
        let errorText = "The runtime approval prompt timed out."

        model.receiveGatewayEvent("message.start", params: [
            "session_id": Fixtures.sessionA,
            "payload": [:]
        ])
        model.receiveGatewayEvent("error", params: [
            "session_id": Fixtures.sessionA,
            "payload": ["message": errorText]
        ])
        model.receiveGatewayEvent("message.complete", params: [
            "session_id": Fixtures.sessionA,
            "payload": ["error": errorText]
        ])

        let errors = model.messages.filter { $0.role == .hermes && $0.isError }
        #expect(errors.count == 1)
        #expect(errors.first?.text == errorText)
    }

    @Test func identicalErrorsOnSeparateTurnsRemainVisible() {
        let model = DockModel(initialSessionID: Fixtures.sessionA)
        let errorText = "The runtime approval prompt timed out."

        for _ in 0..<2 {
            model.receiveGatewayEvent("message.start", params: [
                "session_id": Fixtures.sessionA,
                "payload": [:]
            ])
            model.receiveGatewayEvent("error", params: [
                "session_id": Fixtures.sessionA,
                "payload": ["message": errorText]
            ])
        }

        let errors = model.messages.filter { $0.role == .hermes && $0.isError }
        #expect(errors.count == 2)
    }

    @Test func persistedImageDirectiveRehydratesImageAndCleansTranscriptText() throws {
        let sourceImage = NSImage(size: NSSize(width: 2, height: 2))
        sourceImage.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        sourceImage.unlockFocus()
        let imageData = sourceImage.tiffRepresentation!
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("persisted-image-\(UUID().uuidString).tiff")
        try imageData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let raw = "@image:`\(imageURL.path)`\nwhat is in this photo?\n[screenshot]"
        let parsed = DockModel.parseMessages([
            ["role": "user", "content": raw, "timestamp": 1.0]
        ])

        #expect(parsed.messages.count == 1)
        #expect(parsed.messages[0].text == "what is in this photo?")
        #expect(parsed.messages[0].images.isEmpty)
        #expect(parsed.pendingImages.count == 1)
        #expect(parsed.pendingImages[0].messageID == parsed.messages[0].id)
        #expect(parsed.pendingImages[0].fileURLs == [imageURL])

        let loaded = parsed.pendingImages[0].fileURLs.compactMap { NSImage(contentsOf: $0) }
        #expect(loaded.count == 1)
        let attached = parsed.messages[0].attachingImages(loaded)
        #expect(attached.id == parsed.messages[0].id)
        #expect(attached.images.count == 1)
        #expect(attached.images[0].size.width > 0)
        #expect(attached.images[0].size.height > 0)
    }

    @Test func hermesNativeImageHandlesBecomeAttachmentsNotText() {
        let raw = "compare these\n\n[Image attached at: /tmp/a.png]\n[Image attached at: /tmp/b.png]"
        let parsed = DockModel.persistedImageContent(from: raw)
        #expect(parsed.text == "compare these")
        #expect(parsed.imageFileURLs == [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
    }

    @Test func pendingImageRehydrationDropsPayloadForSessionMismatch() async {
        let model = DockModel(rpcClient: SessionIsolationRPCClient())
        let pending = [RestoredTranscript.PendingImages(
            messageID: UUID(),
            fileURLs: [FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).png")]
        )]

        await model.rehydratePendingTranscriptImages(
            pending,
            requestedSessionID: "session-that-was-never-opened",
            loadData: { _ in Data(count: 16) }
        ).value

        #expect(model.messages.isEmpty)
    }

    @Test func restoredAssistantMarkdownPreservesLineBreaksForTheTranscriptRenderer() {
        let markdown = """
        ## Completed

        - First verified item
        - Second verified item
        """

        let parsed = DockModel.parseMessages([
            ["role": "assistant", "content": markdown, "timestamp": 1.0]
        ])

        #expect(parsed.messages.count == 1)
        #expect(parsed.messages[0].text == markdown)
        #expect(parsed.messages[0].text.contains("\\n") == false)
    }

    @Test func restoredTurnAttachesItsThinkingAndToolCallsToTheReply() {
        let parsed = DockModel.parseMessages([
            ["role": "user", "content": "fix it", "timestamp": 100.0],
            ["role": "assistant", "content": "", "reasoning": "look first", "timestamp": 101.0,
             "tool_calls": [["id": "t1", "function": ["name": "read_file", "arguments": "{\"path\": \"a.swift\"}"]]]],
            ["role": "tool", "tool_call_id": "t1", "content": "ok", "timestamp": 102.0],
            ["role": "assistant", "content": "Done.", "timestamp": 160.0]
        ])

        #expect(parsed.messages.count == 2)
        #expect(parsed.messages[0].activity.isEmpty)
        let activity = parsed.messages[1].activity
        #expect(activity.map(\.name) == [ActiveToolCall.thinkingName, "read_file"])
        #expect(activity[0].result == "look first")
        #expect(activity[1].context == "a.swift")
        #expect(activity[1].result == "ok")
        #expect(parsed.messages[1].responseDuration == 60)
    }

    @Test func compactionShowsAsTurnStepAndStaysAfterItFinishes() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.sessionID == Fixtures.sessionA }
        func send(_ type: String, _ payload: [String: Any] = [:]) {
            model.receiveGatewayEvent(type, params: ["session_id": Fixtures.sessionA, "payload": payload])
        }

        send("message.start")
        send("status.update", ["kind": "compacting"])
        send("status.update", ["kind": "compressing"])
        #expect(model.streamingTurnActivity.map(\.name) == [ActiveToolCall.compactionName])
        #expect(model.streamingTurnActivity[0].isComplete == false)

        send("status.update", ["kind": "compacted"])
        #expect(model.streamingTurnActivity[0].isComplete)
        #expect(model.streamingTurnActivity[0].completedAt != nil)
        #expect(model.compactingSessionID == nil)

        send("message.complete", ["text": "Done."])
        #expect(model.messages.last?.activity.map(\.name) == [ActiveToolCall.compactionName])
    }

    @Test func liveTurnGrowsActivityAndCommitsItOntoTheReply() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.sessionID == Fixtures.sessionA }
        func send(_ type: String, _ payload: [String: Any] = [:]) {
            model.receiveGatewayEvent(type, params: ["session_id": Fixtures.sessionA, "payload": payload])
        }

        send("message.start")
        send("reasoning.start")
        send("reasoning.delta", ["delta": "plan"])
        send("reasoning.complete")
        send("tool.start", ["id": "t1", "name": "terminal", "context": "swift test"])
        #expect(model.streamingTurnActivity.map(\.name) == [ActiveToolCall.thinkingName, "terminal"])
        #expect(model.streamingTurnActivity[1].isComplete == false)

        // A second model call in the same turn resets activeToolCalls but
        // must not drop what already happened.
        send("message.start")
        send("tool.start", ["id": "t2", "name": "read_file", "context": "a.swift"])
        #expect(Array(model.streamingTurnActivity.map { $0.id }.suffix(2)) == ["t1", "t2"])

        send("message.delta", ["delta": "Done."])
        send("message.complete", ["text": "Done."])

        let reply = try #require(model.messages.last)
        #expect(reply.text == "Done.")
        #expect(reply.activity.map(\.name) == [ActiveToolCall.thinkingName, "terminal", "read_file"])
        #expect(reply.activity[0].result == "plan")
        #expect(reply.activity.allSatisfy { $0.isComplete })
        #expect(model.streamingTurnActivity.isEmpty)
    }

    @Test func midTurnKanbanNoticeSplitsLiveTurnInTimeOrder() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [Fixtures.sessionAResponse]
        let model = DockModel(rpcClient: rpc)
        model.resumeSession(HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { !model.isRestoringSession && model.sessionID == Fixtures.sessionA }
        func send(_ type: String, _ payload: [String: Any] = [:]) {
            model.receiveGatewayEvent(type, params: ["session_id": Fixtures.sessionA, "payload": payload])
        }

        send("message.start")
        send("tool.start", ["id": "t1", "name": "terminal", "context": "done before"])
        send("tool.complete", ["id": "t1", "name": "terminal"])
        send("tool.start", ["id": "t2", "name": "terminal", "context": "still running"])
        send("status.update", ["kind": "process", "text": "✔ [default] @sentry Kanban t_c891be93 done — Fix it"])
        send("tool.complete", ["id": "t2", "name": "terminal"])
        send("tool.start", ["id": "t3", "name": "search", "context": "after"])
        send("message.complete", ["text": "Done."])

        let tail = Array(model.messages.suffix(3))
        #expect(tail[0].activity.map(\.id) == ["t1"])
        #expect(tail[1].kanbanNotice != nil)
        #expect(tail[2].activity.map(\.id) == ["t2", "t3"])
        #expect(tail[2].text == "Done.")
    }

    @Test func returningToARunningSessionRestoresItsLiveTurn() async throws {
        let rpc = SessionIsolationRPCClient()
        var running = Fixtures.sessionAResponse
        running["running"] = true
        running["inflight"] = ["user": "fix the build", "assistant": "Half", "streaming": true]
        rpc.resumeResponses = [Fixtures.sessionAResponse, ["session_id": Fixtures.sessionB, "messages": []], running]
        let model = DockModel(rpcClient: rpc)
        let sessionA = HermesSession(id: Fixtures.sessionA, title: "A", preview: "", startedAt: nil, messageCount: 0, source: "test")
        model.resumeSession(sessionA)
        try await waitUntil { model.sessionID == Fixtures.sessionA && model.status == .idle }
        func send(_ type: String, _ payload: [String: Any] = [:]) {
            model.receiveGatewayEvent(type, params: ["session_id": Fixtures.sessionA, "payload": payload])
        }
        send("message.start")
        send("tool.start", ["id": "t1", "name": "terminal", "context": "swift build"])

        model.resumeSession(HermesSession(id: Fixtures.sessionB, title: "B", preview: "", startedAt: nil, messageCount: 0, source: "test"))
        try await waitUntil { model.sessionID == Fixtures.sessionB && model.status == .idle }
        model.resumeSession(sessionA)
        try await waitUntil { rpc.requests.filter { $0.method == "session.resume" }.count == 3 && model.sessionID == Fixtures.sessionA && model.status == .working }

        #expect(model.messages.map(\.text).suffix(2).first == "fix the build")
        #expect(model.streamingTurnActivity.map(\.id) == ["t1"])
        send("message.delta", ["delta": " done"])
        send("message.complete", ["text": "Half done"])
        #expect(model.messages.last?.text == "Half done")
        #expect(model.messages.last?.activity.map(\.id) == ["t1"])
        #expect(model.status == .idle)
    }

    @Test func resumeToolRowsBecomeReplyActivity() {
        // The shape session.resume actually returns: no tool_calls, one
        // compact row per tool call.
        let parsed = DockModel.parseMessages([
            ["role": "user", "content": "check", "timestamp": 10.0],
            ["role": "assistant", "text": "", "reasoning_content": "plan", "timestamp": 11.0],
            ["role": "tool", "name": "terminal", "context": "swift test", "tool_call_id": "c1", "timestamp": 12.0],
            ["role": "assistant", "text": "All green.", "timestamp": 40.0]
        ])

        #expect(parsed.messages.map(\.text) == ["check", "All green."])
        #expect(parsed.messages[1].activity.map(\.name) == [ActiveToolCall.thinkingName, "terminal"])
        #expect(parsed.messages[1].activity[1].context == "swift test")
    }

    @Test func canonicalBotChatDoesNotAdoptAnUnrelatedResumeResponse() async throws {
        let rpc = SessionIsolationRPCClient()
        rpc.resumeResponses = [
            [
                "session_id": Fixtures.sessionB,
                "messages": [
                    ["role": "assistant", "content": "answer in session B"]
                ]
            ]
        ]
        let model = DockModel(rpcClient: rpc)
        let sentry = BotSummary(
            id: "sentry", name: "Sentry", title: nil, description: nil, model: nil,
            isActive: false, chat: nil, avatarURL: nil, preview: nil, lastActive: nil,
            isHidden: false, hasAvatar: false, isDefault: false
        )

        model.resumeBotChat(sentry)
        try await waitUntil { !model.isRestoringSession && !model.messages.isEmpty }

        #expect(model.sessionID == BotService.canonicalBotChatTitle)
        #expect(model.messages.allSatisfy { !$0.text.contains("session B") })
    }
}

@MainActor
private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}
