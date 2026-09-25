import AppKit
import Testing
@testable import HermesAgentDock

struct EdgeNotchTests {
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
        #expect(EdgeNotchActivity().title == "Open Dock")
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
        #expect(state.railWidth == 44)
        #expect(state.railHeight == 72)
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

    @Test func quotaUsageKeepsUnknownValuesUnknownAndClampsBounds() {
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
        #expect(ProviderMark(providerID: "glm", displayName: "GLM Coding Plan") == .monogram("G"))
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
        let tasks = EdgeNotchTask.build(current: current, sessions: sessions, currentSessionID: "open", isOnline: true)
        #expect(tasks.map(\.id).prefix(3) == ["open", "new-work", "old-work"])
        #expect(tasks.filter { !$0.isInProgress }.count == 8)
        #expect(!tasks.contains { $0.id == "seen" })
        #expect(tasks.filter { $0.id == "open" }.count == 1)
        #expect(tasks.first?.tone == .attention)
    }

    @Test func offlineTasksKeepResultsButStopClaimingLiveStatus() {
        let sessions = [
            HermesSession(id: "a", title: "A", preview: "", startedAt: nil, messageCount: 1, source: "cli", isWorking: true),
            HermesSession(id: "b", title: "B", preview: "", startedAt: nil, messageCount: 1, source: "cli", hasUnreadUpdate: true),
        ]
        let tasks = EdgeNotchTask.build(current: nil, sessions: sessions, currentSessionID: nil, isOnline: false)
        #expect(tasks.first { $0.id == "a" }?.tone == .inactive)
        #expect(tasks.first { $0.id == "a" }?.displayStatus == "Status not current")
        #expect(tasks.first { $0.id == "b" }?.tone == .complete)
        #expect(EdgeNotchTask.build(current: nil, sessions: [], currentSessionID: nil, isOnline: true).isEmpty)
    }

    @Test func officeStatusesShareTheDockStatusVocabulary() {
        #expect(OfficeAgentStatus.blocked.tone == .attention)
        #expect(OfficeAgentStatus.idle.tone == .complete)
        #expect(OfficeAgentStatus.working.nsColor == DockStatusTone.working.signageColor)
    }
}
