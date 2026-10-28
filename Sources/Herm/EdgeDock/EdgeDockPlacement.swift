import AppKit
import SwiftUI

enum EdgeDockLayout {
    // Trailing content clears the rounded shoulder; the navigation rail owns its leading padding.
    static let workspaceHorizontalInset: CGFloat = 12
    static let workspaceVerticalInset: CGFloat = 24

    /// The top drop-down's shoulders only flare at the menu bar, so its sides just
    /// clear the 18pt shoulder and its top clears the menu bar it hangs over.
    static let islandSideInset: CGFloat = 22

    static func insets(for side: EdgeDockSide, menuBarHeight: CGFloat = 0) -> EdgeInsets {
        side == .top
            ? EdgeInsets(top: menuBarHeight + 8, leading: islandSideInset, bottom: 6, trailing: islandSideInset)
            : EdgeInsets(
                top: workspaceVerticalInset, leading: 0,
                bottom: workspaceVerticalInset, trailing: workspaceHorizontalInset)
    }
}

enum EdgeDockSide: String, Codable {
    case left, right, top

    /// Where content hugs the anchored screen edge.
    var alignment: Alignment {
        switch self {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        }
    }

    var anchor: UnitPoint {
        switch self {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        }
    }
}

/// Dock-owned placement only; screen coordinates use AppKit's bottom-left origin.
struct EdgeDockPlacement: Equatable {
    var side: EdgeDockSide = .right
    var fraction: CGFloat = 0.5
    var screenFrame: NSRect
    var visibleFrame: NSRect

    var workspaceInsets: EdgeInsets {
        EdgeDockLayout.insets(for: side, menuBarHeight: screenFrame.maxY - visibleFrame.maxY)
    }

    func frame(width: CGFloat, height: CGFloat) -> NSRect {
        let width = min(width, screenFrame.width)
        if side == .top {
            // The island hangs from the physical top edge, over the menu bar.
            let height = min(height, screenFrame.height)
            return NSRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
        }
        let height = min(height, visibleFrame.height)
        let center = visibleFrame.minY + visibleFrame.height * min(1, max(0, fraction))
        let y = min(max(center - height / 2, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(
            x: side == .right ? screenFrame.maxX - width : screenFrame.minX,
            y: y, width: width, height: height)
    }

    /// `allowsTop` is false off the primary display: the island only hangs from the main screen.
    static func dragged(to point: NSPoint, screenFrame: NSRect, visibleFrame: NSRect, allowsTop: Bool = true) -> Self {
        let fraction = min(1, max(0, (point.y - visibleFrame.minY) / max(1, visibleFrame.height)))
        if allowsTop, point.y >= visibleFrame.maxY - 24, abs(point.x - screenFrame.midX) < screenFrame.width / 4 {
            return Self(side: .top, fraction: fraction, screenFrame: screenFrame, visibleFrame: visibleFrame)
        }
        return Self(
            side: point.x < screenFrame.midX ? .left : .right, fraction: fraction,
            screenFrame: screenFrame, visibleFrame: visibleFrame)
    }
}

/// The camera housing the top island wraps; screens without one get a drawn pill of the same shape.
enum EdgeNotchMetrics {
    static let fallbackWidth: CGFloat = 190

    static func notchSize(for screen: NSScreen) -> CGSize {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: max(0, screen.frame.width - left.width - right.width), height: top)
        }
        return CGSize(width: fallbackWidth, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
    }
}
