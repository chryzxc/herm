import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
final class MessagePinRPCClient: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var deferHistory = false
    var rows: [[String: Any]] = [
        ["role": "user", "text": "question", "row_id": 1, "message_uid": "ask"],
        ["role": "assistant", "text": "answer", "row_id": 2, "message_uid": "reply"],
    ]

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "session.resume" {
            if deferHistory {
                return [
                    "session_id": params["session_id"]!, "messages": [], "hydrating": true, "message_count": rows.count,
                ]
            }
            return ["session_id": params["session_id"]!, "messages": rows]
        }
        return [:]
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        let owner = path.components(separatedBy: "/")[3]
        if path.contains("/messages?") {
            let query = URLComponents(string: path)?.queryItems ?? []
            let limit = Int(query.first { $0.name == "limit" }?.value ?? "") ?? 120
            let offset = Int(query.first { $0.name == "offset" }?.value ?? "") ?? 0
            let upper = max(0, rows.count - offset)
            let lower = max(0, upper - limit)
            let page = rows[lower..<upper].map { row in
                [
                    "id": row["row_id"]!, "role": row["role"]!, "content": row["text"]!,
                    "message_uid": row["message_uid"]!,
                ]
            }
            return ["messages": page, "pagination": ["returned": page.count]]
        }
        if path.contains("/timeline") { return ["entries": [], "pagination": ["has_more": false]] }
        throw HermesGateway.GatewayError.httpError(404)
    }
    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        Issue.record("pins must not reach Hermes")
        return [:]
    }
}

private struct PinTranscriptParent: View {
    @ObservedObject var model: DockModel
    let actions: ConversationMessageActionState
    let controlCenter = ControlCenterModel()
    let bots = BotModeModel()
    let voice = VoiceOutput()

    var body: some View {
        let _ = model.isLoadingSessions
        DockWindowWorkspace {
            ConversationTranscriptView(
                model: model, controlCenter: controlCenter, botMode: bots,
                messageActionState: actions, voiceOutput: voice,
                conversationMetrics: .resolve(isFullscreen: true), conversationHermFaceID: nil,
                isShowingMessageSearch: .constant(false), pinnedMessageJumpID: .constant(nil),
                selectedChatImage: .constant(nil)
            ).equatable().dockThemedRoot()
        }
    }
}

@MainActor
struct MessagePinTests {
    func loaded(_ rpc: MessagePinRPCClient) async throws -> DockModel {
        let defaults = try #require(UserDefaults(suiteName: "MessagePinTests.\(UUID().uuidString)"))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "message-pin-\(UUID().uuidString)")
        let model = DockModel(
            sessionAgentStateFileURL: temporary.appendingPathComponent("agents.json"),
            defaults: defaults, initialSessionID: "chat",
            botActivityFileURL: temporary.appendingPathComponent("bots.json"), rpcClient: rpc)
        await model.refreshCurrentSession()
        try await waitUntil { !model.isLoadingMessagePins }
        await model.refreshMessagePins()
        return model
    }

    @Test func pinsAreLocalAndKeyedBySavedIdentity() async throws {
        let model = try await loaded(MessagePinRPCClient())
        let answer = try #require(model.messages.last)
        #expect(model.canPinMessage(answer))
        #expect(!model.canPinMessage(ChatMessage(role: .hermes, text: "unsaved")))
        await model.toggleMessagePinned(answer)
        #expect(model.isMessagePinned(answer))
        #expect(model.messagePinError == nil)
        #expect(model.messagePinStore.pins(profile: model.sessionProfileID, sessionID: "chat").map(\.uid) == ["reply"])
        #expect(await model.messageID(forPin: try #require(model.pinnedMessages.first)) == answer.id)
        await model.toggleMessagePinned(answer)
        #expect(!model.isMessagePinned(answer))
        #expect(model.messagePinStore.pins(profile: model.sessionProfileID, sessionID: "chat").isEmpty)
    }

    @Test func storeKeepsPinsPerConversation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MessagePinStore(fileURL: url)
        let pin = MessagePinRecord(rowID: 4, uid: nil, role: "user")
        store.save([pin], profile: nil, sessionID: "a")
        #expect(MessagePinStore(fileURL: url).pins(profile: nil, sessionID: "a") == [pin])
        #expect(PinnedMessage(record: pin, preview: "").uid == "row:4")
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("preview"))
        #expect(store.pins(profile: nil, sessionID: "b").isEmpty)
        #expect(store.pins(profile: "work", sessionID: "a").isEmpty)
    }

    @Test(arguments: [false, true]) func bubblePinClickWritesAndChangesToUnpin(mouseClick: Bool) async throws {
        let app = NSApplication.shared
        let accessibility = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(accessibility, forKey: "accessibilityEnhancedUserInterface") }
        let rpc = MessagePinRPCClient()
        rpc.rows = (1...40).map { rowID in
            [
                "role": rowID.isMultiple(of: 2) ? "assistant" : "user", "text": "Message \(rowID)",
                "row_id": rowID, "message_uid": rowID == 40 ? "reply" : "uid-\(rowID)",
            ]
        }
        let model = try await loaded(rpc)
        defer { model.shutdown() }
        let actions = ConversationMessageActionState()
        let host = NSHostingView(rootView: PinTranscriptParent(model: model, actions: actions))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func elements(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
        }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        model.isLoadingSessions.toggle()
        model.sessionID = "resumed-chat"
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let pin = try #require(
            elements(host).last {
                $0.accessibilityRole?() == .button && $0.accessibilityLabel?() == "Pin message"
            })
        if mouseClick {
            let frame = try #require(pin.accessibilityFrame?())
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        } else {
            #expect(pin.accessibilityPerformPress?() == true)
        }
        try await waitUntil { !model.pinnedMessages.isEmpty && actions.pendingActions.isEmpty }
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(elements(host).contains { $0.accessibilityLabel?() == "Unpin message" })
    }

    @Test func acceptedPinSurvivesTranscriptProjectionReplacement() async throws {
        let rpc = MessagePinRPCClient()
        let model = try await loaded(rpc)
        defer { model.shutdown() }
        let actions = ConversationMessageActionState()
        let message = try #require(model.messages.last)
        var source: ConversationTranscriptSource? = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: actions, voice: VoiceOutput(),
            coordinator: ConversationTranscriptCoordinator())
        source?.perform(.pin, target: .init(sessionID: "chat", messageID: message.id))
        source = nil
        try await waitUntil { actions.pendingActions.isEmpty }
        #expect(model.isMessagePinned(message))
    }

    @Test func queuedPinDoesNotWriteAfterLeavingTheConversation() async throws {
        let rpc = MessagePinRPCClient()
        let model = try await loaded(rpc)
        defer { model.shutdown() }
        let actions = ConversationMessageActionState()
        let message = try #require(model.messages.last)
        let source = ConversationTranscriptSource(
            model: model, bots: BotModeModel(), actions: actions, voice: VoiceOutput(),
            coordinator: ConversationTranscriptCoordinator())
        source.perform(.pin, target: .init(sessionID: "chat", messageID: message.id))
        model.newChat()
        try await waitUntil { actions.pendingActions.isEmpty }
        #expect(model.pinnedMessages.isEmpty)
    }

    @Test func referencesKeepStableUIDAcrossCompaction() throws {
        let id = UUID()
        let rows = TranscriptHistoryPaging.displayRows(fromStoredRows: [
            ["id": 12, "role": "assistant", "content": "answer", "message_uid": "logical"]
        ])
        let reference = try #require(StoredMessageReference.references(rows: rows, rowIDs: [12: id])[id])
        let pin = PinnedMessage(rowID: 99, uid: "logical", role: "assistant", preview: "answer")
        #expect(pin.matches(reference))
        #expect(!pin.matches(StoredMessageReference(rowID: 99, uid: "foreign")))
    }

    @Test func pinJumpLoadsOlderAssistantMessageAndNeverChoosesANeighbor() async throws {
        let rpc = MessagePinRPCClient()
        rpc.deferHistory = true
        rpc.rows = (1...600).map { id in
            [
                "role": id % 2 == 1 ? "user" : "assistant", "text": "message \(id)", "row_id": id,
                "message_uid": "uid-\(id)",
            ]
        }
        let model = try await loaded(rpc)
        model.messagePinStore.save(
            [MessagePinRecord(rowID: 2, uid: "uid-2", role: "assistant")],
            profile: model.sessionProfileID, sessionID: "chat")
        await model.refreshMessagePins()
        #expect(!model.messages.contains { $0.text == "message 2" })
        let target = await model.messageID(forPin: try #require(model.pinnedMessages.first))
        #expect(model.messages.first(where: { $0.id == target })?.text == "message 2")
        let missing = PinnedMessage(rowID: 3, uid: "missing", role: "assistant", preview: "removed")
        #expect(await model.messageID(forPin: missing) == nil)
    }

    @Test func renderPinsForVisualReview() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MESSAGE_PIN_SNAPSHOT_DIR"] else { return }
        let rpc = MessagePinRPCClient()
        let model = try await loaded(rpc)
        for populated in [false, true] {
            model.messagePinStore.save(
                populated
                    ? [
                        MessagePinRecord(rowID: 1, uid: "ask", role: "user"),
                        MessagePinRecord(rowID: 2, uid: "reply", role: "assistant"),
                    ] : [],
                profile: model.sessionProfileID, sessionID: "chat")
            await model.refreshMessagePins()
            let host = NSHostingView(rootView: MessagePinsView(model: model, onSelect: { _ in }).dockThemedRoot())
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 340)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderFrontRegardless()
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.setNeedsDisplay(host.bounds)
            host.display()
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent(populated ? "pins-loaded.png" : "pins-empty.png"))
            window.orderOut(nil)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
