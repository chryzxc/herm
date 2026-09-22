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
        #expect(EdgeQuotaPreview.usedPercent(remaining: 27) == 73)
        #expect(EdgeQuotaPreview.usedPercent(remaining: nil) == nil)
        #expect(EdgeQuotaPreview.usedPercent(remaining: .nan) == nil)
        #expect(EdgeQuotaPreview.usedPercent(remaining: -5) == 100)
        #expect(EdgeQuotaPreview.usedPercent(remaining: 120) == 0)
    }

}
