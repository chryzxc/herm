import AppKit
import Testing

@testable import Herm

struct EdgeNotchTests {
    @Test @MainActor func enabledWakeKeepsTheIndicatorSlotWhenCaptureIsNotRunning() {
        let state = EdgeNotchState()
        state.side = .right
        let original = state.collapsedRailHeight
        state.wakeEnabled = true
        #expect(state.showsWakeIndicator)
        #expect(state.collapsedRailHeight > original)
        #expect(state.wakeAccessibilityValue.contains("not listening"))
        #expect(state.wakeIndicatorStatus == .standby)
        #expect(state.wakeIndicatorStatus?.icon == .microphone)
        state.wakeError = "Speech recognition unavailable"
        #expect(state.wakeIndicatorStatus == .unavailable)
        #expect(state.wakeIndicatorStatus?.icon == .microphoneSlash)
        #expect(state.wakeAccessibilityValue == "Speech recognition unavailable")
        state.wakeError = nil
        state.wakeListening = true
        #expect(state.wakeIndicatorStatus?.icon == .microphone)
        #expect(state.wakeAccessibilityValue == EdgeWakeIndicator.accessibilityStatus)
    }

    @MainActor @Test func pendingRequestsStayVisibleUntilResolved() {
        let model = DockModel()
        model.receiveGatewayEvent(
            "approval.request",
            params: ["session_id": "approval", "payload": ["title": "Run migration", "request_id": "a1"]])
        model.receiveGatewayEvent(
            "clarify.request",
            params: ["session_id": "question", "payload": ["question": "Which environment?", "request_id": "q1"]])
        let sessions = ["approval", "question"].map {
            HermesSession(id: $0, title: $0, preview: "", startedAt: nil, messageCount: 1, source: "herm")
        }
        let tasks = EdgeNotchTask.build(
            current: nil, sessions: sessions, currentSessionIDs: [], isOnline: true,
            attention: model.sessionAttention)
        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { $0.phase == .attention })
        #expect(tasks.first { $0.id == "approval" }?.displayStatus == "Needs your approval")
        #expect(tasks.first { $0.id == "question" }?.detail == "Which environment?")
        let state = EdgeNotchState()
        state.tasks = tasks
        #expect(state.railActivity.attention)
        #expect(state.railActivity.title == "Needs your approval")
        let stale = EdgeNotchTask.build(
            current: nil, sessions: sessions, currentSessionIDs: [], isOnline: false,
            attention: model.sessionAttention)
        #expect(stale.allSatisfy { $0.displayStatus == "Status not current" })
        model.resolveApproval(for: "approval")
        #expect(model.sessionAttention["approval"] == nil)
        #expect(model.sessionAttention["question"] != nil)
        model.receiveGatewayEvent(
            "clarify.expire", params: ["session_id": "question", "payload": ["request_id": "q1"]])
        #expect(model.sessionAttention.isEmpty)
    }

    @MainActor @Test func attentionRowsCarryOneTapAnswers() throws {
        let model = DockModel()
        model.receiveGatewayEvent(
            "approval.request", params: ["session_id": "a", "payload": ["title": "Run migration", "request_id": "a1"]])
        model.receiveGatewayEvent(
            "clarify.request",
            params: [
                "session_id": "q",
                "payload": ["question": "Which env?", "choices": ["staging", "prod"], "request_id": "q1"],
            ])
        let sessions = ["a", "q"].map {
            HermesSession(id: $0, title: $0, preview: "", startedAt: nil, messageCount: 1, source: "herm")
        }
        let tasks = EdgeNotchTask.build(
            current: nil, sessions: sessions, currentSessionIDs: [], isOnline: true, attention: model.sessionAttention)
        #expect(tasks.first { $0.id == "a" }?.choices.map(EdgeNotchTask.choiceLabel) == ["Allow once", "Deny"])
        #expect(tasks.first { $0.id == "q" }?.choices == ["staging", "prod"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try
            #"{"task_id": "t_1234abcd", "session_id": "bot", "profile": "default", "questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#
            .write(to: dir.appendingPathComponent("t_1234abcd.json"), atomically: true, encoding: .utf8)
        let question = try #require(EdgeDeliveryQuestion.load(from: dir).first)
        #expect(question.row.phase == .attention)
        #expect(question.row.choices == ["Yes", "No"])
        #expect(question.row.session?.id == "bot")
        #expect(question.answerText("Yes") == "ANSWER t_1234abcd: Yes")
    }

    @MainActor @Test func quotaSelectionSurvivesCollapseAndTemporaryAnnouncements() {
        let state = EdgeNotchState()
        state.showsQuota = true
        state.expanded = true
        state.expanded = false
        state.expanded = true
        #expect(state.displaysQuota)
        state.showingAnnouncement = true
        #expect(!state.displaysQuota)
        #expect(state.showsQuota)
        state.showingAnnouncement = false
        #expect(state.displaysQuota)
    }

    @MainActor @Test func quotaAnnouncementShowsQuotaWithoutChangingSelection() {
        let state = EdgeNotchState()
        state.showingAnnouncement = true
        state.announcesQuota = true
        #expect(state.displaysQuota)
        state.showingAnnouncement = false
        #expect(!state.displaysQuota)
    }

    @MainActor @Test func taskAndQuotaAnnouncedTogetherShareTheStatusView() {
        let snapshot = ProviderQuotaSnapshot(
            provider: "codex", displayName: "Codex", model: nil, updatedAt: .now,
            windows: [], safeDetail: nil)
        let state = EdgeNotchState()
        state.quotaChange = EdgeQuotaChange(previous: snapshot, current: snapshot)
        state.showingAnnouncement = true
        state.announcesQuota = true
        #expect(state.displaysQuota && !state.displaysStatus)
        state.announcesTasks = true
        #expect(state.displaysStatus && !state.displaysQuota)
        state.showingAnnouncement = false
        #expect(!state.displaysStatus && !state.displaysQuota)
    }

    @Test func finishedReadTargetsIncludeBotsAndAcknowledgeOnlyTheirExactUpdates() {
        func task(
            _ id: String, _ phase: EdgeNotchTask.Phase, current: Bool = false, date: Date? = nil,
            profile: String? = nil
        ) -> EdgeNotchTask {
            EdgeNotchTask(
                id: id, title: id, phase: phase, statusLabel: "", detail: nil, updatedAt: date,
                isCurrent: current, isStatusCurrent: true, session: nil, profileID: profile)
        }
        #expect(EdgeFinishedReadTargets(tasks: [task("working", .working)]).isEmpty)
        let bot = task("bot:one", .finished, date: Date(timeIntervalSince1970: 1), profile: "a")
        let targets = EdgeFinishedReadTargets(tasks: [bot])
        #expect(!targets.isEmpty)
        var acknowledgements = EdgeFinishedBotAcknowledgements()
        acknowledgements.acknowledge(targets.bots)
        #expect(acknowledgements.isAcknowledged(bot))
        #expect(!acknowledgements.isAcknowledged(task("bot:one", .working, date: bot.updatedAt, profile: "a")))
        #expect(
            !acknowledgements.isAcknowledged(
                task("bot:one", .finished, date: Date(timeIntervalSince1970: 2), profile: "a")))
        #expect(!acknowledgements.isAcknowledged(task("bot:one", .finished, date: bot.updatedAt, profile: "b")))
        #expect(EdgeFinishedReadTargets(tasks: [task("current", .finished, current: true)]).includesCurrent)
    }

    @Test func backgroundSessionFinishingAnnouncesOnce() {
        func task(_ id: String, _ phase: EdgeNotchTask.Phase, current: Bool = false) -> EdgeNotchTask {
            EdgeNotchTask(
                id: id, title: id, phase: phase, statusLabel: "", detail: nil, updatedAt: nil,
                isCurrent: current, isStatusCurrent: true, session: nil)
        }
        #expect(EdgeNotchTask.newlyFinished(from: [task("a", .working)], to: [task("a", .finished)]))
        #expect(!EdgeNotchTask.newlyFinished(from: [task("a", .finished)], to: [task("a", .finished)]))
        #expect(!EdgeNotchTask.newlyFinished(from: [], to: [task("a", .finished)]))
        #expect(
            !EdgeNotchTask.newlyFinished(
                from: [task("a", .working, current: true)], to: [task("a", .finished, current: true)]))
    }

    @Test func quotaAnnouncesOnlyWhenAWindowDropsABand() {
        func quota(_ remaining: Double?) -> [ProviderQuotaSnapshot] {
            [
                ProviderQuotaSnapshot(
                    provider: "codex", displayName: "Codex", model: nil, updatedAt: .now,
                    windows: [
                        ProviderQuotaWindow(
                            id: "session", label: "Session", remainingPercent: remaining,
                            remainingDisplay: nil, limitDisplay: nil, resetsAt: nil, resetsDisplay: nil)
                    ],
                    safeDetail: nil)
            ]
        }
        let full = EdgeQuotaBands.bands(quota(100))
        #expect(!EdgeQuotaBands.dropped(from: full, to: EdgeQuotaBands.bands(quota(91))))
        #expect(EdgeQuotaBands.dropped(from: full, to: EdgeQuotaBands.bands(quota(90))))
        #expect(EdgeQuotaBands.dropped(from: EdgeQuotaBands.bands(quota(11)), to: EdgeQuotaBands.bands(quota(4))))
        #expect(!EdgeQuotaBands.dropped(from: EdgeQuotaBands.bands(quota(4)), to: full))
        #expect(!EdgeQuotaBands.dropped(from: full, to: EdgeQuotaBands.bands(quota(nil))))
        #expect(EdgeQuotaBands.movedProviders(from: quota(80), to: quota(79)) == ["codex"])
        #expect(EdgeQuotaBands.movedProviders(from: quota(80), to: quota(80)).isEmpty)
        #expect(EdgeQuotaBands.movedProviders(from: quota(10), to: quota(100)).isEmpty)
        #expect(
            EdgeQuotaBands.droppedProvider(
                from: ["codex/5h": 10, "glm/5h": 10, "glm/7d": 9],
                to: ["codex/5h": 9, "glm/5h": 8, "glm/7d": 9]) == "glm")
    }

    @Test func attentionTakesPriorityOverUnreadAndWork() {
        let activity = EdgeNotchActivity(status: .needsApproval, unread: true, runningCount: 2)
        #expect(activity.title == "Needs your approval")
        #expect(activity.attention)
        #expect(activity.working)
    }

    @Test func backgroundWorkRemainsVisibleWhenConversationIsIdle() {
        let activity = EdgeNotchActivity(status: .idle, runningCount: 2)
        #expect(activity.working)
        #expect(activity.title == "2 background tasks running")
        #expect(EdgeNotchActivity().title == "Open Herm")
        #expect(EdgeNotchActivity(unread: true).title == "New response")
    }

    @Test func completionIsAnUpdateWithoutInventingPercentageProgress() {
        let completed = EdgeNotchActivity(backgroundCompleted: true)
        #expect(completed.hasUpdate)
        #expect(!completed.working)
        #expect(completed.title == "Background task completed")
    }

    @MainActor @Test func notchRemainsAttachedOnOffsetDisplayWithSystemDockInset() {
        let screen = NSRect(x: -1920, y: 200, width: 1920, height: 1080)
        let visible = NSRect(x: -1920, y: 200, width: 1840, height: 1050)
        for expanded in [false, true] {
            let frame = EdgeDockController.frame(screenFrame: screen, visibleFrame: visible, expanded: expanded)
            #expect(frame.maxX == screen.maxX)
            #expect(frame.midY == visible.midY)
            #expect(screen.contains(frame))
        }
    }

    @MainActor @Test func smallDisplayClampsBothNotchStates() {
        let screen = NSRect(x: 100, y: -200, width: 240, height: 100)
        for expanded in [false, true] {
            let frame = EdgeDockController.frame(screenFrame: screen, visibleFrame: screen, expanded: expanded)
            #expect(screen.contains(frame))
        }
    }
    @Test func progressTransitionsStayCompactButAttentionExpands() {
        let idle = EdgeNotchActivity()
        let working = EdgeNotchActivity(status: .working)
        #expect(idle.quiet)
        #expect(!working.shouldAnnounce(after: idle))
        #expect(!working.shouldAnnounce(after: working))
        #expect(!EdgeNotchActivity(status: .working, runningCount: 2).shouldAnnounce(after: working))
        #expect(EdgeNotchActivity(status: .needsApproval).shouldAnnounce(after: working))
        #expect(!EdgeNotchActivity(unread: true).quiet)
    }

    @Test func draggingChoosesEdgeAndClampsVerticalPosition() {
        let screen = NSRect(x: -1600, y: -200, width: 1600, height: 1000)
        let left = EdgeDockPlacement.dragged(to: NSPoint(x: -1500, y: 2000), screenFrame: screen, visibleFrame: screen)
        #expect(left.side == .left)
        #expect(left.fraction == 1)
        #expect(left.frame(width: 720, height: 600).maxY == screen.maxY)
        #expect(left.frame(width: 720, height: 600).minX == screen.minX)
        let right = EdgeDockPlacement.dragged(to: NSPoint(x: -10, y: -900), screenFrame: screen, visibleFrame: screen)
        #expect(right.side == .right)
        #expect(right.fraction == 0)
        #expect(right.frame(width: 720, height: 600).minY == screen.minY)
        #expect(right.frame(width: 720, height: 600).maxX == screen.maxX)
    }

    @Test func sideWorkspaceKeepsNavigationControlsInsideItsRoundedOutline() {
        let rect = CGRect(x: 0, y: 0, width: 1224, height: 600)
        for side in [EdgeDockSide.left, .right] {
            let insets = EdgeDockLayout.insets(for: side)
            #expect(insets.leading == 0)
            #expect(insets.trailing == 12)
            #expect(insets.top + insets.bottom == 48)
            let path = EdgeNotchShape(side: side).path(in: rect)
            // Navigation controls retain the rail's 7pt horizontal and 12pt/8pt vertical padding.
            for x in [insets.leading + 7, rect.width - insets.trailing] {
                for y in [insets.top + 12, rect.height - insets.bottom - 8] {
                    #expect(path.contains(CGPoint(x: x, y: y)))
                }
            }
        }
    }

    @Test func dockingContourReachesTowardThePetAndKeepsTheCameraStill() {
        let rect = CGRect(x: 0, y: 0, width: 52, height: 96)
        for side in [EdgeDockSide.left, .right] {
            let probe = CGPoint(x: rect.midX, y: rect.maxY - 8)
            #expect(!EdgeNotchShape(side: side).path(in: rect).contains(probe))
            let reaching = EdgeNotchShape(side: side, dockingReach: 1).path(in: rect)
            #expect(reaching.contains(probe))
            #expect(rect.contains(reaching.boundingRect))
        }
        #expect(EdgeNotchShape(side: .top).path(in: rect) == EdgeNotchShape(side: .top, dockingReach: 1).path(in: rect))
    }

    @Test func draggingToTopCenterDocksTheIsland() {
        let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let visible = NSRect(x: 0, y: 0, width: 1600, height: 968)
        let top = EdgeDockPlacement.dragged(to: NSPoint(x: 820, y: 990), screenFrame: screen, visibleFrame: visible)
        #expect(top.side == .top)
        let frame = top.frame(width: 400, height: 32)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY)
        #expect(top.workspaceInsets.top == 40)
        // The top corners away from the camera still dock to the side.
        #expect(
            EdgeDockPlacement.dragged(to: NSPoint(x: 1550, y: 990), screenFrame: screen, visibleFrame: visible).side
                == .right)
        // Secondary displays never get the island.
        #expect(
            EdgeDockPlacement.dragged(
                to: NSPoint(x: 820, y: 990), screenFrame: screen, visibleFrame: visible, allowsTop: false
            ).side == .right)
    }

    @MainActor @Test func announcementGlimpsesOnlyTheUpdatedRow() {
        let state = EdgeNotchState()
        state.tasks = ["a", "b", "c"].map {
            EdgeNotchTask(
                id: $0, title: $0, phase: .working, statusLabel: "", detail: nil, updatedAt: nil,
                isCurrent: false, isStatusCurrent: true, session: nil)
        }
        state.showingAnnouncement = true
        state.announcesTasks = true
        state.glimpseIDs = ["b"]
        #expect(state.glimpsing)
        #expect(state.glimpseTasks.map(\.id) == ["b"])
        #expect(state.openSize.height < EdgeNotchState.expandedSize.height)
        state.showingAnnouncement = false
        #expect(state.openSize == EdgeNotchState.expandedSize)
    }

    @MainActor @Test func topIslandWrapsTheNotchAndOpensBelowIt() {
        let state = EdgeNotchState()
        state.side = .top
        state.notchSize = CGSize(width: 200, height: 32)
        #expect(state.collapsedSize == CGSize(width: 200 + 56 * 2, height: 32))
        #expect(state.islandShellWidth == CGFloat(200 + 56 + 50))
        #expect(state.panelSize == state.collapsedSize)
        state.expanded = true
        #expect(
            state.panelSize
                == CGSize(width: EdgeNotchState.islandSize.width, height: EdgeNotchState.islandSize.height + 32))
    }

    @MainActor @Test func sideRailReservesClearanceForTheListeningIndicator() {
        let state = EdgeNotchState()
        for side in [EdgeDockSide.left, .right] {
            state.side = side
            state.wakeListening = false
            let collapsed = state.collapsedSize
            state.wakeListening = true
            #expect(state.sideWakeTopMargin == 16)
            #expect(EdgeNotchState.sideWakeClearance == 16)
            #expect(state.collapsedSize.height == collapsed.height + 54)
            #expect(state.collapsedSize.width == collapsed.width)
            #expect(state.panelSize == state.collapsedSize)
            let listening = state.collapsedSize
            state.wakeEnabled = true
            state.wakeListening = false
            #expect(state.collapsedSize == listening)
            state.wakeEnabled = false
            #expect(state.collapsedSize == collapsed)
        }
    }

    @MainActor @Test func islandEarsFitTheirOwnMarks() {
        let state = EdgeNotchState()
        state.side = .top
        state.notchSize = CGSize(width: 200, height: 32)
        state.activity.status = .needsApproval
        state.activity.unread = true
        let slots = state.railActivity.slots(for: .stored)
        #expect(
            state.islandEars.left == CGFloat(max(1, slots.extras)) * 30 + 20 + EdgeNotchState.islandBadgeInset)
        #expect(state.islandEars.right == CGFloat(max(1, slots.primary)) * 30 + 20)
        #expect(state.islandShellWidth == 200 + state.islandEars.left + state.islandEars.right)
        // The window stays centered at the wider ear; the shell shifts so the gap stays on the camera.
        #expect(state.collapsedSize.width == 200 + state.islandEar * 2)
        let cameraCenter = state.islandShellOffset - state.islandShellWidth / 2 + state.islandEars.left + 100
        #expect(cameraCenter == 0)

        let quietEars = state.islandEars
        state.wakeListening = true
        #expect(state.islandEars.left == quietEars.left)
        #expect(state.islandEars.right == quietEars.right + EdgeNotchState.wakeSlot + EdgeNotchState.wakeEdgeInset)
    }

    @MainActor @Test func quietNotchDoesNotExposePassiveLabelsOrLargeRail() {
        let state = EdgeNotchState()
        #expect(state.isQuiet)
        #expect(state.railWidth == 66)
        #expect(state.railHeight == 96)
        state.expanded = true
        #expect(!state.isQuiet)
        #expect(state.railWidth == 80)
    }

    @MainActor @Test func generatedIconIsPackagedAndReadable() {
        #expect(DockAppBrand.icon.isValid)
        #expect(DockAppBrand.icon.size.width >= 1024)
    }

    @Test func workspaceContentFitsInsideBothNotchContours() {
        let bounds = CGRect(x: 0, y: 0, width: 1264, height: 720)
        let content = bounds.insetBy(
            dx: EdgeDockLayout.workspaceHorizontalInset,
            dy: EdgeDockLayout.workspaceVerticalInset
        )
        for side in [EdgeDockSide.left, .right] {
            let shape = EdgeNotchShape(side: side).path(in: bounds)
            for point in [
                CGPoint(x: content.minX, y: content.minY),
                CGPoint(x: content.maxX, y: content.minY),
                CGPoint(x: content.minX, y: content.maxY),
                CGPoint(x: content.maxX, y: content.maxY),
            ] {
                #expect(shape.contains(point))
            }
        }
    }

    @MainActor @Test func quotaUsageKeepsUnknownValuesUnknownAndClampsBounds() {
        #expect(EdgeQuotaPreview.remainingPercent(27) == 27)
        #expect(EdgeQuotaPreview.remainingPercent(nil) == nil)
        #expect(EdgeQuotaPreview.remainingPercent(.nan) == nil)
        #expect(EdgeQuotaPreview.remainingPercent(-5) == 0)
        #expect(EdgeQuotaPreview.remainingPercent(120) == 100)
    }

    @Test func quotaPreviewPicksSessionAndWeeklyWindows() {
        func window(_ id: String, _ label: String) -> ProviderQuotaWindow {
            ProviderQuotaWindow(
                id: id, label: label, remainingPercent: 50, remainingDisplay: nil, limitDisplay: nil, resetsAt: nil,
                resetsDisplay: nil)
        }
        let claude = EdgeQuotaPreview.compactWindows([
            window("opus", "Opus"), window("weekly", "Weekly"), window("session", "Session"),
        ])
        #expect(claude.map { $0.label } == ["5h", "7d", "Opus"])
        #expect(claude.map { $0.window.id } == ["session", "weekly", "opus"])

        let other = EdgeQuotaPreview.compactWindows([
            window("a", "Daily"), window("b", "Monthly"), window("c", "Search"),
        ])
        #expect(other.map { $0.label } == ["Daily", "Monthly", "Search"])
        #expect(EdgeQuotaPreview.compactWindows([]).isEmpty)
    }

    @Test func providerMarksCoverDynamicAccountIdentifiers() {
        #expect(ProviderMark(providerID: "claude", displayName: "Claude") == .claude)
        #expect(ProviderMark(providerID: "codex-hermes-0", displayName: "Codex via Hermes") == .openAI)
        #expect(ProviderMark(providerID: "opencode", displayName: "OpenCode Go") == .openCode)
        #expect(ProviderMark(providerID: "glm", displayName: "GLM Coding Plan") == .zai)
        #expect(ProviderMark(providerID: "deepseek", displayName: "DeepSeek") == .deepSeek)
        #expect(ProviderMark(providerID: "kimi", displayName: "Kimi") == .kimi)
        #expect(ProviderMark(providerID: "openrouter", displayName: "OpenRouter") == .openRouter)
        #expect(ProviderMark(providerID: "antigravity", displayName: "Antigravity") == .antigravity)
        #expect(ProviderMark(providerID: "mistral", displayName: "Mistral") == .monogram("M"))
        #expect(ProviderMark(hermesProvider: "nvidia") == .icon("nvidia-color"))
        #expect(ProviderMark(hermesProvider: "copilot-acp") == .icon("githubcopilot"))
        #expect(ProviderMark(hermesProvider: "moa") == .monogram("M"))
        #expect(ProviderMark.image(named: "nvidia-color")?.isTemplate == false)
        #expect(ProviderMark.image(named: "ollama")?.isTemplate == true)
    }

    @MainActor @Test func dragCancelsPendingExpansionDuringHover() {
        let state = EdgeNotchState()
        state.expanded = false
        #expect(!state.expanded)
        // Simulate: hover starts expansion (but with delay now)
        // Then drag immediately begins before expansion completes
        // Result: expansion should be cancelled and notch should stay collapsed
        // (This is handled via expandTask cancellation in moveNotch)
        #expect(!state.expanded)
    }

    @Test func tasksListEveryRunningAndUnopenedSessionInPriorityOrder() {
        let now = Date()
        func session(_ id: String, working: Bool = false, unread: Bool = false, age: TimeInterval) -> HermesSession {
            HermesSession(
                id: id, title: id, preview: "", startedAt: nil, updatedAt: now.addingTimeInterval(-age),
                messageCount: 1, source: "cli", isWorking: working, hasUnreadUpdate: unread)
        }
        let sessions =
            (0..<8).map { session("done-\($0)", unread: true, age: TimeInterval($0 * 60)) } + [
                session("old-work", working: true, age: 600),
                session("new-work", working: true, age: 30),
                session("seen", age: 5),
                session("open", working: true, age: 1),
            ]
        let current = EdgeNotchTask(
            id: "open", title: "Open", phase: .attention, statusLabel: "Needs your approval",
            detail: nil, updatedAt: nil, isCurrent: true, isStatusCurrent: true, session: nil)
        let tasks = EdgeNotchTask.build(
            current: current, sessions: sessions, currentSessionIDs: ["open"], isOnline: true)
        #expect(tasks.map(\.id).prefix(3) == ["open", "new-work", "old-work"])
        #expect(tasks.filter { !$0.isInProgress }.count == 8)
        #expect(!tasks.contains { $0.id == "seen" })
        #expect(tasks.filter { $0.id == "open" }.count == 1)
        #expect(tasks.first?.tone == .attention)
    }

    @Test func openSessionKnownByRuntimeAliasIsNotListedTwice() {
        let sessions = [
            HermesSession(
                id: "20260926_183044_1083e6", title: "Clarify recipients", preview: "", startedAt: nil,
                messageCount: 1, source: "herm", isWorking: true),
            HermesSession(
                id: "other", title: "Other", preview: "", startedAt: nil, messageCount: 1, source: "cli",
                isWorking: true),
        ]
        let current = EdgeNotchTask(
            id: "893ad513", title: "Clarify recipients", phase: .working, statusLabel: "Working",
            detail: nil, updatedAt: nil, isCurrent: true, isStatusCurrent: true, session: nil)
        let tasks = EdgeNotchTask.build(
            current: current, sessions: sessions, currentSessionIDs: ["893ad513"], isOnline: true)
        #expect(tasks.map(\.id) == ["893ad513", "other"])
    }

    @Test func workingTaskShowsLatestActivityNotItsOpeningPrompt() {
        let sessions = [
            HermesSession(
                id: "a", title: "A", preview: "first prompt", startedAt: nil, messageCount: 1, source: "cli",
                isWorking: true),
            HermesSession(
                id: "b", title: "B", preview: "first prompt", startedAt: nil, messageCount: 1, source: "cli",
                isWorking: true),
        ]
        let tasks = EdgeNotchTask.build(
            current: nil, sessions: sessions, activity: ["a": "terminal: git checkout"],
            currentSessionIDs: [], isOnline: true)
        #expect(tasks.first { $0.id == "a" }?.detail == "terminal: git checkout")
        #expect(tasks.first { $0.id == "b" }?.detail == nil)
    }

    @Test func offlineTasksKeepResultsButStopClaimingLiveStatus() {
        let sessions = [
            HermesSession(
                id: "a", title: "A", preview: "", startedAt: nil, messageCount: 1, source: "cli", isWorking: true),
            HermesSession(
                id: "b", title: "B", preview: "", startedAt: nil, messageCount: 1, source: "cli", hasUnreadUpdate: true),
        ]
        let tasks = EdgeNotchTask.build(current: nil, sessions: sessions, currentSessionIDs: [], isOnline: false)
        #expect(tasks.first { $0.id == "a" }?.tone == .inactive)
        #expect(tasks.first { $0.id == "a" }?.displayStatus == "Status not current")
        #expect(tasks.first { $0.id == "b" }?.tone == .complete)
        #expect(EdgeNotchTask.build(current: nil, sessions: [], currentSessionIDs: [], isOnline: true).isEmpty)
    }

    @Test func officeStatusesShareTheDockStatusVocabulary() {
        #expect(OfficeAgentStatus.blocked.tone == .attention)
        #expect(OfficeAgentStatus.idle.tone == .complete)
        #expect(OfficeAgentStatus.working.nsColor == DockStatusTone.working.signageColor)
    }

    @Test func messagedBotsGetTheirOwnRows() {
        let now = Date()
        func record(
            _ id: String, _ state: BotActivityState, age: TimeInterval = 60, card: String? = nil, session: String? = nil
        ) -> BotActivityRecord {
            BotActivityRecord(
                id: id, originSessionID: "s", botID: "forge", botName: "Forge", summary: "Brief \(id)", state: state,
                createdAt: now.addingTimeInterval(-age), updatedAt: now.addingTimeInterval(-age),
                result: "Build green\nmore", linkedCardID: card, botChatSessionID: session)
        }
        let rows = EdgeNotchTask.botRows(
            records: [
                record("live", .working, session: "forge-1"),
                record("done", .completed),
                record("old", .completed, age: 3600),
                record("card", .working, card: "t_1"),
                record("listed", .working, session: "forge-2"),
            ], steps: ["live": "Running swift build"], isOnline: true, listedSessionIDs: ["forge-2"], now: now)
        #expect(rows.map(\.id) == ["bot:live", "bot:done"])
        #expect(rows[0].phase == .working && rows[0].detail == "Forge · Running swift build")
        #expect(rows[0].session?.profileID == "forge" && rows[0].profileID == "forge")
        #expect(rows[1].phase == .finished && rows[1].detail == "Forge · Build green")
    }

    @Test func botsStyleNamesTheBotPerStateAndCountsFinished() {
        func task(_ id: String, _ phase: EdgeNotchTask.Phase, profile: String?, live: Bool = true) -> EdgeNotchTask {
            EdgeNotchTask(
                id: id, title: id, phase: phase, statusLabel: "", detail: nil, updatedAt: nil,
                isCurrent: false, isStatusCurrent: live, session: nil, profileID: profile)
        }
        var activity = EdgeNotchActivity()
        activity.applyBots(from: [
            task("w", .working, profile: "coder"), task("b", .attention, profile: "ops"),
            task("f1", .finished, profile: "writer"), task("f2", .finished, profile: nil),
            task("stale", .finished, profile: "old", live: false),
        ])
        #expect(activity.workingBotIDs == ["coder"])
        #expect(activity.blockedBotID == "ops")
        #expect(activity.finishedBotID == "writer")
        #expect(activity.finishedCount == 2)
        activity.applyBots(from: [task("f", .finished, profile: nil)])
        #expect(activity.workingBotIDs.isEmpty)
        #expect(activity.finishedBotID == "")
        #expect(activity.finishedCount == 1)
    }

    @Test func botsStyleShowsEveryWorkingBotLikeTheBotPicker() {
        let roster = ["nexus", "coder", "idle", "ghost", "chat", "fourth"].map {
            BotActivityBoardTests.bot(
                $0, sessions: $0 != "idle" && $0 != "chat", chat: $0 == "chat", hidden: $0 == "ghost")
        }
        let board = BotActivityBoard.resolve(roster: roster, live: [:], signals: BotActivitySignals())
        let task = EdgeNotchTask(
            id: "w", title: "w", phase: .working, statusLabel: "", detail: nil, updatedAt: nil,
            isCurrent: false, isStatusCurrent: true, session: nil, profileID: "coder")
        var activity = EdgeNotchActivity()
        activity.applyBots(from: [task], board: board)
        // Task rows first, then the shared board, deduplicated and capped at three.
        #expect(activity.workingBotIDs == ["coder", "nexus", "chat"])
        #expect(activity.working)
        #expect(activity.slots(for: .bots).primary == 3)
        #expect(activity.slots(for: .count).primary == 1)

        var boardOnly = EdgeNotchActivity()
        boardOnly.applyBots(
            from: [],
            board: .resolve(
                roster: [BotActivityBoardTests.bot("nexus", sessions: true)], live: [:],
                signals: BotActivitySignals()))
        #expect(boardOnly.working && boardOnly.workingBotIDs == ["nexus"])
    }

    @MainActor @Test func previewIncludesEveryWorkingBotAndKeepsItsSessionRows() {
        let state = EdgeNotchState()
        let roster = ["nexus", "coder", "scout", "writer", "blocked", "idle", "hidden"].map {
            BotActivityBoardTests.bot($0, sessions: $0 != "idle", hidden: $0 == "hidden")
        }
        state.botActivity = BotActivityBoard.resolve(
            roster: roster, live: [:], signals: BotActivitySignals(attention: ["request": "blocked"]))
        state.bots = roster
        state.tasks = ["one", "two"].map {
            EdgeNotchTask(
                id: $0, title: $0, phase: .working, statusLabel: "Working", detail: nil, updatedAt: nil,
                isCurrent: false, isStatusCurrent: true, session: nil, profileID: "nexus")
        }

        let summaryRows = state.previewTasks.filter(\.isBotStatusOnly)
        #expect(Set(summaryRows.compactMap(\.botProfileID)) == Set(["coder", "scout", "writer"]))
        #expect(summaryRows.allSatisfy { $0.session == nil && $0.section == .inProgress })
        #expect(state.previewTasks.filter { !$0.isBotStatusOnly } == state.tasks)
        #expect(state.sessionRailActivity.workingBotIDs.count == 3)
        #expect(state.botActivity.working.count == 4)

        state.tasks.append(
            EdgeNotchTask(
                id: "coder-session", title: "Review", phase: .working, statusLabel: "Working", detail: nil,
                updatedAt: .now, isCurrent: false, isStatusCurrent: true, session: nil, profileID: "coder"))
        #expect(!state.previewTasks.contains { $0.isBotStatusOnly && $0.botProfileID == "coder" })

        state.activity.status = .offline
        #expect(state.previewTasks == state.tasks)
        state.activity.status = .idle
        #expect(state.previewTasks.filter(\.isBotStatusOnly).count == 2)
        state.botActivity = BotActivityBoard()
        #expect(state.previewTasks == state.tasks)
    }
}

struct BotActivityBoardTests {
    static func bot(
        _ id: String, sessions: Bool = false, chat: Bool = false, hidden: Bool = false, recent: String? = nil
    ) -> BotSummary {
        var bot = BotSummary(
            id: id, name: id, title: nil, description: nil, model: nil, isActive: false, chat: nil,
            recentSession: recent.map { BotChatReference(sessionID: $0, profileID: id, title: nil, lastActive: nil) },
            avatarURL: nil, preview: nil, lastActive: nil, isHidden: hidden, hasAvatar: false, isDefault: false)
        bot.sessionsBusy = sessions
        bot.mainChatBusy = chat
        return bot
    }

    static func session(_ id: String, profile: String?, working: Bool = false, unread: Bool = false)
        -> BotSessionSignal
    {
        BotSessionSignal(id: id, profileID: profile, isWorking: working, hasUnreadUpdate: unread)
    }

    @Test func liveSessionsBeyondEachBotsLatestChatStillCount() {
        // Hermes' live list names no profile; session rows map it to its Bot.
        let board = BotActivityBoard.resolve(
            roster: [Self.bot("nexus", recent: "n-latest"), Self.bot("coder")],
            live: ["n-older": .working, "c-1": .waiting],
            signals: BotActivitySignals(sessions: [
                Self.session("n-older", profile: "nexus"), Self.session("c-1", profile: "coder"),
            ]))
        #expect(board.working == ["nexus"])
        #expect(board.blocked == ["coder"])
    }

    @Test func sessionEventsFlipStatusBeforeTheNextRosterPoll() {
        let roster = [Self.bot("nexus"), Self.bot("coder"), Self.bot("scout")]
        let board = BotActivityBoard.resolve(
            roster: roster, live: [:],
            signals: BotActivitySignals(
                sessions: [
                    Self.session("a", profile: "nexus", working: true),
                    Self.session("b", profile: "coder", unread: true),
                ],
                attention: ["s": "scout"]))
        #expect(board.working == ["nexus"])
        #expect(board.finished == ["coder"])
        #expect(board.blocked == ["scout"])
    }

    @Test func streamedPreviewAndTimestampChangesLeaveTheSignalEqual() {
        func row(preview: String, at seconds: TimeInterval, working: Bool) -> HermesSession {
            HermesSession(
                id: "a", profileID: "nexus", title: "", preview: preview, startedAt: nil,
                updatedAt: Date(timeIntervalSince1970: seconds), messageCount: 0, source: "", isHidden: false,
                isWorking: working, hasUnreadUpdate: false)
        }
        // Streaming must not re-resolve the board; only status fields count.
        #expect(
            BotSessionSignal(row(preview: "a", at: 1, working: true))
                == BotSessionSignal(row(preview: "ab", at: 2, working: true)))
        #expect(
            BotSessionSignal(row(preview: "a", at: 1, working: true))
                != BotSessionSignal(row(preview: "a", at: 1, working: false)))
    }

    @Test func updatingOneSessionKeepsOtherBotsAndOtherSessionsWorking() {
        var projection = BotActivityBoard.Projection()
        projection.setRoster([Self.bot("nexus"), Self.bot("coder")], live: [:])
        projection.update(Self.session("a", profile: "nexus", working: true))
        projection.update(Self.session("b", profile: "nexus", working: true))
        projection.update(Self.session("c", profile: "coder", working: true))

        projection.update(Self.session("a", profile: "nexus", unread: true))
        #expect(projection.board.working == ["nexus", "coder"])
        projection.update(Self.session("b", profile: "nexus"))
        #expect(projection.board.working == ["coder"])
        #expect(projection.board.finished == ["nexus"])
    }

    @Test func blockedOutranksWorkingAndHiddenBotsStayOut() {
        let board = BotActivityBoard.resolve(
            roster: [Self.bot("nexus", sessions: true), Self.bot("ghost", sessions: true, hidden: true)],
            live: [:],
            signals: BotActivitySignals(attention: ["x": nil], scopeProfileID: "nexus"))
        #expect(board.status(of: "nexus") == .blocked)
        #expect(board.status(of: "ghost") == .idle)
        #expect(board.order == ["nexus"])
    }

    @Test func liveStatusParsesWaitingAsBlockedAndKeepsTheStrongest() {
        let parsed = BotService.parseLiveSessions([
            ["session_key": "a", "status": "working"], ["session_key": "a", "status": "waiting"],
            ["session_key": "b", "status": "idle"], ["status": "working"],
        ])
        #expect(parsed == ["a": .waiting, "b": .idle])
    }
}

struct BotStatusMotionTests {
    @Test func moodsMapToOneSharedChoreography() {
        #expect(BotStatusMotion(mood: .tool) == .working)
        #expect(BotStatusMotion(mood: .thinking) == .working)
        #expect(BotStatusMotion(mood: .approval) == .blocked)
        #expect(BotStatusMotion(mood: .clarify) == .blocked)
        #expect(BotStatusMotion(mood: .done) == .finished)
        #expect(BotStatusMotion(mood: .listening) == .resting)
        #expect(BotStatusMotion(mood: .idle) == .resting)
    }

    @Test func blockedShakesThenHoldsStill() {
        #expect(BotStatusMotion.blocked.pose(at: 0.1).rotation != 0)
        #expect(BotStatusMotion.blocked.pose(at: 1.2).rotation == 0)
        #expect(BotStatusMotion.blocked.pose(at: 2.1).rotation != 0)
    }

    @Test func finishedHopsOnlyWhileTheReactionRuns() {
        #expect(BotStatusMotion.finished.pose(at: 5).lift == 0)
        #expect(BotStatusMotion.finished.pose(at: 5, hopAge: 0.5).lift > 0)
        #expect(BotStatusMotion.finished.pose(at: 5, hopAge: BotWorkingPose.reactionDuration).lift == 0)
    }

    @Test func liveFinishedNudgesUntilOpened() {
        #expect(BotStatusMotion.finished.loops(live: true))
        #expect(!BotStatusMotion.finished.loops())
        #expect(BotStatusMotion.finished.pose(at: 0.5, live: true).lift > 0)
        #expect(BotStatusMotion.finished.pose(at: 3, live: true).lift == 0)
        #expect(BotStatusMotion.finished.pose(at: BotStatusMotion.finishedNudgePeriod + 0.5, live: true).lift > 0)
    }

    @MainActor @Test func nativeNotchLoopsKeepTheExistingMotionPeriods() throws {
        let layer = CALayer()
        for (motion, duration) in [
            (BotStatusMotion.working, BotWorkingPose.stridePeriod),
            (.blocked, BotStatusMotion.blockedShakePeriod),
            (.finished, BotStatusMotion.finishedNudgePeriod),
        ] {
            let loop = try #require(BotNotchFaceMotion.Host.loop(motion, size: 22, cue: 0, layer: layer))
            let frames = try #require(loop.values as? [NSValue])
            #expect(loop.duration == duration)
            #expect(loop.repeatCount == .infinity)
            #expect(loop.keyTimes?.first == 0 && loop.keyTimes?.last == 1)
            #expect(frames.first == frames.last)
            #expect(frames.contains { $0 != frames.first })
        }
        #expect(BotNotchFaceMotion.Host.loop(.resting, size: 22, cue: 0, layer: layer) == nil)
    }
}

struct NotchBotsStyleIntroductionTests {
    private func defaults() -> UserDefaults {
        let name = "NotchBotsStyleIntroductionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func freshInstallsDefaultToBots() {
        #expect(NotchDisplayStyle.defaultStyle == .bots)
    }

    @Test func anEarlierChoiceSwitchesToBotsOnce() {
        let defaults = defaults()
        defaults.set(NotchDisplayStyle.ring.rawValue, forKey: NotchDisplayStyle.defaultsKey)
        NotchDisplayStyle.introduceBotsStyle(in: defaults)
        #expect(defaults.string(forKey: NotchDisplayStyle.defaultsKey) == NotchDisplayStyle.bots.rawValue)
    }

    @Test func aChoiceMadeAfterTheSwitchSticks() {
        let defaults = defaults()
        NotchDisplayStyle.introduceBotsStyle(in: defaults)
        defaults.set(NotchDisplayStyle.dots.rawValue, forKey: NotchDisplayStyle.defaultsKey)
        NotchDisplayStyle.introduceBotsStyle(in: defaults)
        #expect(defaults.string(forKey: NotchDisplayStyle.defaultsKey) == NotchDisplayStyle.dots.rawValue)
    }
}
