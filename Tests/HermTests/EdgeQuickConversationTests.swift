import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class QuickConversationRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var calls: [(String, [String: Any])] = []
    var rows: [[String: Any]] = []
    var running = false
    var prompt = ""
    var rejectSubmit = false
    var rejectResume = false
    var holdResume = false
    var pendingResume: CheckedContinuation<[String: Any], Error>?

    func connect() async throws {}
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        switch method {
        case "session.create": return ["session_id": "runtime-quick", "stored_session_id": "quick"]
        case "session.resume":
            if rejectResume { throw HermesGateway.GatewayError.disconnected }
            if holdResume {
                holdResume = false
                return try await withCheckedThrowingContinuation { pendingResume = $0 }
            }
            let owner = params["session_id"] as? String ?? "quick"
            return [
                "session_id": "runtime-" + owner, "stored_session_id": owner,
                "profile": params["profile"] as? String ?? "default",
                "messages": rows, "running": running, "inflight": ["user": prompt],
            ]
        case "prompt.submit":
            if rejectSubmit {
                throw NSError(domain: "Hermes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request rejected"])
            }
            prompt = GenerativeUIIntegration.displayUserText(params["text"] as? String ?? "")
            running = true
            return ["status": "streaming"]
        case "session.list", "session.active_list": return ["sessions": []]
        default: return [:]
        }
    }
    func fetchHTTP(_ path: String) async throws -> [String: Any] { ["messages": rows, "sessions": []] }
}

@MainActor
struct EdgeQuickConversationTests {
    private func runtime(_ client: QuickConversationRPC) -> DockModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!, initialSessionID: "workspace",
            botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: client)
    }

    @Test func acknowledgedSendShowsPromptAndLiveReplyWithoutChangingWorkspace() async throws {
        let rpc = QuickConversationRPC()
        let runtime = runtime(rpc)
        defer { runtime.shutdown() }
        runtime.draft = "Keep my workspace draft"
        runtime.messages = [ChatMessage(role: .user, text: "Workspace message")]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = EdgeNotchState(store: QuickDraftStore(directory: directory))
        state.switchQuickProfile("builder")
        state.composing = true
        state.quickDraft = "test"
        state.quickSending = true
        let submitted = try await runtime.submitQuickDraft(state.captureRecord(), progress: state.updateQuickSubmission)
        state.finishQuickSubmission(submitted, failure: nil)
        #expect(state.quickTarget?.id == "quick")
        #expect(state.quickDraft.isEmpty)
        #expect(state.quickResult == nil)
        #expect(state.captureRecord().destination.sessionID == "quick")
        let chat = EdgeQuickConversationModel()
        defer { chat.shutdown() }
        await chat.load(state.captureRecord().destination, runtime: runtime)
        let conversation = try #require(chat.conversation)
        #expect(conversation !== runtime)
        #expect(conversation.messages.contains { $0.role == .user && $0.text.contains("test") })
        #expect(conversation.isSending)
        #expect(chat.unavailableReason != nil)
        runtime.receiveGatewayEvent(
            "message.delta", params: ["session_id": "other", "payload": ["delta": "Unrelated reply"]])
        #expect(!conversation.streamingMessageBuffer.contains("Unrelated"))
        runtime.receiveGatewayEvent(
            "message.delta", params: ["session_id": "runtime-quick", "payload": ["delta": "Test successful!"]])
        #expect(conversation.streamingMessageBuffer == "Test successful!")
        runtime.receiveGatewayEvent(
            "message.complete", params: ["session_id": "runtime-quick", "payload": ["text": "Test successful!"]])
        #expect(conversation.messages.contains { $0.role == .hermes && $0.text == "Test successful!" })
        #expect(chat.unavailableReason == nil)
        #expect(runtime.sessionID == "workspace")
        #expect(runtime.draft == "Keep my workspace draft")
        #expect(runtime.messages.map(\.text) == ["Workspace message"])
        #expect(runtime.pendingImages.isEmpty)

        rpc.running = false
        state.quickDraft = "Follow up"
        let followUp = try await runtime.submitQuickDraft(state.captureRecord(), progress: state.updateQuickSubmission)
        #expect(followUp.destination.sessionID == "quick")
        #expect(rpc.calls.filter { $0.0 == "session.create" }.count == 1)
        let lastPrompt = try #require(rpc.calls.last { $0.0 == "prompt.submit" }?.1)
        #expect(lastPrompt["session_id"] as? String == "runtime-quick")
        #expect(lastPrompt["profile"] as? String == "builder")
    }

    @Test func completedReplyLoadsFromHermesAndReopensAfterClosing() async throws {
        let rpc = QuickConversationRPC()
        rpc.rows = [
            ["role": "user", "content": "test"], ["role": "assistant", "content": "Everything is working."],
        ]
        let runtime = runtime(rpc)
        defer { runtime.shutdown() }
        let destination = QuickDestination(profileID: "default", sessionID: "quick")
        let chat = EdgeQuickConversationModel()
        await chat.load(destination, runtime: runtime)
        #expect(chat.conversation?.messages.map(\.text) == ["test", "Everything is working."])
        let previous = try #require(chat.conversation)
        chat.shutdown()
        runtime.receiveGatewayEvent(
            "message.delta", params: ["session_id": "runtime-quick", "payload": ["delta": "Late event"]])
        #expect(previous.streamingMessageBuffer.isEmpty)
        await chat.load(destination, runtime: runtime)
        defer { chat.shutdown() }
        #expect(chat.conversation !== previous)
        #expect(chat.conversation?.messages.map(\.text) == ["test", "Everything is working."])
    }

    @Test func changingDestinationRejectsAnOlderLoadingResult() async throws {
        let rpc = QuickConversationRPC()
        let runtime = runtime(rpc)
        defer { runtime.shutdown() }
        let chat = EdgeQuickConversationModel()
        defer { chat.shutdown() }
        rpc.holdResume = true
        let first = Task {
            await chat.load(QuickDestination(profileID: "builder", sessionID: "first"), runtime: runtime)
        }
        for _ in 0..<200 where rpc.pendingResume == nil { await Task.yield() }
        let pending = try #require(rpc.pendingResume)
        let previous = try #require(chat.conversation)
        await chat.load(QuickDestination(profileID: "research", sessionID: "second"), runtime: runtime)
        pending.resume(returning: [
            "session_id": "runtime-first", "stored_session_id": "first",
            "messages": [["role": "assistant", "content": "Old reply"]],
        ])
        await first.value
        #expect(chat.conversation?.sessionStorageID == "second")
        #expect(chat.conversation?.sessionProfileID == "research")
        #expect(chat.conversation?.messages.isEmpty == true)
        #expect(!chat.isLoading)
        #expect(previous.hasShutDown)
        #expect(previous.delegationMonitoringTask == nil)
    }

    @Test func unavailableHistoryCanBeRetriedWithoutCreatingOrSending() async throws {
        let rpc = QuickConversationRPC()
        let runtime = runtime(rpc)
        defer { runtime.shutdown() }
        let chat = EdgeQuickConversationModel()
        defer { chat.shutdown() }
        let destination = QuickDestination(profileID: "default", sessionID: "quick")
        rpc.rejectResume = true
        await chat.load(destination, runtime: runtime)
        #expect(chat.loadFailed)
        #expect(chat.unavailableReason != nil)
        #expect(chat.conversation?.messages.first?.text.contains("couldn't load") == true)
        rpc.rejectResume = false
        rpc.rows = [["role": "assistant", "content": "Recovered reply"]]
        await chat.load(destination, runtime: runtime)
        #expect(!chat.loadFailed)
        #expect(chat.conversation?.messages.map(\.text) == ["Recovered reply"])
        #expect(!rpc.calls.contains { $0.0 == "session.create" || $0.0 == "prompt.submit" })
    }

    @Test func failedSendRetainsDraftAndDoesNotAdvanceTheConversation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = EdgeNotchState(store: QuickDraftStore(directory: directory))
        state.quickDraft = "Keep this draft"
        var record = state.captureRecord()
        record.destination.sessionID = "created"
        state.quickSending = true
        try state.updateQuickSubmission(record)
        state.finishQuickSubmission(record, failure: QuickSubmissionFailure(message: "Unavailable", uncertain: true))
        #expect(state.quickDraft == "Keep this draft")
        #expect(state.quickNeedsReview)
        #expect(state.quickTranscriptRevision == 0)
        #expect(state.captureRecord().destination.sessionID == "created")
    }

    @Test func standaloneConversationHasMoreRoomOnEveryEdge() {
        let state = EdgeNotchState()
        state.expanded = true
        for side in [EdgeDockSide.left, .right, .top] {
            state.side = side
            state.composing = false
            let previewHeight = state.panelSize.height
            state.composing = true
            #expect(state.panelSize.height > previewHeight)
            #expect(
                state.openSize.height == EdgeNotchState.quickMessageHeight + (side == .top ? state.notchSize.height : 0)
            )
        }
    }

    @Test func renderQuickConversation() async throws {
        guard let directory = ProcessInfo.processInfo.environment["QUICK_CONVERSATION_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = DockThemeStore.shared
        let previousTheme = DockThemeRuntime.current
        let previousAppearance = NSApplication.shared.appearance
        defer {
            DockThemeRuntime.current = previousTheme
            DockThemeRuntime.revision &+= 1
            NSApplication.shared.appearance = previousAppearance
        }
        let rpc = QuickConversationRPC()
        rpc.rows = [
            ["role": "user", "content": "test"],
            ["role": "assistant", "content": "Test successful! ✅ Everything is working."],
        ]
        let runtime = runtime(rpc)
        defer { runtime.shutdown() }
        for theme in ["clean", "glass", "mono", "storm"] {
            DockThemeRuntime.current = try #require(DockThemeID(rawValue: theme))
            DockThemeRuntime.revision &+= 1
            let dark = theme != "clean"
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for side in [EdgeDockSide.right, .left, .top] {
                let storeURL = URL(fileURLWithPath: directory).appendingPathComponent(UUID().uuidString)
                let state = EdgeNotchState(store: QuickDraftStore(directory: storeURL))
                defer { try? FileManager.default.removeItem(at: storeURL) }
                state.side = side
                state.selectQuickTarget(
                    QuickDestination(profileID: "default", sessionID: "quick", title: "Test").session)
                state.composing = true
                state.expanded = true
                let view = EdgeNotchView(
                    state: state, controlCenter: ControlCenterModel(), quickMessageModel: runtime, openDock: {}
                )
                .frame(width: state.openSize.width, height: state.openSize.height)
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction {
                    $0.disablesAnimations = true
                    $0.animation = nil
                }
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(origin: .zero, size: state.openSize)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSApplication.shared.appearance
                window.contentView = host
                window.orderFrontRegardless()
                for _ in 0..<10 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                }
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(
                        "conversation-\(theme)-\(side.rawValue).png"))
                window.orderOut(nil)
                window.contentView = nil
                state.draftStore.flush()
            }
        }
    }
}
