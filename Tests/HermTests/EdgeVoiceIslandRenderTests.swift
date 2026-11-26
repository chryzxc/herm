import AppKit
import SwiftUI
import Testing

@testable import Herm

/// Env-gated snapshot of the real voice widget panel, so its size and look are checked, not assumed.
@MainActor
struct EdgeVoiceIslandRenderTests {
    @Test func detachedCardStaysCenteredBelowTheTopWidget() {
        let widget = NSRect(x: 310, y: 650, width: 580, height: 150)
        let placement = EdgeVoicePreviewPlacement(
            widget: widget, side: .top, visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 776))
        let frame = placement.frame(height: 300)
        #expect(frame.width == 640)
        #expect(frame.midX == widget.midX)
        #expect(frame.maxY == widget.minY - EdgeVoicePreviewPlacement.gap)
    }

    @Test(arguments: [EdgeDockSide.left, .right])
    func detachedCardFitsBesideEitherSideWidget(side: EdgeDockSide) {
        let screen = NSRect(x: -1024, y: 40, width: 1024, height: 650)
        let widget = NSRect(x: side == .left ? screen.minX : screen.maxX - 420, y: 65, width: 420, height: 150)
        let placement = EdgeVoicePreviewPlacement(widget: widget, side: side, visibleFrame: screen)
        let frame = placement.frame(height: 550)
        #expect(screen.contains(frame))
        #expect(frame.width < 640)
        #expect(!widget.intersects(frame))
        #expect((side == .left ? frame.minX - widget.maxX : widget.minX - frame.maxX) == 12)
    }

    @Test func narrowDisplayMovesTheCardClearOfTheSideWidget() {
        let screen = NSRect(x: 0, y: 0, width: 640, height: 600)
        let widget = NSRect(x: 220, y: 16, width: 420, height: 140)
        let placement = EdgeVoicePreviewPlacement(widget: widget, side: .right, visibleFrame: screen)
        let frame = placement.frame(height: 300)
        #expect(screen.contains(frame))
        #expect(frame.minY == widget.maxY + 12)
        #expect(frame.width > 500)
    }

    @Test func widgetHugsItsContentAndRenders() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VOICE_WIDGET_SNAPSHOT_DIR"] else { return }
        let model = DockModel(
            sessionAgentStateFileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "voice-widget-\(UUID().uuidString).json"),
            initialSessionID: "voice-widget")
        defer { model.shutdown() }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let island = EdgeVoiceIsland(model: model)
        let states: [(String, HermesVoiceState, String, String?, String?)] = [
            ("listening-empty", .listening, "", nil, nil),
            ("listening", .listening, "What's on my calendar this afternoon", nil, nil),
            ("thinking", .thinking, "", nil, nil),
            ("compacting", .thinking, "", nil, nil),
            ("speaking", .speaking, "", "You have two meetings: design review at 2 and a 1:1 with Sam at 4.", nil),
            ("synthesis-gap", .speaking, "", nil, nil),
            ("speaking-next", .speaking, "", "Your afternoon ends at five.", nil),
            ("mic-error", .listening, "", nil, "Microphone permission is required."),
        ]
        for (name, state, heard, caption, error) in states {
            model.voiceState = state
            model.voiceSpokenCaption = caption
            model.compactingSessionID = name == "compacting" ? model.sessionID : nil
            island.show(true)
            try await Task.sleep(for: .milliseconds(200))
            // Set after capture setup, which clears these in the test host.
            model.voiceMic.showForSnapshot(transcript: heard, level: heard.isEmpty ? 0.1 : 0.55, errorMessage: error)
            try await Task.sleep(for: .seconds(1.2))
            let panel = try #require(island.panel)
            let view = try #require(panel.contentView)
            // The bug this guards: the panel ran down the whole screen.
            #expect(panel.frame.height < 400)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("voice-widget-\(name).png"))
            print("voice-widget \(name): \(panel.frame)")
        }
        island.show(false)
    }

    @Test func embeddedVoiceStageRendersAtTopAndSideWidths() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VOICE_WIDGET_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = DockModel(
            defaults: UserDefaults(suiteName: "voice-notch-\(UUID())")!, loadArchives: false)
        defer { model.shutdown() }
        model.isNotchVoiceConversation = true
        model.voiceState = .listening
        model.voiceMic.showForSnapshot(
            transcript: "What’s on my calendar this afternoon?", level: 0.5, errorMessage: nil)

        for side in [EdgeDockSide.top, .right] {
            let state = EdgeNotchState()
            state.side = side
            state.expanded = true
            state.voicePreviewModel = model
            let size = state.panelSize
            let content = EdgeNotchView(
                state: state, controlCenter: ControlCenterModel(), notchVoiceModel: model,
                onMinimizeVoice: {}, openDock: {}
            )
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = EdgeNotchState.themeSurface(for: side).windowAppearance
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            window.setContentSize(state.panelSize)
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()

            #expect(state.voiceHeight < 160)
            #expect(state.openSize.width == (side == .top ? EdgeVoiceIsland.width : EdgeNotchState.voiceSideWidth))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("voice-notch-\(side.rawValue).png"))
        }
    }

    @Test func embeddedChoicesStayInTheWidgetAndVisualRepliesUseASeparatePanel() async throws {
        let defaults = UserDefaults.standard
        let key = GenerativeUIIntegration.preferenceKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let model = DockModel(
            defaults: UserDefaults(suiteName: "voice-preview-\(UUID())")!, loadArchives: false)
        defer { model.shutdown() }
        model.isNotchVoiceConversation = true
        model.voiceAssistant.hasRecognition = { false }
        model.voiceState = .listening
        model.voiceMic.showForSnapshot(transcript: "", level: 0.1, errorMessage: nil)

        let root = EdgeVoiceWidget(
            model: model, mic: model.voiceMic, bots: model.botMode, shown: true,
            inNotch: true
        )
        .frame(width: EdgeNotchState.voiceSideWidth)
        .fixedSize(horizontal: false, vertical: true)
        .dockThemedRoot(surface: .cameraNotch)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = DockThemeStore.notchAppearance
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func measure(_ name: String) async throws -> CGFloat {
            try await Task.sleep(for: .milliseconds(300))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["VOICE_WIDGET_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("voice-widget-\(name).png"))
            }
            return host.fittingSize.height
        }

        let empty = try await measure("no-preview")
        model.approvalText = "Run the project’s tests"
        model.status = .needsApproval
        let approval = try await measure("approval-caption")
        model.approvalText = nil
        model.status = .needsClarification
        model.clarificationQuestion = "Which report should I use?"
        let question = try await measure("clarification-caption")
        model.clarificationRequestID = "example-choice"
        let labels = ["Weekly overview", "Full monthly report", "Comparison of both reporting periods"]
        model.clarificationChoices = labels
        model.clarificationProgress = "Question 1 of 2"
        let choices = try await measure("clarification-choices")
        #expect(choices > question + 40)
        #expect(model.voiceStage.snapshot.clarificationPreview?.choices == labels)
        #expect(model.voiceStage.snapshot.clarificationPreview?.progress == "Question 1 of 2")
        #expect(model.voiceStage.snapshot.clarificationPreview?.hint == nil)
        model.clarificationRequestID = nil
        let resolved = try await measure("clarification-resolved")
        #expect(abs(resolved - question) <= 1)
        #expect(model.voiceStage.snapshot.clarificationPreview == nil)
        model.clarificationQuestion = nil
        model.status = .idle
        model.valuePrompt = ValuePrompt.from(payload: ["request_id": "secure", "method": "sudo"])
        let secure = try await measure("secure-input-caption")
        let compactHeight = max(empty, approval, question, secure)
        #expect(compactHeight < 160)

        model.valuePrompt = nil
        let noticeFreeHeight = try await measure("voice-caption")
        let island = EdgeVoiceIsland(model: model)
        defer { island.show(false) }
        let widget = NSRect(x: 310, y: 650, width: 580, height: noticeFreeHeight)
        let placement = EdgeVoicePreviewPlacement(
            widget: widget, side: .top, visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        island.show(true, attachedTo: placement)
        let table = try #require(
            VoicePassiveVisual.table(title: "Results", columns: ["Option"], rows: [["A"], ["B"], ["C"]]))
        model.voiceStage.localVisual = ChatMessage(role: .hermes, text: table)
        let withVisual = try await measure("detached-voice-caption")
        #expect(abs(withVisual - noticeFreeHeight) <= 1)
        #expect(island.panel == nil)
        let preview = try #require(island.previewPanel)
        for _ in 0..<50 where !preview.isVisible { try await Task.sleep(for: .milliseconds(20)) }
        #expect(preview.isVisible)
        #expect(preview.frame.maxY == widget.minY - EdgeVoicePreviewPlacement.gap)
        #expect(preview.frame.width == 640)
        if let directory = ProcessInfo.processInfo.environment["VOICE_WIDGET_SNAPSHOT_DIR"],
            let view = preview.contentView
        {
            try await Task.sleep(for: .milliseconds(700))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("detached-voice-result.png"))
        }
        let movedWidget = widget.offsetBy(dx: 0, dy: -24)
        island.moveAttachedPreview(
            to: EdgeVoicePreviewPlacement(
                widget: movedWidget, side: .top, visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 800)))
        #expect(island.previewPanel === preview)
        #expect(preview.frame.maxY == movedWidget.minY - EdgeVoicePreviewPlacement.gap)
        island.show(false)
        for _ in 0..<50 where preview.isVisible { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!preview.isVisible)
    }

    @Test func previewStaysVisibleWhenCompletionRewritesTheSpokenSummary() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let key = GenerativeUIIntegration.preferenceKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let model = DockModel(
            defaults: UserDefaults(suiteName: "voice-preview-\(UUID())")!,
            initialSessionID: "preview-handoff", loadArchives: false)
        defer { model.shutdown() }
        model.isNotchVoiceConversation = true
        model.voiceState = .thinking
        model.voiceRepliesEnabled = false
        let chart = """
            ```herm-ui
            {"version":1,"id":"comparison","title":"Totals","fallback":"Two totals","kind":"native",
            "blocks":[{"type":"chart","style":"bar","points":[{"label":"A","value":1},{"label":"B","value":2}]}]}
            ```
            """
        model.handleEvent("message.start", params: ["session_id": "preview-handoff"])
        model.handleEvent(
            "message.delta",
            params: ["session_id": "preview-handoff", "payload": ["delta": "I found two totals.\n\n" + chart]])
        model.flushStreamingMessage()
        await model.voiceStage.liveVisualTask?.value
        let live = try #require(model.voiceGenerativeReply)
        #expect(live == model.liveVoiceVisual)

        func card(_ message: ChatMessage) -> some View {
            VoiceGenerativeCard(model: model, message: message, maxWidth: 360)
                .frame(width: 360)
                .fixedSize(horizontal: false, vertical: true)
        }
        let host = NSHostingView(rootView: card(live))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<100 where host.fittingSize.height < 100 {
            try await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
        let liveHeight = host.fittingSize.height
        try #require(liveHeight >= 100)

        model.handleEvent("message.complete", params: ["session_id": "preview-handoff", "payload": ["text": chart]])
        let complete = try #require(model.voiceGenerativeReply)
        #expect(complete.id == live.id)
        #expect(model.liveVoiceVisual == nil)
        host.rootView = card(complete)
        host.layoutSubtreeIfNeeded()
        // Inspect the first layout, before an asynchronous parse could refill it.
        #expect(abs(host.fittingSize.height - liveHeight) < 1)
    }

    @Test func botFaceOrbRendersEachMood() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VOICE_WIDGET_SNAPSHOT_DIR"] else { return }
        let reading = VoiceMeterReading()
        reading.level = 0.4
        let helpers = ["Scout", "Builder"].map {
            HermesSubagent(id: $0, name: $0, goal: "Look things up", status: "running")
        }
        let modes: [VoiceOrbMode] = [.idle, .listening, .thinking, .speaking]
        let row = HStack(spacing: 18) {
            ForEach(modes.indices, id: \.self) { index in
                EdgeVoiceWidgetOrb(level: reading, mode: modes[index], tint: Color.dockAccent, faceID: "default")
            }
            EdgeVoiceHelperFaces(agents: helpers)
        }
        .padding(16).background(Color.black).dockThemedRoot(surface: .cameraNotch)
        let host = NSHostingView(rootView: row)
        host.appearance = DockThemeStore.notchAppearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("voice-widget-faces.png"))
    }
}
