import AppKit

enum EdgeDockLayout {
    // Clear the 18pt shoulder and 26pt inner corner at the narrow side inset.
    static let workspaceHorizontalInset: CGFloat = 4
    static let workspaceVerticalInset: CGFloat = 44
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
