import Foundation
import Testing

@testable import Herm

@MainActor
struct NotchAssistantTests {
    @Test func parsesNamedTimerAndOrganizerCommands() {
        #expect(
            AssistantIntent.parse("Set a coffee timer for five minutes.") == .timerCreate(name: "coffee", seconds: 300))
        #expect(AssistantIntent.parse("Check the coffee timer") == .timerRemaining("coffee"))
        #expect(AssistantIntent.parse("Show my calendar tomorrow.") == .calendarAgenda(.tomorrow))
        #expect(VoicePrompts.isClosePreview("Hide the calendar."))
        #expect(AssistantIntent.parse("Add two minutes to the coffee timer") == .timerExtend("coffee", seconds: 120))
        #expect(AssistantIntent.parse("Cancel the coffee timer") == .timerCancel("coffee"))
        #expect(AssistantIntent.parse("When am I free tomorrow afternoon?") == .calendarFree(.tomorrow, .afternoon))
        #expect(
            AssistantIntent.parse("Block thirty minutes tomorrow morning for planning")
                == .calendarBlock(.tomorrow, .morning, seconds: 1_800, title: "planning"))
        #expect(
            AssistantIntent.parse("Add oat milk to my Groceries list due tomorrow")
                == .reminder(title: "oat milk", list: "Groceries", due: .tomorrow))
        #expect(
            AssistantIntent.parse("Add review the notes to my task board")
                == .task(title: "review the notes", board: nil))
        #expect(AssistantIntent.parse("Explain why the build is stuck.") == nil)
        #expect(AssistantIntent.parse("Add a changelog to the project") == nil)
    }

    @Test func externalBrowserPhrasesAreDistinctFromTheBrowserTabAndPageRequests() {
        #expect(AssistantIntent.parse("Open a browser outside Herm") == .launchBrowser(.systemDefault))
        #expect(AssistantIntent.parse("Could you please open my default browser?") == .launchBrowser(.systemDefault))
        #expect(AssistantIntent.parse("Open a standalone browser window.") == .launchBrowser(.systemDefault))
        #expect(AssistantIntent.parse("Can you please open the Chrome?") == .launchBrowser(.chrome))
        #expect(AssistantIntent.parse("Launch Google Chrome, outside of Herm.") == .launchBrowser(.chrome))
        #expect(AssistantIntent.parse("Open Firefox, not in Herm.") == .launchBrowser(.firefox))
        #expect(VoicePrompts.revealedTab("Open Browser") == .browser)
        #expect(AssistantBrowserApp.parse("Open Browser") == nil)
        #expect(AssistantBrowserApp.parse("Open a browser tab") == nil)
        #expect(AssistantBrowserApp.parse("Open example.com in Chrome outside Herm") == nil)
        #expect(AssistantBrowserApp.parse("Open Chrome outside Herm and sign in") == nil)
    }

    @Test(arguments: [false, true])
    func spokenExternalBrowserLaunchDoesNotSendChatOrSwitchTheInspector(isNotch: Bool) async throws {
        let rpc = AssistantTestRPC()
        let model = makeVoiceModel(rpc)
        defer { model.shutdown() }
        model.isNotchVoiceConversation = isNotch
        model.voiceState = .listening
        model.isHermesConnected = true
        model.voiceRepliesEnabled = false

        var launches: [AssistantBrowserApp] = []
        model.voiceAssistant.launchBrowser = { browser in
            launches.append(browser)
            return AssistantReply("Opened your browser.")
        }
        let before = rpc.requests.count
        model.finishVoiceUtterance(transcript: "Open a browser outside Herm")
        let launch = try #require(model.voiceAssistant.task)
        await launch.value

        #expect(launches == [.systemDefault])
        #expect(model.voiceSpokenCaption == "Opened your browser.")
        #expect(model.voiceState == .listening)
        #expect(model.voiceShownTab == nil)
        let chatRequests = ["prompt.submit", "session.create", "session.resume", "session.redirect", "session.steer"]
        #expect(!rpc.requests.dropFirst(before).contains { chatRequests.contains($0) })
        #expect(model.messages.isEmpty)
    }

    @Test func mapRequestShowsTheRecognizedPlaceWithoutOpeningATab() async throws {
        let model = makeVoiceModel(AssistantTestRPC())
        defer { model.shutdown() }
        model.isNotchVoiceConversation = true
        model.voiceAssistant.isLocal = true
        model.voiceState = .listening
        model.voiceRepliesEnabled = false
        var query: String?
        model.voiceAssistant.findMap = { place in
            query = place
            return RichMap(title: place, latitude: 11.24, longitude: 125.0).reply()
        }
        #expect(model.receiveAssistantRequest("Show me a map of Tacloban City."))
        await model.voiceAssistant.task?.value
        #expect(query == "Tacloban City")
        let visual = try #require(model.voiceStage.localVisual)
        #expect(RichDocument(visual.text).hasVoiceVisuals)
        #expect(visual.text.contains("Tacloban City"))
        #expect(model.voiceShownTab == nil)
        #expect(model.receiveAssistantRequest("Close the map."))
        #expect(model.voiceStage.localVisual == nil)
    }

    @Test func onlyMatchingPlacesAndValidCoordinatesCanBeShown() {
        #expect(RichMap.matches("Tacloban City", name: "Tacloban", address: ["Leyte", "Philippines"]))
        #expect(RichMap.matches("Tacloban, Philippines", name: "Tacloban City", address: ["Philippines"]))
        #expect(!RichMap.matches("Tacloban City", name: "Bonifacio Global City", address: ["Philippines"]))
        #expect(RichMap(title: "Invalid", latitude: 91, longitude: 0).reply().visual == nil)
    }

    @Test func completedReplyTablesBecomePassiveVisualsWithoutGuessingData() throws {
        let text = "Here is the schedule.\n\n| Time | Meeting |\n| --- | --- |\n| 10:00 | Design review |\n"
        let visual = try #require(VoicePassiveVisual.tablePreview(text))
        #expect(RichDocument(visual).hasVoiceVisuals)
        #expect(visual.contains("Design review"))
        #expect(VoicePassiveVisual.tablePreview("```text\n" + text + "```") == nil)
        #expect(VoicePassiveVisual.tablePreview("| A | B |\n| - | - |\n| 1 |") == nil)
    }

    @Test func voiceShowsACompletedTableWithoutChangingTheChatReply() throws {
        let defaults = UserDefaults.standard
        let key = GenerativeUIIntegration.preferenceKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }

        let model = makeVoiceModel(AssistantTestRPC())
        defer { model.shutdown() }
        let id = try #require(model.sessionID)
        model.isNotchVoiceConversation = true
        model.voiceState = .thinking
        model.voiceRepliesEnabled = false
        let answer = "There are two options.\n\n| Option | Price |\n| --- | --- |\n| A | $60 |\n| B | $80 |"
        model.handleEvent("message.complete", params: ["session_id": id, "payload": ["text": answer]])

        let preview = try #require(model.voiceGenerativeReply)
        #expect(VoicePassiveVisual.contains(preview.text))
        #expect(model.messages.last?.text == answer)
        model.dismissVoicePreview()
        #expect(model.voiceGenerativeReply == nil)
    }

    @Test func voiceShowsAnImageWithACompletedTableAndKeepsTheChatReply() throws {
        let model = makeVoiceModel(AssistantTestRPC())
        defer { model.shutdown() }
        let id = try #require(model.sessionID)
        model.isNotchVoiceConversation = true
        model.voiceState = .thinking
        model.voiceRepliesEnabled = false
        let answer = "Here is the photo.\n\nMEDIA:/tmp/city.jpg\n\n| City | Time |\n| --- | --- |\n| Oslo | Noon |"
        model.handleEvent("message.complete", params: ["session_id": id, "payload": ["text": answer]])

        let preview = try #require(model.voiceGenerativeReply)
        #expect(VoicePassiveVisual.contains(preview.text))
        #expect(VoiceReplyMedia.items(in: preview).map(\.kind) == [.image])
        #expect(model.messages.last?.text == answer)
    }

    @Test func voiceShowsOnlyMediaDeliveredInTheCurrentReply() throws {
        let model = makeVoiceModel(AssistantTestRPC())
        defer { model.shutdown() }
        let id = try #require(model.sessionID)
        model.isNotchVoiceConversation = true
        model.voiceState = .thinking
        model.voiceRepliesEnabled = false
        let answer = "Here's the clip.\n\nMEDIA:/tmp/clip.mp4"
        model.handleEvent("message.complete", params: ["session_id": id, "payload": ["text": answer]])

        let preview = try #require(model.voiceGenerativeReply)
        #expect(preview.id == model.messages.last?.id)
        #expect(VoiceReplyMedia.items(in: preview).map(\.kind) == [.video])
        model.appendChatMessage(ChatMessage(role: .user, text: "Please show something else."))
        #expect(model.voiceGenerativeReply == nil)
    }

    @Test func voiceShowsClosedVisualBeforeCompletionAndReconcilesFinalText() async throws {
        let defaults = UserDefaults.standard
        let key = GenerativeUIIntegration.preferenceKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }

        let model = makeVoiceModel(AssistantTestRPC())
        defer { model.shutdown() }
        let id = try #require(model.sessionID)
        model.isNotchVoiceConversation = true
        model.voiceState = .thinking
        model.voiceRepliesEnabled = false
        model.handleEvent("message.start", params: ["session_id": id])

        func delta(_ text: String) async {
            model.handleEvent("message.delta", params: ["session_id": id, "payload": ["delta": text]])
            model.flushStreamingMessage()
            await model.voiceStage.liveVisualTask?.value
        }

        await delta(
            """
            ```herm-ui
            {"version":1,"id":"early","title":"Results","fallback":"One result","kind":"native",
            "blocks":[{"type":"table","columns":["Name"],"rows":[["Result"]]}]}
            """)
        #expect(model.voiceGenerativeReply == nil)
        await delta("\n" + "```".dropLast(1))
        #expect(model.voiceGenerativeReply == nil)
        await delta("`")
        let early = try #require(model.voiceGenerativeReply)
        #expect(early == model.liveVoiceVisual)
        #expect(model.messages.last?.text == "")

        model.handleEvent(
            "message.complete", params: ["session_id": id, "payload": ["text": "The final answer has no table."]])
        #expect(model.voiceGenerativeReply == nil)
        #expect(model.voiceStage.liveVisual == nil)
        #expect(model.messages.last?.text == "The final answer has no table.")
    }

    @Test func spokenPreviewControlsStayLocalAndDoNotReplaceTheAnswer() throws {
        let defaults = UserDefaults.standard
        let key = GenerativeUIIntegration.preferenceKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let rpc = AssistantTestRPC()
        let model = makeVoiceModel(rpc)
        defer { model.shutdown() }
        model.isNotchVoiceConversation = true
        model.voiceAssistant.isLocal = true
        model.voiceState = .listening
        model.voiceRepliesEnabled = false
        let table = try #require(
            VoicePassiveVisual.table(title: "Results", columns: ["Item"], rows: (1...14).map { ["Item \($0)"] }))
        let message = ChatMessage(role: .hermes, text: table)
        model.voiceStage.localVisual = message
        let before = rpc.requests

        model.finishVoiceUtterance(transcript: "Show the next results.")
        #expect(model.voicePreviewPosition(for: message.id).page == 1)
        #expect(model.voiceSpokenCaption == "Showing rows 7 through 12 of 14.")
        model.finishVoiceUtterance(transcript: "Read row fourteen.")
        #expect(model.voicePreviewPosition(for: message.id).page == 2)
        #expect(model.voicePreviewPosition(for: message.id).row == 13)
        #expect(model.voiceSpokenCaption == "Row 14. Item: Item 14.")
        #expect(model.voiceGenerativeReply?.id == message.id)
        #expect(rpc.requests == before)
        #expect(model.messages.isEmpty)

        model.dismissVoicePreview()
        #expect(model.voicePreviewPosition(for: message.id) == .init())
    }

    @Test func calendarRowsUseTheSamePassivePreviewAsAgentTables() throws {
        let preview = try #require(
            VoicePassiveVisual.table(
                title: "Wednesday", columns: ["Time", "Event"],
                rows: [["All day", "Team offsite"], ["3 PM", "Review"]]))
        #expect(RichDocument(preview).hasVoiceVisuals)
        #expect(preview.contains("Team offsite"))
    }

    @Test func messageBodyPreservesPunctuationAndCasing() {
        #expect(
            AssistantIntent.parse("Draft an email to Robin subject Update saying I’m ready!")
                == .message(.mail, to: "Robin", subject: "Update", body: "I’m ready!", draftOnly: true))
        #expect(
            AssistantIntent.parse("Send a text to Robin saying Can you call?")
                == .message(.messages, to: "Robin", subject: nil, body: "Can you call?", draftOnly: false))
    }

    @Test func calculatesAndConvertsWithoutEvaluatingCode() {
        #expect(AssistantMath.answer("18 percent of 50") == "9")
        #expect(AssistantMath.answer("five divided by zero") == "Division by zero is undefined.")
        #expect(AssistantMath.answer("convert one inch to centimeters") != nil)
        #expect(
            AssistantIntent.parse("Convert five miles to kilometers")
                == .calculation("Convert five miles to kilometers"))
        #expect(AssistantIntent.parse("What is the weather?") == nil)
    }

    @Test func gapsMergeOverlappingAndClippedEvents() {
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        func interval(_ start: Double, _ end: Double) -> DateInterval {
            DateInterval(start: day.addingTimeInterval(start), end: day.addingTimeInterval(end))
        }
        let gaps = AssistantOrganizer.freeIntervals(
            in: interval(0, 160),
            blocking: [
                interval(125, 180), interval(-20, 25), interval(75, 100), interval(60, 80),
            ])
        #expect(gaps == [interval(25, 60), interval(100, 125)])
    }

    @Test func confirmationRequiresExactPhraseAndIsConsumedByTheSession() async throws {
        let session = VoiceAssistantSession()
        var submissions = 0
        let reply = AssistantReply.confirm("Readback.", phrase: "send it", requiresReadback: true) {
            submissions += 1
            return "Submitted."
        }
        session.setPending(reply.followUp)
        let answer = try #require(session.takePending())
        #expect(session.takePending() == nil)
        let retry = try await answer("yes")
        #expect(retry.requiresReadback)
        #expect(submissions == 0)
        let confirm = try #require(retry.followUp)
        let result = try await confirm("send it.")
        #expect(result.followUp == nil)
        #expect(submissions == 1)
        let cancel = try await answer("cancel")
        #expect(cancel.followUp == nil)
        #expect(submissions == 1)
    }

    @Test func expiredConfirmationsCannotBeConsumed() {
        let session = VoiceAssistantSession()
        session.setPending({ _ in AssistantReply("Expired") }, now: .now.advanced(by: .seconds(-46)))
        #expect(!session.hasPending)
        #expect(session.takePending() == nil)
    }

    @Test func draftReadbackDoesNotArmSending() async throws {
        let draft = await AssistantShortcuts.compose(
            channel: .mail, recipient: "example@example.test", subject: "Update", body: "Still here!", draftOnly: true)
        #expect(draft.text.contains("example@example.test"))
        #expect(draft.text.contains("Update"))
        #expect(draft.text.contains("Still here!"))
        let answer = try #require(draft.followUp)
        let premature = try await answer("send it")
        #expect(premature.text == draft.text)
        let discarded = try await answer("cancel")
        #expect(discarded.followUp == nil)
    }

    @Test func shortcutInventoryUsesStableIdentifiers() {
        let first = UUID()
        let second = UUID()
        let rows = AssistantShortcuts.parseInstalled(
            "An Alias (\(first.uuidString))\nUnidentified\nAn Alias\t\(second.uuidString)\n")
        #expect(rows.map(\.id) == [first, second])
        #expect(rows.map(\.name) == ["An Alias", "An Alias"])
    }

    @Test func commandPaletteStartsNotchVoiceAndLeavesTheWorkspaceAlone() async throws {
        let rpc = AssistantTestRPC()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            initialSessionID: "workspace", botActivityFileURL: root.appendingPathComponent("bots.json"), rpcClient: rpc)
        workspace.draft = "Work in progress"
        workspace.defaults.set(false, forKey: NotchDisplayStyle.enabledKey)
        let controller = EdgeDockController(
            model: workspace, controlCenter: ControlCenterModel(), defaults: workspace.defaults,
            openQuota: {}, openKanban: { _ in }, openDock: {}, startsRuntime: false)
        defer {
            controller.shutdown()
            workspace.shutdown()
        }
        _ = workspace.voiceCapture.claim(workspace)
        workspace.voiceState = .localFallback("Workspace voice fallback")
        let notch = try #require(workspace.voiceCapture.standby)
        notch.voiceAssistant.hasRecognition = { true }
        let startVoice = try #require(workspace.voiceCapture.onStartNotchVoice)

        startVoice()
        await notch.voiceAssistant.task?.value
        #expect(workspace.voiceCapture.owner === notch)
        startVoice()
        #expect(notch.voiceState == .listening)
        notch.voiceRepliesEnabled = false
        notch.finishVoiceUtterance(transcript: "What is two plus two?")
        await notch.voiceAssistant.task?.value
        #expect(notch.voiceSpokenCaption == "4")
        #expect(notch.voiceState == .listening)
        #expect(rpc.requests.allSatisfy { $0 == "groups.capabilities" })
        #expect(notch.sessionID == nil)
        #expect(workspace.sessionID == "workspace")
        #expect(workspace.draft == "Work in progress")
        notch.finishVoiceUtterance(transcript: "Stop.")
        #expect(notch.voiceState == .inactive)
        #expect(workspace.voiceCapture.owner == nil)
    }

    @Test func minimizingVoiceLetsHoverShowTheQuickPreviewWithoutEndingTheCall() async throws {
        let workspace = makeVoiceModel(AssistantTestRPC())
        workspace.defaults.set(true, forKey: NotchDisplayStyle.enabledKey)
        let controller = EdgeDockController(
            model: workspace, controlCenter: ControlCenterModel(), defaults: workspace.defaults,
            openQuota: {}, openKanban: { _ in }, openDock: {}, startsRuntime: false)
        defer {
            controller.shutdown()
            controller.panel.orderOut(nil)
            workspace.shutdown()
        }
        let notch = try #require(workspace.voiceCapture.standby)
        let host = try #require(controller.panel.contentView?.subviews.first as? EdgeDockHostingView<EdgeNotchView>)
        _ = workspace.voiceCapture.claim(notch)
        notch.isVoiceMicMuted = true
        notch.voiceState = .listening
        controller.restoreNotch()
        #expect(controller.state.voiceLive)
        #expect(controller.state.expanded)

        controller.minimizeVoiceStage()
        #expect(!controller.state.voiceLive)
        #expect(!controller.state.expanded)
        #expect(workspace.voiceCapture.owner === notch)
        controller.startRuntime()
        host.onHoverChanged?(true)
        for _ in 0..<100 where !controller.state.expanded { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.state.expanded)
        #expect(!controller.state.voiceLive)
        #expect(notch.voiceState == .listening)

        controller.toggleVoiceFromPreview()
        #expect(controller.state.voiceLive)
        #expect(controller.state.minimizedVoiceModel == nil)
        controller.minimizeVoiceStage()
        notch.stopVoiceConversation()
        controller.restoreNotch()
        #expect(controller.state.minimizedVoiceModel == nil)
    }

    @Test func pausedNotchWakesAfterAnUtteranceWithNoWords() async {
        let workspace = makeVoiceModel(AssistantTestRPC())
        workspace.defaults.set(true, forKey: VoiceAcknowledgment.acknowledgesKey)
        let projection = EdgeQuickConversationModel()
        let notch = projection.prepareVoice(runtime: workspace)
        defer {
            projection.shutdown()
            workspace.shutdown()
        }
        notch.voiceAssistant.hasRecognition = { true }
        notch.voiceAssistant.isLocal = true
        notch.voiceState = .paused

        let acknowledgment = VoiceQueuePlayback()
        notch.voiceAssistant.acknowledgmentPlayback = acknowledgment
        let microphoneStatus = notch.voiceMic.errorMessage
        notch.voiceMic.onUtteranceEnd?(nil)
        #expect(notch.voiceState == .paused)
        #expect(notch.voiceMic.errorMessage == microphoneStatus)

        notch.finishVoiceUtterance(transcript: "Hey \(notch.voiceWakeName)")
        #expect(notch.voiceState == .listening)
        #expect(notch.wakeCount == 1)
        await notch.voiceAssistant.acknowledgmentTask?.value
        #expect(acknowledgment.localSpeeches == ["I’m listening."])
        #expect(notch.voiceAssistant.task == nil)
        #expect(notch.voiceSpeechQueue.isEmpty)
        #expect(notch.voiceSpokenCaption == nil)
        #expect(notch.sessionID == nil)
    }

    @Test func repeatedWakePhraseIsSpokenWithoutStartingAnotherTurn() async {
        let workspace = makeVoiceModel(AssistantTestRPC())
        workspace.defaults.set(true, forKey: VoiceAcknowledgment.acknowledgesKey)
        let projection = EdgeQuickConversationModel()
        let notch = projection.prepareVoice(runtime: workspace)
        defer {
            projection.shutdown()
            workspace.shutdown()
        }
        let acknowledgment = VoiceQueuePlayback()
        notch.voiceAssistant.acknowledgmentPlayback = acknowledgment
        notch.voiceAssistant.isLocal = true
        notch.voiceState = .listening
        let wake = "Hey \(notch.voiceWakeName)"

        for _ in 0..<2 {
            notch.finishVoiceUtterance(transcript: wake)
            await notch.voiceAssistant.acknowledgmentTask?.value
        }

        notch.finishVoiceUtterance(transcript: "I’m listening.", overPlayback: true)
        notch.finishVoiceUtterance(transcript: wake, overPlayback: true)
        workspace.defaults.set(false, forKey: VoiceAcknowledgment.acknowledgesKey)
        notch.finishVoiceUtterance(transcript: wake)
        await notch.voiceAssistant.acknowledgmentTask?.value

        #expect(acknowledgment.localSpeeches == ["I’m listening.", "I’m listening."])
        #expect(notch.voiceState == .listening)
        #expect(notch.voiceAssistant.task == nil)
        #expect(notch.messages.isEmpty)
        #expect(notch.sessionID == nil)
    }

    @Test func acknowledgmentRespectsTheWorkspaceSettingAndMutedReplies() async {
        let workspace = makeVoiceModel(AssistantTestRPC())
        let projection = EdgeQuickConversationModel()
        let notch = projection.prepareVoice(runtime: workspace)
        defer {
            projection.shutdown()
            workspace.shutdown()
        }
        let key = VoiceAcknowledgment.acknowledgesKey
        let acknowledgment = VoiceQueuePlayback()
        notch.voiceAssistant.acknowledgmentPlayback = acknowledgment
        notch.voiceAssistant.generateAcknowledgment = { _ in nil }
        notch.voiceAssistant.launchBrowser = { _ in AssistantReply("Opened Chrome.") }
        notch.voiceAssistant.isLocal = true
        notch.voiceState = .listening

        workspace.defaults.set(true, forKey: key)
        notch.acknowledgeVoiceRequest("Open Chrome outside Herm")
        await notch.voiceAssistant.acknowledgmentTask?.value
        #expect(acknowledgment.localSpeeches == ["Understood."])

        notch.toggleVoiceReplies()
        notch.finishVoiceUtterance(transcript: "Open Chrome outside Herm")
        await notch.voiceAssistant.task?.value
        notch.finishVoiceUtterance(transcript: "Hey \(notch.voiceWakeName)")
        #expect(notch.voiceAssistant.acknowledgmentTask == nil)
        #expect(acknowledgment.localSpeeches == ["Understood."])
        #expect(notch.voiceSpokenCaption == "Opened Chrome.")

        notch.toggleVoiceReplies()
        workspace.defaults.set(false, forKey: key)
        notch.acknowledgeVoiceRequest("Open Chrome outside Herm")
        notch.finishVoiceUtterance(transcript: "Hey \(notch.voiceWakeName)")
        #expect(notch.voiceAssistant.acknowledgmentTask == nil)
        #expect(acknowledgment.localSpeeches == ["Understood."])
    }

    @Test func voiceChromeUsesHermWhenTheConfiguredBotHasItsOwnName() {
        let workspace = makeVoiceModel(AssistantTestRPC())
        defer { workspace.shutdown() }
        workspace.defaultBotName = "Juniper"
        workspace.voiceState = .speaking
        workspace.voiceSpokenCaption = "Ready."

        let stage = VoiceStagePresentation(model: workspace)
        #expect(stage.widgetStatus == "Speaking")
        #expect(stage.statusText == "HERM IS SPEAKING")
        #expect(workspace.agentRecognitionName == "Juniper")
    }

    @Test func busyNotchKeepsMessagesAndConfirmationsOutOfTheRunningHermesTurn() {
        let rpc = AssistantTestRPC()
        let workspace = makeVoiceModel(rpc)
        let projection = EdgeQuickConversationModel()
        let notch = projection.prepareVoice(runtime: workspace)
        defer {
            projection.shutdown()
            workspace.shutdown()
        }
        notch.isHermesConnected = true
        notch.sessionID = "running"
        notch.voiceSessionID = "running"
        notch.voiceState = .thinking
        notch.status = .working
        notch.isSending = true
        let before = rpc.requests

        notch.defaultBotName = "Juniper"
        notch.finishVoiceUtterance(transcript: "Hey Juniper")
        #expect(notch.queuedPrompts.isEmpty)
        #expect(!notch.hasQueuedOrRedirectingPrompt)
        #expect(rpc.requests == before)

        notch.finishVoiceUtterance(transcript: "Send a text to Robin saying Can you call?")
        notch.finishVoiceUtterance(transcript: "send it.")
        #expect(notch.voiceSpokenCaption == VoiceAssistantSession.busyMessage)
        #expect(notch.queuedPrompts.isEmpty)
        #expect(!notch.hasQueuedOrRedirectingPrompt)
        #expect(notch.draft.isEmpty)
        #expect(rpc.requests == before)

        notch.finishVoiceUtterance(transcript: "Hey Juniper, actually check the test results.")
        #expect(notch.hasQueuedOrRedirectingPrompt)
    }

    @Test func aMutedReadbackNeverArmsSending() async {
        let workspace = makeVoiceModel(AssistantTestRPC())
        defer { workspace.shutdown() }
        workspace.voiceRepliesEnabled = false
        let reply = AssistantReply.confirm("Readback.", phrase: "send it", requiresReadback: true) {
            Issue.record("A muted confirmation must never submit a message.")
            return "Submitted."
        }
        await workspace.completeAssistantReply(reply, generation: workspace.voiceConversationGeneration)
        #expect(workspace.voiceAssistant.takePending() == nil)
        #expect(workspace.voiceSpokenCaption == "Turn on voice replies and ask to send the message again.")
        #expect(workspace.voiceState == .listening)
    }

    @Test func workSummaryUsesTheApprovalQueueAndBoundedCompletedReplies() async throws {
        let rpc = AssistantTestRPC()
        let workspace = makeVoiceModel(rpc)
        defer { workspace.shutdown() }
        workspace.isHermesConnected = true
        workspace.approvalText = "Review access"
        workspace.approvalTitle = "Approve publishing"
        let control = ControlCenterModel()
        control.dockModel = workspace
        control.rpc = HermesControlRPC(client: rpc)
        let approvals = await control.voiceWork(.approvals)
        #expect(approvals.text.contains("Approve publishing"))

        let now = Calendar.current.startOfDay(for: .now).addingTimeInterval(15 * 60 * 60)
        let timestamp = now.timeIntervalSince1970
        func rows(_ json: String) throws -> [[String: Any]] {
            try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        }
        rpc.history = try rows(
            """
            [
                {"id":"done","title":"Morning report","profile":"work","last_active":\(timestamp - 60)},
                {"id":"tool","title":"Still working","last_active":\(timestamp)},
                {"id":"failed","title":"Failed job","last_active":\(timestamp - 5)},
                {"id":"old","title":null,"last_active":\(timestamp - 86_400)}
            ]
            """)
        rpc.messageRows["done"] = try rows(
            """
            [
                {"id":1,"role":"assistant","content":"Done.","timestamp":\(timestamp - 60),
                 "tool_calls":null,"tool_name":null,"display_kind":null},
                {"id":2,"role":"assistant","content":"Ready.","timestamp":\(timestamp - 120),
                 "tool_calls":null,"tool_name":null}
            ]
            """)
        rpc.messageRows["failed"] = try rows(
            """
            [
                {"id":3,"role":"assistant","content":"The turn failed.","timestamp":\(timestamp - 5),
                 "tool_calls":null,"tool_name":null,"display_kind":"failed_turn"},
                {"id":4,"role":"tool","timestamp":\(timestamp - 6),"tool_calls":null,"tool_name":"Response"}
            ]
            """)
        rpc.messageRows["tool"] = (0..<12).map { index in
            [
                "id": 10 + index, "role": "tool", "tool_name": "search",
                "timestamp": timestamp - Double(index), "tool_calls": NSNull(),
            ]
        }
        let completed = await control.voiceWork(.activity(sinceLunch: false), now: now)
        #expect(completed.text == "Completed replies today. Morning report.")
        #expect(rpc.httpPaths.first == "/api/sessions?limit=24&offset=0&order=recent")
        #expect(rpc.httpPaths.count == 4)
        #expect(
            rpc.httpPaths.contains("/api/sessions/done/messages?limit=40&order=latest&profile=work&inline_images=false")
        )
        #expect(control.latestActivities.isEmpty)

        rpc.messageRows["tool"] = nil
        let partial = await control.voiceWork(.activity(sinceLunch: true), now: now)
        #expect(partial.text.contains("Morning report: Response"))
        #expect(partial.text.contains("Failed job: Failed turn"))
        #expect(partial.text.contains("I could only check part of the recent history."))

        rpc.messageRows.removeAll()
        let unavailable = await control.voiceWork(.activity(sinceLunch: false), now: now)
        #expect(unavailable.text == "I couldn't load recent activity.")
    }

    private func makeVoiceModel(_ rpc: AssistantTestRPC) -> DockModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DockModel(
            sessionAgentStateFileURL: root.appendingPathComponent("agents.json"),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            initialSessionID: "approval", botActivityFileURL: root.appendingPathComponent("bots.json"),
            rpcClient: rpc)
    }

    @Test func onlyHermTimersCanBeCancelledFromTheCountdown() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let deadline = now.addingTimeInterval(300)
        let schedule = ISO8601DateFormatter().string(from: deadline)
        let ordinary = CronSummary(
            id: "ordinary", name: "Other job", schedule: "once", enabled: true, nextRun: schedule)
        let herm = CronSummary(
            id: "herm", name: "Coffee", schedule: "once", enabled: true, nextRun: schedule,
            details: CronJobDetails(script: AssistantTimers.scriptName, noAgent: true))
        let board = VoiceTimerBoard(now: { now })
        board.update([ordinary, herm])
        var cancelled: [String] = []
        board.onCancel = { cancelled.append($0.id) }
        let ordinaryTimer = try #require(board.timers.first { $0.id == ordinary.id })
        let hermTimer = try #require(board.timers.first { $0.id == herm.id })
        #expect(!ordinaryTimer.canCancel)
        #expect(hermTimer.canCancel)
        board.cancel(ordinaryTimer)
        board.cancel(hermTimer)
        board.update([ordinary])
        board.cancel(hermTimer)
        #expect(cancelled == ["herm"])
    }

    @Test func aJobThatStoppedBeingAHermTimerCannotBeDeletedFromTheNotch() async throws {
        let rpc = AssistantTestRPC()
        let control = ControlCenterModel()
        control.rpc = HermesControlRPC(client: rpc)
        control.recordProjectionSuccess("cron.jobs")
        let deadline = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) + 300)
        let schedule = ISO8601DateFormatter().string(from: deadline)
        let cached = CronSummary(
            id: "timer", name: "Coffee", schedule: "once", enabled: true, nextRun: schedule,
            details: CronJobDetails(script: AssistantTimers.scriptName, noAgent: true))
        control.cronJobs = [cached]
        rpc.liveCronJob = [
            "id": cached.id, "name": cached.name, "prompt": "Normal automation",
            "schedule": ["kind": "once", "display": "once at a time"],
            "enabled": true, "next_run_at": schedule,
        ]

        let timer = try #require(VoiceTimerBoard.projectTimer(cached))
        control.cancelVoiceTimer(timer)
        for _ in 0..<50 where !control.pendingActionIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(rpc.httpPaths == ["/api/cron/jobs/timer"])
        #expect(control.pendingActionIDs.isEmpty)
        #expect(control.routineActionErrors.values.first?.contains("This timer changed.") == true)
        #expect(rpc.post == nil)
    }

    @Test func timerTransportSendsOnlyTheScopedNoAgentContract() async throws {
        let rpc = AssistantTestRPC()
        let transport = HermesControlRPC(client: rpc)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let deadline = now.addingTimeInterval(300)
        let schedule = ISO8601DateFormatter().string(from: deadline)
        let created = try await transport.createAssistantTimer(name: "Coffee", schedule: schedule, profileID: "test")
        #expect(AssistantTimers.due(created, now: now) == deadline)
        #expect(rpc.post?.path == "/api/cron/jobs?profile=test")
        #expect(rpc.post?.body["repeat"] as? Int == 1)
        #expect(rpc.post?.body["no_agent"] as? Bool == true)
        #expect(rpc.post?.body["script"] as? String == AssistantTimers.scriptName)
        #expect(rpc.post?.body["schedule"] as? String == schedule)
        #expect(
            AssistantTimers.due(
                CronSummary(
                    id: "other", name: "Coffee", schedule: "once",
                    enabled: true, nextRun: schedule), now: now) == nil)
    }
}

@MainActor
private final class AssistantTestRPC: HermesRPCClientProtocol {
    var onEvent: ((String, [String: Any]) -> Void)?
    var requests: [String] = []
    var liveCronJob: [String: Any]?
    var history: [[String: Any]] = []
    var messageRows: [String: [[String: Any]]] = [:]
    var httpPaths: [String] = []
    var post: (path: String, body: [String: Any])?

    func connect() async throws { requests.append("connect") }
    func close() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        requests.append(method)
        return [:]
    }

    func fetchHTTP(_ path: String) async throws -> [String: Any] {
        httpPaths.append(path)
        if path.hasPrefix("/api/cron/jobs/"), let liveCronJob { return liveCronJob }
        if path.hasPrefix("/api/sessions?") {
            return ["sessions": history, "total": history.count]
        }
        let id = path.split(separator: "/").dropFirst(2).first.map(String.init)
        guard let id, let rows = messageRows[id] else { throw HermesGateway.GatewayError.httpError(503) }
        return ["messages": rows]
    }

    func sendHTTP(_ method: String, path: String, body: [String: Any]) async throws -> [String: Any] {
        post = (path, body)
        return [
            "id": "timer", "name": "Coffee", "prompt": "", "profile": "test",
            "schedule": ["kind": "once", "display": "once at a time"],
            "enabled": true, "next_run_at": body["schedule"] as? String ?? "",
            "script": AssistantTimers.scriptName, "no_agent": true,
        ]
    }
}
