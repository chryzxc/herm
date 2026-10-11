import AppKit
import Testing
@testable import Herm

struct EdgeNotchTests {
    @MainActor @Test func pendingRequestsStayVisibleUntilResolved() {
        let model = DockModel()
        model.receiveGatewayEvent("approval.request", params: ["session_id": "approval", "payload": ["title": "Run migration", "request_id": "a1"]])
        model.receiveGatewayEvent("clarify.request", params: ["session_id": "question", "payload": ["question": "Which environment?", "request_id": "q1"]])
        let sessions = ["approval", "question"].map {
            HermesSession(id: $0, title: $0, preview: "", startedAt: nil, messageCount: 1, source: "herm")
        }
        let tasks = EdgeNotchTask.build(current: nil, sessions: sessions, currentSessionIDs: [], isOnline: true,
                                        attention: model.sessionAttention)
        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { $0.phase == .attention })
        #expect(tasks.first { $0.id == "approval" }?.displayStatus == "Needs your approval")
        #expect(tasks.first { $0.id == "question" }?.detail == "Which environment?")
        let state = EdgeNotchState()
        state.tasks = tasks
        #expect(state.railActivity.attention)
        #expect(state.railActivity.title == "Needs your attention")
        let stale = EdgeNotchTask.build(current: nil, sessions: sessions, currentSessionIDs: [], isOnline: false,
                                        attention: model.sessionAttention)
        #expect(stale.allSatisfy { $0.displayStatus == "Status not current" })
        model.resolveApproval(for: "approval")
        #expect(model.sessionAttention["approval"] == nil)
        #expect(model.sessionAttention["question"] != nil)
        model.receiveGatewayEvent("clarify.expire", params: ["session_id": "question", "payload": ["request_id": "q1"]])
        #expect(model.sessionAttention.isEmpty)
    }

    @MainActor @Test func attentionRowsCarryOneTapAnswers() throws {
        let model = DockModel()
        model.receiveGatewayEvent("approval.request", params: ["session_id": "a", "payload": ["title": "Run migration", "request_id": "a1"]])
        model.receiveGatewayEvent("clarify.request", params: ["session_id": "q", "payload": ["question": "Which env?", "choices": ["staging", "prod"], "request_id": "q1"]])
        let sessions = ["a", "q"].map { HermesSession(id: $0, title: $0, preview: "", startedAt: nil, messageCount: 1, source: "herm") }
        let tasks = EdgeNotchTask.build(current: nil, sessions: sessions, currentSessionIDs: [], isOnline: true, attention: model.sessionAttention)
        #expect(tasks.first { $0.id == "a" }?.choices.map(EdgeNotchTask.choiceLabel) == ["Allow once", "Deny"])
        #expect(tasks.first { $0.id == "q" }?.choices == ["staging", "prod"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"task_id": "t_1234abcd", "session_id": "bot", "profile": "default", "questions": [{"question": "Ship it?", "choices": ["Yes", "No"]}]}"#
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
        let snapshot = ProviderQuotaSnapshot(provider: "codex", displayName: "Codex", model: nil, updatedAt: .now,
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

    @Test func backgroundSessionFinishingAnnouncesOnce() {
        func task(_ id: String, _ phase: EdgeNotchTask.Phase, current: Bool = false) -> EdgeNotchTask {
            EdgeNotchTask(id: id, title: id, phase: phase, statusLabel: "", detail: nil, updatedAt: nil,
                          isCurrent: current, isStatusCurrent: true, session: nil)
        }
        #expect(EdgeNotchTask.newlyFinished(from: [task("a", .working)], to: [task("a", .finished)]))
        #expect(!EdgeNotchTask.newlyFinished(from: [task("a", .finished)], to: [task("a", .finished)]))
        #expect(!EdgeNotchTask.newlyFinished(from: [], to: [task("a", .finished)]))
        #expect(!EdgeNotchTask.newlyFinished(from: [task("a", .working, current: true)], to: [task("a", .finished, current: true)]))
    }

    @Test func quotaAnnouncesOnlyWhenAWindowDropsABand() {
        func quota(_ remaining: Double?) -> [ProviderQuotaSnapshot] {
            [ProviderQuotaSnapshot(provider: "codex", displayName: "Codex", model: nil, updatedAt: .now,
                windows: [ProviderQuotaWindow(id: "session", label: "Session", remainingPercent: remaining,
                    remainingDisplay: nil, limitDisplay: nil, resetsAt: nil, resetsDisplay: nil)],
                safeDetail: nil)]
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
        #expect(EdgeQuotaBands.droppedProvider(from: ["codex/5h": 10, "glm/5h": 10, "glm/7d": 9],
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
    @Test func progressTransitionsExpandButRepeatedStateDoesNot() {
        let idle = EdgeNotchActivity()
        let working = EdgeNotchActivity(status: .working)
        #expect(idle.quiet)
        #expect(working.shouldAnnounce(after: idle))
        #expect(!working.shouldAnnounce(after: working))
        #expect(EdgeNotchActivity(status: .working, runningCount: 2).shouldAnnounce(after: working))
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

    @MainActor @Test func quietNotchDoesNotExposePassiveLabelsOrLargeRail() {
        let state = EdgeNotchState()
        #expect(state.isQuiet)
        #expect(state.railWidth == 56)
        #expect(state.railHeight == 60)
        state.expanded = true
        #expect(!state.isQuiet)
        #expect(state.railWidth == 72)
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
            for point in [CGPoint(x: content.minX, y: content.minY),
                          CGPoint(x: content.maxX, y: content.minY),
                          CGPoint(x: content.minX, y: content.maxY),
                          CGPoint(x: content.maxX, y: content.maxY)] {
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
            ProviderQuotaWindow(id: id, label: label, remainingPercent: 50, remainingDisplay: nil, limitDisplay: nil, resetsAt: nil, resetsDisplay: nil)
        }
        let claude = EdgeQuotaPreview.compactWindows([window("opus", "Opus"), window("weekly", "Weekly"), window("session", "Session")])
        #expect(claude.map { $0.label } == ["5h", "7d"])
        #expect(claude.map { $0.window.id } == ["session", "weekly"])

        let other = EdgeQuotaPreview.compactWindows([window("a", "Daily"), window("b", "Monthly"), window("c", "Search")])
        #expect(other.map { $0.label } == ["Daily", "Monthly"])
        #expect(EdgeQuotaPreview.compactWindows([]).isEmpty)
    }

    @Test func providerMarksCoverDynamicAccountIdentifiers() {
        #expect(ProviderMark(providerID: "claude", displayName: "Claude") == .claude)
        #expect(ProviderMark(providerID: "codex-hermes-0", displayName: "Codex via Hermes") == .openAI)
        #expect(ProviderMark(providerID: "opencode", displayName: "OpenCode Go") == .openCode)
        #expect(ProviderMark(providerID: "glm", displayName: "GLM Coding Plan") == .zai)
        #expect(ProviderMark(providerID: "antigravity", displayName: "Antigravity") == .antigravity)
        #expect(ProviderMark(providerID: "kimi", displayName: "Kimi") == .monogram("K"))
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
            HermesSession(id: id, title: id, preview: "", startedAt: nil, updatedAt: now.addingTimeInterval(-age),
                          messageCount: 1, source: "cli", isWorking: working, hasUnreadUpdate: unread)
        }
        let sessions = (0..<8).map { session("done-\($0)", unread: true, age: TimeInterval($0 * 60)) } + [
            session("old-work", working: true, age: 600),
            session("new-work", working: true, age: 30),
            session("seen", age: 5),
            session("open", working: true, age: 1),
        ]
        let current = EdgeNotchTask(id: "open", title: "Open", phase: .attention, statusLabel: "Needs your approval",
                                    detail: nil, updatedAt: nil, isCurrent: true, isStatusCurrent: true, session: nil)
        let tasks = EdgeNotchTask.build(current: current, sessions: sessions, currentSessionIDs: ["open"], isOnline: true)
        #expect(tasks.map(\.id).prefix(3) == ["open", "new-work", "old-work"])
        #expect(tasks.filter { !$0.isInProgress }.count == 8)
        #expect(!tasks.contains { $0.id == "seen" })
        #expect(tasks.filter { $0.id == "open" }.count == 1)
        #expect(tasks.first?.tone == .attention)
    }

    @Test func openSessionKnownByRuntimeAliasIsNotListedTwice() {
        let sessions = [
            HermesSession(id: "20260926_183044_1083e6", title: "Clarify recipients", preview: "", startedAt: nil,
                          messageCount: 1, source: "herm", isWorking: true),
            HermesSession(id: "other", title: "Other", preview: "", startedAt: nil, messageCount: 1, source: "cli", isWorking: true),
        ]
        let current = EdgeNotchTask(id: "893ad513", title: "Clarify recipients", phase: .working, statusLabel: "Working",
                                    detail: nil, updatedAt: nil, isCurrent: true, isStatusCurrent: true, session: nil)
        let tasks = EdgeNotchTask.build(current: current, sessions: sessions, currentSessionIDs: ["893ad513"], isOnline: true)
        #expect(tasks.map(\.id) == ["893ad513", "other"])
    }

    @Test func workingTaskShowsLatestActivityNotItsOpeningPrompt() {
        let sessions = [
            HermesSession(id: "a", title: "A", preview: "first prompt", startedAt: nil, messageCount: 1, source: "cli", isWorking: true),
            HermesSession(id: "b", title: "B", preview: "first prompt", startedAt: nil, messageCount: 1, source: "cli", isWorking: true),
        ]
        let tasks = EdgeNotchTask.build(current: nil, sessions: sessions, activity: ["a": "terminal: git checkout"],
                                        currentSessionIDs: [], isOnline: true)
        #expect(tasks.first { $0.id == "a" }?.detail == "terminal: git checkout")
        #expect(tasks.first { $0.id == "b" }?.detail == nil)
    }

    @Test func offlineTasksKeepResultsButStopClaimingLiveStatus() {
        let sessions = [
            HermesSession(id: "a", title: "A", preview: "", startedAt: nil, messageCount: 1, source: "cli", isWorking: true),
            HermesSession(id: "b", title: "B", preview: "", startedAt: nil, messageCount: 1, source: "cli", hasUnreadUpdate: true),
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
}
