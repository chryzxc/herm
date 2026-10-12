import AppKit
import Testing
@testable import Herm

@MainActor
struct SidebarSplitLayoutTests {
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

    private func makeSplit(width: CGFloat) -> FractionPreservingSplitView {
        let split = FractionPreservingSplitView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        split.isVertical = true
        split.dividerStyle = .thin
        split.minimumLeadingWidth = 300
        split.minimumTrailingWidth = 520
        return split
    }
}
