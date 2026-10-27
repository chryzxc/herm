import AppKit
import Testing

@testable import Herm

@MainActor
struct SidebarSplitLayoutTests {
    @Test func changingPaneMinimumsRelayoutsWithoutAnotherWindowResize() {
        let split = makeSplit(width: 847)
        split.minimumLeadingWidth = 520
        split.minimumTrailingWidth = 360
        split.fraction = DesktopWorkspaceFractions.conversationOfRemainder
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.layout()
        split.minimumLeadingWidth = 486
        split.layout()
        #expect(split.arrangedSubviews[1].frame.width >= 360)
    }

    @Test func minimumWindowCollapsesQueueBeforeInspectorLosesItsWidth() {
        #expect(DesktopWorkspaceFractions.shouldCollapseQueue(width: 900, isFullscreen: true))
        #expect(DesktopWorkspaceFractions.shouldCollapseQueue(width: 1200, isFullscreen: true))
        #expect(!DesktopWorkspaceFractions.shouldCollapseQueue(width: 1235, isFullscreen: true))
        #expect(!DesktopWorkspaceFractions.shouldCollapseQueue(width: 1110, isFullscreen: false))
        let split = makeSplit(width: 847)
        split.minimumLeadingWidth = 486
        split.minimumTrailingWidth = 360
        split.fraction = DesktopWorkspaceFractions.conversationOfRemainder
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.layout()
        #expect(split.arrangedSubviews[0].frame.width >= 486)
        #expect(split.arrangedSubviews[1].frame.width >= 360)
    }

    @Test func narrowWorkspacePreservesReadableSidebar() {
        let split = makeSplit(width: 668)
        #expect(split.minimumLeadingPosition == 300)
        #expect(split.maximumLeadingPosition == 300)
    }

    @Test func wideWorkspaceLeavesRoomForBothPanes() {
        let split = makeSplit(width: 1200)
        #expect(split.minimumLeadingPosition == 300)
        #expect(split.maximumLeadingPosition == 1200 - split.dividerThickness - 520)
    }

    @Test func resizingClampsSidebarToItsMinimum() {
        let split = makeSplit(width: 1200)
        split.fraction = 0.34
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        split.layout()
        split.setFrameSize(NSSize(width: 668, height: 600))
        split.layout()
        #expect(abs(split.arrangedSubviews[0].frame.width - 300) < 1)
    }

    @Test func undersizedHostKeepsPositionsWithinBounds() {
        let split = makeSplit(width: 200)
        #expect(split.minimumLeadingPosition == 200 - split.dividerThickness)
        #expect(split.maximumLeadingPosition == split.minimumLeadingPosition)
    }

    @Test func floatingInspectorExpansionKeepsBothWorkspacePanesVisible() {
        // Remaining space after the navigation rail and 300pt conversation list.
        for width: CGFloat in [730, 834] {
            let split = makeSplit(width: width)
            split.minimumLeadingWidth = DesktopWorkspaceFractions.minimumConversationWidth(isFullscreen: false)
            split.minimumTrailingWidth = 360
            split.fraction = DesktopWorkspaceFractions.conversationOfRemainder
            split.addArrangedSubview(NSView())
            split.addArrangedSubview(NSView())
            split.layout()

            for _ in 0..<2 {
                split.setTrailingCollapsed(true)
                split.layout()
                #expect(split.arrangedSubviews[1].frame.width < 1)
                split.setTrailingCollapsed(false)
                split.layout()
                #expect(split.arrangedSubviews[0].frame.width >= 360)
                #expect(split.arrangedSubviews[1].frame.width >= 359)
                #expect(split.arrangedSubviews.count == 2)
            }
        }
    }

    @Test func desktopPanesStayNearTwentyFiveFortyThirtyFiveAcrossWindowSizes() {
        for (width, fullscreen): (CGFloat, Bool) in [(1134, false), (1534, true), (1934, true)] {
            let minimumConversation = DesktopWorkspaceFractions.minimumConversationWidth(isFullscreen: fullscreen)
            let outer = makeSplit(width: width)
            outer.minimumTrailingWidth = minimumConversation + 1 + 360
            outer.fraction = DesktopWorkspaceFractions.queue
            outer.addArrangedSubview(NSView())
            outer.addArrangedSubview(NSView())
            outer.layout()

            let inner = makeSplit(width: outer.arrangedSubviews[1].frame.width)
            inner.minimumLeadingWidth = minimumConversation
            inner.minimumTrailingWidth = 360
            inner.fraction = DesktopWorkspaceFractions.conversationOfRemainder
            inner.addArrangedSubview(NSView())
            inner.addArrangedSubview(NSView())
            inner.layout()

            #expect(abs(outer.arrangedSubviews[0].frame.width / width - 0.25) < 0.035)
            #expect(abs(inner.arrangedSubviews[0].frame.width / width - 0.40) < 0.035)
            #expect(abs(inner.arrangedSubviews[1].frame.width / width - 0.35) < 0.035)
        }
    }

    @Test func fullscreenRetainsItsWiderConversationMinimum() {
        #expect(DesktopWorkspaceFractions.minimumConversationWidth(isFullscreen: true) == 520)
    }

    private func makeSplit(width: CGFloat) -> FractionPreservingSplitView {
        let split = FractionPreservingSplitView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        split.isVertical = true
        split.dividerStyle = .thin
        split.minimumLeadingWidth = 300
        split.minimumTrailingWidth = 520
        return split
    }
}
