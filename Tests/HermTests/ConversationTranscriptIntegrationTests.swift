import AppKit
import Darwin
import SwiftUI
import Testing

@testable import Herm

@MainActor
private final class SessionSwitchTimingRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    let rows: [[String: Any]]

    init(rows: [[String: Any]]) { self.rows = rows }
    func connect() async throws {}
    func close() {}

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard method == "session.resume" else { return [:] }
        try await Task.sleep(for: .milliseconds(30))
        let id = params["session_id"] as? String ?? ""
        return ["session_id": "runtime-\(id)", "session_key": id, "messages": [], "hydrating": true]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        try await Task.sleep(for: .milliseconds(10))
        if path.contains("/timeline") { return ["entries": []] }
        let query = URLComponents(string: path)?.queryItems ?? []
        let limit = Int(query.first { $0.name == "limit" }?.value ?? "") ?? 120
        let offset = Int(query.first { $0.name == "offset" }?.value ?? "") ?? 0
        let upper = max(0, rows.count - offset)
        let page = Array(rows[max(0, upper - limit)..<upper])
        return ["messages": page, "pagination": ["returned": page.count]]
    }
}

@MainActor
struct ConversationTranscriptIntegrationTests {
    /// Match DockPopover's broad observation around an equatable transcript.
    struct Parent: View {
        @ObservedObject var model: DockModel
        let transcript: ConversationTranscriptView
        var timeline: SessionTraceModel? = nil
        @ViewBuilder
        var body: some View {
            let _ = model.isLoadingSessions
            if let timeline {
                HStack(spacing: 0) {
                    transcript.equatable()
                    SessionTraceView(model: model, trace: timeline).equatable().frame(width: 400)
                }
            } else {
                transcript.equatable()
            }
        }
    }

    final class RowEvaluations {
        var messageBodies = 0
        var timelineCanvases = 0
        var activityBodies = 0
    }

    struct Root: View {
        let parent: Parent
        let evaluations: RowEvaluations
        var body: some View {
            #if DEBUG
                parent.environment(
                    \.conversationRowEvaluation,
                    { name, _ in
                        if name == "message" { evaluations.messageBodies += 1 }
                        if name == "timeline-canvas" { evaluations.timelineCanvases += 1 }
                        if name == "turn-activity" { evaluations.activityBodies += 1 }
                    })
            #else
                parent
            #endif
        }
    }

    @MainActor
    final class Fixture {
        let model: DockModel
        let controller = ConversationScrollController()
        let coordinator: ConversationTranscriptCoordinator
        let performance = ConversationPerformanceMonitor()
        let evaluations = RowEvaluations()
        let timeline: SessionTraceModel?
        let host: NSHostingView<Root>
        let window: NSWindow
        var layoutWorkMS = 0.0

        init(
            source: String? = nil, streaming: Bool = false, messages: [ChatMessage]? = nil,
            includeTimeline: Bool = false, trailingContentInset: CGFloat = 0,
            rpcClient: HermesRPCClientProtocol? = nil
        ) {
            timeline = includeTimeline ? SessionTraceModel() : nil
            coordinator = ConversationTranscriptCoordinator(controller: controller)
            _ = NSApplication.shared
            let fixtureID = UUID().uuidString
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("herm-transcript-test-\(fixtureID)")
            let defaults = UserDefaults(suiteName: "Herm.TranscriptTests.\(fixtureID)")!
            model = DockModel(
                sessionAgentStateFileURL: root.appendingPathComponent("agents.json"), defaults: defaults,
                initialSessionID: "scroll-integration", botActivityFileURL: root.appendingPathComponent("bots.json"),
                rpcClient: rpcClient)
            model.messages =
                messages
                ?? (0..<500).map { index in
                    ChatMessage(
                        role: .hermes,
                        text: ((index.isMultiple(of: 5) ? source : nil)
                            ?? String(repeating: "Paragraph **content** with `code` and wrapping text.\n\n", count: 6))
                            + "\nMessage \(index)")
                }
            if streaming {
                model.streamingMessageID = model.messages.last?.id
                model.streamingText.appendPresentation(source ?? "A streaming reply")
            }
            let transcriptCoordinator = coordinator
            let view = ConversationTranscriptView(
                model: model, controlCenter: ControlCenterModel(), botMode: BotModeModel(),
                messageActionState: ConversationMessageActionState(), voiceOutput: VoiceOutput(),
                conversationMetrics: .resolve(isFullscreen: true), conversationHermFaceID: nil,
                isShowingMessageSearch: .constant(false), pinnedMessageJumpID: .constant(nil),
                selectedChatImage: .constant(nil), trailingContentInset: trailingContentInset,
                coordinator: transcriptCoordinator
            )
            host = NSHostingView(
                rootView: Root(
                    parent: Parent(model: model, transcript: view, timeline: timeline), evaluations: evaluations))
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: includeTimeline ? 1040 : 640, height: 600)
            window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
        }

        func settle() async throws {
            for _ in 0..<10 {
                let start = DispatchTime.now().uptimeNanoseconds
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                layoutWorkMS += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func move(to top: CGFloat) throws {
            let clip = try #require(controller.clipView)
            let geometry = try #require(controller.geometry)
            let document = try #require(clip.documentView)
            let origin = document.isFlipped ? top : geometry.documentHeight - geometry.visibleHeight - top
            clip.scroll(to: NSPoint(x: 0, y: origin))
        }
    }

    @Test func unreadDividerMountsAndJumpsToItsMessage() async throws {
        let messages = (0..<60).map { ChatMessage(role: .hermes, text: "Reply \($0)") }
        let fixture = Fixture(messages: messages)
        fixture.window.orderFrontRegardless()
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        fixture.model.unreadDividerMessageID = messages[20].id
        try await fixture.settle()
        #expect(fixture.coordinator.mountedRange.contains(20))
        let row = try #require(fixture.coordinator.rowViewports.first { $0.target.messageID == messages[20].id })
        let geometry = try #require(fixture.controller.geometry)
        #expect(row.minY >= geometry.visibleTop - 2)
        #expect(row.minY < geometry.visibleTop + geometry.visibleHeight)
        #expect(!fixture.coordinator.presentation.isAtBottom)
    }

    @Test func visibleHistoryWaitsForAdjacentPreparation() async throws {
        let source = "```swift\n" + String(repeating: "let value = 42 // complete line\n", count: 2_000) + "```"
        let fixture = Fixture(source: source)
        fixture.controller.allowsOccludedPreparationForTesting = true
        fixture.window.orderFrontRegardless()
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        let original = fixture.coordinator.mountedRange
        let first = try #require(fixture.coordinator.rowViewports.min { $0.index < $1.index })
        NativeMarkdownCompletedHeightCache.removeAll()
        fixture.controller.userScrollDidMove()
        try fixture.move(to: first.minY + 20)
        fixture.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        fixture.controller.userScrollDidSettle()
        let deadline = Date().addingTimeInterval(20)
        while fixture.coordinator.mountedRange == original, Date() < deadline {
            fixture.host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.coordinator.mountedRange.lowerBound < original.lowerBound)
        #expect(fixture.coordinator.mountedRange.lowerBound >= original.lowerBound - ConversationMessageWindow.pageSize)
        try await fixture.settle()
        #expect(fixture.coordinator.pendingPage == nil)
    }

    @Test(arguments: [CGFloat(220), CGFloat(360)])
    func railSpaceKeepsTheNativeScrollbarAtTheOuterEdge(railWidth: CGFloat) async throws {
        let fixture = Fixture(trailingContentInset: railWidth)
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        let scroll = try #require(fixture.controller.clipView?.superview as? NSScrollView)
        let scrollFrame = fixture.host.convert(scroll.bounds, from: scroll)
        #expect(abs(scrollFrame.maxX - fixture.host.bounds.maxX) < 1)
        func containers(_ view: NSView) -> [NativeMarkdownDocumentContainerView] {
            (view as? NativeMarkdownDocumentContainerView).map { [$0] } ?? view.subviews.flatMap(containers)
        }
        let bodies = containers(fixture.host)
        #expect(!bodies.isEmpty)
        for body in bodies {
            let frame = fixture.host.convert(body.bounds, from: body)
            #expect(frame.maxX <= fixture.host.bounds.maxX - railWidth + 1)
        }
        let before = try #require(fixture.controller.geometry)
        try fixture.move(to: max(0, before.visibleTop - 80))
        #expect(try #require(fixture.controller.geometry).visibleTop < before.visibleTop)
    }

    @Test func explicitRailReplyJumpRevealsTheTailWhileBrowsingHistory() async throws {
        let fixture = Fixture()
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        let geometry = try #require(fixture.controller.geometry)
        try fixture.move(to: max(0, geometry.visibleTop - 200))
        fixture.coordinator.presentation.isAtBottom = false
        try await fixture.settle()
        let original = fixture.host.rootView.parent.transcript
        let jumping = ConversationTranscriptView(
            model: original.model, controlCenter: original.controlCenter, botMode: original.botMode,
            messageActionState: original.messageActionState, voiceOutput: original.voiceOutput,
            conversationMetrics: original.conversationMetrics, conversationHermFaceID: nil,
            isShowingMessageSearch: .constant(false), pinnedMessageJumpID: .constant(nil),
            selectedChatImage: .constant(nil), latestJumpRequest: 1, coordinator: fixture.coordinator)
        #expect(original != jumping)
        fixture.host.rootView = Root(
            parent: Parent(model: fixture.model, transcript: jumping), evaluations: fixture.evaluations)
        try await fixture.settle()
        #expect(fixture.coordinator.presentation.isAtBottom)
        #expect(fixture.coordinator.mountedRange.upperBound == fixture.model.messages.count)
        let after = try #require(fixture.controller.geometry)
        #expect(after.documentHeight - after.visibleHeight - after.visibleTop < 2)
    }

    @Test func productionPagingKeepsTheVisibleMessageWithoutManualCorrection() async throws {
        try await checkProductionPaging()
    }

    @Test func cachedTranscriptPromotesToFreshRowsWithoutChangingTheirIdentity() async throws {
        let fixture = Fixture(
            messages: (0..<36).map {
                ChatMessage(role: .hermes, text: String(repeating: "Cached reply \($0). ", count: 20))
            })
        defer { fixture.window.orderOut(nil) }
        let cached = fixture.model.messages
        fixture.model.sessionStorageID = "stored-session"
        fixture.model.storageIDsByRuntimeID["requested-session"] = "stored-session"
        fixture.model.storageIDsByRuntimeID["resolved-runtime"] = "stored-session"
        fixture.model.sessionID = "requested-session"
        fixture.model.messages = []
        fixture.model.sessionTranscriptPreview = SessionTranscriptPreview(
            messages: cached, rowIDs: [:], references: [:], pendingImages: [])
        fixture.model.sessionTranscriptLoadState = .refreshing
        try await fixture.settle()
        #expect(fixture.coordinator.sessionID == fixture.model.transcriptPresentationID)
        #expect(!fixture.coordinator.rowViewports.isEmpty)
        let geometry = try #require(fixture.controller.geometry)
        try fixture.move(to: max(0, geometry.visibleTop - 200))
        fixture.coordinator.presentation.isAtBottom = false
        try await fixture.settle()
        let visible = try #require(fixture.controller.geometry)
        let anchor = try #require(
            fixture.coordinator.rowViewports.filter {
                $0.maxY > visible.visibleTop && $0.minY < visible.visibleTop + visible.visibleHeight
            }.min { $0.index < $1.index })
        let offset = anchor.minY - visible.visibleTop

        fixture.model.sessionID = "resolved-runtime"
        fixture.model.messages = (0..<10).map { ChatMessage(role: .user, text: "Older \($0)") } + cached
        fixture.model.sessionTranscriptPreview = nil
        fixture.model.sessionTranscriptLoadState = .ready
        try await fixture.settle()
        #expect(fixture.coordinator.sessionID == fixture.model.transcriptPresentationID)
        #expect(
            fixture.coordinator.rowViewports.allSatisfy { row in
                fixture.model.messages.contains { $0.id == row.target.messageID }
            })
        let restored = try #require(
            fixture.coordinator.rowViewports.first { $0.target.messageID == anchor.target.messageID })
        #expect(abs(restored.minY - (try #require(fixture.controller.geometry)).visibleTop - offset) < 1)
    }

    @Test func streamingTailStillAllowsPagingWhileBrowsingHistory() async throws {
        try await checkProductionPaging(streaming: true)
    }

    @Test func largerPagesPreserveAnchorsAcrossTallMarkdownAndCodeRows() async throws {
        let source =
            String(repeating: "A tall **Markdown** paragraph with `inline code`.\n\n", count: 240)
            + "```swift\n" + String(repeating: "let value = 42 // source line\n", count: 500) + "```\n"
        try await checkProductionPaging(source: source, streaming: true)
    }

    @Test(arguments: [false, true])
    func activityAndHiddenRowsStillAllowEarlierPaging(includesHiddenRows: Bool) async throws {
        let messages = (0..<60).map { index in
            let activity: [ActiveToolCall] =
                index.isMultiple(of: 3)
                ? [
                    ActiveToolCall(
                        id: "tool-\(index)", name: "terminal", input: "Synthetic command", context: "",
                        startedAt: .distantPast, result: "Done", isComplete: true)
                ] : []
            return ChatMessage(
                role: .hermes,
                text: includesHiddenRows && index % 3 == 1
                    ? "" : String(repeating: "History message \(index).\n\n", count: 8),
                activity: activity)
        }
        let fixture = Fixture(messages: messages)
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        #expect(fixture.coordinator.rowViewports.count == fixture.coordinator.mountedRange.count)
        let previousRange = fixture.coordinator.mountedRange
        let anchor = try #require(
            fixture.coordinator.rowViewports
                .filter { $0.maxY > $0.minY }.min { $0.index < $1.index })
        try fixture.move(to: anchor.minY + 40)
        try fixture.move(to: anchor.minY + 20)
        let offset = anchor.minY - (try #require(fixture.controller.geometry)).visibleTop
        try await fixture.settle()
        #expect(fixture.coordinator.mountedRange.lowerBound < previousRange.lowerBound)
        #expect(fixture.coordinator.pendingPage == nil)
        let restored = try #require(fixture.coordinator.rowViewports.first { $0.target == anchor.target })
        #expect(abs(restored.minY - (try #require(fixture.controller.geometry)).visibleTop - offset) < 1)
    }

    @Test func storedHistoryPrependBecomesVisibleWithActivityRows() async throws {
        let messages = (0..<12).map { index in
            ChatMessage(
                role: .hermes, text: String(repeating: "Loaded reply \(index).\n\n", count: 8),
                activity: [
                    ActiveToolCall(
                        id: "loaded-\(index)", name: "terminal", input: "Synthetic command",
                        context: "", startedAt: .distantPast, result: "Done", isComplete: true)
                ])
        }
        let fixture = Fixture(messages: messages)
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        let anchor = try #require(fixture.coordinator.rowViewports.min { $0.index < $1.index })
        let earlier = (0..<4).map { ChatMessage(role: .user, text: "Earlier stored message \($0)") }
        var requested = false
        fixture.coordinator.onEarlierHistory = {
            guard !requested else { return }
            requested = true
            fixture.model.messages = earlier + fixture.model.messages
            fixture.model.lastTranscriptPrepend = .init(generation: 1, count: 4, resultingCount: 16)
        }
        defer { fixture.coordinator.onEarlierHistory = {} }
        try fixture.move(to: anchor.minY + 40)
        try fixture.move(to: anchor.minY + 20)
        let offset = anchor.minY - (try #require(fixture.controller.geometry)).visibleTop
        try await fixture.settle()
        #expect(requested)
        #expect(fixture.coordinator.mountedRange.lowerBound == 0)
        #expect(Set(earlier.map(\.id)).isSubset(of: Set(fixture.coordinator.rowViewports.map { $0.target.messageID })))
        #expect(fixture.coordinator.pendingPage == nil)
        let restored = try #require(fixture.coordinator.rowViewports.first { $0.target == anchor.target })
        #expect(abs(restored.minY - (try #require(fixture.controller.geometry)).visibleTop - offset) < 1)
    }

    func checkProductionPaging(source: String? = nil, streaming: Bool = false) async throws {
        let fixture = Fixture(source: source, streaming: streaming)
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        for earlier in [true, true, false, false] {
            let previousRange = fixture.coordinator.mountedRange
            let previousPages = fixture.coordinator.performance.pageTransactions
            let previousCorrections = fixture.coordinator.performance.anchorCorrections
            let before = fixture.coordinator.rowViewports
            let anchor = try #require(earlier ? before.min { $0.index < $1.index } : before.max { $0.index < $1.index })
            let geometry = try #require(fixture.controller.geometry)
            let target = earlier ? anchor.minY + 20 : anchor.maxY - geometry.visibleHeight - 20
            try fixture.move(to: target)
            try fixture.move(to: target + (earlier ? -10 : 10))
            let offset = anchor.minY - (try #require(fixture.controller.geometry)).visibleTop
            if streaming { fixture.model.streamingText.appendPresentation("\n\nA live update while browsing.") }
            try await fixture.settle()
            let restored = try #require(fixture.coordinator.rowViewports.first { $0.target == anchor.target })
            let current = try #require(fixture.controller.geometry)
            #expect(abs(restored.minY - current.visibleTop - offset) < 1)
            #expect(fixture.coordinator.rowViewports.count <= ConversationMessageWindow.maxMountedRowCount)
            #expect(fixture.coordinator.pendingPage == nil)
            let range = fixture.coordinator.mountedRange
            let revealed =
                earlier ? previousRange.lowerBound - range.lowerBound : range.upperBound - previousRange.upperBound
            let remaining = earlier ? previousRange.lowerBound : fixture.model.messages.count - previousRange.upperBound
            #expect(revealed == min(8, remaining))
            #expect(fixture.coordinator.performance.pageTransactions == previousPages + 1)
            #expect(fixture.coordinator.performance.anchorCorrections == previousCorrections + 1)
        }
        #expect(fixture.coordinator.performance.pageTransactions >= 4)
    }

    @Test func unrelatedParentRefreshDoesNotEvaluateMessageBodiesOrMeasureMarkdown() async throws {
        let fixture = Fixture()
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        let beforeBodies = fixture.evaluations.messageBodies
        func containers(_ view: NSView) -> [NativeMarkdownDocumentContainerView] {
            (view as? NativeMarkdownDocumentContainerView).map { [$0] } ?? view.subviews.flatMap(containers)
        }
        let beforeContainers = containers(fixture.host)
        let beforeMeasurements = beforeContainers.map(\.sectionMeasurementCount)
        #expect(!beforeContainers.isEmpty)
        #if DEBUG
            #expect(beforeBodies > 0)
        #endif
        fixture.model.sessions = []
        fixture.model.isLoadingSessions = true
        fixture.model.runtimeConfigurationError = "Unrelated synthetic refresh"
        try await fixture.settle()
        #expect(fixture.evaluations.messageBodies == beforeBodies)
        #expect(containers(fixture.host).map(ObjectIdentifier.init) == beforeContainers.map(ObjectIdentifier.init))
        #expect(containers(fixture.host).map(\.sectionMeasurementCount) == beforeMeasurements)
        let beforeRelevant = fixture.coordinator.performance.transcriptEvaluations
        fixture.model.approvalText = "A visible synthetic approval"
        try await fixture.settle()
        #expect(fixture.coordinator.performance.transcriptEvaluations > beforeRelevant)
    }

    @Test(arguments: [false, true])
    func concurrentSessionBurstsKeepCompletedRowsAndScrollPositionStable(browsingHistory: Bool) async throws {
        let fixture = Fixture(
            source: String(repeating: "Long **Markdown** paragraph with `code` and wrapping text.\n\n", count: 160),
            streaming: true)
        defer { fixture.window.orderOut(nil) }
        fixture.model.sessions = (0..<8).map {
            HermesSession(
                id: "background-\($0)", title: "Background \($0)", preview: "", startedAt: nil,
                messageCount: 500, source: "test", isWorking: true)
        }
        try await fixture.settle()
        if browsingHistory {
            fixture.coordinator.jump(to: 250)
            try await fixture.settle()
            let row = try #require(fixture.coordinator.rowViewports.first { $0.index == 250 })
            try fixture.move(to: row.minY + 20)
            try await fixture.settle()
        }
        // Slow runners keep mounting rows after a jump; baseline once body evaluations hold steady.
        var stable = 0
        for _ in 0..<20 where stable < 2 {
            let count = fixture.evaluations.messageBodies
            try await fixture.settle()
            stable = fixture.evaluations.messageBodies == count ? stable + 1 : 0
        }
        let streamingID = fixture.model.streamingMessageID
        let beforeRows = fixture.coordinator.rowViewports.filter { $0.target.messageID != streamingID }
        let beforeBodies = fixture.evaluations.messageBodies
        let beforeTop = try #require(fixture.controller.geometry).visibleTop
        func containers(_ view: NSView) -> [NativeMarkdownDocumentContainerView] {
            (view as? NativeMarkdownDocumentContainerView).map { [$0] } ?? view.subviews.flatMap(containers)
        }
        let beforeContainers = containers(fixture.host)
        let beforeMeasurements = beforeContainers.map(\.sectionMeasurementCount)
        let initialText = fixture.model.streamingText.text
        var receivedText = ""
        for batch in 0..<5 {
            for index in 0..<200 {
                let owner = "background-\(index % 8)"
                fixture.model.receiveGatewayEvent(
                    "message.delta",
                    params: [
                        "session_id": owner, "payload": ["delta": "Background chunk \(index)"],
                    ])
                fixture.model.receiveGatewayEvent(
                    "tool.call",
                    params: [
                        "session_id": owner,
                        "payload": [
                            "id": "\(batch)-\(index)", "name": "terminal", "args": ["command": "echo synthetic"],
                        ],
                    ])
                fixture.model.botLiveSteps[owner] = "Background step \(batch)-\(index)"
            }
            let delta = "\n\nVisible-session chunk \(batch)."
            receivedText += delta
            fixture.model.streamingText.appendPresentation(delta)
            fixture.model.activeToolCalls.append(
                ActiveToolCall(
                    id: "current-\(batch)", name: "terminal",
                    input: "Selected-session tool", context: "", startedAt: .distantPast, isComplete: false))
            fixture.model.isLoadingSessions.toggle()
            try await fixture.settle()
        }
        #expect(fixture.model.streamingText.text == initialText + receivedText)
        #expect(fixture.model.sessions.count == 8 && fixture.model.sessions.allSatisfy(\.isWorking))
        #expect(fixture.model.sessionActivityLabels.keys.filter { $0.hasPrefix("background-") }.count == 8)
        #expect(fixture.model.activeToolCalls.count == 5)
        #expect(fixture.evaluations.messageBodies == beforeBodies)
        #expect(fixture.coordinator.mountedRange.count <= ConversationMessageWindow.maxMountedRowCount)
        for row in beforeRows {
            let current = try #require(fixture.coordinator.rowViewports.first { $0.target == row.target })
            #expect(abs((current.maxY - current.minY) - (row.maxY - row.minY)) < 1)
        }
        if browsingHistory {
            #expect(abs((try #require(fixture.controller.geometry)).visibleTop - beforeTop) < 1)
            #expect(containers(fixture.host).map(ObjectIdentifier.init) == beforeContainers.map(ObjectIdentifier.init))
            #expect(containers(fixture.host).map(\.sectionMeasurementCount) == beforeMeasurements)
            let range = fixture.coordinator.mountedRange
            let first = try #require(fixture.coordinator.rowViewports.min { $0.index < $1.index })
            try fixture.move(to: first.minY + 20)
            try fixture.move(to: first.minY + 10)
            let offset = first.minY - (try #require(fixture.controller.geometry)).visibleTop
            try await fixture.settle()
            #expect(fixture.coordinator.mountedRange.lowerBound < range.lowerBound)
            #expect(fixture.coordinator.pendingPage == nil)
            let restored = try #require(fixture.coordinator.rowViewports.first { $0.target == first.target })
            #expect(abs(restored.minY - (try #require(fixture.controller.geometry)).visibleTop - offset) < 1)
        }
    }

    @Test func botStepUpdatesOnlyEvaluateTheirOwningActivityRow() async throws {
        let messages = (0..<60).map { index in
            ChatMessage(
                role: .hermes, text: "Completed reply \(index)",
                activity: [
                    ActiveToolCall(
                        id: "call-\(index)", name: "terminal", input: "Synthetic tool",
                        context: "", startedAt: .distantPast, isComplete: true)
                ])
        }
        let fixture = Fixture(messages: messages)
        defer { fixture.window.orderOut(nil) }
        let record = BotActivityRecord(
            id: "bot-dispatch:call-59", originSessionID: "scroll-integration",
            botID: "fixture-bot", botName: "Bot", summary: "Waiting for input", state: .waiting)
        fixture.model.botActivityBySessionID = ["scroll-integration": [record]]
        fixture.model.botLiveSteps = [record.id: "Original step"]
        try await fixture.settle()
        let bodies = fixture.evaluations.messageBodies
        let activity = fixture.evaluations.activityBodies
        #if DEBUG
            #expect(activity > 0)
        #endif
        fixture.model.botLiveSteps[record.id] = "Current step"
        try await fixture.settle()
        #expect(fixture.evaluations.messageBodies == bodies)
        #if DEBUG
            #expect(fixture.evaluations.activityBodies == activity + 1)
        #endif
        fixture.model.botLiveSteps["unrelated-record"] = "Background step"
        try await fixture.settle()
        #if DEBUG
            #expect(fixture.evaluations.activityBodies == activity + 1)
        #endif
        fixture.model.botActivityBySessionID["scroll-integration"]?[0].state = .completed
        try await fixture.settle()
        #expect(fixture.evaluations.messageBodies == bodies)
        #if DEBUG
            #expect(fixture.evaluations.activityBodies == activity + 2)
        #endif
    }

    @Test func thousandLiveToolsKeepHistoryAndStreamingTextStable() async throws {
        let fixture = Fixture(streaming: true)
        defer { fixture.window.orderOut(nil) }
        var calls = (0..<1_000).map { index in
            ActiveToolCall(
                id: "tool-\(index)", name: "terminal", input: "", context: "", startedAt: .distantPast,
                isComplete: false)
        }
        fixture.model.activeToolCalls = calls
        try await fixture.settle()
        fixture.coordinator.jump(to: 250)
        try await fixture.settle()
        let row = try #require(fixture.coordinator.rowViewports.first { $0.index == 250 })
        try fixture.move(to: row.minY + 20)
        try await fixture.settle()
        let top = try #require(fixture.controller.geometry).visibleTop
        let bodies = fixture.evaluations.messageBodies
        let initial = fixture.model.streamingText.text
        calls[500].isComplete = true
        fixture.model.activeToolCalls = calls
        fixture.model.streamingText.appendPresentation(" exact streamed suffix")
        try await fixture.settle()
        #expect(fixture.model.streamingTurnActivity.map(\.id) == calls.map(\.id))
        #expect(fixture.model.streamingTurnActivity[500].isComplete)
        #expect(fixture.model.streamingText.text == initial + " exact streamed suffix")
        #expect(fixture.evaluations.messageBodies == bodies)
        #expect(abs((try #require(fixture.controller.geometry)).visibleTop - top) < 1)
    }

    @Test func sessionReplacementResetsProductionMountingAndRejectsOldGeometry() async throws {
        let fixture = Fixture()
        defer { fixture.window.orderOut(nil) }
        try await fixture.settle()
        let stale = ConversationTranscriptLayout(
            sessionID: fixture.coordinator.sessionID,
            generation: fixture.coordinator.generation, range: fixture.coordinator.mountedRange,
            rows: fixture.coordinator.rowViewports)
        fixture.model.sessionID = "replacement"
        fixture.model.messages = (0..<4).map { ChatMessage(role: .hermes, text: "Replacement message \($0)") }
        try await fixture.settle()
        fixture.coordinator.receiveLayout(stale)
        #expect(fixture.coordinator.sessionID == fixture.model.transcriptPresentationID)
        #expect(fixture.coordinator.mountedRange == 0..<4)
        #expect(fixture.coordinator.pendingPage == nil)
        #expect(fixture.coordinator.rowViewports.allSatisfy { $0.target.sessionID == "replacement" })
        #expect(fixture.coordinator.rowViewports.count == 4)
    }

    @Test func timelineAndChatStayIsolatedDuringLiveActivityAndHistoryPaging() async throws {
        let start = Date().addingTimeInterval(-1_000)
        let messages = (0..<500).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .hermes,
                text: String(repeating: "Message \(index), **Markdown** and `code`.\n\n", count: 6),
                timestamp: start.addingTimeInterval(Double(index)),
                activity: index.isMultiple(of: 2)
                    ? []
                    : [
                        ActiveToolCall(
                            id: "old-\(index)", name: "terminal",
                            input: "Saved tool", context: "", startedAt: start.addingTimeInterval(Double(index)),
                            isComplete: true, traceDuration: 1, traceTiming: .runtime)
                    ])
        }
        let fixture = Fixture(streaming: true, messages: messages, includeTimeline: true)
        defer { fixture.window.orderOut(nil) }
        fixture.model.isHermesConnected = true
        fixture.model.status = .working
        fixture.model.streamingMessageSessionID = fixture.model.sessionID
        fixture.model.streamingResponseStartedAt = Date()
        fixture.model.activeSubagents = (0..<8).map {
            HermesSubagent(
                id: "worker-\($0)", name: "Worker \($0)", goal: "Selected-session work",
                status: "running", startedAt: Date())
        }
        try await fixture.settle()
        fixture.coordinator.jump(to: 250)
        try await fixture.settle()
        let anchor = try #require(fixture.coordinator.rowViewports.first { $0.index == 250 })
        try fixture.move(to: anchor.minY + 20)
        try await fixture.settle()
        let top = try #require(fixture.controller.geometry).visibleTop
        let bodies = fixture.evaluations.messageBodies
        let timeline = try #require(fixture.timeline)
        // This fixture's window stays offscreen; subscribe explicitly so this
        // test exercises simultaneous updates independently of occlusion.
        timeline.observe(fixture.model)
        defer { timeline.suspend() }
        let scans = timeline.historyScanCount
        for batch in 0..<5 {
            for index in 0..<200 {
                fixture.model.receiveGatewayEvent(
                    "tool.call",
                    params: [
                        "session_id": "background-\(index % 8)",
                        "payload": ["id": "\(batch)-\(index)", "name": "terminal"],
                    ])
            }
            fixture.model.streamingText.appendPresentation("\n\nIncoming chunk \(batch).")
            fixture.model.activeToolCalls.append(
                ActiveToolCall(
                    id: "selected-\(batch)", name: "terminal",
                    input: "Selected tool", context: "", startedAt: Date(), isComplete: false, traceTiming: .observed))
            fixture.model.isLoadingSessions.toggle()
            try await fixture.settle()
        }
        try await Task.sleep(for: .milliseconds(400))
        try await fixture.settle()
        #expect(timeline.historyScanCount == scans)
        #expect(timeline.turns.flatMap(\.calls).filter { $0.id.hasPrefix("selected-") }.count == 5)
        #expect(timeline.turns.last?.agentCount == 8)
        #expect(fixture.evaluations.messageBodies == bodies)
        #expect(abs((try #require(fixture.controller.geometry)).visibleTop - top) < 1)
        let canvases = fixture.evaluations.timelineCanvases
        let updates = timeline.updateCount
        for index in 0..<100 {
            fixture.model.botLiveSteps["background"] = "Step \(index)"
            fixture.model.isLoadingSessions.toggle()
        }
        try await fixture.settle()
        #expect(timeline.updateCount == updates)
        #expect(fixture.evaluations.timelineCanvases == canvases)
        let previousRange = fixture.coordinator.mountedRange
        let first = try #require(fixture.coordinator.rowViewports.min { $0.index < $1.index })
        try fixture.move(to: first.minY + 20)
        try fixture.move(to: first.minY + 10)
        let offset = first.minY - (try #require(fixture.controller.geometry)).visibleTop
        try await fixture.settle()
        #expect(fixture.coordinator.mountedRange.lowerBound < previousRange.lowerBound)
        #expect(fixture.coordinator.pendingPage == nil)
        let restored = try #require(fixture.coordinator.rowViewports.first { $0.target == first.target })
        #expect(abs(restored.minY - (try #require(fixture.controller.geometry)).visibleTop - offset) < 1)
    }

    /// Five cold/warm pairs; layout/display work excludes synthetic pacing sleeps.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_SESSION_PROFILE"] == "1"))
    func releaseSessionSwitchTimings() async throws {
        func session(_ id: String) -> HermesSession {
            HermesSession(id: id, title: id, preview: "", startedAt: nil, messageCount: 0, source: "test")
        }
        func waitForLayout(_ fixture: Fixture, generation: Int, cached: Bool) async throws -> Double {
            for _ in 0..<1_000 {
                fixture.host.layoutSubtreeIfNeeded()
                fixture.host.displayIfNeeded()
                let recorded =
                    cached
                    ? fixture.model.sessionSwitchCachedLayoutRecorded : fixture.model.sessionSwitchFreshLayoutRecorded
                if fixture.model.sessionResumeGeneration == generation,
                    recorded
                {
                    return Double(DispatchTime.now().uptimeNanoseconds - fixture.model.sessionSwitchStartedAt)
                        / 1_000_000
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            throw URLError(.timedOut)
        }
        for scenario in ["prose", "code", "tool_heavy", "streaming"] {
            for pair in 0..<5 {
                let body =
                    scenario == "code"
                    ? "```swift\n" + String(repeating: "let value = 42\n", count: 500) + "```"
                    : String(repeating: "A **readable** paragraph with `code`.\n\n", count: 80)
                var rows: [[String: Any]] = []
                for turn in 0..<18 {
                    rows.append(["id": rows.count + 1, "role": "user", "content": "Question \(turn)"])
                    if scenario == "tool_heavy" {
                        for _ in 0..<20 {
                            rows.append(["id": rows.count + 1, "role": "tool", "content": "Tool output"])
                        }
                    }
                    rows.append(["id": rows.count + 1, "role": "assistant", "content": body])
                }
                let fixture = Fixture(messages: [], rpcClient: SessionSwitchTimingRPC(rows: rows))
                defer { fixture.window.orderOut(nil) }
                try await fixture.settle()
                let coldGeneration = fixture.model.sessionResumeGeneration + 1
                let cold = Task { await fixture.model.resumeSession(session("a"), reportFailure: true) }
                let coldMS = try await waitForLayout(fixture, generation: coldGeneration, cached: false)
                #expect(await cold.value)
                #expect(await fixture.model.resumeSession(session("b"), reportFailure: true))
                try await fixture.settle()
                if scenario == "streaming" {
                    fixture.model.streamingMessageID = fixture.model.messages.last?.id
                    fixture.model.streamingText.appendPresentation("Background streaming")
                }
                let warmGeneration = fixture.model.sessionResumeGeneration + 1
                let warm = Task { await fixture.model.resumeSession(session("a"), reportFailure: true) }
                let cachedMS = try await waitForLayout(fixture, generation: warmGeneration, cached: true)
                #expect(await warm.value)
                print(
                    "session_switch_fixture scenario=\(scenario) pair=\(pair) cold_ms=\(coldMS) cached_ms=\(cachedMS)")
            }
        }
    }

    /// Five cold/warm pairs; layout/display work excludes synthetic pacing sleeps.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HERM_CHAT_PROFILE"] == "1"))
    func releaseTranscriptBaseline() async throws {
        let environment = ProcessInfo.processInfo.environment
        let requestedPair = environment["HERM_CHAT_PROFILE_PAIR"].flatMap(Int.init)
        let requestedScenario = environment["HERM_CHAT_PROFILE_SCENARIO"]
        let prose = ScrollPerformanceFixture.standard.idleLongMarkdown
        let code = "```swift\n" + String(repeating: "let value = 42 // complete source line\n", count: 1_000) + "```\n"
        for scenario in ["prose", "code", "streaming"] {
            guard requestedScenario == nil || requestedScenario == scenario else { continue }
            for pair in 0..<5 {
                guard requestedPair == nil || requestedPair == pair else { continue }
                for warm in [false, true] {
                    let fixture = Fixture(
                        source: (scenario == "code" ? code : prose) + "\nScenario \(scenario) pair \(pair)",
                        streaming: scenario == "streaming")
                    defer { fixture.window.orderOut(nil) }
                    try await fixture.settle()
                    let first = try #require(fixture.coordinator.rowViewports.min { $0.index < $1.index })
                    let previousLayoutWork = fixture.layoutWorkMS
                    let parsesBefore = MarkdownRenderDocumentCache.parseCount
                    let hitsBefore = NativeMarkdownCompletedHeightCache.hits
                    let missesBefore = NativeMarkdownCompletedHeightCache.misses
                    let cpuStarted = mainThreadCPUMilliseconds()
                    let start = DispatchTime.now().uptimeNanoseconds
                    try fixture.move(to: first.minY + 20)
                    if scenario == "streaming" {
                        fixture.model.streamingText.appendPresentation("\n\nA streaming update.")
                    }
                    fixture.host.layoutSubtreeIfNeeded()
                    fixture.host.displayIfNeeded()
                    let workMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    try await fixture.settle()
                    let pageWork = workMS + fixture.layoutWorkMS - previousLayoutWork
                    let mainCPU = mainThreadCPUMilliseconds() - cpuStarted
                    print(
                        "chat_release scenario=\(scenario) pair=\(pair) warm=\(warm) step_work_ms=\(workMS) page_work_ms=\(pageWork) main_thread_cpu_ms=\(mainCPU) sync_parses=\(MarkdownRenderDocumentCache.parseCount - parsesBefore) measurement_hits=\(NativeMarkdownCompletedHeightCache.hits - hitsBefore) measurement_misses=\(NativeMarkdownCompletedHeightCache.misses - missesBefore)"
                    )
                }
            }
        }
    }
}

func mainThreadCPUMilliseconds() -> Double {
    var info = thread_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return Double(info.user_time.seconds + info.system_time.seconds) * 1_000
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000
}
