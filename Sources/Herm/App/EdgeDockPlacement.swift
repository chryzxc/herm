import AppKit

enum EdgeDockLayout {
    // The contour needs more breathing room above and below its shoulders than
    // beside the workspace. Keeping these separate avoids wasting horizontal
    // capacity in the expanded three-pane layout. The vertical inset must clear
    // the 24pt shoulder plus enough of the 30pt corner curve that the 4pt side
    // inset stays inside the contour (≈36pt); see EdgeNotchShape.
    static let workspaceHorizontalInset: CGFloat = 4
    static let workspaceVerticalInset: CGFloat = 38
}

enum EdgeDockSide: String, Codable {
    case left, right
}

/// Dock-owned placement only; screen coordinates use AppKit's bottom-left origin.
struct EdgeDockPlacement: Equatable {
    var side: EdgeDockSide = .right
    var fraction: CGFloat = 0.5
    var screenFrame: NSRect
    var visibleFrame: NSRect

    func frame(width: CGFloat, height: CGFloat) -> NSRect {
        let width = min(width, screenFrame.width)
        let height = min(height, visibleFrame.height)
        let center = visibleFrame.minY + visibleFrame.height * min(1, max(0, fraction))
        let y = min(max(center - height / 2, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: side == .right ? screenFrame.maxX - width : screenFrame.minX,
                      y: y, width: width, height: height)
    }

    static func dragged(to point: NSPoint, screenFrame: NSRect, visibleFrame: NSRect) -> Self {
        Self(side: point.x < screenFrame.midX ? .left : .right,
             fraction: min(1, max(0, (point.y - visibleFrame.minY) / max(1, visibleFrame.height))),
             screenFrame: screenFrame, visibleFrame: visibleFrame)
    }
}
